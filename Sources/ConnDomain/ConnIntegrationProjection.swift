import Foundation

public struct IntegrationProjection: Equatable, Sendable {
    public private(set) var descriptor: IntegrationDescriptor?
    public private(set) var generation: IntegrationConnectionGeneration?
    public private(set) var freshness: IntegrationFreshness
    public private(set) var inventoryAuthority: InventoryAuthority
    public private(set) var capabilities: IntegrationCapabilities
    public private(set) var throughSequence: UInt64
    public private(set) var sessionsByID: [ConnSessionID: ConnSession]
    public private(set) var attentionByID: [AttentionRequestID: AttentionRequest]
    public private(set) var authoritativeSessionIDs: Set<ConnSessionID>

    public init() {
        descriptor = nil
        generation = nil
        freshness = .stale
        inventoryAuthority = .partial
        capabilities = .init(canMonitor: false)
        throughSequence = 0
        sessionsByID = [:]
        attentionByID = [:]
        authoritativeSessionIDs = []
    }

    public var sessions: [ConnSession] {
        sessionsByID.values.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }

    public var attentionRequests: [AttentionRequest] {
        attentionByID.values.sorted {
            if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
            return $0.id < $1.id
        }
    }

    public func hasCurrentAuthority(for sessionID: ConnSessionID) -> Bool {
        freshness == .live && authoritativeSessionIDs.contains(sessionID)
    }

    public mutating func qualify(
        with snapshot: IntegrationSnapshot,
        bounds: ConnDomainBounds = .default
    ) -> IntegrationReductionResult {
        guard Self.isWellScoped(snapshot) else {
            return .rejected(.wrongIntegrationScope)
        }
        let sessionIDs = snapshot.sessions.map(\.id)
        let requestIDs = snapshot.attentionRequests.map(\.id)
        guard Set(sessionIDs).count == sessionIDs.count,
              Set(requestIDs).count == requestIDs.count else {
            return .rejected(.duplicateIdentity)
        }
        guard snapshot.sessions.allSatisfy(Self.isInternallyConsistent) else {
            return .rejected(.invalidRunReference)
        }
        let incoming = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.id, $0) })
        let candidateSessionIDs: Set<ConnSessionID>
        switch snapshot.inventoryAuthority {
        case .complete:
            candidateSessionIDs = Set(incoming.keys)
        case .partial:
            candidateSessionIDs = Set(sessionsByID.keys).union(incoming.keys)
        }
        guard candidateSessionIDs.count <= bounds.maximumSessionsPerIntegration,
              snapshot.attentionRequests.count
                <= bounds.maximumAttentionRequestsPerIntegration else {
            return .rejected(.boundsExceeded)
        }
        guard snapshot.attentionRequests.allSatisfy({ request in
            let resolvedSession = switch snapshot.inventoryAuthority {
            case .complete:
                incoming[request.sessionID]
            case .partial:
                incoming[request.sessionID] ?? sessionsByID[request.sessionID]
            }
            return candidateSessionIDs.contains(request.sessionID)
                && (request.runID == nil
                    || resolvedSession?.runs.contains(
                        where: { $0.id == request.runID }
                    ) == true)
        }) else {
            return .rejected(.invalidRunReference)
        }

        descriptor = snapshot.integration
        generation = snapshot.generation
        freshness = .live
        inventoryAuthority = snapshot.inventoryAuthority
        capabilities = snapshot.capabilities
        throughSequence = snapshot.throughSequence

        authoritativeSessionIDs = Set(incoming.keys)
        switch snapshot.inventoryAuthority {
        case .complete:
            sessionsByID = incoming
        case .partial:
            sessionsByID.merge(incoming) { _, incoming in incoming }
        }
        attentionByID = Dictionary(
            uniqueKeysWithValues: snapshot.attentionRequests.map { ($0.id, $0) }
        )
        return .qualified
    }

    public mutating func apply(
        _ envelope: IntegrationUpdate,
        bounds: ConnDomainBounds = .default
    ) -> IntegrationReductionResult {
        guard let descriptor, let generation else {
            return .requiresRequalification
        }
        guard envelope.integrationID == descriptor.id,
              envelope.cursor.generation == generation else {
            return .ignoredStaleGeneration
        }
        guard freshness == .live else { return .requiresRequalification }
        guard envelope.cursor.sequence > throughSequence else {
            return .ignoredDuplicate
        }
        guard envelope.cursor.sequence == throughSequence + 1 else {
            freshness = .stale
            capabilities = .init(canMonitor: false)
            authoritativeSessionIDs = []
            return .sequenceGap(
                expected: throughSequence + 1,
                received: envelope.cursor.sequence
            )
        }
        guard Self.isWellScoped(envelope.update, integrationID: descriptor.id) else {
            freshness = .stale
            capabilities = .init(canMonitor: false)
            authoritativeSessionIDs = []
            return .rejected(.wrongIntegrationScope)
        }

        switch envelope.update {
        case let .sessionUpsert(session):
            if sessionsByID[session.id] == nil,
               sessionsByID.count >= bounds.maximumSessionsPerIntegration {
                freshness = .stale
                capabilities = .init(canMonitor: false)
                authoritativeSessionIDs = []
                return .rejected(.boundsExceeded)
            }
            let retainedRunIDs = Set(session.runs.map(\.id))
            attentionByID = attentionByID.filter { _, request in
                request.sessionID != session.id
                    || request.runID.map(retainedRunIDs.contains) ?? true
            }
            sessionsByID[session.id] = session
            authoritativeSessionIDs.insert(session.id)

        case let .sessionRemoved(sessionID):
            sessionsByID.removeValue(forKey: sessionID)
            authoritativeSessionIDs.remove(sessionID)
            attentionByID = attentionByID.filter { $0.value.sessionID != sessionID }

        case let .activityUpsert(sessionID, activity):
            guard let session = sessionsByID[sessionID] else {
                freshness = .stale
                capabilities = .init(canMonitor: false)
                authoritativeSessionIDs = []
                return .rejected(.missingSession)
            }
            guard activity.runID == nil
                    || session.runs.contains(where: { $0.id == activity.runID }) else {
                freshness = .stale
                capabilities = .init(canMonitor: false)
                authoritativeSessionIDs = []
                return .rejected(.invalidRunReference)
            }
            var activities = session.activities.filter { $0.id != activity.id }
            activities.append(activity)
            sessionsByID[sessionID] = ConnSession(
                id: session.id,
                title: session.title,
                workspace: session.workspace,
                origin: session.origin,
                ownership: session.ownership,
                retention: session.retention,
                status: session.status,
                runs: session.runs,
                activities: activities,
                issues: session.issues,
                updatedAt: max(session.updatedAt, envelope.observedAt),
                bounds: bounds
            )

        case let .attentionUpsert(request):
            guard sessionsByID[request.sessionID] != nil else {
                freshness = .stale
                capabilities = .init(canMonitor: false)
                authoritativeSessionIDs = []
                return .rejected(.missingSession)
            }
            guard request.runID == nil
                    || sessionsByID[request.sessionID]?.runs.contains(
                        where: { $0.id == request.runID }
                    ) == true else {
                freshness = .stale
                capabilities = .init(canMonitor: false)
                authoritativeSessionIDs = []
                return .rejected(.invalidRunReference)
            }
            if attentionByID[request.id] == nil,
               attentionByID.count >= bounds.maximumAttentionRequestsPerIntegration {
                freshness = .stale
                capabilities = .init(canMonitor: false)
                authoritativeSessionIDs = []
                return .rejected(.boundsExceeded)
            }
            attentionByID[request.id] = request

        case let .attentionRemoved(sessionID, requestID):
            guard attentionByID[requestID]?.sessionID == sessionID else {
                throughSequence = envelope.cursor.sequence
                return .ignoredMissingEntity
            }
            attentionByID.removeValue(forKey: requestID)

        case let .inventoryAuthorityChanged(authority):
            inventoryAuthority = authority

        case .authorityLost:
            freshness = .stale
            capabilities = .init(canMonitor: false)
            authoritativeSessionIDs = []
        }

        throughSequence = envelope.cursor.sequence
        return .applied
    }

    private static func isWellScoped(_ snapshot: IntegrationSnapshot) -> Bool {
        snapshot.sessions.allSatisfy {
            $0.id.integrationID == snapshot.integration.id
        } && snapshot.attentionRequests.allSatisfy {
            $0.sessionID.integrationID == snapshot.integration.id
        }
    }

    private static func isInternallyConsistent(_ session: ConnSession) -> Bool {
        let runIDs = session.runs.map(\.id)
        let activityIDs = session.activities.map(\.id)
        let issueIDs = session.issues.map(\.id)
        guard Set(runIDs).count == runIDs.count,
              Set(activityIDs).count == activityIDs.count,
              Set(issueIDs).count == issueIDs.count else {
            return false
        }
        let knownRuns = Set(runIDs)
        return session.activities.allSatisfy {
            $0.runID.map(knownRuns.contains) ?? true
        }
    }

    private static func isWellScoped(
        _ update: IntegrationSemanticUpdate,
        integrationID: IntegrationID
    ) -> Bool {
        switch update {
        case let .sessionUpsert(session):
            session.id.integrationID == integrationID
        case let .sessionRemoved(sessionID):
            sessionID.integrationID == integrationID
        case let .activityUpsert(sessionID, _):
            sessionID.integrationID == integrationID
        case let .attentionUpsert(request):
            request.sessionID.integrationID == integrationID
        case let .attentionRemoved(sessionID, _):
            sessionID.integrationID == integrationID
        case .inventoryAuthorityChanged, .authorityLost:
            true
        }
    }
}

public enum IntegrationReductionRejection: Equatable, Sendable {
    case wrongIntegrationScope
    case missingSession
    case invalidRunReference
    case duplicateIdentity
    case boundsExceeded
}

public enum IntegrationReductionResult: Equatable, Sendable {
    case qualified
    case applied
    case ignoredDuplicate
    case ignoredStaleGeneration
    case ignoredMissingEntity
    case requiresRequalification
    case sequenceGap(expected: UInt64, received: UInt64)
    case rejected(IntegrationReductionRejection)
}

// MARK: - Neutral checkpoint validation

public struct PersistedIntegrationProjection: Codable, Equatable, Sendable {
    public let descriptor: IntegrationDescriptor
    public let inventoryAuthority: InventoryAuthority
    public let sessions: [ConnSession]
    public let checkpointedAt: Date

    public init(
        descriptor: IntegrationDescriptor,
        inventoryAuthority: InventoryAuthority,
        sessions: [ConnSession],
        checkpointedAt: Date
    ) {
        self.descriptor = descriptor
        self.inventoryAuthority = inventoryAuthority
        self.sessions = sessions
        self.checkpointedAt = checkpointedAt
    }
}

public struct ConnProjectionCheckpoint: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let integrations: [PersistedIntegrationProjection]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        integrations: [PersistedIntegrationProjection]
    ) {
        self.schemaVersion = schemaVersion
        self.integrations = integrations
    }

    public func validate(bounds: ConnDomainBounds = .default) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ConnProjectionCheckpointError.unsupportedSchemaVersion(schemaVersion)
        }
        var integrationIDs: Set<IntegrationID> = []
        for integration in integrations {
            guard integrationIDs.insert(integration.descriptor.id).inserted else {
                throw ConnProjectionCheckpointError.duplicateIntegration(
                    integration.descriptor.id
                )
            }
            guard integration.sessions.count <= bounds.maximumSessionsPerIntegration else {
                throw ConnProjectionCheckpointError.boundsExceeded
            }
            var sessionIDs: Set<ConnSessionID> = []
            for session in integration.sessions {
                guard session.id.integrationID == integration.descriptor.id else {
                    throw ConnProjectionCheckpointError.wrongIntegrationScope
                }
                guard sessionIDs.insert(session.id).inserted else {
                    throw ConnProjectionCheckpointError.duplicateSession(session.id)
                }
                guard session.runs.count <= bounds.maximumRunsPerSession,
                      session.activities.count <= bounds.maximumActivitiesPerSession,
                      session.issues.count <= bounds.maximumIssuesPerSession else {
                    throw ConnProjectionCheckpointError.boundsExceeded
                }
                let runIDs = session.runs.map(\.id)
                let activityIDs = session.activities.map(\.id)
                let issueIDs = session.issues.map(\.id)
                guard Set(runIDs).count == runIDs.count,
                      Set(activityIDs).count == activityIDs.count,
                      Set(issueIDs).count == issueIDs.count else {
                    throw ConnProjectionCheckpointError.duplicateNestedIdentity
                }
                let knownRuns = Set(runIDs)
                guard session.activities.allSatisfy({
                    $0.runID.map(knownRuns.contains) ?? true
                }) else {
                    throw ConnProjectionCheckpointError.invalidRunReference
                }
            }
        }
    }
}

public enum ConnProjectionCheckpointError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case duplicateIntegration(IntegrationID)
    case duplicateSession(ConnSessionID)
    case wrongIntegrationScope
    case duplicateNestedIdentity
    case invalidRunReference
    case boundsExceeded
}
