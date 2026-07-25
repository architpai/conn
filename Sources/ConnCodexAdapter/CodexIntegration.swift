import Foundation
import ConnDomain

public enum CodexIntegrationIdentity {
    public static let harnessID = HarnessID(rawValue: "openai")
    public static let integrationID = IntegrationID(rawValue: "builtin-codex")
    public static let descriptor = IntegrationDescriptor(
        id: integrationID,
        harnessID: harnessID,
        displayName: "Codex"
    )
}

/// Production Codex implementation of the provider-neutral Conn port.
///
/// App Server transport, schemas, request authority, response tokens, and
/// connection recovery remain behind this actor. The only outward values are
/// bounded Conn semantics.
public actor CodexIntegration: ConnIntegration {
    public nonisolated let descriptor = CodexIntegrationIdentity.descriptor

    private let configuration: AppServerMonitoringRuntimeConfiguration
    private let feedQualificationTimeout: Duration
    private let legacyHookRetirement: @Sendable () -> String?
    private let attentionRegistry = CodexAttentionRegistry()
    private let originRegistry = CodexOriginRegistry()
    private var runtime: AppServerMonitoringRuntime?
    private var runtimeTask: Task<Void, Never>?
    private var feedBootstrap: CodexFeedBootstrap?
    private var generationOrdinal: UInt64 = 0
    private var actionGeneration: UInt64 = 0

    public init(
        configuration: AppServerMonitoringRuntimeConfiguration = .init(),
        feedQualificationTimeout: Duration = .seconds(45),
        legacyHookRetirement: @escaping @Sendable () -> String? = { nil }
    ) {
        self.configuration = configuration
        self.feedQualificationTimeout = feedQualificationTimeout
        self.legacyHookRetirement = legacyHookRetirement
    }

    deinit {
        runtimeTask?.cancel()
    }

    public func establishFeed() async throws(ConnIntegrationError) -> ConnIntegrationFeed {
        if let feedBootstrap {
            await feedBootstrap.invalidate()
        }
        runtimeTask?.cancel()
        runtimeTask = nil
        runtime = nil
        generationOrdinal &+= 1
        let generation = IntegrationConnectionGeneration(
            instanceID: UUID(),
            ordinal: generationOrdinal
        )
        let runtime = AppServerMonitoringRuntime(
            configuration: configuration,
            legacyHookRetirement: legacyHookRetirement
        )
        self.runtime = runtime
        let registry = attentionRegistry
        let origins = originRegistry
        let bootstrap = await MainActor.run {
            CodexFeedBootstrap(
                generation: generation,
                originRegistry: origins,
                attentionRegistry: registry
            )
        }
        feedBootstrap = bootstrap
        runtimeTask = Task {
            await runtime.run { update in
                bootstrap.consume(update)
            }
            await MainActor.run {
                bootstrap.finish()
            }
        }

        let feed = await withTaskGroup(of: ConnIntegrationFeed?.self) { group in
            group.addTask {
                var iterator = bootstrap.feeds.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask { [feedQualificationTimeout] in
                try? await Task.sleep(for: feedQualificationTimeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard feedBootstrap === bootstrap else {
            throw .connectionInvalidated
        }
        guard let feed else {
            await bootstrap.invalidate()
            runtimeTask?.cancel()
            runtimeTask = nil
            self.runtime = nil
            feedBootstrap = nil
            throw .qualificationFailed
        }
        return feed
    }

    public func perform(_ action: ConnAction) async -> ConnActionOutcome {
        guard action.integrationID == descriptor.id else {
            return outcome(for: action, .unavailable, "Wrong Integration target")
        }
        guard let runtime else {
            return outcome(for: action, .unavailable, "Codex Integration is not qualified")
        }

        switch action {
        case .open:
            return outcome(
                for: action,
                .unavailable,
                "Opening Codex is composed by ConnApp, not an App Server action"
            )

        case let .createSession(_, workspacePath, initialPrompt, modelID):
            let catalog = await runtime.loadNewThreadModelCatalog()
            guard catalog.outcome == .available,
                  let option = catalog.catalog?.options.first(where: {
                      $0.id == modelID.rawValue
                  })
            else {
                return outcome(for: action, .invalidated, "Selected Codex model is unavailable")
            }
            await prepareDispatch(runtime)
            let result = await runtime.executeNewThread(.init(
                workingDirectory: workspacePath.value,
                initialPrompt: initialPrompt.value,
                modelID: option.id,
                model: option.model,
                draftRevision: actionGeneration
            ))
            if result.outcome == .accepted, let threadID = result.createdThreadID {
                originRegistry.insert(threadID)
            }
            return outcome(for: action, result.outcome)

        case let .followUp(sessionID, text, modelID):
            let selectedModel: String?
            if let modelID {
                let catalog = await runtime.loadNewThreadModelCatalog()
                guard catalog.outcome == .available,
                      let option = catalog.catalog?.options.first(where: {
                          $0.id == modelID.rawValue
                      }) else {
                    return outcome(
                        for: action,
                        .invalidated,
                        "Selected Codex model is unavailable"
                    )
                }
                selectedModel = option.model
            } else {
                selectedModel = nil
            }
            return await execute(
                .followUp(
                    threadID: threadID(sessionID),
                    text: text.value,
                    model: selectedModel,
                    draftRevision: actionGeneration
                ),
                action: action,
                runtime: runtime
            )

        case let .steer(sessionID, runID, text):
            return await execute(
                .steer(
                    threadID: threadID(sessionID),
                    expectedTurnID: .init(rawValue: runID.rawValue),
                    text: text.value,
                    draftRevision: actionGeneration
                ),
                action: action,
                runtime: runtime
            )

        case let .interrupt(sessionID, runID):
            return await execute(
                .interrupt(
                    threadID: threadID(sessionID),
                    expectedTurnID: .init(rawValue: runID.rawValue)
                ),
                action: action,
                runtime: runtime
            )

        case let .answer(sessionID, authority, answers):
            guard authority.generation == attentionRegistry.currentGeneration,
                  let request = attentionRegistry.request(for: authority.requestID),
                  request.threadID == threadID(sessionID) else {
                return outcome(for: action, .invalidated, "Attention authority is stale")
            }
            return await execute(
                .answer(
                    request: request.id,
                    threadID: request.threadID,
                    turnID: request.turnID,
                    answers: .init(valuesByQuestionID: answers.valuesByQuestionID)
                ),
                action: action,
                runtime: runtime
            )

        case let .resolveApproval(sessionID, authority, decision):
            guard authority.generation == attentionRegistry.currentGeneration,
                  let request = attentionRegistry.request(for: authority.requestID),
                  request.threadID == threadID(sessionID) else {
                return outcome(for: action, .invalidated, "Attention authority is stale")
            }
            return await execute(
                .decide(
                    request: request.id,
                    threadID: request.threadID,
                    turnID: request.turnID,
                    choice: decision.appServerChoice
                ),
                action: action,
                runtime: runtime
            )
        }
    }

    public func sessionModels() async -> ConnSessionModelCatalogResult {
        guard let runtime else {
            return .init(outcome: .unavailable)
        }
        let result = await runtime.loadNewThreadModelCatalog()
        guard result.outcome == .available, let catalog = result.catalog else {
            return .init(
                outcome: result.outcome == .connectionInvalidated
                    ? .invalidated
                    : .unavailable
            )
        }
        return .init(
            outcome: .available,
            catalog: .init(
                integrationID: descriptor.id,
                options: catalog.options.map {
                    .init(
                        id: .init(rawValue: $0.id),
                        displayName: $0.displayName,
                        detail: $0.detail.isEmpty ? nil : $0.detail,
                        isDefault: $0.isDefault
                    )
                }
            )
        )
    }

    /// Migration-edge inspection for the exact retired Sidequest plugin.
    /// Candidate identity remains connection-scoped and is never persisted.
    public func legacyPluginCandidate() async
        -> LegacySidequestPluginCandidate?
    {
        guard let runtime else { return nil }
        await runtime.requestInventoryRefresh()
        return await runtime.legacyPluginCandidate()
    }

    /// Executes only after ConnApp presents the captured candidate and the
    /// user confirms that exact identity.
    public func uninstallLegacyPlugin(
        confirmed candidate: LegacySidequestPluginCandidate
    ) async -> LegacySidequestPluginUninstallOutcome {
        guard let runtime else { return .staleConfirmation }
        return await runtime.uninstallLegacyPlugin(confirmed: candidate)
    }

    public func disconnect() async {
        await feedBootstrap?.invalidate()
        feedBootstrap = nil
        runtimeTask?.cancel()
        runtimeTask = nil
        runtime = nil
    }

    private func execute(
        _ intent: AppServerControlIntent,
        action: ConnAction,
        runtime: AppServerMonitoringRuntime
    ) async -> ConnActionOutcome {
        await prepareDispatch(runtime)
        let result = await runtime.executeControl(
            intent,
            selectionGeneration: actionGeneration
        )
        return outcome(for: action, result.outcome)
    }

    private func prepareDispatch(_ runtime: AppServerMonitoringRuntime) async {
        actionGeneration &+= 1
        await runtime.updateControlSelectionGeneration(actionGeneration)
    }

    private func threadID(_ sessionID: ConnSessionID) -> AppServerThreadID {
        .init(rawValue: sessionID.upstreamID.rawValue)
    }

    private func outcome(
        for action: ConnAction,
        _ kind: ConnActionOutcomeKind,
        _ evidence: String? = nil
    ) -> ConnActionOutcome {
        .init(
            integrationID: descriptor.id,
            action: action.kind,
            kind: kind,
            evidence: evidence
        )
    }

    private func outcome(
        for action: ConnAction,
        _ result: AppServerControlOutcome
    ) -> ConnActionOutcome {
        outcome(for: action, result.connOutcome)
    }
}

private extension ApprovalDecision {
    var appServerChoice: AppServerApprovalChoice {
        switch self {
        case .approve: .approve
        case .approveForSession: .approveForSession
        case .deny: .deny
        case .cancel: .cancel
        }
    }
}

private extension AppServerControlOutcome {
    var connOutcome: ConnActionOutcomeKind {
        switch self {
        case .accepted:
            .accepted
        case .resolvedElsewhere:
            .resolvedElsewhere
        case .stalePrecondition, .duplicateSuppressed, .connectionInvalidated:
            .invalidated
        case .acknowledgementUncertain, .acknowledgementTimedOut,
             .terminalStateUnconfirmed:
            .acknowledgementUncertain
        case .rejected:
            .rejected
        }
    }
}

private final class CodexOriginRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Set<AppServerThreadID> = []

    var threadIDs: Set<AppServerThreadID> {
        lock.withLock { storage }
    }

    func insert(_ threadID: AppServerThreadID) {
        _ = lock.withLock {
            storage.insert(threadID)
        }
    }
}

private final class CodexAttentionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: IntegrationConnectionGeneration?
    private var requestsByID: [AttentionRequestID: AppServerProjectedRequest] = [:]
    private var connIDsByProviderID: [
        AppServerScopedRequestID: AttentionRequestID
    ] = [:]

    var currentGeneration: IntegrationConnectionGeneration? {
        lock.withLock { generation }
    }

    func replace(
        generation: IntegrationConnectionGeneration,
        requests: [AttentionRequestID: AppServerProjectedRequest]
    ) {
        lock.withLock {
            self.generation = generation
            requestsByID = requests
        }
    }

    func id(for request: AppServerScopedRequestID) -> AttentionRequestID {
        lock.withLock {
            if let existing = connIDsByProviderID[request] { return existing }
            let generated = AttentionRequestID(
                rawValue: "codex-attention-\(UUID().uuidString.lowercased())"
            )
            connIDsByProviderID[request] = generated
            return generated
        }
    }

    func clear() {
        lock.withLock {
            generation = nil
            requestsByID = [:]
            connIDsByProviderID = [:]
        }
    }

    func request(for id: AttentionRequestID) -> AppServerProjectedRequest? {
        lock.withLock { requestsByID[id] }
    }
}

@MainActor
private final class CodexFeedBootstrap {
    private let generation: IntegrationConnectionGeneration
    private let originRegistry: CodexOriginRegistry
    private let attentionRegistry: CodexAttentionRegistry
    private let feedContinuation: AsyncStream<ConnIntegrationFeed>.Continuation
    let feeds: AsyncStream<ConnIntegrationFeed>

    private var updateContinuation: AsyncStream<IntegrationUpdate>.Continuation?
    private var previousSessions: [ConnSessionID: ConnSession] = [:]
    private var previousAttention: [AttentionRequestID: AttentionRequest] = [:]
    private var previousInventoryAuthority: InventoryAuthority = .partial
    private var providerConnection: AppServerConnectionIdentity?
    private var sequence: UInt64 = 0
    private var didPublish = false
    private var isFinished = false

    init(
        generation: IntegrationConnectionGeneration,
        originRegistry: CodexOriginRegistry,
        attentionRegistry: CodexAttentionRegistry
    ) {
        self.generation = generation
        self.originRegistry = originRegistry
        self.attentionRegistry = attentionRegistry
        var captured: AsyncStream<ConnIntegrationFeed>.Continuation!
        feeds = AsyncStream(bufferingPolicy: .bufferingOldest(1)) {
            captured = $0
        }
        feedContinuation = captured
    }

    func consume(_ update: AppServerMonitoringRuntime.Update) {
        guard !isFinished else { return }
        guard update.status.phase == .connected,
              let currentProviderConnection = update.snapshot.connection else {
            if didPublish {
                yield(.authorityLost, observedAt: update.observedAt)
                finish()
            }
            return
        }
        if let providerConnection,
           providerConnection != currentProviderConnection {
            yield(.authorityLost, observedAt: update.observedAt)
            finish()
            return
        }
        providerConnection = currentProviderConnection

        let inventoryAuthority: InventoryAuthority =
            update.status.isThreadInventoryMembershipComplete ? .complete : .partial
        let mapping = CodexProjectionMapper.map(
            update.snapshot,
            integration: CodexIntegrationIdentity.descriptor,
            generation: generation,
            throughSequence: sequence,
            inventoryAuthority: inventoryAuthority,
            connOriginatedThreadIDs: originRegistry.threadIDs,
            attentionID: attentionRegistry.id(for:),
            observedAt: update.observedAt
        )
        attentionRegistry.replace(
            generation: generation,
            requests: mapping.providerRequestsByID
        )

        if !didPublish {
            previousSessions = Dictionary(
                uniqueKeysWithValues: mapping.snapshot.sessions.map { ($0.id, $0) }
            )
            previousAttention = Dictionary(
                uniqueKeysWithValues: mapping.snapshot.attentionRequests.map { ($0.id, $0) }
            )
            previousInventoryAuthority = inventoryAuthority
            var captured: AsyncStream<IntegrationUpdate>.Continuation!
            let updates = AsyncStream<IntegrationUpdate>(
                bufferingPolicy: .bufferingOldest(ConnDomainBounds.default.maximumBufferedUpdates)
            ) {
                captured = $0
            }
            updateContinuation = captured
            didPublish = true
            feedContinuation.yield(.init(snapshot: mapping.snapshot, updates: updates))
            feedContinuation.finish()
            return
        }

        if previousInventoryAuthority != inventoryAuthority {
            yield(
                .inventoryAuthorityChanged(inventoryAuthority),
                observedAt: update.observedAt
            )
            previousInventoryAuthority = inventoryAuthority
        }
        let incomingSessions = Dictionary(
            uniqueKeysWithValues: mapping.snapshot.sessions.map { ($0.id, $0) }
        )
        for session in mapping.snapshot.sessions where previousSessions[session.id] != session {
            yield(.sessionUpsert(session), observedAt: update.observedAt)
        }
        if mapping.snapshot.inventoryAuthority == .complete {
            for removed in previousSessions.keys where incomingSessions[removed] == nil {
                yield(.sessionRemoved(removed), observedAt: update.observedAt)
            }
        }
        previousSessions.merge(incomingSessions) { _, incoming in incoming }
        if mapping.snapshot.inventoryAuthority == .complete {
            previousSessions = incomingSessions
        }

        let incomingAttention = Dictionary(
            uniqueKeysWithValues: mapping.snapshot.attentionRequests.map { ($0.id, $0) }
        )
        for request in mapping.snapshot.attentionRequests
        where previousAttention[request.id] != request {
            yield(.attentionUpsert(request), observedAt: update.observedAt)
        }
        for (requestID, previous) in previousAttention
        where mapping.snapshot.inventoryAuthority == .complete
            && incomingAttention[requestID] == nil {
                yield(
                    .attentionRemoved(sessionID: previous.sessionID, requestID: requestID),
                    observedAt: update.observedAt
                )
        }
        if mapping.snapshot.inventoryAuthority == .complete {
            previousAttention = incomingAttention
        } else {
            previousAttention.merge(incomingAttention) { _, incoming in incoming }
        }
    }

    func invalidate() {
        guard !isFinished else { return }
        if didPublish {
            yield(.authorityLost, observedAt: Date())
        }
        finish()
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        attentionRegistry.clear()
        updateContinuation?.finish()
        updateContinuation = nil
        feedContinuation.finish()
    }

    private func yield(_ update: IntegrationSemanticUpdate, observedAt: Date) {
        guard let updateContinuation else { return }
        sequence &+= 1
        let result = updateContinuation.yield(.init(
            integrationID: CodexIntegrationIdentity.integrationID,
            cursor: .init(generation: generation, sequence: sequence),
            observedAt: observedAt,
            update: update
        ))
        switch result {
        case .enqueued:
            break
        case .dropped, .terminated:
            finish()
        @unknown default:
            finish()
        }
    }
}

package struct CodexProjectionMapping: Sendable {
    package let snapshot: IntegrationSnapshot
    package let providerRequestsByID: [
        AttentionRequestID: AppServerProjectedRequest
    ]
}

package enum CodexProjectionMapper {
    package static func map(
        _ source: AppServerProjectionSnapshot,
        integration: IntegrationDescriptor = CodexIntegrationIdentity.descriptor,
        generation: IntegrationConnectionGeneration,
        throughSequence: UInt64,
        inventoryAuthority: InventoryAuthority,
        connOriginatedThreadIDs: Set<AppServerThreadID> = [],
        attentionID: (AppServerScopedRequestID) -> AttentionRequestID,
        observedAt: Date
    ) -> CodexProjectionMapping {
        let sessions = source.threads.map {
            mapSession(
                $0,
                integrationID: integration.id,
                connOriginated: connOriginatedThreadIDs.contains($0.id)
            )
        }
        var providerRequests: [
            AttentionRequestID: AppServerProjectedRequest
        ] = [:]
        var attention: [AttentionRequest] = []
        for thread in source.threads {
            for request in thread.requests {
                let id = attentionID(request.id)
                providerRequests[id] = request
                attention.append(.init(
                    id: id,
                    sessionID: sessionID(thread.id, integrationID: integration.id),
                    runID: request.turnID.map { .init(rawValue: $0.rawValue) },
                    kind: request.kind == .structuredQuestion
                        ? .structuredQuestion
                        : .approval,
                    content: requestContent(request),
                    summary: requestSummary(request),
                    observedAt: request.startedAt
                ))
            }
        }
        return .init(
            snapshot: .init(
                integration: integration,
                generation: generation,
                throughSequence: throughSequence,
                inventoryAuthority: inventoryAuthority,
                capabilities: capabilities(source.featureSupport),
                sessions: sessions,
                attentionRequests: attention,
                observedAt: observedAt
            ),
            providerRequestsByID: providerRequests
        )
    }

    private static func mapSession(
        _ thread: AppServerProjectedThread,
        integrationID: IntegrationID,
        connOriginated: Bool
    ) -> ConnSession {
        // The legacy projection exposes Turns newest-first for row/outcome
        // decisions. A transcript is the opposite: chronological Turn blocks,
        // while each Turn's authoritative Item order must remain untouched.
        let chronologicalTurns = thread.turns.reversed()
        let runs = chronologicalTurns.map { turn in
            ConnRun(
                id: .init(rawValue: turn.id.rawValue),
                status: runStatus(turn.status),
                startedAt: turn.startedAt,
                completedAt: turn.completedAt
            )
        }
        let activities = chronologicalTurns.reduce(into: [ConnActivity]()) {
            result, turn in
            result.append(contentsOf: turn.items.map { item in
                ConnActivity(
                    id: .init(rawValue: "\(turn.id.rawValue):\(item.id.rawValue)"),
                    runID: .init(rawValue: turn.id.rawValue),
                    kind: activityKind(item.kind),
                    status: activityStatus(item.status),
                    summary: item.presentation.map(presentationSummary),
                    observedAt: item.completedAt ?? item.startedAt ?? thread.lastObservedAt
                )
            })
        }
        let issue: [SessionIssue]
        if thread.status == .systemError {
            issue = [.init(
                id: .init(rawValue: "codex-system-error"),
                kind: .session,
                summary: "Codex reported a system error",
                observedAt: thread.lastObservedAt
            )]
        } else {
            issue = []
        }
        let workspacePath = thread.projectRootPath ?? thread.workingDirectoryPath
        return .init(
            id: sessionID(thread.id, integrationID: integrationID),
            title: thread.title,
            workspace: workspacePath.map { .init(canonicalPath: $0) },
            origin: connOriginated ? .conn : .external,
            ownership: .harness,
            retention: connOriginated ? .ephemeral : .unknown,
            status: sessionStatus(thread),
            runs: runs,
            activities: activities,
            issues: issue,
            updatedAt: thread.updatedAt
        )
    }

    private static func capabilities(
        _ support: AppServerFeatureSupport
    ) -> IntegrationCapabilities {
        var actions: Set<ConnActionKind> = []
        if support.supports(.createThread) { actions.insert(.createSession) }
        if support.supports(.followUp) { actions.insert(.followUp) }
        if support.supports(.steer) { actions.insert(.steer) }
        if support.supports(.stopTurn) { actions.insert(.interrupt) }
        if support.supports(.answer) { actions.insert(.answer) }
        if support.supports(.resolveApproval) { actions.insert(.resolveApproval) }
        return .init(canMonitor: support.supports(.monitor), actions: actions)
    }

    private static func sessionID(
        _ threadID: AppServerThreadID,
        integrationID: IntegrationID
    ) -> ConnSessionID {
        .init(
            integrationID: integrationID,
            upstreamID: .init(rawValue: threadID.rawValue)
        )
    }

    private static func requestSummary(_ request: AppServerProjectedRequest) -> String {
        switch request.facts {
        case let .commandApproval(facts):
            facts.reason ?? facts.command ?? "Command approval requested"
        case let .fileChangeApproval(facts):
            facts.reason ?? "File change approval requested"
        case let .permissionsApproval(facts):
            facts.reason ?? "Permission approval requested"
        case let .structuredQuestions(facts):
            facts.questions.first?.prompt ?? "Codex needs an answer"
        case .unsupported:
            "Codex needs attention"
        }
    }

    private static func requestContent(
        _ request: AppServerProjectedRequest
    ) -> AttentionRequestContent {
        switch request.facts {
        case let .commandApproval(facts):
            .approval(availableDecisions: facts.availableChoices.map(approvalDecision))
        case let .fileChangeApproval(facts):
            .approval(availableDecisions: facts.availableChoices.map(approvalDecision))
        case let .permissionsApproval(facts):
            .approval(availableDecisions: facts.availableChoices.map(approvalDecision))
        case let .structuredQuestions(facts):
            .structuredQuestions(
                questions: facts.questions.map { question in
                    ConnStructuredQuestion(
                        id: question.id,
                        header: question.header,
                        prompt: question.prompt,
                        choices: question.options?.map {
                            .init(label: $0.label, detail: $0.detail)
                        } ?? [],
                        permitsOther: question.permitsOther,
                        isSecret: question.isSecret
                    )
                },
                autoResolutionMilliseconds: facts.autoResolutionMilliseconds
            )
        case .unsupported:
            .approval(availableDecisions: [])
        }
    }

    private static func approvalDecision(
        _ choice: AppServerApprovalChoice
    ) -> ApprovalDecision {
        switch choice {
        case .approve: .approve
        case .approveForSession: .approveForSession
        case .deny: .deny
        case .cancel: .cancel
        }
    }

    private static func sessionStatus(
        _ thread: AppServerProjectedThread
    ) -> ConnSessionStatus {
        if !thread.requests.isEmpty { return .waitingForAttention }
        switch thread.status {
        case .notLoaded: return .notLoaded
        case .idle: return thread.outcome == nil ? .idle : outcomeStatus(thread.outcome)
        case .systemError: return .failed
        case .active: return .working
        case .unknown: return .unknown
        }
    }

    private static func outcomeStatus(
        _ outcome: AppServerProjectedOutcome?
    ) -> ConnSessionStatus {
        switch outcome?.kind {
        case .completed: .completed
        case .failed: .failed
        case .interrupted: .idle
        case nil: .idle
        }
    }

    private static func runStatus(_ status: AppServerTurnStatus) -> ConnRunStatus {
        switch status {
        case .inProgress: .inProgress
        case .completed: .completed
        case .interrupted: .interrupted
        case .failed: .failed
        case .unknown: .unknown
        }
    }

    private static func activityKind(_ kind: AppServerItemKind) -> ConnActivityKind {
        switch kind {
        case .userMessage, .hookPrompt: .userMessage
        case .agentMessage: .agentMessage
        case .plan: .plan
        case .reasoning: .reasoning
        case .commandExecution: .command
        case .fileChange: .fileChange
        case .mcpToolCall, .dynamicToolCall, .collabAgentToolCall: .toolCall
        case .subagentActivity: .subagent
        case .webSearch: .webSearch
        case .imageView, .imageGeneration: .image
        case .contextCompaction: .compaction
        case .sleep, .enteredReviewMode, .exitedReviewMode, .unknown: .unknown
        }
    }

    private static func activityStatus(
        _ status: AppServerItemStatus
    ) -> ConnActivityStatus {
        switch status {
        case .started: .started
        case .completed: .completed
        case .failed: .failed
        case .unknown: .unknown
        }
    }

    private static func presentationSummary(
        _ presentation: AppServerItemPresentationPayload
    ) -> String {
        switch presentation {
        case let .userText(text), let .agentText(text),
             let .agentFinalText(text), let .planText(text),
             let .command(text):
            text
        case let .reasoningSummary(parts):
            parts.joined(separator: " ")
        case let .fileChanges(changes):
            "\(changes.count) file change\(changes.count == 1 ? "" : "s")"
        case let .tool(name, server):
            server.map { "\(name) · \($0)" } ?? name
        }
    }
}
