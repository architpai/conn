import Darwin
import Foundation
import ConnAppCore
import ConnDomain

enum Phase4NeutralAggregationTestCases {
    private static let codexID = IntegrationID(rawValue: "fixture-codex")
    private static let syntheticID = IntegrationID(rawValue: "fixture-synthetic")
    private static let generation = IntegrationConnectionGeneration(
        instanceID: UUID(uuidString: "44000000-0000-4000-8000-000000000001")!,
        ordinal: 1
    )
    private static let baseDate = Date(timeIntervalSince1970: 1_860_000_000)

    static func run(into suite: inout TestSuite) async throws {
        try await simultaneousIntegrationsRemainIsolated(into: &suite)
        try await restoredStateIsNonActionable(into: &suite)
        try twoSlotStoreRecoversLastValidGeneration(into: &suite)
        neutralPresentationPoliciesUseOnlySemanticState(into: &suite)
        historicalCompletedActivitiesLoadedLaterStaySilent(into: &suite)
        completedRunsCompressAroundTheirFullAnswer(into: &suite)
    }

    private static func historicalCompletedActivitiesLoadedLaterStaySilent(
        into suite: inout TestSuite
    ) {
        let sessionID = ConnSessionID(
            integrationID: codexID,
            upstreamID: .init(rawValue: "historical-completion")
        )
        let run = ConnRun(
            id: .init(rawValue: "historical-run"),
            status: .completed,
            startedAt: at(1),
            completedAt: at(2)
        )
        var ledger = ConnUserFacingNotificationLedger()
        suite.check(
            ledger.collect(from: ConnPresentationBuilder.make(aggregate(
                session: .init(
                    id: sessionID,
                    status: .completed,
                    runs: [run],
                    updatedAt: at(2)
                ),
                revision: 1
            ))).isEmpty,
            "initial completed inventory seeds silently before details load"
        )

        let historicalAnswer = ConnActivity(
            id: .init(rawValue: "historical-answer"),
            runID: run.id,
            kind: .agentMessage,
            status: .completed,
            summary: "An answer completed long before Conn opened this Session.",
            observedAt: at(2)
        )
        suite.check(
            ledger.collect(from: ConnPresentationBuilder.make(aggregate(
                session: .init(
                    id: sessionID,
                    status: .completed,
                    runs: [run],
                    activities: [historicalAnswer],
                    updatedAt: at(2)
                ),
                revision: 2
            ))).isEmpty,
            "opening a completed Session does not replay its historical answer as a notification"
        )

        let followUpRun = ConnRun(
            id: .init(rawValue: "follow-up-run"),
            status: .inProgress,
            startedAt: at(3)
        )
        _ = ledger.collect(from: ConnPresentationBuilder.make(aggregate(
            session: .init(
                id: sessionID,
                status: .working,
                runs: [run, followUpRun],
                activities: [historicalAnswer],
                updatedAt: at(3)
            ),
            revision: 3
        )))
        let followUpAnswer = ConnActivity(
            id: .init(rawValue: "follow-up-answer"),
            runID: followUpRun.id,
            kind: .agentMessage,
            status: .completed,
            summary: "A genuinely new answer.",
            observedAt: at(4)
        )
        let completedFollowUp = ConnRun(
            id: followUpRun.id,
            status: .completed,
            startedAt: at(3),
            completedAt: at(4)
        )
        suite.checkEqual(
            ledger.collect(from: ConnPresentationBuilder.make(aggregate(
                session: .init(
                    id: sessionID,
                    status: .completed,
                    runs: [run, completedFollowUp],
                    activities: [historicalAnswer, followUpAnswer],
                    updatedAt: at(4)
                ),
                revision: 4
            ))).map(\.text),
            ["A genuinely new answer."],
            "a follow-up notifies only output from the Run Conn observed active"
        )

        var delayedHydrationLedger = ConnUserFacingNotificationLedger()
        _ = delayedHydrationLedger.collect(from: ConnPresentationBuilder.make(aggregate(
            session: .init(
                id: sessionID,
                status: .completed,
                runs: [run],
                updatedAt: at(2)
            ),
            revision: 5
        )))
        suite.check(
            delayedHydrationLedger.collect(from: ConnPresentationBuilder.make(aggregate(
                session: .init(
                    id: sessionID,
                    status: .working,
                    runs: [run, followUpRun],
                    activities: [historicalAnswer],
                    updatedAt: at(3)
                ),
                revision: 6
            ))).isEmpty,
            "starting a follow-up cannot replay a late-hydrated answer from an older completed Run"
        )
    }

    private static func completedRunsCompressAroundTheirFullAnswer(
        into suite: inout TestSuite
    ) {
        let sessionID = ConnSessionID(
            integrationID: codexID,
            upstreamID: .init(rawValue: "completed-run-presentation")
        )
        let runID = RunID(rawValue: "completed-run")
        let fullAnswer = "First answer line.\nSecond answer line."
        let session = ConnSession(
            id: sessionID,
            title: "Completed run presentation",
            status: .completed,
            runs: [.init(
                id: runID,
                status: .completed,
                startedAt: at(1),
                completedAt: at(66)
            )],
            activities: [
                .init(
                    id: .init(rawValue: "completed-run:user"),
                    runID: runID,
                    kind: .userMessage,
                    status: .completed,
                    summary: "Question",
                    observedAt: at(1)
                ),
                .init(
                    id: .init(rawValue: "completed-run:answer"),
                    runID: runID,
                    kind: .agentMessage,
                    status: .completed,
                    summary: fullAnswer,
                    observedAt: at(2)
                ),
            ],
            updatedAt: at(2)
        )
        let descriptor = IntegrationDescriptor(
            id: codexID,
            harnessID: .init(rawValue: "openai"),
            displayName: "OpenAI"
        )
        let state = ConnSessionState(
            session: session,
            integration: descriptor,
            freshness: .live,
            actionAvailability: .init(available: [], unavailable: [:]),
            attention: []
        )
        let domain = ConnAggregateSnapshot(
            revision: 1,
            integrations: [],
            sessions: [state],
            projects: [],
            persistenceHealth: .healthy
        )
        let presentation = ConnPresentationBuilder.make(domain)
        suite.checkEqual(
            presentation.sessions.first?.runs.first?.summary,
            fullAnswer,
            "completed Run presentation preserves the full multiline answer"
        )
        suite.checkEqual(
            presentation.sessions.first?.runs.first?.triggeringUserMessage,
            "Question",
            "collapsed Run presentation preserves its triggering User message"
        )
        suite.checkEqual(
            presentation.sessions.first?.runs.first?.workedForLabel,
            "Worked for 1m 5s",
            "completed Run presentation derives a readable elapsed duration"
        )
        suite.check(
            presentation.sessions.first?.runs.first?.isCollapsedByDefault == true,
            "completed Runs default to a compressed presentation"
        )
        suite.checkEqual(
            presentation.sessions.first?.runs.first?.activities.count,
            2,
            "Run presentation groups its complete chronological Activity sequence"
        )
    }

    private static func simultaneousIntegrationsRemainIsolated(
        into suite: inout TestSuite
    ) async throws {
        let codexSessionID = ConnSessionID(
            integrationID: codexID,
            upstreamID: .init(rawValue: "same-upstream-id")
        )
        let syntheticSessionID = ConnSessionID(
            integrationID: syntheticID,
            upstreamID: .init(rawValue: "same-upstream-id")
        )
        let runID = RunID(rawValue: "codex-run")
        let workspace = WorkspaceEvidence(
            canonicalPath: "/tmp/shared-project",
            equivalenceKey: "local-workspace-identity"
        )
        let codex = ControlledIntegration(
            descriptor: .init(
                id: codexID,
                harnessID: .init(rawValue: "openai"),
                displayName: "Codex"
            ),
            snapshot: .init(
                integration: .init(
                    id: codexID,
                    harnessID: .init(rawValue: "openai"),
                    displayName: "Codex"
                ),
                generation: generation,
                throughSequence: 0,
                inventoryAuthority: .complete,
                capabilities: .init(
                    canMonitor: true,
                    actions: [.followUp, .steer, .interrupt]
                ),
                sessions: [.init(
                    id: codexSessionID,
                    title: "Codex Session",
                    workspace: workspace,
                    status: .working,
                    runs: [.init(id: runID, status: .inProgress)],
                    updatedAt: at(2)
                )],
                observedAt: at(2)
            ),
            actionOutcome: .accepted
        )
        let synthetic = ControlledIntegration(
            descriptor: .init(
                id: syntheticID,
                harnessID: .init(rawValue: "synthetic"),
                displayName: "Synthetic Monitor"
            ),
            snapshot: .init(
                integration: .init(
                    id: syntheticID,
                    harnessID: .init(rawValue: "synthetic"),
                    displayName: "Synthetic Monitor"
                ),
                generation: generation,
                throughSequence: 0,
                inventoryAuthority: .complete,
                capabilities: .init(canMonitor: true),
                sessions: [.init(
                    id: syntheticSessionID,
                    title: "Session-scoped Activity",
                    workspace: workspace,
                    status: .working,
                    activities: [.init(
                        id: .init(rawValue: "session-activity"),
                        runID: nil,
                        kind: .toolCall,
                        status: .started,
                        summary: "Monitor only",
                        observedAt: at(2)
                    )],
                    updatedAt: at(2)
                )],
                observedAt: at(2)
            ),
            actionOutcome: .accepted
        )
        let coordinator = try ConnIntegrationCoordinator(
            integrations: [codex, synthetic],
            retryDelay: .seconds(60)
        )
        await coordinator.start()
        defer { Task { await coordinator.stop() } }
        try await waitUntil {
            await coordinator.snapshot().integrations.allSatisfy {
                $0.freshness == .live
            }
        }

        var snapshot = await coordinator.snapshot()
        suite.checkEqual(snapshot.integrations.count, 2, "two Integrations aggregate simultaneously")
        suite.checkEqual(snapshot.sessions.count, 2, "both Harness Sessions remain visible")
        suite.check(
            snapshot.sessions.map(\.id).contains(codexSessionID)
                && snapshot.sessions.map(\.id).contains(syntheticSessionID),
            "identical upstream IDs remain scoped by Integration identity"
        )
        suite.checkEqual(snapshot.projects.count, 1, "proven Workspace identity groups across Harnesses")
        suite.checkEqual(
            snapshot.projects.first?.sessions.count,
            2,
            "cross-Harness Project retains both attributed Sessions"
        )
        let codexState = snapshot.sessions.first { $0.id == codexSessionID }
        let syntheticState = snapshot.sessions.first { $0.id == syntheticSessionID }
        suite.check(
            codexState?.actionAvailability.supports(.followUp) == true,
            "controllable Integration exposes its own live follow-up authority"
        )
        suite.check(
            syntheticState?.actionAvailability.available.isEmpty == true,
            "monitor-only Integration cannot borrow another Integration's capabilities"
        )
        suite.check(
            syntheticState?.session.runs.isEmpty == true
                && syntheticState?.session.activities.first?.runID == nil,
            "Session-scoped Activities require no invented Run"
        )

        let text = try ConnActionText("harmless follow-up")
        let accepted = await coordinator.perform(.followUp(
            sessionID: codexSessionID,
            text: text
        ))
        suite.checkEqual(accepted.kind, .accepted, "available action reaches the target Integration")
        suite.checkEqual(await codex.performedActionCount(), 1, "Codex-shaped fixture receives the action")
        suite.checkEqual(
            await synthetic.performedActionCount(),
            0,
            "monitor-only fixture receives no cross-routed action"
        )

        let refused = await coordinator.perform(.followUp(
            sessionID: syntheticSessionID,
            text: text
        ))
        suite.checkEqual(refused.kind, .unavailable, "unsupported local action fails before dispatch")
        suite.checkEqual(
            await synthetic.performedActionCount(),
            0,
            "unavailable action is never sent to its Integration"
        )

        await synthetic.yield(sequence: 1, update: .inventoryAuthorityChanged(.partial))
        try await waitUntil {
            await coordinator.snapshot().integrations.first {
                $0.id == syntheticID
            }?.inventoryAuthority == .partial
        }
        snapshot = await coordinator.snapshot()
        suite.check(
            snapshot.sessions.contains { $0.id == codexSessionID },
            "one Integration's partial inventory cannot remove another's Session"
        )
        suite.check(
            snapshot.sessions.contains { $0.id == syntheticSessionID },
            "partial inventory preserves its own omitted membership"
        )

        await synthetic.yield(sequence: 3, update: .authorityLost)
        try await waitUntil {
            await coordinator.snapshot().integrations.first {
                $0.id == syntheticID
            }?.freshness == .stale
        }
        snapshot = await coordinator.snapshot()
        suite.check(
            snapshot.integrations.first { $0.id == codexID }?.freshness == .live,
            "one Integration's sequence gap cannot stale another Integration"
        )
        suite.check(
            snapshot.sessions.first { $0.id == codexSessionID }?
                .actionAvailability.supports(.followUp) == true,
            "unrelated Integration overflow cannot revoke current Codex authority"
        )
        suite.check(
            snapshot.sessions.first { $0.id == syntheticSessionID }?
                .actionAvailability.available.isEmpty == true,
            "failed Integration becomes non-actionable while its Session stays visible"
        )
    }

    private static func restoredStateIsNonActionable(
        into suite: inout TestSuite
    ) async throws {
        let sessionID = ConnSessionID(
            integrationID: codexID,
            upstreamID: .init(rawValue: "restored")
        )
        let descriptor = IntegrationDescriptor(
            id: codexID,
            harnessID: .init(rawValue: "openai"),
            displayName: "Codex"
        )
        let checkpoint = ConnProjectionCheckpoint(integrations: [
            .init(
                descriptor: descriptor,
                inventoryAuthority: .complete,
                sessions: [.init(
                    id: sessionID,
                    title: "Restored",
                    status: .idle,
                    updatedAt: at(1)
                )],
                checkpointedAt: at(1)
            ),
        ])
        let store = MemoryCheckpointStore(checkpoint: checkpoint)
        let integration = ControlledIntegration(
            descriptor: descriptor,
            snapshot: .init(
                integration: descriptor,
                generation: generation,
                throughSequence: 0,
                inventoryAuthority: .complete,
                capabilities: .init(canMonitor: true, actions: [.followUp]),
                sessions: [],
                observedAt: at(2)
            ),
            actionOutcome: .accepted
        )
        let coordinator = try ConnIntegrationCoordinator(
            integrations: [integration],
            checkpointStore: store
        )
        let snapshot = await coordinator.snapshot()
        suite.checkEqual(snapshot.sessions.count, 1, "neutral checkpoint restores bounded Session rows")
        suite.checkEqual(
            snapshot.sessions.first?.freshness,
            .rehydrated,
            "restored Session begins rehydrated"
        )
        suite.check(
            snapshot.sessions.first?.actionAvailability.available.isEmpty == true,
            "restored state has no action authority"
        )
        suite.check(
            snapshot.sessions.first?.attention.isEmpty == true,
            "Attention response authority is never restored"
        )
        let encoded = try JSONEncoder().encode(await coordinator.checkpoint(at: at(2)))
        let text = String(decoding: encoded, as: UTF8.self)
        suite.check(
            text.contains(ConnProjectionCheckpoint.formatDiscriminator),
            "neutral checkpoint carries its distinct root discriminator"
        )
        suite.check(
            !text.contains("capabilities")
                && !text.contains(generation.instanceID.uuidString)
                && !text.contains("responseAuthority"),
            "checkpoint cannot persist capabilities, generation, or response authority"
        )
    }

    private static func twoSlotStoreRecoversLastValidGeneration(
        into suite: inout TestSuite
    ) throws {
        let support = try temporaryPrivateDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let store = try ConnProjectionCheckpointFileStore(
            applicationSupportDirectory: support
        )
        let descriptor = IntegrationDescriptor(
            id: codexID,
            harnessID: .init(rawValue: "openai"),
            displayName: "Codex"
        )
        let first = ConnProjectionCheckpoint(integrations: [
            .init(
                descriptor: descriptor,
                inventoryAuthority: .complete,
                sessions: [],
                checkpointedAt: at(1)
            ),
        ])
        let second = ConnProjectionCheckpoint(integrations: [
            .init(
                descriptor: descriptor,
                inventoryAuthority: .complete,
                sessions: [.init(
                    id: .init(
                        integrationID: codexID,
                        upstreamID: .init(rawValue: "second")
                    ),
                    status: .idle,
                    updatedAt: at(2)
                )],
                checkpointedAt: at(2)
            ),
        ])
        suite.checkEqual(try store.save(first), 1, "first neutral checkpoint uses generation one")
        suite.checkEqual(try store.save(second), 2, "second neutral checkpoint alternates slots")
        suite.checkEqual(try store.load(), second, "highest valid generation restores")

        let newest = store.rootDirectory.appendingPathComponent("checkpoint-b.json")
        let handle = try FileHandle(forWritingTo: newest)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("{invalid".utf8))
        try handle.synchronize()
        try handle.close()
        suite.checkEqual(
            try store.load(),
            first,
            "corrupt newest slot preserves the previous crash-consistent generation"
        )

        let rootAttributes = try FileManager.default.attributesOfItem(
            atPath: store.rootDirectory.path
        )
        let slotAttributes = try FileManager.default.attributesOfItem(
            atPath: store.rootDirectory.appendingPathComponent("checkpoint-a.json").path
        )
        suite.checkEqual(
            (rootAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o700,
            "neutral checkpoint directory is owner-only"
        )
        suite.checkEqual(
            (slotAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600,
            "neutral checkpoint slots are owner-only"
        )
        suite.check(
            !store.rootDirectory.path.contains("AppServerDomain"),
            "clean persistence cut uses a provider-neutral root"
        )
    }

    private static func neutralPresentationPoliciesUseOnlySemanticState(
        into suite: inout TestSuite
    ) {
        let sessionID = ConnSessionID(
            integrationID: codexID,
            upstreamID: .init(rawValue: "presentation")
        )
        let firstRun = ConnRun(
            id: .init(rawValue: "first-run"),
            status: .completed,
            startedAt: at(1),
            completedAt: at(2)
        )
        let firstActivity = ConnActivity(
            id: .init(rawValue: "first-message"),
            runID: firstRun.id,
            kind: .agentMessage,
            status: .completed,
            summary: "First bounded message",
            observedAt: at(2)
        )
        let initial = aggregate(
            session: .init(
                id: sessionID,
                title: "Neutral Session",
                workspace: .init(
                    canonicalPath: "/tmp/neutral-project",
                    equivalenceKey: "neutral-project"
                ),
                status: .completed,
                runs: [firstRun],
                activities: [firstActivity],
                updatedAt: at(2)
            ),
            revision: 1
        )
        let presentation = ConnPresentationBuilder.make(
            initial,
            harnessAssets: [.init(rawValue: "openai"): "OpenAI"]
        )
        suite.checkEqual(
            presentation.integrations.first?.statusLabel,
            "Live",
            "generic Integration presentation derives from neutral freshness"
        )
        suite.checkEqual(
            presentation.sessions.first?.harness.label,
            "Codex",
            "Session presentation keeps textual Harness attribution"
        )
        suite.checkEqual(
            presentation.sessions.first?.harness.assetName,
            "OpenAI",
            "composition may supply a Harness asset without changing the semantic model"
        )
        suite.checkEqual(
            presentation.sessions.first?.visualState,
            .completed,
            "neutral Session status drives visual state"
        )
        suite.checkEqual(
            ConnStatusPillPolicy.make(from: presentation.sessions).map(\.kind),
            [.completed],
            "completed Sessions remain represented in the status display"
        )
        let idlePresentation = ConnPresentationBuilder.make(aggregate(
            session: .init(
                id: .init(
                    integrationID: codexID,
                    upstreamID: .init(rawValue: "idle-status-pill")
                ),
                title: "Idle Session",
                status: .idle,
                updatedAt: at(2)
            ),
            revision: 2
        ))
        suite.checkEqual(
            ConnStatusPillPolicy.make(from: idlePresentation.sessions).map(\.kind),
            [.idle],
            "idle Sessions remain represented in the status display"
        )
        let oldIdle = ConnPresentationBuilder.make(aggregate(
            session: .init(
                id: .init(
                    integrationID: codexID,
                    upstreamID: .init(rawValue: "old-idle-status-pill")
                ),
                title: "Old Idle Session",
                status: .idle,
                updatedAt: at(1)
            ),
            revision: 3
        )).sessions
        let recentIdle = ConnPresentationBuilder.make(aggregate(
            session: .init(
                id: .init(
                    integrationID: codexID,
                    upstreamID: .init(rawValue: "recent-idle-status-pill")
                ),
                title: "Recent Idle Session",
                status: .idle,
                updatedAt: at(90_000)
            ),
            revision: 4
        )).sessions
        let visibleRows = SessionPickerPolicy.select(
            sessions: oldIdle + recentIdle,
            projects: [],
            configuration: .init(activityWindow: .last24Hours),
            now: at(90_001)
        ).rows
        let filteredIdlePill = ConnStatusPillPolicy.make(
            from: visibleRows.map(\.session)
        ).first
        suite.checkEqual(
            filteredIdlePill?.count,
            1,
            "idle count excludes inventory outside the sidebar's 24-hour window"
        )
        suite.checkEqual(
            filteredIdlePill?.primarySessionID,
            recentIdle.first?.id,
            "idle pill navigation stays inside the sidebar's filtered rows"
        )
        suite.checkEqual(
            SessionPickerPolicy.select(
                sessions: presentation.sessions,
                projects: presentation.projects,
                configuration: .init(activityWindow: .all, grouping: .project),
                now: at(10)
            ).groups.first?.rows.count,
            1,
            "Session picker groups semantic Sessions by proven Project"
        )

        var notificationLedger = ConnUserFacingNotificationLedger()
        suite.check(
            notificationLedger.collect(from: presentation).isEmpty,
            "first hydration seeds notification history silently"
        )
        let secondRun = ConnRun(
            id: .init(rawValue: "second-run"),
            status: .inProgress,
            startedAt: at(3)
        )
        _ = notificationLedger.collect(
            from: ConnPresentationBuilder.make(aggregate(
                session: .init(
                    id: sessionID,
                    title: "Neutral Session",
                    workspace: .init(
                        canonicalPath: "/tmp/neutral-project",
                        equivalenceKey: "neutral-project"
                    ),
                    status: .working,
                    runs: [firstRun, secondRun],
                    activities: [firstActivity],
                    updatedAt: at(3)
                ),
                revision: 2
            ))
        )
        let secondActivity = ConnActivity(
            id: .init(rawValue: "second-message"),
            runID: secondRun.id,
            kind: .agentMessage,
            status: .completed,
            summary: "New bounded message",
            observedAt: at(4)
        )
        let completedSecondRun = ConnRun(
            id: secondRun.id,
            status: .completed,
            startedAt: at(3),
            completedAt: at(4)
        )
        let messageCompletedWhileRunContinues = aggregate(
            session: .init(
                id: sessionID,
                title: "Neutral Session",
                workspace: .init(
                    canonicalPath: "/tmp/neutral-project",
                    equivalenceKey: "neutral-project"
                ),
                status: .working,
                runs: [firstRun, secondRun],
                activities: [firstActivity, secondActivity],
                updatedAt: at(4)
            ),
            revision: 3
        )
        let newNotifications = notificationLedger.collect(
            from: ConnPresentationBuilder.make(messageCompletedWhileRunContinues)
        )
        suite.checkEqual(
            newNotifications.map(\.text),
            ["New bounded message"],
            "only newly observed user-facing semantic output notifies"
        )
        let activeBatch = ConnUserFacingNotificationPolicy.batch(newNotifications)
        suite.checkEqual(
            activeBatch?.notifications.count,
            1,
            "Compact Shelf notification batching stays bounded"
        )
        suite.check(
            activeBatch?.notifications.first?.isFinal == false,
            "an answer arriving while its Run remains active initially shows activity"
        )
        let completedPresentation = ConnPresentationBuilder.make(aggregate(
            session: .init(
                id: sessionID,
                title: "Neutral Session",
                workspace: .init(
                    canonicalPath: "/tmp/neutral-project",
                    equivalenceKey: "neutral-project"
                ),
                status: .completed,
                runs: [firstRun, completedSecondRun],
                activities: [firstActivity, secondActivity],
                updatedAt: at(5)
            ),
            revision: 4
        ))
        let completedBatch = activeBatch.map {
            ConnUserFacingNotificationPolicy.reconcileFinality(
                of: $0,
                with: completedPresentation
            )
        }
        suite.check(
            completedBatch?.notifications.first?.isFinal == true,
            "the visible activity notification upgrades when its Session completes"
        )
        suite.checkEqual(
            completedBatch?.id,
            activeBatch?.id,
            "completion feedback preserves notification identity and its timer"
        )
        suite.checkEqual(
            completedBatch?.duration,
            activeBatch?.duration,
            "completion feedback does not restart or extend notification timing"
        )

        var sessionFallbackLedger = ConnUserFacingNotificationLedger()
        _ = sessionFallbackLedger.collect(from: ConnPresentationBuilder.make(aggregate(
            session: .init(
                id: sessionID,
                status: .working,
                runs: [],
                updatedAt: at(6)
            ),
            revision: 5
        )))
        let sessionScopedActivity = ConnActivity(
            id: .init(rawValue: "session-fallback-message"),
            kind: .agentMessage,
            status: .completed,
            summary: "Session-scoped update",
            observedAt: at(7)
        )
        let fallbackNotifications = sessionFallbackLedger.collect(
            from: ConnPresentationBuilder.make(aggregate(
                session: .init(
                    id: sessionID,
                    status: .working,
                    runs: [],
                    activities: [sessionScopedActivity],
                    updatedAt: at(7)
                ),
                revision: 6
            ))
        )
        suite.checkEqual(
            fallbackNotifications.map(\.text),
            ["Session-scoped update"],
            "a previously active Session can notify genuinely Session-scoped output"
        )

        var review = ConnOutcomeReviewLedger(baselineAt: at(2))
        suite.check(
            review.reconcile(with: initial, observedAt: at(2)),
            "first authoritative outcome establishes a clean v0.2 baseline"
        )
        suite.check(
            review.unreviewedOutcomeIDs.isEmpty,
            "historical completion is reviewed at the fresh baseline"
        )
        let overflowDescriptor = IntegrationDescriptor(
            id: codexID,
            harnessID: .init(rawValue: "openai"),
            displayName: "Codex"
        )
        let overflowSessions = (0...ConnOutcomeReviewLedger.maximumMarkers).map { index in
            let overflowID = ConnSessionID(
                integrationID: codexID,
                upstreamID: .init(rawValue: "active-overflow-\(index)")
            )
            return ConnSessionState(
                session: .init(
                    id: overflowID,
                    status: .working,
                    runs: [.init(
                        id: .init(rawValue: "run-\(index)"),
                        status: .inProgress,
                        startedAt: at(8)
                    )],
                    updatedAt: at(8)
                ),
                integration: overflowDescriptor,
                freshness: .live,
                actionAvailability: .init(available: [], unavailable: [:]),
                attention: []
            )
        }
        var boundedReview = ConnOutcomeReviewLedger(baselineAt: at(8))
        _ = boundedReview.reconcile(
            with: .init(
                revision: 8,
                integrations: [],
                sessions: overflowSessions,
                projects: [],
                persistenceHealth: .notConfigured
            ),
            observedAt: at(8)
        )
        suite.check(
            boundedReview.isValid(),
            "active Run observations are trimmed to the durable ledger bound"
        )
        let reviewSecondRun = ConnRun(
            id: .init(rawValue: "review-second-run"),
            status: .inProgress,
            startedAt: at(3)
        )
        _ = review.reconcile(
            with: aggregate(
                session: .init(
                    id: sessionID,
                    status: .working,
                    runs: [firstRun, reviewSecondRun],
                    updatedAt: at(3)
                ),
                revision: 5
            ),
            observedAt: at(3)
        )
        let completedReviewSecondRun = ConnRun(
            id: reviewSecondRun.id,
            status: .completed,
            startedAt: at(3),
            completedAt: at(4)
        )
        _ = review.reconcile(
            with: aggregate(
                session: .init(
                    id: sessionID,
                    status: .completed,
                    runs: [firstRun, completedReviewSecondRun],
                    updatedAt: at(4)
                ),
                revision: 6
            ),
            observedAt: at(4)
        )
        suite.check(
            review.unreviewedOutcomeIDs.contains(.init(
                sessionID: sessionID,
                runID: reviewSecondRun.id
            )),
            "a Run observed active then terminal becomes a new review outcome"
        )
    }

    private static func aggregate(
        session: ConnSession,
        revision: UInt64
    ) -> ConnAggregateSnapshot {
        let descriptor = IntegrationDescriptor(
            id: codexID,
            harnessID: .init(rawValue: "openai"),
            displayName: "Codex"
        )
        let availability = SessionActionAvailability(
            available: [.followUp],
            unavailable: [:]
        )
        let state = ConnSessionState(
            session: session,
            integration: descriptor,
            freshness: .live,
            actionAvailability: availability,
            attention: []
        )
        let project = ConnProjectState(
            id: .init(rawValue: "equivalent:neutral-project"),
            workspacePath: "/tmp/neutral-project",
            sessions: [session.id]
        )
        return .init(
            revision: revision,
            integrations: [.init(
                descriptor: descriptor,
                freshness: .live,
                inventoryAuthority: .complete,
                capabilities: .init(canMonitor: true, actions: [.followUp]),
                sessionCount: 1
            )],
            sessions: [state],
            projects: [project],
            persistenceHealth: .healthy
        )
    }

    private static func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WaitError.timedOut
    }

    private static func temporaryPrivateDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "conn-neutral-store-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private static func at(_ seconds: TimeInterval) -> Date {
        baseDate.addingTimeInterval(seconds)
    }

    private enum WaitError: Error {
        case timedOut
    }
}

private actor ControlledIntegration: ConnIntegration {
    nonisolated let descriptor: IntegrationDescriptor
    private let initialSnapshot: IntegrationSnapshot
    private let actionOutcome: ConnActionOutcomeKind
    private var continuation: AsyncStream<IntegrationUpdate>.Continuation?
    private var performedActions: [ConnAction] = []

    init(
        descriptor: IntegrationDescriptor,
        snapshot: IntegrationSnapshot,
        actionOutcome: ConnActionOutcomeKind
    ) {
        self.descriptor = descriptor
        self.initialSnapshot = snapshot
        self.actionOutcome = actionOutcome
    }

    func establishFeed() async throws(ConnIntegrationError) -> ConnIntegrationFeed {
        let pair = AsyncStream<IntegrationUpdate>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        continuation = pair.continuation
        return .init(snapshot: initialSnapshot, updates: pair.stream)
    }

    func perform(_ action: ConnAction) async -> ConnActionOutcome {
        performedActions.append(action)
        return .init(
            integrationID: descriptor.id,
            action: action.kind,
            kind: actionOutcome
        )
    }

    func yield(sequence: UInt64, update: IntegrationSemanticUpdate) {
        continuation?.yield(.init(
            integrationID: descriptor.id,
            cursor: .init(
                generation: initialSnapshot.generation,
                sequence: sequence
            ),
            observedAt: initialSnapshot.observedAt.addingTimeInterval(
                TimeInterval(sequence)
            ),
            update: update
        ))
    }

    func performedActionCount() -> Int {
        performedActions.count
    }
}

private final class MemoryCheckpointStore: ConnProjectionCheckpointStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: ConnProjectionCheckpoint?
    private var generation: UInt64 = 0

    init(checkpoint: ConnProjectionCheckpoint?) {
        value = checkpoint
    }

    func load() throws -> ConnProjectionCheckpoint? {
        lock.withLock { value }
    }

    func save(_ checkpoint: ConnProjectionCheckpoint) throws -> UInt64 {
        lock.withLock {
            generation += 1
            value = checkpoint
            return generation
        }
    }
}
