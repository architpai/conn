import Darwin
import Foundation
import ConnDomain

public enum PiExternalIntegrationIdentity {
    public static let harnessID = HarnessID(rawValue: "pi")
    public static let integrationID = IntegrationID(rawValue: "pi.external")
    public static let descriptor = IntegrationDescriptor(
        id: integrationID,
        harnessID: harnessID,
        displayName: "Pi"
    )
}

public enum PiHarnessAsset {
    public static let officialSourceURL = URL(
        string: "https://pi.dev/favicon.svg"
    )!

    public static var bundledBadgeURL: URL {
        guard let url = Bundle.module.url(
            forResource: "PiHarnessBadge",
            withExtension: "svg"
        ) else {
            preconditionFailure("ConnPiAdapter is missing PiHarnessBadge.svg")
        }
        return url
    }
}

public actor PiExternalIntegration: ConnIntegration {
    public nonisolated let descriptor = PiExternalIntegrationIdentity.descriptor
    private let broker: PiLocalBroker
    private var generationOrdinal: UInt64 = 0
    private var enabled: Bool

    public init(broker: PiLocalBroker, enabled: Bool = false) {
        self.broker = broker
        self.enabled = enabled
    }

    public static func userDefault(
        enabled: Bool = false
    ) -> PiExternalIntegration {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let runtimeStore = PiRuntimeDescriptorStore(
            directory: home.appendingPathComponent(
                "Library/Application Support/Conn/pi-runtime",
                isDirectory: true
            )
        )
        let socketURL = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("conn-pi-\(getuid())", isDirectory: true)
            .appendingPathComponent("broker.sock")
        return PiExternalIntegration(
            broker: PiLocalBroker(
                runtimeStore: runtimeStore,
                socketURL: socketURL
            ),
            enabled: enabled
        )
    }

    public func establishFeed() async throws(ConnIntegrationError) -> ConnIntegrationFeed {
        guard enabled else { throw .unavailable }
        do {
            _ = try await broker.start()
        } catch {
            throw .unavailable
        }
        let brokerFeed = await broker.feed()
        generationOrdinal &+= 1
        let generation = IntegrationConnectionGeneration(
            instanceID: UUID(),
            ordinal: generationOrdinal
        )
        let sequence: UInt64 = 0
        let observedAt = Date()
        let actions: Set<ConnActionKind> = [.followUp, .steer, .interrupt]
        let initialSessions = brokerFeed.registrations.map {
            Self.session(from: $0, observedAt: observedAt)
        }
        let snapshot = IntegrationSnapshot(
            integration: descriptor,
            generation: generation,
            throughSequence: sequence,
            inventoryAuthority: .partial,
            capabilities: .init(
                canMonitor: true,
                actions: actions
            ),
            sessions: initialSessions,
            observedAt: observedAt
        )
        let updates = AsyncStream<IntegrationUpdate>(
            bufferingPolicy: .bufferingNewest(
                ConnDomainBounds.default.maximumBufferedUpdates
            )
        ) { continuation in
            let task = Task {
                var nextSequence = sequence
                var sessionsByUpstreamID = Dictionary(
                    uniqueKeysWithValues: initialSessions.map {
                        ($0.id.upstreamID.rawValue, $0)
                    }
                )
                var activeInstanceBySessionID = Dictionary(
                    uniqueKeysWithValues: brokerFeed.registrations.map {
                        ($0.handshake.sessionID, $0.handshake.instanceID)
                    }
                )
                for await event in brokerFeed.events {
                    nextSequence &+= 1
                    let now = Date()
                    switch event {
                    case let .registered(registration):
                        let mapped = Self.session(
                            from: registration,
                            observedAt: now
                        )
                        sessionsByUpstreamID[
                            registration.handshake.sessionID
                        ] = mapped
                        activeInstanceBySessionID[
                            registration.handshake.sessionID
                        ] = registration.handshake.instanceID
                        continuation.yield(.init(
                            integrationID: PiExternalIntegrationIdentity.integrationID,
                            cursor: .init(generation: generation, sequence: nextSequence),
                            observedAt: now,
                            update: .sessionUpsert(mapped)
                        ))
                    case let .stateChanged(
                        sessionID,
                        state,
                        event,
                        activity,
                        outcome
                    ):
                        let mapped = Self.session(
                            sessionID: sessionID,
                            state: state,
                            event: event,
                            activity: activity,
                            outcome: outcome,
                            previous: sessionsByUpstreamID[sessionID],
                            observedAt: now
                        )
                        sessionsByUpstreamID[sessionID] = mapped
                        continuation.yield(.init(
                            integrationID: PiExternalIntegrationIdentity.integrationID,
                            cursor: .init(generation: generation, sequence: nextSequence),
                            observedAt: now,
                            update: .sessionUpsert(mapped)
                        ))
                    case let .disconnected(sessionID, instanceID):
                        guard activeInstanceBySessionID[sessionID] == instanceID,
                              let previous = sessionsByUpstreamID[sessionID] else {
                            continue
                        }
                        activeInstanceBySessionID.removeValue(forKey: sessionID)
                        let mapped = Self.disconnectedSession(
                            previous,
                            observedAt: now
                        )
                        sessionsByUpstreamID[sessionID] = mapped
                        continuation.yield(.init(
                            integrationID: PiExternalIntegrationIdentity.integrationID,
                            cursor: .init(generation: generation, sequence: nextSequence),
                            observedAt: now,
                            update: .sessionUpsert(mapped)
                        ))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return .init(snapshot: snapshot, updates: updates)
    }

    public func perform(_ action: ConnAction) async -> ConnActionOutcome {
        guard action.integrationID == descriptor.id else {
            return outcome(action, .unavailable, "Wrong Integration target")
        }
        let command: PiBrokerCommand
        let upstreamID: String
        switch action {
        case .createSession:
            return outcome(action, .unavailable, "External Pi cannot create Sessions")
        case let .followUp(sessionID, text, modelSelection):
            upstreamID = sessionID.upstreamID.rawValue
            if let modelSelection {
                let switchOutcome = await apply(
                    modelSelection,
                    to: upstreamID,
                    action: action
                )
                if let switchOutcome {
                    return switchOutcome
                }
            }
            command = .followUp(id: UUID().uuidString, message: text.value)
        case let .steer(sessionID, _, text):
            upstreamID = sessionID.upstreamID.rawValue
            command = .steer(id: UUID().uuidString, message: text.value)
        case let .interrupt(sessionID, _):
            upstreamID = sessionID.upstreamID.rawValue
            command = .interrupt(id: UUID().uuidString)
        case .answer, .resolveApproval:
            return outcome(
                action,
                .unavailable,
                "Pi has no standard question or approval control"
            )
        }
        switch await broker.send(command, to: upstreamID) {
        case .accepted:
            return outcome(action, .accepted, "Pi accepted the command")
        case let .rejected(error, _):
            return outcome(action, .rejected, error)
        case .acknowledgementUncertain:
            return outcome(
                action,
                .acknowledgementUncertain,
                "Pi command acknowledgement was not received; Conn will not replay it"
            )
        }
    }

    public func sessionModels(
        for sessionID: ConnSessionID?
    ) async -> ConnSessionModelCatalogResult {
        guard let sessionID,
              sessionID.integrationID == descriptor.id,
              let effective = await broker.effectiveModelState(
                  for: sessionID.upstreamID.rawValue
              ) else {
            return .init(outcome: .unavailable)
        }
        let modelID = Self.modelID(
            provider: effective.provider,
            modelID: effective.modelID
        )
        let reasoningID = ConnReasoningEffortID(rawValue: effective.thinkingLevel)
        let options = effective.availableModels.map { option in
            let optionID = Self.modelID(
                provider: option.provider,
                modelID: option.modelID
            )
            let reasoning = option.thinkingLevels.map {
                ConnReasoningEffortOption(
                    id: .init(rawValue: $0),
                    displayName: $0.capitalized
                )
            }
            return ConnSessionModelOption(
                id: optionID,
                displayName: option.displayName,
                detail: option.provider,
                isDefault: optionID == modelID,
                reasoningEfforts: reasoning,
                defaultReasoningEffortID: optionID == modelID
                    && option.thinkingLevels.contains(effective.thinkingLevel)
                    ? reasoningID
                    : reasoning.first?.id
            )
        }
        guard !options.isEmpty,
              options.contains(where: { option in
                  option.id == modelID
                      && option.reasoningEfforts.contains {
                          $0.id == reasoningID
                      }
              }) else {
            return .init(outcome: .unavailable)
        }
        return .init(
            outcome: .available,
            catalog: .init(
                integrationID: descriptor.id,
                options: options,
                currentSelection: .init(
                    modelID: modelID,
                    reasoningEffortID: reasoningID
                )
            )
        )
    }

    public func disconnect() async {
        await broker.stop()
    }

    public func setEnabled(_ value: Bool) async {
        enabled = value
        if !value {
            await broker.stop()
        }
    }

    public func isEnabled() -> Bool {
        enabled
    }

    private static func session(
        from registration: PiLiveRegistration,
        observedAt: Date
    ) -> ConnSession {
        let handshake = registration.handshake
        let activeRunID = RunID(rawValue: "pi-active-\(handshake.sessionID)")
        let settledRunID = RunID(rawValue: "pi-settled-\(handshake.sessionID)")
        let runs: [ConnRun] = if handshake.isIdle == false {
            [.init(id: activeRunID, status: .inProgress, startedAt: observedAt)]
        } else {
            switch handshake.outcome {
            case .completed:
                [.init(id: settledRunID, status: .completed, completedAt: observedAt)]
            case .failed:
                [.init(id: settledRunID, status: .failed, completedAt: observedAt)]
            case .interrupted:
                [.init(id: settledRunID, status: .interrupted, completedAt: observedAt)]
            case .unknown, nil:
                []
            }
        }
        let status: ConnSessionStatus = if handshake.isIdle == false {
            .working
        } else {
            switch handshake.outcome {
            case .completed: .completed
            case .failed: .failed
            case .interrupted, .unknown, nil: .idle
            }
        }
        let activities = handshake.activities.map { activity in
            ConnActivity(
                id: .init(rawValue: activity.id),
                kind: Self.activityKind(activity.kind),
                status: .completed,
                summary: activity.text,
                observedAt: observedAt
            )
        }
        return .init(
            id: .init(
                integrationID: PiExternalIntegrationIdentity.integrationID,
                upstreamID: .init(rawValue: handshake.sessionID)
            ),
            title: handshake.sessionName,
            workspace: .init(canonicalPath: handshake.workspace),
            model: Self.modelMetadata(
                provider: handshake.modelProvider,
                modelID: handshake.modelID,
                modelName: handshake.availableModels.first {
                    $0.provider == handshake.modelProvider
                        && $0.modelID == handshake.modelID
                }?.displayName,
                thinking: handshake.thinkingLevel
            ),
            origin: .external,
            retention: .persistent,
            status: status,
            runs: runs,
            activities: activities,
            updatedAt: observedAt
        )
    }

    private static func activityKind(_ rawValue: String) -> ConnActivityKind {
        switch rawValue {
        case "userMessage": .userMessage
        case "agentMessage": .agentMessage
        case "toolCall": .toolCall
        default: .unknown
        }
    }

    private static func sessionID(_ upstreamID: String) -> ConnSessionID {
        .init(
            integrationID: PiExternalIntegrationIdentity.integrationID,
            upstreamID: .init(rawValue: upstreamID)
        )
    }

    private static func disconnectedSession(
        _ previous: ConnSession,
        observedAt: Date
    ) -> ConnSession {
        let runs = previous.runs.map { run in
            guard run.status == .inProgress else { return run }
            return ConnRun(
                id: run.id,
                status: .unknown,
                startedAt: run.startedAt,
                completedAt: observedAt
            )
        }
        let status: ConnSessionStatus = switch previous.status {
        case .working, .waitingForAttention, .unknown: .idle
        default: previous.status
        }
        return .init(
            id: previous.id,
            title: previous.title,
            workspace: previous.workspace,
            model: previous.model,
            origin: previous.origin,
            ownership: previous.ownership,
            retention: previous.retention,
            status: status,
            runs: runs,
            activities: previous.activities,
            issues: previous.issues,
            updatedAt: observedAt
        )
    }

    private static func session(
        sessionID: String,
        state: PiBridgeState,
        event: String,
        activity: PiBridgeActivity?,
        outcome: PiBridgeRunOutcome?,
        previous: ConnSession?,
        observedAt: Date
    ) -> ConnSession {
        let priorActiveRun = previous?.runs.last { $0.status == .inProgress }
        let activeRunID = priorActiveRun?.id ?? RunID(
            rawValue: "pi-run-\(sessionID)-\(Int(observedAt.timeIntervalSince1970 * 1_000))"
        )
        let runs: [ConnRun]
        if state.isIdle, let outcome {
            let terminalRunStatus: ConnRunStatus = switch outcome {
            case .interrupted: .interrupted
            case .failed: .failed
            case .unknown: .unknown
            case .completed: .completed
            }
            runs = (previous?.runs ?? []).map {
                guard $0.status == .inProgress else { return $0 }
                return ConnRun(
                    id: $0.id,
                    status: terminalRunStatus,
                    startedAt: $0.startedAt,
                    completedAt: observedAt
                )
            }
        } else if priorActiveRun != nil {
            runs = previous?.runs ?? []
        } else if state.isIdle {
            runs = previous?.runs ?? []
        } else {
            runs = (previous?.runs ?? []) + [
                ConnRun(
                    id: activeRunID,
                    status: .inProgress,
                    startedAt: observedAt
                )
            ]
        }
        var activities = previous?.activities ?? []
        if let activity {
            let activityKind = Self.activityKind(activity.kind)
            let activityRunID = priorActiveRun?.id
                ?? (state.isIdle ? nil : activeRunID)
            let activityStatus: ConnActivityStatus =
                activityKind == .toolCall && !event.hasSuffix("_end")
                    ? .started
                    : .completed
            activities.append(ConnActivity(
                id: .init(rawValue: activity.id),
                runID: activityRunID,
                kind: activityKind,
                status: activityStatus,
                summary: activity.text,
                observedAt: observedAt
            ))
        }
        let status: ConnSessionStatus
        if !state.isIdle {
            status = .working
        } else {
            status = switch outcome {
            case .completed: .completed
            case .failed: .failed
            case .interrupted: .idle
            case .unknown: .idle
            case nil:
                switch previous?.status {
                case .completed: .completed
                case .failed: .failed
                case .working: .working
                default: .idle
                }
            }
        }
        return .init(
            id: .init(
                integrationID: PiExternalIntegrationIdentity.integrationID,
                upstreamID: .init(rawValue: sessionID)
            ),
            title: state.sessionName,
            workspace: .init(canonicalPath: state.workspace),
            model: Self.modelMetadata(
                provider: state.modelProvider,
                modelID: state.modelID,
                modelName: state.modelName,
                thinking: state.thinkingLevel
            ),
            origin: .external,
            retention: .persistent,
            status: status,
            runs: runs,
            activities: activities,
            issues: previous?.issues ?? [],
            updatedAt: observedAt
        )
    }

    private func outcome(
        _ action: ConnAction,
        _ kind: ConnActionOutcomeKind,
        _ evidence: String
    ) -> ConnActionOutcome {
        .init(
            integrationID: descriptor.id,
            action: action.kind,
            kind: kind,
            evidence: evidence
        )
    }

    private func currentModelSelection(
        for upstreamID: String
    ) async -> ConnSessionModelSelection? {
        guard let effective = await broker.effectiveModelState(
            for: upstreamID
        ) else { return nil }
        return .init(
            modelID: Self.modelID(
                provider: effective.provider,
                modelID: effective.modelID
            ),
            reasoningEffortID: .init(rawValue: effective.thinkingLevel)
        )
    }

    private func apply(
        _ selection: ConnSessionModelSelection,
        to upstreamID: String,
        action: ConnAction
    ) async -> ConnActionOutcome? {
        guard let desired = Self.splitModelID(selection.modelID),
              let effective = await broker.effectiveModelState(for: upstreamID),
              effective.isIdle,
              effective.availableModels.contains(where: {
                  $0.provider == desired.provider
                      && $0.modelID == desired.modelID
                      && $0.thinkingLevels.contains(
                          selection.reasoningEffortID.rawValue
                      )
              }) else {
            return outcome(
                action,
                .rejected,
                "Pi model selection is stale, unavailable, or the Session is active"
            )
        }
        var state = effective
        if state.provider != desired.provider || state.modelID != desired.modelID {
            switch await broker.send(
                .setModel(
                    id: UUID().uuidString,
                    provider: desired.provider,
                    modelID: desired.modelID
                ),
                to: upstreamID
            ) {
            case let .accepted(response)
                where response.modelProvider == desired.provider
                    && response.modelID == desired.modelID:
                state = .init(
                    provider: response.modelProvider,
                    modelID: response.modelID,
                    modelName: response.modelName,
                    thinkingLevel: response.thinkingLevel,
                    isIdle: response.isIdle,
                    availableModels: response.availableModels
                )
            case let .rejected(error, _):
                return outcome(action, .rejected, error)
            case .accepted:
                return outcome(
                    action,
                    .rejected,
                    "Pi did not confirm the requested model"
                )
            case .acknowledgementUncertain:
                return outcome(
                    action,
                    .acknowledgementUncertain,
                    "Pi model acknowledgement was not received; Conn will not send the message"
                )
            }
        }
        let desiredThinking = selection.reasoningEffortID.rawValue
        if state.thinkingLevel != desiredThinking {
            switch await broker.send(
                .setThinking(id: UUID().uuidString, level: desiredThinking),
                to: upstreamID
            ) {
            case let .accepted(response)
                where response.modelProvider == desired.provider
                    && response.modelID == desired.modelID
                    && response.thinkingLevel == desiredThinking:
                break
            case let .rejected(error, _):
                return outcome(action, .rejected, error)
            case .accepted:
                return outcome(
                    action,
                    .rejected,
                    "Pi did not confirm the requested reasoning level"
                )
            case .acknowledgementUncertain:
                return outcome(
                    action,
                    .acknowledgementUncertain,
                    "Pi reasoning acknowledgement was not received; Conn will not send the message"
                )
            }
        }
        return nil
    }

    private static func modelID(
        provider: String,
        modelID: String
    ) -> ConnSessionModelID {
        .init(rawValue: "\(provider)\u{1F}\(modelID)")
    }

    private static func splitModelID(
        _ id: ConnSessionModelID
    ) -> (provider: String, modelID: String)? {
        let parts = id.rawValue.split(
            separator: "\u{1F}",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            return nil
        }
        return (String(parts[0]), String(parts[1]))
    }

    private static func modelMetadata(
        provider: String,
        modelID: String,
        modelName: String?,
        thinking: String
    ) -> ConnSessionModelMetadata {
        let displayName = modelName.flatMap { $0.isEmpty ? nil : $0 } ?? modelID
        return .init(
            displayName: displayName,
            providerLabel: provider,
            reasoningLabel: thinking.capitalized
        )
    }
}
