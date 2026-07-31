import Foundation
import ConnDomain

public protocol ConnProjectionCheckpointStore: Sendable {
    func load() throws -> ConnProjectionCheckpoint?
    @discardableResult
    func save(_ checkpoint: ConnProjectionCheckpoint) throws -> UInt64
}

public enum ConnIntegrationCoordinatorError: Error, Equatable, Sendable {
    case duplicateIntegration(IntegrationID)
    case checkpointRejected
}

public enum SessionActionUnavailability: String, Equatable, Sendable {
    case unsupported
    case integrationNotLive
    case sessionNotAuthoritative
    case activeRunRequired
    case attentionAuthorityRequired
}

public struct SessionActionAvailability: Equatable, Sendable {
    public let available: Set<ConnActionKind>
    public let unavailable: [ConnActionKind: SessionActionUnavailability]

    public init(
        available: Set<ConnActionKind>,
        unavailable: [ConnActionKind: SessionActionUnavailability]
    ) {
        self.available = available
        self.unavailable = unavailable
    }

    public func supports(_ action: ConnActionKind) -> Bool {
        available.contains(action)
    }
}

public struct ConnAttentionState: Equatable, Identifiable, Sendable {
    public var id: AttentionRequestID { request.id }
    public let request: AttentionRequest
    public let responseAuthority: AttentionResponseAuthority

    public init(
        request: AttentionRequest,
        responseAuthority: AttentionResponseAuthority
    ) {
        self.request = request
        self.responseAuthority = responseAuthority
    }
}

public struct ConnIntegrationState: Equatable, Identifiable, Sendable {
    public var id: IntegrationID { descriptor.id }
    public let descriptor: IntegrationDescriptor
    public let freshness: IntegrationFreshness
    public let inventoryAuthority: InventoryAuthority
    public let capabilities: IntegrationCapabilities
    public let sessionCount: Int

    public init(
        descriptor: IntegrationDescriptor,
        freshness: IntegrationFreshness,
        inventoryAuthority: InventoryAuthority,
        capabilities: IntegrationCapabilities,
        sessionCount: Int
    ) {
        self.descriptor = descriptor
        self.freshness = freshness
        self.inventoryAuthority = inventoryAuthority
        self.capabilities = capabilities
        self.sessionCount = sessionCount
    }
}

public struct ConnSessionState: Equatable, Identifiable, Sendable {
    public var id: ConnSessionID { session.id }
    public let session: ConnSession
    public let integration: IntegrationDescriptor
    public let freshness: IntegrationFreshness
    public let hasCurrentAuthority: Bool
    public let actionAvailability: SessionActionAvailability
    public let attention: [ConnAttentionState]

    public init(
        session: ConnSession,
        integration: IntegrationDescriptor,
        freshness: IntegrationFreshness,
        hasCurrentAuthority: Bool = true,
        actionAvailability: SessionActionAvailability,
        attention: [ConnAttentionState]
    ) {
        self.session = session
        self.integration = integration
        self.freshness = freshness
        self.hasCurrentAuthority = hasCurrentAuthority
        self.actionAvailability = actionAvailability
        self.attention = attention
    }
}

public struct ConnProjectID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct ConnProjectState: Equatable, Identifiable, Sendable {
    public let id: ConnProjectID
    public let workspacePath: String
    public let sessions: [ConnSessionID]

    public init(
        id: ConnProjectID,
        workspacePath: String,
        sessions: [ConnSessionID]
    ) {
        self.id = id
        self.workspacePath = workspacePath
        self.sessions = sessions
    }
}

public enum ConnPersistenceHealth: Equatable, Sendable {
    case notConfigured
    case healthy
    case degraded
}

public struct ConnAggregateSnapshot: Equatable, Sendable {
    public let revision: UInt64
    public let integrations: [ConnIntegrationState]
    public let sessions: [ConnSessionState]
    public let projects: [ConnProjectState]
    public let persistenceHealth: ConnPersistenceHealth

    public init(
        revision: UInt64,
        integrations: [ConnIntegrationState],
        sessions: [ConnSessionState],
        projects: [ConnProjectState],
        persistenceHealth: ConnPersistenceHealth
    ) {
        self.revision = revision
        self.integrations = integrations
        self.sessions = sessions
        self.projects = projects
        self.persistenceHealth = persistenceHealth
    }
}

/// The single aggregation actor for Conn's provider-neutral runtime. Callers
/// learn one interface while connection generation, ordering, isolation,
/// persistence, action routing, and requalification remain local.
public actor ConnIntegrationCoordinator {
    private let integrations: [IntegrationID: any ConnIntegration]
    private let checkpointStore: (any ConnProjectionCheckpointStore)?
    private let bounds: ConnDomainBounds
    private let retryDelay: Duration

    private var enabledIntegrationIDs: Set<IntegrationID>
    private var projections: [IntegrationID: IntegrationProjection] = [:]
    private var supervisionTasks: [IntegrationID: Task<Void, Never>] = [:]
    private var supervisionEpochs: [IntegrationID: UInt64] = [:]
    private var nextSupervisionEpoch: UInt64 = 0
    private var observers: [UUID: AsyncStream<ConnAggregateSnapshot>.Continuation] = [:]
    private var revision: UInt64 = 0
    private var persistenceHealth: ConnPersistenceHealth
    private var started = false

    public init(
        integrations: [any ConnIntegration],
        enabledIntegrationIDs: Set<IntegrationID>? = nil,
        checkpointStore: (any ConnProjectionCheckpointStore)? = nil,
        bounds: ConnDomainBounds = .default,
        retryDelay: Duration = .seconds(1)
    ) throws {
        var integrationsByID: [IntegrationID: any ConnIntegration] = [:]
        for integration in integrations {
            guard integrationsByID[integration.descriptor.id] == nil else {
                throw ConnIntegrationCoordinatorError.duplicateIntegration(
                    integration.descriptor.id
                )
            }
            integrationsByID[integration.descriptor.id] = integration
        }
        self.integrations = integrationsByID
        self.enabledIntegrationIDs = enabledIntegrationIDs.map {
            $0.intersection(integrationsByID.keys)
        } ?? Set(integrationsByID.keys)
        self.checkpointStore = checkpointStore
        self.bounds = bounds
        self.retryDelay = retryDelay
        self.persistenceHealth = checkpointStore == nil ? .notConfigured : .healthy

        var restoredByID: [IntegrationID: PersistedIntegrationProjection] = [:]
        if let checkpointStore, let checkpoint = try checkpointStore.load() {
            do {
                try checkpoint.validate(bounds: bounds)
            } catch {
                throw ConnIntegrationCoordinatorError.checkpointRejected
            }
            restoredByID = Dictionary(
                uniqueKeysWithValues: checkpoint.integrations.map {
                    ($0.descriptor.id, $0)
                }
            )
        }

        for integration in integrations {
            let descriptor = integration.descriptor
            let persisted = restoredByID[descriptor.id] ?? .init(
                descriptor: descriptor,
                inventoryAuthority: .partial,
                sessions: [],
                checkpointedAt: .distantPast
            )
            var projection = IntegrationProjection()
            guard projection.restore(persisted, bounds: bounds) == .restored else {
                throw ConnIntegrationCoordinatorError.checkpointRejected
            }
            projections[descriptor.id] = projection
        }
    }

    deinit {
        for task in supervisionTasks.values {
            task.cancel()
        }
    }

    public func start() {
        guard !started else { return }
        started = true
        for integrationID in enabledIntegrationIDs {
            supervise(integrationID)
        }
        publish()
    }

    public func stop() async {
        started = false
        for task in supervisionTasks.values {
            task.cancel()
        }
        supervisionTasks.removeAll()
        supervisionEpochs.removeAll()
        for integration in integrations.values {
            await integration.disconnect()
        }
        for integrationID in projections.keys {
            projections[integrationID]?.markStale()
        }
        publish()
    }

    public func refresh(_ integrationID: IntegrationID) async {
        guard let integration = integrations[integrationID] else { return }
        supervisionTasks.removeValue(forKey: integrationID)?.cancel()
        supervisionEpochs.removeValue(forKey: integrationID)
        await integration.disconnect()
        projections[integrationID]?.markStale()
        publish()
        if started, enabledIntegrationIDs.contains(integrationID) {
            supervise(integrationID)
        }
    }

    public func isEnabled(_ integrationID: IntegrationID) -> Bool {
        enabledIntegrationIDs.contains(integrationID)
    }

    public func setEnabled(
        _ integrationID: IntegrationID,
        _ enabled: Bool
    ) async {
        guard let integration = integrations[integrationID] else { return }
        if enabled {
            guard enabledIntegrationIDs.insert(integrationID).inserted else {
                return
            }
            publish()
            if started {
                supervise(integrationID)
            }
            return
        }

        guard enabledIntegrationIDs.remove(integrationID) != nil else { return }
        supervisionTasks.removeValue(forKey: integrationID)?.cancel()
        supervisionEpochs.removeValue(forKey: integrationID)
        await integration.disconnect()
        projections[integrationID]?.markStale()
        publish()
    }

    public func snapshot() -> ConnAggregateSnapshot {
        makeSnapshot()
    }

    public func snapshots() -> AsyncStream<ConnAggregateSnapshot> {
        let observerID = UUID()
        let current = makeSnapshot()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[observerID] = continuation
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(observerID) }
            }
        }
    }

    public func perform(_ action: ConnAction) async -> ConnActionOutcome {
        guard enabledIntegrationIDs.contains(action.integrationID),
              let integration = integrations[action.integrationID],
              let projection = projections[action.integrationID] else {
            return unavailable(action, "Integration is not installed")
        }
        guard actionIsAvailable(action, projection: projection) else {
            return unavailable(action, "Current Integration authority is insufficient")
        }
        return await integration.perform(action)
    }

    public func sessionModels(
        for integrationID: IntegrationID,
        sessionID: ConnSessionID? = nil
    ) async -> ConnSessionModelCatalogResult {
        guard enabledIntegrationIDs.contains(integrationID),
              let integration = integrations[integrationID],
              let projection = projections[integrationID],
              projection.freshness == .live else {
            return .init(outcome: .unavailable)
        }
        guard sessionID == nil || sessionID?.integrationID == integrationID else {
            return .init(outcome: .invalidated)
        }
        if let sessionID {
            guard projection.capabilities.supports(.followUp),
                  projection.hasCurrentAuthority(for: sessionID) else {
                return .init(outcome: .unavailable)
            }
        } else {
            guard projection.capabilities.supports(.createSession) else {
                return .init(outcome: .unavailable)
            }
        }
        let result = await integration.sessionModels(for: sessionID)
        guard result.catalog?.integrationID == integrationID || result.catalog == nil else {
            return .init(outcome: .invalidated)
        }
        return result
    }

    public func checkpoint(at date: Date = Date()) -> ConnProjectionCheckpoint {
        makeCheckpoint(at: date)
    }

    private func supervise(_ integrationID: IntegrationID) {
        guard supervisionTasks[integrationID] == nil else { return }
        nextSupervisionEpoch &+= 1
        let epoch = nextSupervisionEpoch
        supervisionEpochs[integrationID] = epoch
        supervisionTasks[integrationID] = Task { [weak self] in
            await self?.runSupervisionLoop(integrationID, epoch: epoch)
        }
    }

    private func runSupervisionLoop(
        _ integrationID: IntegrationID,
        epoch: UInt64
    ) async {
        defer {
            if supervisionEpochs[integrationID] == epoch {
                supervisionTasks[integrationID] = nil
                supervisionEpochs[integrationID] = nil
            }
        }
        guard let integration = integrations[integrationID] else { return }

        while started,
              enabledIntegrationIDs.contains(integrationID),
              supervisionEpochs[integrationID] == epoch,
              !Task.isCancelled {
            do {
                let feed = try await integration.establishFeed()
                guard supervisionEpochs[integrationID] == epoch,
                      !Task.isCancelled else { break }
                guard projections[integrationID]?.qualify(
                    with: feed.snapshot,
                    bounds: bounds
                ) == .qualified else {
                    projections[integrationID]?.markStale()
                    publishAndPersist()
                    try? await Task.sleep(for: retryDelay)
                    continue
                }
                publishAndPersist()

                var requiresRequalification = false
                for await update in feed.updates {
                    if Task.isCancelled || !started
                        || supervisionEpochs[integrationID] != epoch { break }
                    guard update.integrationID == integrationID,
                          var projection = projections[integrationID] else {
                        requiresRequalification = true
                        break
                    }
                    let result = projection.apply(update, bounds: bounds)
                    projections[integrationID] = projection
                    switch result {
                    case .applied:
                        publishAndPersist()
                    case .ignoredMissingEntity:
                        publish()
                    case .ignoredDuplicate, .ignoredStaleGeneration:
                        break
                    case .restored, .qualified:
                        requiresRequalification = true
                    case .requiresRequalification, .sequenceGap, .rejected:
                        requiresRequalification = true
                    }
                    if requiresRequalification { break }
                }
            } catch {
                // Qualification failure is isolated to this Integration.
            }

            if Task.isCancelled || !started
                || !enabledIntegrationIDs.contains(integrationID)
                || supervisionEpochs[integrationID] != epoch { break }
            projections[integrationID]?.markStale()
            publish()
            try? await Task.sleep(for: retryDelay)
        }
    }

    private func actionIsAvailable(
        _ action: ConnAction,
        projection: IntegrationProjection
    ) -> Bool {
        guard projection.freshness == .live,
              projection.capabilities.supports(action.kind) else {
            return false
        }
        switch action {
        case .createSession:
            return true
        case let .followUp(sessionID, _, _):
            return projection.sessionsByID[sessionID] != nil
                && projection.hasCurrentAuthority(for: sessionID)
        case let .steer(sessionID, runID, _),
             let .interrupt(sessionID, runID):
            return projection.hasCurrentAuthority(for: sessionID)
                && projection.sessionsByID[sessionID]?.runs.contains {
                    $0.id == runID && $0.status == .inProgress
                } == true
        case let .answer(sessionID, authority, _):
            return attentionIsCurrent(
                sessionID: sessionID,
                authority: authority,
                kind: .structuredQuestion,
                projection: projection
            )
        case let .resolveApproval(sessionID, authority, _):
            return attentionIsCurrent(
                sessionID: sessionID,
                authority: authority,
                kind: .approval,
                projection: projection
            )
        }
    }

    private func attentionIsCurrent(
        sessionID: ConnSessionID,
        authority: AttentionResponseAuthority,
        kind: AttentionRequestKind,
        projection: IntegrationProjection
    ) -> Bool {
        guard projection.hasCurrentAuthority(for: sessionID),
              authority.generation == projection.generation,
              let request = projection.attentionByID[authority.requestID] else {
            return false
        }
        return request.sessionID == sessionID && request.kind == kind
    }

    private func makeSnapshot() -> ConnAggregateSnapshot {
        var integrationStates: [ConnIntegrationState] = []
        var sessionStates: [ConnSessionState] = []

        for integrationID in projections.keys.sorted() {
            guard enabledIntegrationIDs.contains(integrationID),
                  let projection = projections[integrationID],
                  let descriptor = projection.descriptor else { continue }
            integrationStates.append(.init(
                descriptor: descriptor,
                freshness: projection.freshness,
                inventoryAuthority: projection.inventoryAuthority,
                capabilities: projection.capabilities,
                sessionCount: projection.sessions.count
            ))
            for session in projection.sessions {
                let attention = projection.attentionRequests
                    .filter { $0.sessionID == session.id }
                    .compactMap { request -> ConnAttentionState? in
                        guard let generation = projection.generation else {
                            return nil
                        }
                        return .init(
                            request: request,
                            responseAuthority: .init(
                                requestID: request.id,
                                generation: generation
                            )
                        )
                    }
                sessionStates.append(.init(
                    session: session,
                    integration: descriptor,
                    freshness: projection.freshness,
                    hasCurrentAuthority: projection.hasCurrentAuthority(
                        for: session.id
                    ),
                    actionAvailability: availability(
                        for: session,
                        attention: attention,
                        projection: projection
                    ),
                    attention: attention
                ))
            }
        }
        sessionStates.sort {
            if $0.session.updatedAt != $1.session.updatedAt {
                return $0.session.updatedAt > $1.session.updatedAt
            }
            return $0.id < $1.id
        }
        return .init(
            revision: revision,
            integrations: integrationStates,
            sessions: sessionStates,
            projects: projects(from: sessionStates),
            persistenceHealth: persistenceHealth
        )
    }

    private func availability(
        for session: ConnSession,
        attention: [ConnAttentionState],
        projection: IntegrationProjection
    ) -> SessionActionAvailability {
        var available: Set<ConnActionKind> = []
        var unavailable: [ConnActionKind: SessionActionUnavailability] = [:]
        let hasAuthority = projection.hasCurrentAuthority(for: session.id)
        let hasActiveRun = session.runs.contains { $0.status == .inProgress }
        let attentionKinds = Set(attention.map(\.request.kind))

        for action in ConnActionKind.allCasesForAvailability {
            guard projection.capabilities.supports(action) else {
                unavailable[action] = .unsupported
                continue
            }
            guard projection.freshness == .live else {
                unavailable[action] = .integrationNotLive
                continue
            }
            guard hasAuthority else {
                unavailable[action] = .sessionNotAuthoritative
                continue
            }
            switch action {
            case .steer where !hasActiveRun,
                 .interrupt where !hasActiveRun:
                unavailable[action] = .activeRunRequired
            case .answer where !attentionKinds.contains(.structuredQuestion):
                unavailable[action] = .attentionAuthorityRequired
            case .resolveApproval where !attentionKinds.contains(.approval):
                unavailable[action] = .attentionAuthorityRequired
            case .createSession:
                // Creation is Integration-scoped, not Session-scoped.
                unavailable[action] = .unsupported
            default:
                available.insert(action)
            }
        }
        return .init(available: available, unavailable: unavailable)
    }

    private func projects(from sessions: [ConnSessionState]) -> [ConnProjectState] {
        struct Accumulator {
            var path: String
            var sessionIDs: [ConnSessionID]
        }
        var grouped: [ConnProjectID: Accumulator] = [:]
        for state in sessions {
            guard let workspace = state.session.workspace else { continue }
            let identity = workspace.equivalenceKey.map {
                "equivalent:\($0)"
            } ?? "scoped:\(state.id.integrationID.rawValue):\(workspace.canonicalPath)"
            let projectID = ConnProjectID(rawValue: identity)
            grouped[projectID, default: .init(
                path: workspace.canonicalPath,
                sessionIDs: []
            )].sessionIDs.append(state.id)
        }
        return grouped.map { id, value in
            ConnProjectState(
                id: id,
                workspacePath: value.path,
                sessions: value.sessionIDs
            )
        }.sorted {
            if $0.workspacePath != $1.workspacePath {
                return $0.workspacePath < $1.workspacePath
            }
            return $0.id < $1.id
        }
    }

    private func makeCheckpoint(at date: Date) -> ConnProjectionCheckpoint {
        let persisted: [PersistedIntegrationProjection] =
            projections.keys.sorted().compactMap { integrationID in
            guard let projection = projections[integrationID],
                  let descriptor = projection.descriptor else { return nil }
            return PersistedIntegrationProjection(
                descriptor: descriptor,
                inventoryAuthority: projection.inventoryAuthority,
                sessions: projection.sessions,
                checkpointedAt: date
            )
        }
        return .init(integrations: persisted)
    }

    private func publishAndPersist() {
        if let checkpointStore {
            do {
                _ = try checkpointStore.save(makeCheckpoint(at: Date()))
                persistenceHealth = .healthy
            } catch {
                persistenceHealth = .degraded
            }
        }
        publish()
    }

    private func publish() {
        revision &+= 1
        let value = makeSnapshot()
        for continuation in observers.values {
            continuation.yield(value)
        }
    }

    private func removeObserver(_ observerID: UUID) {
        observers.removeValue(forKey: observerID)
    }

    private func unavailable(_ action: ConnAction, _ evidence: String) -> ConnActionOutcome {
        .init(
            integrationID: action.integrationID,
            action: action.kind,
            kind: .unavailable,
            evidence: evidence
        )
    }
}

private extension ConnActionKind {
    static let allCasesForAvailability: [ConnActionKind] = [
        .createSession,
        .followUp,
        .steer,
        .interrupt,
        .answer,
        .resolveApproval,
    ]
}
