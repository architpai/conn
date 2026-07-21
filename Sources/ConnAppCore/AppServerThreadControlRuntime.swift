import Foundation
import ConnAppServerAdapter
import ConnDomain

package protocol AppServerThreadControlConnection: Sendable {
    func requestEnvelope(
        method: String,
        params: JSONValue?,
        timeout: Duration?
    ) async throws -> ConnAppServerResponseEnvelope
    func respond(to requestID: RequestID, result: JSONValue) async throws
    func controlIdentity() async -> ConnAppServerConnectionIdentity?
}

extension ConnAppServerConnection: AppServerThreadControlConnection {
    package func controlIdentity() async -> ConnAppServerConnectionIdentity? { activeIdentity }
}

public enum AppServerApprovalRoutingPolicy: String, Equatable, Sendable {
    /// The conservative Phase 9 policy. Merely resuming or selecting a thread
    /// never grants Conn authority to race its originating client.
    case connOriginatedTurnsOnly
    /// Available only if a pinned-version two-client qualification proves the
    /// upstream arbitration contract and the product explicitly adopts it.
    case allSubscribedConnectionsQualified
}

public struct AppServerControlExecutionResult: Equatable, Sendable {
    public let outcome: AppServerControlOutcome
    public let acceptedTurnID: AppServerTurnID?
    public let draftRevision: UInt64?

    public init(
        outcome: AppServerControlOutcome,
        acceptedTurnID: AppServerTurnID? = nil,
        draftRevision: UInt64? = nil
    ) {
        self.outcome = outcome
        self.acceptedTurnID = acceptedTurnID
        self.draftRevision = draftRevision
    }
}

public struct AppServerThreadControlAvailability: Equatable, Sendable {
    public let connection: AppServerConnectionIdentity?
    public let routingPolicy: AppServerApprovalRoutingPolicy
    public let responseAuthoritativeTurns: Set<AppServerTurnID>

    public init(
        connection: AppServerConnectionIdentity? = nil,
        routingPolicy: AppServerApprovalRoutingPolicy = .connOriginatedTurnsOnly,
        responseAuthoritativeTurns: Set<AppServerTurnID> = []
    ) {
        self.connection = connection
        self.routingPolicy = routingPolicy
        self.responseAuthoritativeTurns = responseAuthoritativeTurns
    }

    public func mayRespond(to request: AppServerProjectedRequest) -> Bool {
        guard let connection, request.id.connection == connection else { return false }
        switch routingPolicy {
        case .allSubscribedConnectionsQualified:
            switch request.kind {
            case .commandApproval, .fileChangeApproval, .permissionsApproval:
                return true
            case .structuredQuestion, .mcpElicitation, .unknown:
                guard let turnID = request.turnID else { return false }
                return responseAuthoritativeTurns.contains(turnID)
            }
        case .connOriginatedTurnsOnly:
            guard let turnID = request.turnID else { return false }
            return responseAuthoritativeTurns.contains(turnID)
        }
    }
}

public struct AppServerThreadControlConfiguration: Equatable, Sendable {
    public let requestAcknowledgementTimeout: Duration
    public let responseResolutionTimeout: Duration
    public let interruptConfirmationTimeout: Duration
    public let reconciliationTimeout: Duration
    public let routingPolicy: AppServerApprovalRoutingPolicy

    public init(
        requestAcknowledgementTimeout: Duration = .seconds(10),
        responseResolutionTimeout: Duration = .seconds(15),
        interruptConfirmationTimeout: Duration = .seconds(15),
        reconciliationTimeout: Duration = .seconds(5),
        routingPolicy: AppServerApprovalRoutingPolicy = .connOriginatedTurnsOnly
    ) {
        self.requestAcknowledgementTimeout = requestAcknowledgementTimeout
        self.responseResolutionTimeout = responseResolutionTimeout
        self.interruptConfirmationTimeout = interruptConfirmationTimeout
        self.reconciliationTimeout = reconciliationTimeout
        self.routingPolicy = routingPolicy
    }
}

public struct AppServerControlOutcomePresentation: Equatable, Sendable {
    public let error: String?
    public let notice: String?

    public init(error: String?, notice: String?) {
        self.error = error
        self.notice = notice
    }
}

/// Runtime-only user input and completion routing for the control surface.
/// Drafts, answers (including secrets), and outcome copy are deliberately not
/// Codable and are pruned against live scoped request identities.
public struct AppServerThreadControlPresentationState: Sendable {
    private var draftsByThreadID: [String: AppServerControlDraft] = [:]
    private var questionAnswersByRequestID: [AppServerScopedRequestID: [String: [String]]] = [:]
    private var outcomesByThreadID: [String: AppServerControlOutcomePresentation] = [:]
    private var connection: AppServerConnectionIdentity?

    public init() {}

    public func draft(for threadID: String) -> AppServerControlDraft {
        draftsByThreadID[threadID] ?? .init()
    }

    public mutating func updateDraft(_ text: String, threadID: String) {
        var draft = draft(for: threadID)
        draft.update(text)
        draftsByThreadID[threadID] = draft
    }

    public func questionAnswer(
        request: AppServerScopedRequestID,
        questionID: String
    ) -> String {
        questionAnswersByRequestID[request]?[questionID]?.first ?? ""
    }

    public func questionAnswers(
        for request: AppServerScopedRequestID
    ) -> [String: [String]] {
        questionAnswersByRequestID[request] ?? [:]
    }

    public mutating func updateQuestionAnswer(
        _ value: String,
        request: AppServerScopedRequestID,
        questionID: String
    ) {
        var answers = questionAnswersByRequestID[request] ?? [:]
        answers[questionID] = [value]
        questionAnswersByRequestID[request] = answers
    }

    public func outcome(for threadID: String) -> AppServerControlOutcomePresentation? {
        outcomesByThreadID[threadID]
    }

    public mutating func clearOutcome(for threadID: String) {
        outcomesByThreadID.removeValue(forKey: threadID)
    }

    public mutating func applyCompletion(
        intent: AppServerControlIntent,
        result: AppServerControlExecutionResult,
        error: String?,
        notice: String?
    ) {
        let threadID = intent.threadID.rawValue
        if result.outcome == .accepted,
           result.draftRevision != nil,
           var draft = draftsByThreadID[threadID] {
            draft.apply(result)
            draftsByThreadID[threadID] = draft
        }
        if let requestID = intent.answerRequestID,
           result.outcome == .accepted || result.outcome == .resolvedElsewhere {
            questionAnswersByRequestID.removeValue(forKey: requestID)
        }
        outcomesByThreadID[threadID] = .init(error: error, notice: notice)
    }

    public mutating func reconcile(with snapshot: AppServerProjectionSnapshot) {
        if connection != snapshot.connection {
            questionAnswersByRequestID.removeAll(keepingCapacity: true)
        }
        connection = snapshot.connection
        let liveRequestIDs = Set(snapshot.attentionRequests.map(\.id))
        questionAnswersByRequestID = questionAnswersByRequestID.filter {
            liveRequestIDs.contains($0.key)
        }
    }
}

/// Consequential sends live here, outside monitoring hydration/replay. The
/// actor retains only identity keys while an intent is pending; draft text,
/// approval decisions, and answers stay on the executing task stack.
public actor AppServerThreadControlRuntime {
    private struct TimedOutDraft: Sendable {
        let observedActiveTurnIDs: Set<AppServerTurnID>
    }

    private struct BlockedNewThreadAttempt: Sendable {
        let stage: AppServerNewThreadExecutionStage
        let createdThreadID: AppServerThreadID?
    }

    private struct Session: Sendable {
        let runtimeGeneration: UUID
        let wireIdentity: ConnAppServerConnectionIdentity
        let domainIdentity: AppServerDomainCommitIdentity
        let domainConnection: AppServerConnectionIdentity
        let serverVersion: SupportedAppServerVersion
        let mode: AppServerCapabilityMode
        let connection: any AppServerThreadControlConnection
        let coordinator: AppServerDomainCoordinator
    }

    private enum IntentKey: Hashable, Sendable {
        case followUp(AppServerThreadID, UInt64)
        case steer(AppServerThreadID, AppServerTurnID, UInt64)
        case decide(AppServerScopedRequestID)
        case answer(AppServerScopedRequestID)
        case interrupt(AppServerThreadID, AppServerTurnID)
    }

    private let configuration: AppServerThreadControlConfiguration
    private let newThreadPreCommitProbe: (@Sendable () async -> Void)?
    private var session: Session?
    private var selectionGeneration: UInt64 = 0
    private var pendingIntents: Set<IntentKey> = []
    private var timedOutDrafts: [IntentKey: TimedOutDraft] = [:]
    private var connOriginatedTurnIDs: Set<AppServerTurnID> = []
    private var pendingNewThreadRevisions: Set<UInt64> = []
    private var blockedNewThreadAttempts: [UInt64: BlockedNewThreadAttempt] = [:]
    private var createdEmptyThreadLeases: [
        AppServerThreadID: AppServerDomainCommitIdentity
    ] = [:]
    private var createdEmptyThreadLeaseOrder: [AppServerThreadID] = []
    private var uncertainCreatedThreadIntentKeys: Set<IntentKey> = []
    private var uncertainCreatedThreadIntentOrder: [IntentKey] = []
    private var createdThreadUncertaintyOverflowed = false
    private var reservedCreatedEmptyThreadIDs: Set<AppServerThreadID> = []
    private var newThreadModelCatalog: AppServerNewThreadModelCatalog?
    private var modelCatalogLoadGeneration: UInt64 = 0

    private static let modelListPageLimit: Int64 = 100
    private static let maximumModelListPages = 8
    private static let maximumModelOptions = 256
    private static let maximumModelIdentityUTF8Bytes = 512
    private static let maximumModelDisplayNameUTF8Bytes = 256
    private static let maximumModelDescriptionUTF8Bytes = 2_048
    private static let maximumModelCursorUTF8Bytes = 512
    private static let maximumCreatedThreadLeases = 64

    public init(configuration: AppServerThreadControlConfiguration = .init()) {
        self.configuration = configuration
        newThreadPreCommitProbe = nil
    }

    package init(
        configuration: AppServerThreadControlConfiguration = .init(),
        newThreadPreCommitProbe: @escaping @Sendable () async -> Void
    ) {
        self.configuration = configuration
        self.newThreadPreCommitProbe = newThreadPreCommitProbe
    }

    package func attach(
        connection: any AppServerThreadControlConnection,
        wireIdentity: ConnAppServerConnectionIdentity,
        domainConnection: AppServerConnectionIdentity,
        coordinator: AppServerDomainCoordinator,
        serverVersion: SupportedAppServerVersion,
        mode: AppServerCapabilityMode
    ) {
        session = Session(
            runtimeGeneration: UUID(),
            wireIdentity: wireIdentity,
            domainIdentity: .init(connection: domainConnection, coordinator: coordinator),
            domainConnection: domainConnection,
            serverVersion: serverVersion,
            mode: mode,
            connection: connection,
            coordinator: coordinator
        )
        pendingIntents.removeAll(keepingCapacity: true)
        timedOutDrafts.removeAll(keepingCapacity: true)
        connOriginatedTurnIDs.removeAll(keepingCapacity: true)
        pendingNewThreadRevisions.removeAll(keepingCapacity: true)
        createdEmptyThreadLeases.removeAll(keepingCapacity: true)
        createdEmptyThreadLeaseOrder.removeAll(keepingCapacity: true)
        uncertainCreatedThreadIntentKeys.removeAll(keepingCapacity: true)
        uncertainCreatedThreadIntentOrder.removeAll(keepingCapacity: true)
        createdThreadUncertaintyOverflowed = false
        reservedCreatedEmptyThreadIDs.removeAll(keepingCapacity: true)
        newThreadModelCatalog = nil
        modelCatalogLoadGeneration &+= 1
    }

    package func detach(ifWireIdentityMatches wireIdentity: ConnAppServerConnectionIdentity) {
        guard session?.wireIdentity == wireIdentity else { return }
        session = nil
        pendingIntents.removeAll(keepingCapacity: true)
        timedOutDrafts.removeAll(keepingCapacity: true)
        connOriginatedTurnIDs.removeAll(keepingCapacity: true)
        pendingNewThreadRevisions.removeAll(keepingCapacity: true)
        createdEmptyThreadLeases.removeAll(keepingCapacity: true)
        createdEmptyThreadLeaseOrder.removeAll(keepingCapacity: true)
        uncertainCreatedThreadIntentKeys.removeAll(keepingCapacity: true)
        uncertainCreatedThreadIntentOrder.removeAll(keepingCapacity: true)
        createdThreadUncertaintyOverflowed = false
        reservedCreatedEmptyThreadIDs.removeAll(keepingCapacity: true)
        newThreadModelCatalog = nil
        modelCatalogLoadGeneration &+= 1
    }

    public func updateSelectionGeneration(_ generation: UInt64) {
        selectionGeneration = generation
    }

    public func availability() -> AppServerThreadControlAvailability {
        .init(
            connection: session?.domainConnection,
            routingPolicy: configuration.routingPolicy,
            responseAuthoritativeTurns: connOriginatedTurnIDs
        )
    }

    /// Loads the current managed App Server's visible model catalog for New
    /// Chat. The catalog remains runtime-only and is invalidated on every
    /// attach/detach so a reconnect can never inherit an earlier selection.
    public func loadNewThreadModelCatalog() async -> AppServerNewThreadModelCatalogResult {
        // A refresh revokes the earlier catalog immediately. Any failure below
        // therefore disables creation even if the wire identity is unchanged.
        newThreadModelCatalog = nil
        modelCatalogLoadGeneration &+= 1
        let loadGeneration = modelCatalogLoadGeneration
        guard let capturedSession = session else {
            return .init(outcome: .connectionInvalidated)
        }
        let policy = AppServerCompatibilityPolicy(
            version: capturedSession.serverVersion,
            mode: capturedSession.mode
        )
        guard policy.supports(method: "model/list") else {
            return .init(outcome: .unavailable)
        }

        var cursor: String?
        var seenCursors: Set<String> = []
        var options: [AppServerNewThreadModelOption] = []
        var seenModels: Set<String> = []
        var seenOptionIDs: Set<String> = []

        do {
            for pageIndex in 0..<Self.maximumModelListPages {
                guard loadGeneration == modelCatalogLoadGeneration,
                      isCurrentSession(capturedSession) else {
                    return .init(outcome: .connectionInvalidated)
                }
                var params: [String: JSONValue] = [
                    "includeHidden": .bool(false),
                    "limit": .integer(Self.modelListPageLimit),
                ]
                if let cursor {
                    params["cursor"] = .string(cursor)
                }
                let response = try await capturedSession.connection.requestEnvelope(
                    method: "model/list",
                    params: .object(params),
                    timeout: configuration.requestAcknowledgementTimeout
                )
                guard response.connection == capturedSession.wireIdentity else {
                    return .init(outcome: .invalidResponse)
                }
                guard loadGeneration == modelCatalogLoadGeneration,
                      isCurrentSession(capturedSession) else {
                    return .init(outcome: .connectionInvalidated)
                }
                guard let page = decodeModelListPage(response.result) else {
                    return .init(outcome: .invalidResponse)
                }
                for option in page.options {
                    guard seenOptionIDs.insert(option.id).inserted else {
                        return .init(outcome: .invalidResponse)
                    }
                    guard !seenModels.contains(option.model) else { continue }
                    guard options.count < Self.maximumModelOptions else {
                        return .init(outcome: .invalidResponse)
                    }
                    seenModels.insert(option.model)
                    options.append(option)
                }
                guard let nextCursor = page.nextCursor else {
                    guard !options.isEmpty else {
                        return .init(outcome: .unavailable)
                    }
                    let catalog = AppServerNewThreadModelCatalog(
                        connection: capturedSession.domainConnection,
                        options: options
                    )
                    guard loadGeneration == modelCatalogLoadGeneration,
                          isCurrentSession(capturedSession) else {
                        return .init(outcome: .connectionInvalidated)
                    }
                    newThreadModelCatalog = catalog
                    return .init(outcome: .available, catalog: catalog)
                }
                guard pageIndex + 1 < Self.maximumModelListPages,
                      !nextCursor.isEmpty,
                      nextCursor.utf8.count <= Self.maximumModelCursorUTF8Bytes,
                      seenCursors.insert(nextCursor).inserted else {
                    return .init(outcome: .invalidResponse)
                }
                cursor = nextCursor
            }
            return .init(outcome: .invalidResponse)
        } catch is CancellationError {
            return .init(outcome: .connectionInvalidated)
        } catch ConnAppServerConnectionError.staleConnection,
                ConnAppServerConnectionError.notConnected {
            return .init(outcome: .connectionInvalidated)
        } catch {
            return .init(outcome: .unavailable)
        }
    }

    public func execute(
        _ intent: AppServerControlIntent,
        selectionGeneration capturedSelectionGeneration: UInt64
    ) async -> AppServerControlExecutionResult {
        guard let capturedSession = session else {
            return .init(outcome: .connectionInvalidated, draftRevision: intent.draftRevision)
        }
        guard followUpModelIsAllowed(intent, session: capturedSession) else {
            return .init(outcome: .stalePrecondition, draftRevision: intent.draftRevision)
        }
        let key = intentKey(intent)
        if createdThreadUncertaintyOverflowed, case .followUp = intent {
            return .init(outcome: .acknowledgementUncertain, draftRevision: intent.draftRevision)
        }
        guard !uncertainCreatedThreadIntentKeys.contains(key) else {
            return .init(outcome: .acknowledgementUncertain, draftRevision: intent.draftRevision)
        }
        guard pendingIntents.insert(key).inserted else {
            return .init(outcome: .duplicateSuppressed, draftRevision: intent.draftRevision)
        }
        defer { pendingIntents.remove(key) }

        let precondition = controlPrecondition(intent)
        let identity = AppServerControlCommitIdentity(
            domain: capturedSession.domainIdentity,
            runtimeGeneration: capturedSession.runtimeGeneration,
            selectionGeneration: capturedSelectionGeneration,
            threadID: intent.threadID,
            precondition: precondition
        )
        guard isCurrent(identity, session: capturedSession) else {
            return .init(outcome: .connectionInvalidated, draftRevision: intent.draftRevision)
        }
        // Reject a peer first-turn send before the first actor suspension. A
        // later snapshot must never let it outlive the reservation it observed.
        guard !reservedCreatedEmptyThreadIDs.contains(intent.threadID) else {
            return .init(outcome: .duplicateSuppressed, draftRevision: intent.draftRevision)
        }
        let usesCreatedEmptyThreadLease = mayUseCreatedEmptyThreadLease(
            intent,
            session: capturedSession
        )
        let reservedCreatedEmptyThreadLease = usesCreatedEmptyThreadLease
            ? takeCreatedEmptyThreadLease(for: intent.threadID)
            : nil
        if reservedCreatedEmptyThreadLease != nil {
            reservedCreatedEmptyThreadIDs.insert(intent.threadID)
        }
        defer {
            if reservedCreatedEmptyThreadLease != nil {
                reservedCreatedEmptyThreadIDs.remove(intent.threadID)
            }
        }
        let snapshot = await capturedSession.coordinator.snapshot()
        if let timedOutDraft = timedOutDrafts[key] {
            await reconcileTimedOutDraft(
                key,
                intent: intent,
                baseline: timedOutDraft,
                snapshot: snapshot,
                session: capturedSession
            )
            return .init(outcome: .acknowledgementUncertain, draftRevision: intent.draftRevision)
        }
        guard usesCreatedEmptyThreadLease
                || preflight(intent, snapshot: snapshot, session: capturedSession) else {
            return .init(outcome: .stalePrecondition, draftRevision: intent.draftRevision)
        }

        do {
            guard let result = try await AppServerDomainCommitGate.performIfCurrent(
                captured: identity.domain,
                current: { self.currentDomainIdentity(for: identity) },
                commit: { try await self.send(intent, session: capturedSession) }
            ) else {
                if let reservedCreatedEmptyThreadLease,
                   isCurrentSession(capturedSession) {
                    recordCreatedEmptyThreadLease(
                        reservedCreatedEmptyThreadLease,
                        for: intent.threadID
                    )
                }
                return .init(outcome: .connectionInvalidated, draftRevision: intent.draftRevision)
            }
            guard isCurrentSession(capturedSession), identity.domain == session?.domainIdentity else {
                if usesCreatedEmptyThreadLease {
                    recordUncertainCreatedThreadIntent(key)
                }
                return .init(outcome: .connectionInvalidated, draftRevision: intent.draftRevision)
            }
            if usesCreatedEmptyThreadLease, result.outcome != .accepted {
                recordUncertainCreatedThreadIntent(key)
                return .init(
                    outcome: .acknowledgementUncertain,
                    draftRevision: intent.draftRevision
                )
            }
            return result
        } catch is CancellationError {
            if usesCreatedEmptyThreadLease {
                recordUncertainCreatedThreadIntent(key)
                return .init(outcome: .acknowledgementUncertain, draftRevision: intent.draftRevision)
            }
            return .init(outcome: .connectionInvalidated, draftRevision: intent.draftRevision)
        } catch ConnAppServerConnectionError.timedOut {
            if usesCreatedEmptyThreadLease {
                recordUncertainCreatedThreadIntent(key)
            }
            if intent.draftRevision != nil,
               let thread = snapshot.threads.first(where: { $0.id == intent.threadID }) {
                timedOutDrafts[key] = .init(observedActiveTurnIDs: Set(thread.activeTurnIDs))
            }
            return .init(outcome: .acknowledgementTimedOut, draftRevision: intent.draftRevision)
        } catch ConnAppServerConnectionError.staleConnection,
                ConnAppServerConnectionError.notConnected {
            if usesCreatedEmptyThreadLease {
                recordUncertainCreatedThreadIntent(key)
                return .init(outcome: .acknowledgementUncertain, draftRevision: intent.draftRevision)
            }
            return .init(outcome: .connectionInvalidated, draftRevision: intent.draftRevision)
        } catch ConnAppServerConnectionError.unknownServerRequest {
            if let reservedCreatedEmptyThreadLease,
               isCurrentSession(capturedSession) {
                recordCreatedEmptyThreadLease(
                    reservedCreatedEmptyThreadLease,
                    for: intent.threadID
                )
            }
            let current = await capturedSession.coordinator.snapshot()
            return .init(
                outcome: containsRequest(for: intent, in: current) ? .stalePrecondition : .resolvedElsewhere,
                draftRevision: intent.draftRevision
            )
        } catch ConnAppServerConnectionError.server {
            if let reservedCreatedEmptyThreadLease,
               isCurrentSession(capturedSession) {
                recordCreatedEmptyThreadLease(
                    reservedCreatedEmptyThreadLease,
                    for: intent.threadID
                )
            }
            let stale = await reconcileStalePrecondition(intent, session: capturedSession)
            return .init(
                outcome: stale ? .stalePrecondition : .rejected,
                draftRevision: intent.draftRevision
            )
        } catch {
            if usesCreatedEmptyThreadLease {
                recordUncertainCreatedThreadIntent(key)
                return .init(outcome: .acknowledgementUncertain, draftRevision: intent.draftRevision)
            }
            return .init(outcome: .rejected, draftRevision: intent.draftRevision)
        }
    }

    public func executeNewThread(
        _ intent: AppServerNewThreadIntent
    ) async -> AppServerNewThreadExecutionResult {
        let revision = intent.draftRevision
        let isQuickStart = intent.initialPrompt.isEmpty
            && intent.modelID.isEmpty
            && intent.model.isEmpty
        if let blocked = blockedNewThreadAttempts[revision] {
            return .init(
                outcome: .acknowledgementUncertain,
                stage: blocked.stage,
                createdThreadID: blocked.createdThreadID,
                draftRevision: revision
            )
        }
        guard pendingNewThreadRevisions.insert(revision).inserted else {
            return .init(
                outcome: .duplicateSuppressed,
                stage: .threadStart,
                draftRevision: revision
            )
        }
        defer { pendingNewThreadRevisions.remove(revision) }
        guard let capturedSession = session else {
            return .init(
                outcome: .connectionInvalidated,
                stage: .threadStart,
                draftRevision: revision
            )
        }
        let capturedModelCatalogGeneration = modelCatalogLoadGeneration
        let hasCurrentModelAuthority = isQuickStart || (
            newThreadModelCatalog?.connection == capturedSession.domainConnection
                && newThreadModelCatalog?.options.contains(where: {
                    $0.id == intent.modelID && $0.model == intent.model
                }) == true
        )
        guard hasCurrentModelAuthority,
              let normalized = validatedNewThreadInput(intent, permitsEmptyPrompt: isQuickStart),
              await mayCreateThread(session: capturedSession) else {
            return .init(
                outcome: .stalePrecondition,
                stage: .threadStart,
                draftRevision: revision
            )
        }
        if let newThreadPreCommitProbe {
            await newThreadPreCommitProbe()
        }
        guard isQuickStart
                ? isCurrentSession(capturedSession)
                : isCurrentNewThreadModelAuthority(
                    generation: capturedModelCatalogGeneration,
                    intent: intent,
                    session: capturedSession
                ) else {
            return .init(
                outcome: isCurrentSession(capturedSession)
                    ? .stalePrecondition
                    : .connectionInvalidated,
                stage: .threadStart,
                draftRevision: revision
            )
        }

        var stage = AppServerNewThreadExecutionStage.threadStart
        var createdThreadID: AppServerThreadID?
        do {
            guard let threadResponse = try await AppServerDomainCommitGate.performIfCurrent(
                captured: capturedSession.domainIdentity,
                current: {
                    guard isQuickStart
                            ? self.isCurrentSession(capturedSession)
                            : self.isCurrentNewThreadModelAuthority(
                                generation: capturedModelCatalogGeneration,
                                intent: intent,
                                session: capturedSession
                            ) else { return nil }
                    return self.currentCreationDomainIdentity(for: capturedSession)
                },
                commit: {
                    var params: [String: JSONValue] = [
                        "cwd": .string(normalized.workingDirectory),
                        "ephemeral": .bool(true),
                    ]
                    if !isQuickStart {
                        params["model"] = .string(normalized.model)
                    }
                    return try await capturedSession.connection.requestEnvelope(
                        method: "thread/start",
                        params: .object(params),
                        timeout: self.configuration.requestAcknowledgementTimeout
                    )
                }
            ) else {
                return .init(
                    outcome: isCurrentSession(capturedSession)
                        ? .stalePrecondition
                        : .connectionInvalidated,
                    stage: stage,
                    draftRevision: revision
                )
            }
            guard threadResponse.connection == capturedSession.wireIdentity,
                  let threadID = nestedThreadID(threadResponse.result) else {
                // A response was received, but Conn cannot prove which thread
                // was allocated. Treat the consequential acknowledgement as
                // uncertain so the unchanged draft can never create a duplicate.
                blockNewThreadAttempt(revision, stage: stage, threadID: nil)
                return .init(
                    outcome: .acknowledgementUncertain,
                    stage: stage,
                    draftRevision: revision
                )
            }
            createdThreadID = threadID
            if isQuickStart {
                guard isCurrentSession(capturedSession) else {
                    blockNewThreadAttempt(revision, stage: stage, threadID: threadID)
                    return .init(
                        outcome: .connectionInvalidated,
                        stage: stage,
                        createdThreadID: threadID,
                        draftRevision: revision
                    )
                }
                blockedNewThreadAttempts.removeValue(forKey: revision)
                recordCreatedEmptyThreadLease(
                    capturedSession.domainIdentity,
                    for: threadID
                )
                return .init(
                    outcome: .accepted,
                    stage: .threadStart,
                    createdThreadID: threadID,
                    draftRevision: revision
                )
            }
            stage = .initialTurn
            guard isCurrentSession(capturedSession) else {
                blockNewThreadAttempt(revision, stage: stage, threadID: threadID)
                return .init(
                    outcome: .connectionInvalidated,
                    stage: stage,
                    createdThreadID: threadID,
                    draftRevision: revision
                )
            }

            let turnResponse = try await capturedSession.connection.requestEnvelope(
                method: "turn/start",
                params: messageParams(
                    threadID: threadID,
                    text: normalized.initialPrompt,
                    expectedTurnID: nil
                ),
                timeout: configuration.requestAcknowledgementTimeout
            )
            guard turnResponse.connection == capturedSession.wireIdentity,
                  let turnID = nestedTurnID(turnResponse.result) else {
                blockNewThreadAttempt(revision, stage: stage, threadID: threadID)
                return .init(
                    outcome: .acknowledgementUncertain,
                    stage: stage,
                    createdThreadID: threadID,
                    draftRevision: revision
                )
            }
            guard isCurrentSession(capturedSession) else {
                blockNewThreadAttempt(revision, stage: stage, threadID: threadID)
                return .init(
                    outcome: .connectionInvalidated,
                    stage: stage,
                    createdThreadID: threadID,
                    acceptedTurnID: turnID,
                    draftRevision: revision
                )
            }
            connOriginatedTurnIDs.insert(turnID)
            blockedNewThreadAttempts.removeValue(forKey: revision)
            return .init(
                outcome: .accepted,
                stage: stage,
                createdThreadID: threadID,
                acceptedTurnID: turnID,
                draftRevision: revision
            )
        } catch is CancellationError {
            blockNewThreadAttempt(revision, stage: stage, threadID: createdThreadID)
            return .init(
                outcome: .connectionInvalidated,
                stage: stage,
                createdThreadID: createdThreadID,
                draftRevision: revision
            )
        } catch ConnAppServerConnectionError.timedOut {
            blockNewThreadAttempt(revision, stage: stage, threadID: createdThreadID)
            return .init(
                outcome: .acknowledgementTimedOut,
                stage: stage,
                createdThreadID: createdThreadID,
                draftRevision: revision
            )
        } catch ConnAppServerConnectionError.staleConnection,
                ConnAppServerConnectionError.notConnected {
            blockNewThreadAttempt(revision, stage: stage, threadID: createdThreadID)
            return .init(
                outcome: .connectionInvalidated,
                stage: stage,
                createdThreadID: createdThreadID,
                draftRevision: revision
            )
        } catch ConnAppServerConnectionError.server {
            // A server error is a definite rejection. Once thread/start has
            // succeeded, however, the exact draft must remain locked so a retry
            // cannot allocate a second thread for the same user intent.
            if stage == .initialTurn {
                blockNewThreadAttempt(revision, stage: stage, threadID: createdThreadID)
            }
            return .init(
                outcome: .rejected,
                stage: stage,
                createdThreadID: createdThreadID,
                draftRevision: revision
            )
        } catch {
            // Transport failure and invalid response can both occur after the
            // consequential send. Without a definite server rejection, refuse
            // the unchanged revision even when thread identity is unavailable.
            blockNewThreadAttempt(revision, stage: stage, threadID: createdThreadID)
            return .init(
                outcome: .acknowledgementUncertain,
                stage: stage,
                createdThreadID: createdThreadID,
                draftRevision: revision
            )
        }
    }

    /// Returns the accepted creation and its still-current domain connection
    /// from one actor-isolated operation so callers cannot bind an old thread
    /// acknowledgement to authority observed after a reconnect.
    package func executeNewThreadWithConnection(
        _ intent: AppServerNewThreadIntent
    ) async -> (
        result: AppServerNewThreadExecutionResult,
        connection: AppServerConnectionIdentity?
    ) {
        let result = await executeNewThread(intent)
        let connection = result.outcome == .accepted ? session?.domainConnection : nil
        return (result, connection)
    }

    package func recordUncertainCreatedThreadIntentForTesting(
        threadID: AppServerThreadID,
        draftRevision: UInt64
    ) {
        recordUncertainCreatedThreadIntent(
            .followUp(threadID, draftRevision)
        )
    }

    private func send(
        _ intent: AppServerControlIntent,
        session capturedSession: Session
    ) async throws -> AppServerControlExecutionResult {
        guard isCurrentSession(capturedSession) else {
            return .init(outcome: .connectionInvalidated, draftRevision: intent.draftRevision)
        }
        switch intent {
        case let .followUp(threadID, text, model, revision):
            let response = try await capturedSession.connection.requestEnvelope(
                method: "turn/start",
                params: messageParams(
                    threadID: threadID,
                    text: text,
                    expectedTurnID: nil,
                    model: model
                ),
                timeout: configuration.requestAcknowledgementTimeout
            )
            guard response.connection == capturedSession.wireIdentity,
                  let turnID = nestedTurnID(response.result) else {
                return .init(outcome: .rejected, draftRevision: revision)
            }
            guard isCurrentSession(capturedSession) else {
                return .init(outcome: .connectionInvalidated, draftRevision: revision)
            }
            connOriginatedTurnIDs.insert(turnID)
            return .init(outcome: .accepted, acceptedTurnID: turnID, draftRevision: revision)

        case let .steer(threadID, expectedTurnID, text, revision):
            let response = try await capturedSession.connection.requestEnvelope(
                method: "turn/steer",
                params: messageParams(
                    threadID: threadID,
                    text: text,
                    expectedTurnID: expectedTurnID
                ),
                timeout: configuration.requestAcknowledgementTimeout
            )
            guard response.connection == capturedSession.wireIdentity,
                  response.result.objectValue?["turnId"]?.stringValue == expectedTurnID.rawValue
            else { return .init(outcome: .stalePrecondition, draftRevision: revision) }
            return .init(outcome: .accepted, acceptedTurnID: expectedTurnID, draftRevision: revision)

        case let .decide(requestID, _, _, choice):
            guard let request = projectedRequest(requestID, in: await capturedSession.coordinator.snapshot()),
                  mayRespond(to: request) else {
                return .init(outcome: .resolvedElsewhere)
            }
            let result = try AppServerControlResponseEncoder.approvalResult(
                for: request,
                choice: choice
            )
            guard isCurrentSession(capturedSession),
                  await capturedSession.connection.controlIdentity() == capturedSession.wireIdentity,
                  isCurrentSession(capturedSession) else {
                return .init(outcome: .connectionInvalidated)
            }
            try await capturedSession.connection.respond(
                to: wireRequestID(requestID.requestID),
                result: result
            )
            return await awaitRequestResolution(requestID, session: capturedSession)

        case let .answer(requestID, _, _, answers):
            guard let request = projectedRequest(requestID, in: await capturedSession.coordinator.snapshot()),
                  mayRespond(to: request) else {
                return .init(outcome: .resolvedElsewhere)
            }
            let result = try AppServerControlResponseEncoder.questionResult(
                for: request,
                answers: answers
            )
            guard isCurrentSession(capturedSession),
                  await capturedSession.connection.controlIdentity() == capturedSession.wireIdentity,
                  isCurrentSession(capturedSession) else {
                return .init(outcome: .connectionInvalidated)
            }
            try await capturedSession.connection.respond(
                to: wireRequestID(requestID.requestID),
                result: result
            )
            return await awaitRequestResolution(requestID, session: capturedSession)

        case let .interrupt(threadID, expectedTurnID):
            let response = try await capturedSession.connection.requestEnvelope(
                method: "turn/interrupt",
                params: .object([
                    "threadId": .string(threadID.rawValue),
                    // The stable wire schema calls this `turnId`; the captured
                    // value remains Conn's expected-turn precondition.
                    "turnId": .string(expectedTurnID.rawValue),
                ]),
                timeout: configuration.requestAcknowledgementTimeout
            )
            guard response.connection == capturedSession.wireIdentity,
                  response.result.objectValue != nil else {
                return .init(outcome: .rejected)
            }
            return await confirmInterrupt(
                threadID: threadID,
                turnID: expectedTurnID,
                session: capturedSession
            )
        }
    }

    private func confirmInterrupt(
        threadID: AppServerThreadID,
        turnID: AppServerTurnID,
        session capturedSession: Session
    ) async -> AppServerControlExecutionResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: configuration.interruptConfirmationTimeout)
        while clock.now < deadline {
            guard isCurrentSession(capturedSession) else {
                return .init(outcome: .connectionInvalidated)
            }
            do {
                let response = try await readThread(
                    threadID,
                    session: capturedSession,
                    timeout: min(
                        configuration.reconciliationTimeout,
                        clock.now.duration(to: deadline)
                    )
                )
                if terminalTurn(turnID, inThreadReadResult: response.result) {
                    return .init(outcome: .accepted, acceptedTurnID: turnID)
                }
            } catch ConnAppServerConnectionError.timedOut {
                break
            } catch {
                return .init(outcome: .terminalStateUnconfirmed)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return .init(outcome: .terminalStateUnconfirmed)
    }

    private func awaitRequestResolution(
        _ requestID: AppServerScopedRequestID,
        session capturedSession: Session
    ) async -> AppServerControlExecutionResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: configuration.responseResolutionTimeout)
        while clock.now < deadline {
            guard isCurrentSession(capturedSession) else {
                return .init(outcome: .connectionInvalidated)
            }
            let snapshot = await capturedSession.coordinator.snapshot()
            if projectedRequest(requestID, in: snapshot) == nil {
                return .init(outcome: .accepted)
            }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return .init(outcome: .connectionInvalidated)
            }
        }
        return .init(outcome: .acknowledgementTimedOut)
    }

    private func reconcileStalePrecondition(
        _ intent: AppServerControlIntent,
        session capturedSession: Session
    ) async -> Bool {
        guard intent.expectedTurnID != nil else { return false }
        do {
            let response = try await readThread(
                intent.threadID,
                session: capturedSession,
                timeout: configuration.reconciliationTimeout
            )
            guard let expected = intent.expectedTurnID else { return false }
            return !inProgressTurn(expected, inThreadReadResult: response.result)
        } catch {
            return false
        }
    }

    private func reconcileTimedOutDraft(
        _ key: IntentKey,
        intent: AppServerControlIntent,
        baseline: TimedOutDraft,
        snapshot: AppServerProjectionSnapshot,
        session capturedSession: Session
    ) async {
        guard let thread = snapshot.threads.first(where: { $0.id == intent.threadID }) else {
            return
        }
        guard Set(thread.activeTurnIDs) == baseline.observedActiveTurnIDs else {
            timedOutDrafts.removeValue(forKey: key)
            return
        }
        do {
            let response = try await readThread(
                intent.threadID,
                session: capturedSession,
                timeout: configuration.reconciliationTimeout
            )
            guard response.connection == capturedSession.wireIdentity,
                  confirmedThreadState(
                      inThreadReadResult: response.result,
                      expectedThreadID: intent.threadID
                  ) != nil else { return }
            timedOutDrafts.removeValue(forKey: key)
        } catch {
            // Keep the exact identity cooling down until a later bounded read
            // or projection fact closes the late-acceptance window.
        }
    }

    private func readThread(
        _ threadID: AppServerThreadID,
        session capturedSession: Session,
        timeout: Duration
    ) async throws -> ConnAppServerResponseEnvelope {
        try await capturedSession.connection.requestEnvelope(
            method: "thread/read",
            params: .object([
                "threadId": .string(threadID.rawValue),
                "includeTurns": .bool(true),
            ]),
            timeout: timeout
        )
    }

    private func mayCreateThread(session capturedSession: Session) async -> Bool {
        guard isCurrentSession(capturedSession) else { return false }
        let snapshot = await capturedSession.coordinator.snapshot()
        let policy = AppServerCompatibilityPolicy(
            version: capturedSession.serverVersion,
            mode: capturedSession.mode
        )
        return snapshot.connection == capturedSession.domainConnection
            && snapshot.featureSupport.supports(.createThread)
            && snapshot.featureSupport.supports(.followUp)
            && policy.supports(method: "thread/start")
            && policy.supports(method: "turn/start")
    }

    private func currentCreationDomainIdentity(
        for capturedSession: Session
    ) -> AppServerDomainCommitIdentity? {
        guard isCurrentSession(capturedSession) else { return nil }
        return session?.domainIdentity
    }

    private func isCurrentNewThreadModelAuthority(
        generation: UInt64,
        intent: AppServerNewThreadIntent,
        session capturedSession: Session
    ) -> Bool {
        guard generation == modelCatalogLoadGeneration,
              isCurrentSession(capturedSession),
              let catalog = newThreadModelCatalog,
              catalog.connection == capturedSession.domainConnection else { return false }
        return catalog.options.contains {
            $0.id == intent.modelID && $0.model == intent.model
        }
    }

    private func validatedNewThreadInput(
        _ intent: AppServerNewThreadIntent,
        permitsEmptyPrompt: Bool = false
    ) -> (workingDirectory: String, initialPrompt: String, model: String)? {
        let rawDirectory = intent.workingDirectory.trimmingCharacters(in: .whitespaces)
        let prompt = intent.initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NSString(string: rawDirectory).isAbsolutePath,
              !rawDirectory.unicodeScalars.contains(where: Self.isLineSeparator),
              rawDirectory.utf8.count <= 4_096,
              (permitsEmptyPrompt || !prompt.isEmpty),
              prompt.utf8.count <= 16 * 1_024,
              (permitsEmptyPrompt || !intent.model.isEmpty),
              intent.model.utf8.count <= Self.maximumModelIdentityUTF8Bytes,
              !intent.model.unicodeScalars.contains(where: Self.isLineSeparator) else { return nil }
        let directory = URL(fileURLWithPath: rawDirectory).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return (directory, prompt, intent.model)
    }

    private func decodeModelListPage(
        _ result: JSONValue
    ) -> (options: [AppServerNewThreadModelOption], nextCursor: String?)? {
        guard let object = result.objectValue,
              let rows = object["data"]?.arrayValue,
              rows.count <= Self.maximumModelOptions else { return nil }
        var options: [AppServerNewThreadModelOption] = []
        options.reserveCapacity(rows.count)
        for encodedRow in rows {
            guard let row = encodedRow.objectValue,
                  let id = row["id"]?.stringValue,
                  let model = row["model"]?.stringValue,
                  let displayName = row["displayName"]?.stringValue,
                  let description = row["description"]?.stringValue,
                  let hidden = row["hidden"]?.boolValue,
                  let isDefault = row["isDefault"]?.boolValue,
                  row["defaultReasoningEffort"]?.stringValue != nil,
                  row["supportedReasoningEfforts"]?.arrayValue != nil,
                  !id.isEmpty,
                  !model.isEmpty,
                  !displayName.isEmpty,
                  id.utf8.count <= Self.maximumModelIdentityUTF8Bytes,
                  model.utf8.count <= Self.maximumModelIdentityUTF8Bytes,
                  displayName.utf8.count <= Self.maximumModelDisplayNameUTF8Bytes,
                  description.utf8.count <= Self.maximumModelDescriptionUTF8Bytes,
                  !id.unicodeScalars.contains(where: Self.isLineSeparator),
                  !model.unicodeScalars.contains(where: Self.isLineSeparator),
                  !displayName.unicodeScalars.contains(where: Self.isLineSeparator)
            else { return nil }
            guard !hidden else { continue }
            options.append(.init(
                id: id,
                model: model,
                displayName: displayName,
                detail: description,
                isDefault: isDefault
            ))
        }

        let nextCursor: String?
        if let encodedCursor = object["nextCursor"] {
            switch encodedCursor {
            case .null:
                nextCursor = nil
            case let .string(value):
                nextCursor = value
            default:
                return nil
            }
        } else {
            nextCursor = nil
        }
        return (options, nextCursor)
    }

    private static func isLineSeparator(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x0D, 0x85, 0x2028, 0x2029: true
        default: false
        }
    }

    private func blockNewThreadAttempt(
        _ revision: UInt64,
        stage: AppServerNewThreadExecutionStage,
        threadID: AppServerThreadID?
    ) {
        blockedNewThreadAttempts[revision] = .init(
            stage: stage,
            createdThreadID: threadID
        )
        while blockedNewThreadAttempts.count > 64,
              let oldest = blockedNewThreadAttempts.keys.min() {
            blockedNewThreadAttempts.removeValue(forKey: oldest)
        }
    }

    private func preflight(
        _ intent: AppServerControlIntent,
        snapshot: AppServerProjectionSnapshot,
        session capturedSession: Session
    ) -> Bool {
        guard snapshot.connection == session?.domainConnection,
              let thread = snapshot.threads.first(where: { $0.id == intent.threadID }),
              thread.freshness == .live else { return false }
        let policy = AppServerCompatibilityPolicy(
            version: capturedSession.serverVersion,
            mode: capturedSession.mode
        )
        switch intent {
        case .followUp:
            return policy.supports(method: "turn/start")
                && snapshot.featureSupport.supports(.followUp)
                && thread.status == .idle
                && thread.activeTurnIDs.isEmpty
        case let .steer(_, expectedTurnID, _, _):
            return policy.supports(method: "turn/steer")
                && snapshot.featureSupport.supports(.steer)
                && thread.activeTurnIDs == [expectedTurnID]
        case let .decide(request, _, turnID, _):
            return snapshot.featureSupport.supports(.resolveApproval)
                && thread.requests.contains {
                    $0.id == request
                        && $0.turnID == turnID
                        && responseMethod(for: $0.kind).map(policy.supportsServerResponse(method:)) == true
                }
        case let .answer(request, _, turnID, _):
            return snapshot.featureSupport.supports(.answer)
                && thread.requests.contains {
                    $0.id == request
                        && $0.turnID == turnID
                        && responseMethod(for: $0.kind).map(policy.supportsServerResponse(method:)) == true
                }
        case let .interrupt(_, expectedTurnID):
            return policy.supports(method: "turn/interrupt")
                && snapshot.featureSupport.supports(.stopTurn)
                && thread.activeTurnIDs == [expectedTurnID]
        }
    }

    private func followUpModelIsAllowed(
        _ intent: AppServerControlIntent,
        session capturedSession: Session
    ) -> Bool {
        guard case let .followUp(_, _, model, _) = intent, let model else { return true }
        return newThreadModelCatalog?.connection == capturedSession.domainConnection
            && newThreadModelCatalog?.options.contains(where: { $0.model == model }) == true
    }

    private func mayUseCreatedEmptyThreadLease(
        _ intent: AppServerControlIntent,
        session capturedSession: Session
    ) -> Bool {
        guard case .followUp = intent,
              createdEmptyThreadLeases[intent.threadID] == capturedSession.domainIdentity,
              capturedSession.domainIdentity == session?.domainIdentity else { return false }
        return AppServerCompatibilityPolicy(
            version: capturedSession.serverVersion,
            mode: capturedSession.mode
        ).supports(method: "turn/start")
    }

    private func recordCreatedEmptyThreadLease(
        _ identity: AppServerDomainCommitIdentity,
        for threadID: AppServerThreadID
    ) {
        createdEmptyThreadLeases[threadID] = identity
        createdEmptyThreadLeaseOrder.removeAll { $0 == threadID }
        createdEmptyThreadLeaseOrder.append(threadID)
        while createdEmptyThreadLeaseOrder.count > Self.maximumCreatedThreadLeases {
            createdEmptyThreadLeases.removeValue(
                forKey: createdEmptyThreadLeaseOrder.removeFirst()
            )
        }
    }

    private func takeCreatedEmptyThreadLease(
        for threadID: AppServerThreadID
    ) -> AppServerDomainCommitIdentity? {
        createdEmptyThreadLeaseOrder.removeAll { $0 == threadID }
        return createdEmptyThreadLeases.removeValue(forKey: threadID)
    }

    private func recordUncertainCreatedThreadIntent(_ key: IntentKey) {
        guard !createdThreadUncertaintyOverflowed else { return }
        if !uncertainCreatedThreadIntentKeys.contains(key),
           uncertainCreatedThreadIntentKeys.count >= Self.maximumCreatedThreadLeases {
            // Never forget an uncertain consequential send. Once the bounded
            // ledger fills, fail every follow-up closed for this session.
            createdThreadUncertaintyOverflowed = true
            uncertainCreatedThreadIntentKeys.removeAll(keepingCapacity: true)
            uncertainCreatedThreadIntentOrder.removeAll(keepingCapacity: true)
            return
        }
        uncertainCreatedThreadIntentKeys.insert(key)
        uncertainCreatedThreadIntentOrder.removeAll { $0 == key }
        uncertainCreatedThreadIntentOrder.append(key)
    }

    private func responseMethod(for kind: AppServerRequestKind) -> String? {
        switch kind {
        case .commandApproval: "item/commandExecution/requestApproval"
        case .fileChangeApproval: "item/fileChange/requestApproval"
        case .permissionsApproval: "item/permissions/requestApproval"
        case .structuredQuestion: "item/tool/requestUserInput"
        case .mcpElicitation, .unknown: nil
        }
    }

    private func isCurrent(
        _ identity: AppServerControlCommitIdentity,
        session capturedSession: Session
    ) -> Bool {
        identity.selectionGeneration == selectionGeneration
            && identity.runtimeGeneration == session?.runtimeGeneration
            && identity.domain == session?.domainIdentity
            && capturedSession.runtimeGeneration == session?.runtimeGeneration
    }

    private func currentDomainIdentity(
        for identity: AppServerControlCommitIdentity
    ) -> AppServerDomainCommitIdentity? {
        guard identity.selectionGeneration == selectionGeneration,
              identity.runtimeGeneration == session?.runtimeGeneration else { return nil }
        return session?.domainIdentity
    }

    private func isCurrentSession(_ capturedSession: Session) -> Bool {
        guard capturedSession.runtimeGeneration == session?.runtimeGeneration,
              capturedSession.domainIdentity == session?.domainIdentity else { return false }
        return true
    }

    private func mayRespond(to request: AppServerProjectedRequest) -> Bool {
        switch configuration.routingPolicy {
        case .allSubscribedConnectionsQualified:
            switch request.kind {
            case .commandApproval, .fileChangeApproval, .permissionsApproval:
                return true
            case .structuredQuestion, .mcpElicitation, .unknown:
                guard let turnID = request.turnID else { return false }
                return connOriginatedTurnIDs.contains(turnID)
            }
        case .connOriginatedTurnsOnly:
            guard let turnID = request.turnID else { return false }
            return connOriginatedTurnIDs.contains(turnID)
        }
    }

    private func containsRequest(
        for intent: AppServerControlIntent,
        in snapshot: AppServerProjectionSnapshot
    ) -> Bool {
        guard let requestID = intent.requestID else { return false }
        return projectedRequest(requestID, in: snapshot) != nil
    }

    private func projectedRequest(
        _ requestID: AppServerScopedRequestID,
        in snapshot: AppServerProjectionSnapshot
    ) -> AppServerProjectedRequest? {
        snapshot.threads.lazy.flatMap(\.requests).first { $0.id == requestID }
    }

    private func intentKey(_ intent: AppServerControlIntent) -> IntentKey {
        switch intent {
        case let .followUp(threadID, _, _, revision): .followUp(threadID, revision)
        case let .steer(threadID, turnID, _, revision): .steer(threadID, turnID, revision)
        case let .decide(request, _, _, _): .decide(request)
        case let .answer(request, _, _, _): .answer(request)
        case let .interrupt(threadID, turnID): .interrupt(threadID, turnID)
        }
    }

    private func controlPrecondition(_ intent: AppServerControlIntent) -> AppServerControlPrecondition {
        switch intent {
        case .followUp: .idle
        case let .steer(_, turnID, _, _), let .interrupt(_, turnID): .activeTurn(turnID)
        case let .decide(request, _, turnID, _), let .answer(request, _, turnID, _):
            .serverRequest(request, turnID: turnID)
        }
    }

    private func messageParams(
        threadID: AppServerThreadID,
        text: String,
        expectedTurnID: AppServerTurnID?,
        model: String? = nil
    ) -> JSONValue {
        var params: [String: JSONValue] = [
            "threadId": .string(threadID.rawValue),
            "input": .array([.object([
                "type": .string("text"),
                "text": .string(text),
            ])]),
        ]
        if let expectedTurnID {
            params["expectedTurnId"] = .string(expectedTurnID.rawValue)
        }
        if let model {
            params["model"] = .string(model)
        }
        return .object(params)
    }

    private func nestedTurnID(_ result: JSONValue) -> AppServerTurnID? {
        guard let raw = result.objectValue?["turn"]?.objectValue?["id"]?.stringValue,
              !raw.isEmpty,
              raw.utf8.count <= 512 else { return nil }
        return .init(rawValue: raw)
    }

    private func nestedThreadID(_ result: JSONValue) -> AppServerThreadID? {
        guard let raw = result.objectValue?["thread"]?.objectValue?["id"]?.stringValue,
              !raw.isEmpty,
              raw.utf8.count <= 512 else { return nil }
        return .init(rawValue: raw)
    }

    private func wireRequestID(_ id: AppServerRequestID) -> RequestID {
        switch id {
        case let .integer(value): .integer(value)
        case let .string(value): .string(value)
        }
    }

    private func turns(inThreadReadResult result: JSONValue) -> [[String: JSONValue]] {
        result.objectValue?["thread"]?.objectValue?["turns"]?.arrayValue?
            .compactMap(\.objectValue) ?? []
    }

    private func confirmedThreadState(
        inThreadReadResult result: JSONValue,
        expectedThreadID: AppServerThreadID
    ) -> (status: String, turns: [[String: JSONValue]])? {
        guard let thread = result.objectValue?["thread"]?.objectValue,
              thread["id"]?.stringValue == expectedThreadID.rawValue,
              let status = thread["status"]?.stringValue,
              !status.isEmpty,
              let encodedTurns = thread["turns"]?.arrayValue else { return nil }
        var decodedTurns: [[String: JSONValue]] = []
        decodedTurns.reserveCapacity(encodedTurns.count)
        for encodedTurn in encodedTurns {
            guard let turn = encodedTurn.objectValue,
                  let id = turn["id"]?.stringValue,
                  !id.isEmpty,
                  let status = turn["status"]?.stringValue,
                  !status.isEmpty else { return nil }
            decodedTurns.append(turn)
        }
        return (status, decodedTurns)
    }

    private func terminalTurn(
        _ turnID: AppServerTurnID,
        inThreadReadResult result: JSONValue
    ) -> Bool {
        turns(inThreadReadResult: result).contains {
            $0["id"]?.stringValue == turnID.rawValue
                && ["completed", "interrupted", "failed"].contains($0["status"]?.stringValue)
        }
    }

    private func inProgressTurn(
        _ turnID: AppServerTurnID,
        inThreadReadResult result: JSONValue
    ) -> Bool {
        turns(inThreadReadResult: result).contains {
            $0["id"]?.stringValue == turnID.rawValue
                && $0["status"]?.stringValue == "inProgress"
        }
    }
}

private extension AppServerControlIntent {
    var threadID: AppServerThreadID {
        switch self {
        case let .followUp(threadID, _, _, _),
             let .steer(threadID, _, _, _),
             let .decide(_, threadID, _, _),
             let .answer(_, threadID, _, _),
             let .interrupt(threadID, _): threadID
        }
    }

    var expectedTurnID: AppServerTurnID? {
        switch self {
        case let .steer(_, turnID, _, _), let .interrupt(_, turnID): turnID
        case .followUp, .decide, .answer: nil
        }
    }

    var requestID: AppServerScopedRequestID? {
        switch self {
        case let .decide(request, _, _, _), let .answer(request, _, _, _): request
        case .followUp, .steer, .interrupt: nil
        }
    }

    var answerRequestID: AppServerScopedRequestID? {
        guard case let .answer(request, _, _, _) = self else { return nil }
        return request
    }

    var draftRevision: UInt64? {
        switch self {
        case let .followUp(_, _, _, revision), let .steer(_, _, _, revision): revision
        case .decide, .answer, .interrupt: nil
        }
    }

    var isInterrupt: Bool {
        if case .interrupt = self { return true }
        return false
    }
}
