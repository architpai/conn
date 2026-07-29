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
            let task = Task { [broker] in
                var nextSequence = sequence
                var sessionsByUpstreamID = Dictionary(
                    uniqueKeysWithValues: initialSessions.map {
                        ($0.id.upstreamID.rawValue, $0)
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
                        continuation.yield(.init(
                            integrationID: PiExternalIntegrationIdentity.integrationID,
                            cursor: .init(generation: generation, sequence: nextSequence),
                            observedAt: now,
                            update: .sessionUpsert(mapped)
                        ))
                    case let .stateChanged(sessionID, state, event, activity):
                        let mapped = Self.session(
                            sessionID: sessionID,
                            state: state,
                            event: event,
                            activity: activity,
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
                    case .disconnected:
                        continuation.yield(.init(
                            integrationID: PiExternalIntegrationIdentity.integrationID,
                            cursor: .init(generation: generation, sequence: nextSequence),
                            observedAt: now,
                            update: .authorityLost
                        ))
                        continuation.finish()
                        await broker.stop()
                        return
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
            if let modelSelection,
               await currentModelSelection(
                   for: sessionID.upstreamID.rawValue
               ) != modelSelection {
                return outcome(
                    action,
                    .rejected,
                    "Pi's effective model changed; reload the current model selection"
                )
            }
            upstreamID = sessionID.upstreamID.rawValue
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
        let modelID = ConnSessionModelID(
            rawValue: "\(effective.provider)\u{1F}\(effective.modelID)"
        )
        let reasoningID = ConnReasoningEffortID(rawValue: effective.thinkingLevel)
        return .init(
            outcome: .available,
            catalog: .init(
                integrationID: descriptor.id,
                options: [
                    .init(
                        id: modelID,
                        displayName: effective.modelID,
                        detail: "Current authenticated Pi model",
                        isDefault: true,
                        reasoningEfforts: [
                            .init(
                                id: reasoningID,
                                displayName: effective.thinkingLevel.capitalized
                            )
                        ],
                        defaultReasoningEffortID: reasoningID
                    )
                ],
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
        let runID = RunID(rawValue: "pi-active-\(handshake.sessionID)")
        let runs = handshake.isIdle == false
            ? [ConnRun(id: runID, status: .inProgress, startedAt: observedAt)]
            : []
        return .init(
            id: .init(
                integrationID: PiExternalIntegrationIdentity.integrationID,
                upstreamID: .init(rawValue: handshake.sessionID)
            ),
            title: handshake.sessionName,
            workspace: .init(canonicalPath: handshake.workspace),
            origin: .external,
            retention: .persistent,
            status: handshake.isIdle == true ? .idle : .working,
            runs: runs,
            updatedAt: observedAt
        )
    }

    private static func sessionID(_ upstreamID: String) -> ConnSessionID {
        .init(
            integrationID: PiExternalIntegrationIdentity.integrationID,
            upstreamID: .init(rawValue: upstreamID)
        )
    }

    private static func session(
        sessionID: String,
        state: PiBridgeState,
        event: String,
        activity: PiBridgeActivity?,
        previous: ConnSession?,
        observedAt: Date
    ) -> ConnSession {
        let priorActiveRun = previous?.runs.last { $0.status == .inProgress }
        let activeRunID = priorActiveRun?.id ?? RunID(
            rawValue: "pi-run-\(sessionID)-\(Int(observedAt.timeIntervalSince1970 * 1_000))"
        )
        let runs: [ConnRun]
        if state.isIdle {
            runs = (previous?.runs ?? []).map {
                guard $0.status == .inProgress else { return $0 }
                return ConnRun(
                    id: $0.id,
                    status: .completed,
                    startedAt: $0.startedAt,
                    completedAt: observedAt
                )
            }
        } else if priorActiveRun != nil {
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
            let activityKind: ConnActivityKind = switch activity.kind {
            case "userMessage": .userMessage
            case "agentMessage": .agentMessage
            case "toolCall": .toolCall
            default: .unknown
            }
            let activityRunID = priorActiveRun?.id
                ?? (state.isIdle ? nil : activeRunID)
            activities.append(ConnActivity(
                id: .init(rawValue: activity.id),
                runID: activityRunID,
                kind: activityKind,
                status: event.hasSuffix("_end") ? .completed : .started,
                summary: activity.text,
                observedAt: observedAt
            ))
        }
        return .init(
            id: .init(
                integrationID: PiExternalIntegrationIdentity.integrationID,
                upstreamID: .init(rawValue: sessionID)
            ),
            title: state.sessionName,
            workspace: .init(canonicalPath: state.workspace),
            origin: .external,
            retention: .persistent,
            status: state.isIdle ? .idle : .working,
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
            modelID: .init(
                rawValue: "\(effective.provider)\u{1F}\(effective.modelID)"
            ),
            reasoningEffortID: .init(rawValue: effective.thinkingLevel)
        )
    }
}
