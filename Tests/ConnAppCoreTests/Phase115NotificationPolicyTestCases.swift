import Foundation
import ConnAppCore
import ConnDomain

enum Phase115NotificationPolicyTestCases {
    static func run(into suite: inout TestSuite) async {
        eligibility(into: &suite)
        grouping(into: &suite)
        unseenFiltering(into: &suite)
        hydrationSeeding(into: &suite)
        await resumedHistoricalCompletionSeeding(into: &suite)
    }

    private static func eligibility(into suite: inout TestSuite) {
        for category in [
            AppServerTimelineCategory.command, .fileChange, .tool, .reasoning,
            .webSearch, .image, .lifecycle, .plan, .userMessage,
        ] {
            suite.check(
                !ShellUserFacingNotificationPolicy.isEligible(
                    category: category,
                    statusLabel: "Completed",
                    text: "Internal activity"
                ),
                "\(category) never produces a compact notification"
            )
        }
        suite.check(
            ShellUserFacingNotificationPolicy.isEligible(
                category: .agentOutput,
                statusLabel: "Completed",
                text: "User-facing commentary"
            ),
            "completed commentary produces a compact notification"
        )
        suite.check(
            ShellUserFacingNotificationPolicy.isEligible(
                category: .finalAnswer,
                statusLabel: "Completed",
                text: "Compiled answer"
            ),
            "a completed compiled answer produces a compact notification"
        )
        suite.check(
            !ShellUserFacingNotificationPolicy.isEligible(
                category: .agentOutput,
                statusLabel: "In progress",
                text: "Partial delta"
            ),
            "streaming fragments do not repeatedly notify"
        )
    }

    private static func grouping(into suite: inout TestSuite) {
        let alpha = AppServerThreadID(rawValue: "alpha")
        let beta = AppServerThreadID(rawValue: "beta")
        let a1 = notification("a1", thread: alpha, title: "Alpha task", text: "First")
        let a2 = notification("a2", thread: alpha, title: "Alpha task", text: "Second")
        let b1 = notification("b1", thread: beta, title: "Beta task", text: "Third")
        let sameThread = ShellUserFacingNotificationPolicy.batch([a1, a2])
        suite.checkEqual(sameThread?.groups.map(\.threadTitle), ["Alpha task"], "same-thread overlap uses one heading")
        suite.checkEqual(sameThread?.groups.first?.messages.map(\.id), ["a1", "a2"], "same-thread messages share one named group")
        let differentThreads = ShellUserFacingNotificationPolicy.batch([a1, b1])
        suite.checkEqual(differentThreads?.groups.map(\.threadTitle), ["Alpha task", "Beta task"], "different-thread overlap retains separate attribution")
        suite.check((differentThreads?.duration ?? 0) >= 5, "notification duration leaves enough reading time")
        let single = ShellUserFacingNotificationPolicy.batch([a1])
        suite.check(
            (differentThreads?.preferredHeight ?? 0) > (single?.preferredHeight ?? 0),
            "overlapping text blocks expand the compact shelf instead of colliding"
        )
        suite.checkEqual(
            ShellUserFacingNotificationPolicy.batch([a1, a2, b1])?.groups.flatMap(\.messages).count,
            2,
            "additional overlap remains queued instead of clipping the visible shelf"
        )
        suite.checkEqual(
            ShellUserFacingNotificationPolicy.batch([a1, a2, b1])?.groups
                .flatMap(\.messages).map(\.id),
            ["a2", "b1"],
            "an overlapping batch follows the transcript's newest two messages"
        )
        suite.check(
            single?.showsCompletionIndicator == false,
            "commentary notifications retain the animated activity indicator"
        )
        let final = notification(
            "final",
            thread: alpha,
            title: "Alpha task",
            text: "Finished",
            observedAt: Date(timeIntervalSince1970: 20),
            isFinalAnswer: true
        )
        suite.check(
            ShellUserFacingNotificationPolicy.batch([a1, final])?.showsCompletionIndicator == true,
            "the newest compiled answer replaces the waveform with a completion indicator"
        )
        let afterFinal = notification(
            "after-final",
            thread: alpha,
            title: "Alpha task",
            text: "Continuing",
            observedAt: Date(timeIntervalSince1970: 30)
        )
        suite.check(
            ShellUserFacingNotificationPolicy.batch([final, afterFinal])?.showsCompletionIndicator == false,
            "newer commentary restores the activity indicator even after an older final answer"
        )
        let sameTimeLater = notification(
            "a-lexically-first",
            thread: alpha,
            title: "Alpha task",
            text: "Later",
            observedAt: Date(timeIntervalSince1970: 10),
            sourceOrder: 2
        )
        let sameTimeEarlier = notification(
            "z-lexically-last",
            thread: alpha,
            title: "Alpha task",
            text: "Earlier",
            observedAt: Date(timeIntervalSince1970: 10),
            sourceOrder: 1
        )
        suite.checkEqual(
            ShellUserFacingNotificationPolicy.batch([sameTimeLater, sameTimeEarlier])?
                .groups.flatMap(\.messages).map(\.text),
            ["Earlier", "Later"],
            "equal-timestamp notifications follow transcript source order instead of opaque IDs"
        )
    }

    private static func unseenFiltering(into suite: inout TestSuite) {
        let thread = AppServerThreadID(rawValue: "thread")
        let notifications = [
            notification("seen", thread: thread, title: "Thread", text: "Old"),
            notification("new", thread: thread, title: "Thread", text: "New"),
        ]
        suite.checkEqual(
            ShellUserFacingNotificationPolicy.unseen(notifications, excluding: ["seen"]).map(\.id),
            ["new"],
            "completed assistant text notifies once"
        )
    }

    private static func hydrationSeeding(into suite: inout TestSuite) {
        suite.check(
            ShellUserFacingNotificationPolicy.shouldSeedFirstHydration(
                wasHydrated: false,
                visualState: .idle
            ),
            "the first lazy hydration of idle history seeds without alerting"
        )
        suite.check(
            ShellUserFacingNotificationPolicy.shouldSeedFirstHydration(
                wasHydrated: false,
                visualState: .running
            ),
            "the first detailed hydration of a running thread seeds history silently"
        )
        suite.check(
            !ShellUserFacingNotificationPolicy.shouldSeedFirstHydration(
                wasHydrated: true,
                visualState: .idle
            ),
            "later completed text on an already hydrated thread is not suppressed as history"
        )

        for visualState in [
            AppServerThreadVisualState.waitingForApproval,
            .needsInput,
        ] {
            suite.check(
                ShellUserFacingNotificationPolicy.shouldSeedFirstHydration(
                    wasHydrated: false,
                    visualState: visualState
                ),
                "first hydration seeds silently in \(visualState) state"
            )
        }
    }

    private static func resumedHistoricalCompletionSeeding(
        into suite: inout TestSuite
    ) async {
        let connection = AppServerConnectionIdentity(
            instanceID: UUID(uuidString: "11500000-0000-4000-8000-000000000006")!,
            generation: 115
        )
        let threadID = AppServerThreadID(rawValue: "idle-thread")
        let turnID = AppServerTurnID(rawValue: "old-turn")
        let oldItemID = AppServerItemID(rawValue: "old-answer")
        let store = AppServerProjectionStore()
        _ = await store.apply(.connectionActivated(
            identity: connection,
            source: .managedDaemon,
            featureSupport: .init(features: [.monitor])
        ))
        _ = await store.apply(.snapshot(.init(
            cursor: .init(connection: connection, sequence: 1),
            observedAt: Date(timeIntervalSince1970: 1_850_000_001),
            threads: [.init(
                id: threadID,
                sessionID: .init(rawValue: "idle-session"),
                title: "Idle thread",
                source: .appServer,
                status: .idle,
                updatedAt: Date(timeIntervalSince1970: 1_850_000_000),
                turnsAreAuthoritative: true,
                turns: [
                    .init(
                        id: turnID,
                        status: .completed,
                        completedAt: Date(timeIntervalSince1970: 1_850_000_000),
                        itemsView: .full,
                        items: [.init(
                            id: oldItemID,
                            kind: .agentMessage,
                            status: .completed,
                            completedAt: Date(timeIntervalSince1970: 1_850_000_000),
                            presentation: nil
                        )]
                    ),
                    .init(
                        id: .init(rawValue: "b"),
                        status: .completed,
                        itemsView: .full,
                        items: [.init(
                            id: .init(rawValue: "c:d"),
                            kind: .agentMessage,
                            status: .completed,
                            presentation: nil
                        )]
                    ),
                    .init(
                        id: .init(rawValue: "b:c"),
                        status: .completed,
                        itemsView: .full,
                        items: [.init(
                            id: .init(rawValue: "d"),
                            kind: .agentMessage,
                            status: .completed,
                            presentation: nil
                        )]
                    ),
                ]
            )]
        )))

        let baseline = await store.snapshot(at: Date(timeIntervalSince1970: 1_850_000_002))
        var seedLedger = ShellUserFacingNotificationSeedLedger()
        let seededIDs = seedLedger.consume(baseline.threads, notifications: [])
        suite.checkEqual(
            seededIDs.count,
            0,
            "terminal history with no materialized prose establishes a silent turn baseline"
        )

        let laterThreadID = AppServerThreadID(rawValue: "later-idle-thread")
        _ = await store.apply(.delta(.init(
            cursor: .init(connection: connection, sequence: 2),
            observedAt: Date(timeIntervalSince1970: 1_850_000_003),
            delta: .threadUpsert(.init(
                id: laterThreadID,
                sessionID: .init(rawValue: "later-idle-session"),
                title: "Later idle thread",
                source: .appServer,
                status: .idle,
                updatedAt: Date(timeIntervalSince1970: 1_850_000_000),
                turns: [.init(
                    id: .init(rawValue: "later-old-turn"),
                    status: .completed,
                    itemsView: .full,
                    items: [.init(
                        id: .init(rawValue: "later-old-answer"),
                        kind: .agentMessage,
                        status: .completed,
                        presentation: nil
                    )]
                )]
            ))
        )))
        let laterSnapshot = await store.snapshot(at: Date(timeIntervalSince1970: 1_850_000_003))
        let laterThreadSeededIDs = seedLedger.consume(laterSnapshot.threads, notifications: [])
        suite.checkEqual(
            laterThreadSeededIDs.count,
            0,
            "a terminal turn first observed later is sealed without item-level inference"
        )
        suite.checkEqual(
            seedLedger.consume(laterSnapshot.threads, notifications: []),
            [],
            "a repeated textless terminal publication remains silent"
        )

        let replayedTurnID = AppServerTurnID(rawValue: "same-thread-later-turn")
        let replayedItemID = AppServerItemID(rawValue: "same-thread-later-answer")
        _ = await store.apply(.delta(.init(
            cursor: .init(connection: connection, sequence: 3),
            observedAt: Date(timeIntervalSince1970: 1_850_000_004),
            delta: .turnUpsert(
                threadID: threadID,
                turn: .init(
                    id: replayedTurnID,
                    status: .completed,
                    completedAt: Date(timeIntervalSince1970: 1_850_000_004),
                    itemsView: .full,
                    items: [.init(
                        id: replayedItemID,
                        kind: .agentMessage,
                        status: .completed,
                        completedAt: Date(timeIntervalSince1970: 1_850_000_004),
                        presentation: nil
                    )]
                )
            )
        )))
        let sameThreadLateSnapshot = await store.snapshot(
            at: Date(timeIntervalSince1970: 1_850_000_004)
        )
        let sameThreadSeededIDs = seedLedger.consume(
            sameThreadLateSnapshot.threads,
            notifications: []
        )
        suite.checkEqual(
            sameThreadSeededIDs.count,
            0,
            "a later terminal turn in the same thread is sealed before prose is restored"
        )
        suite.checkEqual(
            seedLedger.consume(sameThreadLateSnapshot.threads, notifications: []),
            [],
            "the sealed same-thread turn stays silent without stable item IDs"
        )

        let mutatingTurnID = AppServerTurnID(rawValue: "same-turn-mutation")
        let mutatingItemID = AppServerItemID(rawValue: "same-item-mutation")
        _ = await store.apply(.delta(.init(
            cursor: .init(connection: connection, sequence: 5),
            observedAt: Date(timeIntervalSince1970: 1_850_000_005),
            delta: .turnUpsert(
                threadID: threadID,
                turn: .init(
                    id: mutatingTurnID,
                    status: .inProgress,
                    startedAt: Date(timeIntervalSince1970: 1_850_000_005),
                    itemsView: .full,
                    items: [.init(
                        id: mutatingItemID,
                        kind: .agentMessage,
                        status: .started
                    )]
                )
            )
        )))
        let beforeSameItemCompletion = await store.snapshot(
            at: Date(timeIntervalSince1970: 1_850_000_005)
        )
        suite.checkEqual(
            seedLedger.consume(beforeSameItemCompletion.threads, notifications: []),
            [],
            "an in-progress agent item is not silently seeded"
        )
        _ = await store.apply(.delta(.init(
            cursor: .init(connection: connection, sequence: 4),
            observedAt: Date(timeIntervalSince1970: 1_850_000_006),
            delta: .itemUpsert(
                threadID: threadID,
                turnID: mutatingTurnID,
                item: .init(
                    id: mutatingItemID,
                    kind: .agentMessage,
                    status: .completed,
                    completedAt: Date(timeIntervalSince1970: 1_850_000_006),
                    presentation: nil
                )
            )
        )))
        let sameItemMutationSeededIDs = seedLedger.consume(
            await store.snapshot(at: Date(timeIntervalSince1970: 1_850_000_006))
                .threads,
            notifications: []
        )
        suite.checkEqual(
            sameItemMutationSeededIDs.count,
            0,
            "an active turn does not infer notification history from a textless item"
        )

        let activeTurnID = AppServerTurnID(rawValue: "new-active-turn")
        _ = await store.apply(.delta(.init(
            cursor: .init(connection: connection, sequence: 6),
            observedAt: Date(timeIntervalSince1970: 1_850_000_007),
            delta: .turnUpsert(
                threadID: threadID,
                turn: .init(
                    id: activeTurnID,
                    status: .inProgress,
                    startedAt: Date(timeIntervalSince1970: 1_850_000_007),
                    itemsView: .full
                )
            )
        )))
        _ = await store.apply(.delta(.init(
            cursor: .init(connection: connection, sequence: 7),
            observedAt: Date(timeIntervalSince1970: 1_850_000_008),
            delta: .itemUpsert(
                threadID: threadID,
                turnID: replayedTurnID,
                item: .init(
                    id: replayedItemID,
                    kind: .agentMessage,
                    status: .completed,
                    completedAt: Date(timeIntervalSince1970: 1_850_000_004),
                    presentation: .agentFinalText("Previous completion")
                )
            )
        )))
        _ = await store.apply(.delta(.init(
            cursor: .init(connection: connection, sequence: 8),
            observedAt: Date(timeIntervalSince1970: 1_850_000_009),
            delta: .itemUpsert(
                threadID: threadID,
                turnID: turnID,
                item: .init(
                    id: oldItemID,
                    kind: .agentMessage,
                    status: .completed,
                    completedAt: Date(timeIntervalSince1970: 1_850_000_000),
                    presentation: .agentFinalText("Earlier previous completion")
                )
            )
        )))
        var accumulatedSeenIDs = seededIDs
        accumulatedSeenIDs.formUnion(laterThreadSeededIDs)
        accumulatedSeenIDs.formUnion(sameThreadSeededIDs)
        accumulatedSeenIDs.formUnion(sameItemMutationSeededIDs)
        let resumedSnapshot = await store.snapshot(
            at: Date(timeIntervalSince1970: 1_850_000_009)
        )
        let resumed = AppServerDomainPresentation(
            snapshot: resumedSnapshot,
            runtimeStatus: .init(phase: .connected, detail: "Testing resume seeding."),
            now: Date(timeIntervalSince1970: 1_850_000_009),
            detailedThreadIDs: [threadID]
        )
        let resumedNotifications = ShellUserFacingNotificationPolicy.collect(
            from: resumed.threads
        )
        let resumedSuppressedIDs = seedLedger.consume(
            resumedSnapshot.threads,
            notifications: resumedNotifications
        )
        suite.checkEqual(
            Set(resumedNotifications.map(\.text)),
            ["Earlier previous completion", "Previous completion"],
            "resume can atomically rematerialize multiple prior answers with new identities"
        )
        suite.checkEqual(
            ShellUserFacingNotificationPolicy.unseen(
                resumedNotifications,
                excluding: accumulatedSeenIDs.union(resumedSuppressedIDs)
            ).map(\.id),
            [],
            "starting the next turn suppresses every rematerialized sealed-turn completion"
        )
        accumulatedSeenIDs.formUnion(resumedSuppressedIDs)

        _ = await store.apply(.delta(.init(
            cursor: .init(connection: connection, sequence: 9),
            observedAt: Date(timeIntervalSince1970: 1_850_000_010),
            delta: .itemUpsert(
                threadID: threadID,
                turnID: activeTurnID,
                item: .init(
                    id: .init(rawValue: "new-answer"),
                    kind: .agentMessage,
                    status: .completed,
                    completedAt: Date(timeIntervalSince1970: 1_850_000_010),
                    presentation: .agentFinalText("Genuinely new completion")
                )
            )
        )))
        let afterNewCompletionSnapshot = await store.snapshot(
            at: Date(timeIntervalSince1970: 1_850_000_011)
        )
        let afterNewCompletion = AppServerDomainPresentation(
            snapshot: afterNewCompletionSnapshot,
            runtimeStatus: .init(phase: .connected, detail: "Testing resume seeding."),
            now: Date(timeIntervalSince1970: 1_850_000_011),
            detailedThreadIDs: [threadID]
        )
        let afterNewCompletionCollected = ShellUserFacingNotificationPolicy.collect(
            from: afterNewCompletion.threads
        )
        let afterNewCompletionSuppressedIDs = seedLedger.consume(
            afterNewCompletionSnapshot.threads,
            notifications: afterNewCompletionCollected
        )
        let newNotifications = ShellUserFacingNotificationPolicy.unseen(
            afterNewCompletionCollected,
            excluding: accumulatedSeenIDs.union(afterNewCompletionSuppressedIDs)
        )
        suite.check(
            newNotifications.count == 1
                && newNotifications.first?.text == "Genuinely new completion",
            "a distinct new completed assistant item still emits exactly once"
        )
        accumulatedSeenIDs.formUnion(newNotifications.map(\.id))
        suite.checkEqual(
            ShellUserFacingNotificationPolicy.unseen(
                ShellUserFacingNotificationPolicy.collect(from: afterNewCompletion.threads),
                excluding: accumulatedSeenIDs.union(
                    seedLedger.consume(
                        afterNewCompletionSnapshot.threads,
                        notifications: afterNewCompletionCollected
                    )
                )
            ),
            [],
            "the genuine current completion emits only once"
        )

        _ = await store.apply(.delta(.init(
            cursor: .init(connection: connection, sequence: 10),
            observedAt: Date(timeIntervalSince1970: 1_850_000_012),
            delta: .turnUpsert(
                threadID: threadID,
                turn: .init(
                    id: activeTurnID,
                    status: .completed,
                    completedAt: Date(timeIntervalSince1970: 1_850_000_012),
                    itemsView: .full,
                    items: [.init(
                        id: .init(rawValue: "new-answer"),
                        kind: .agentMessage,
                        status: .completed,
                        presentation: .agentFinalText("Genuinely new completion")
                    )]
                )
            )
        )))
        let terminalSnapshot = await store.snapshot(
            at: Date(timeIntervalSince1970: 1_850_000_012)
        )
        let terminalPresentation = AppServerDomainPresentation(
            snapshot: terminalSnapshot,
            runtimeStatus: .init(phase: .connected, detail: "Testing terminal seal."),
            now: Date(timeIntervalSince1970: 1_850_000_012),
            detailedThreadIDs: [threadID]
        )
        let terminalNotifications = ShellUserFacingNotificationPolicy.collect(
            from: terminalPresentation.threads
        )
        suite.checkEqual(
            seedLedger.consume(
                terminalSnapshot.threads,
                notifications: terminalNotifications
            ),
            resumedSuppressedIDs,
            "the active-to-terminal publication closes the epoch without suppressing its live answer"
        )

        _ = await store.apply(.delta(.init(
            cursor: .init(connection: connection, sequence: 11),
            observedAt: Date(timeIntervalSince1970: 1_850_000_013),
            delta: .turnUpsert(
                threadID: threadID,
                turn: .init(
                    id: activeTurnID,
                    status: .completed,
                    completedAt: Date(timeIntervalSince1970: 1_850_000_012),
                    itemsView: .full,
                    items: [.init(
                        id: .init(rawValue: "new-answer-remapped"),
                        kind: .agentMessage,
                        status: .completed,
                        presentation: .agentFinalText("Genuinely new completion")
                    )]
                )
            )
        )))
        let remappedTerminalSnapshot = await store.snapshot(
            at: Date(timeIntervalSince1970: 1_850_000_013)
        )
        let remappedTerminalPresentation = AppServerDomainPresentation(
            snapshot: remappedTerminalSnapshot,
            runtimeStatus: .init(phase: .connected, detail: "Testing sealed remap."),
            now: Date(timeIntervalSince1970: 1_850_000_013),
            detailedThreadIDs: [threadID]
        )
        let remappedTerminalNotifications = ShellUserFacingNotificationPolicy.collect(
            from: remappedTerminalPresentation.threads
        )
        let remappedTerminalSuppressedIDs = seedLedger.consume(
            remappedTerminalSnapshot.threads,
            notifications: remappedTerminalNotifications
        )
        suite.check(
            remappedTerminalNotifications.contains {
                $0.itemID.contains("new-answer-remapped")
                    && remappedTerminalSuppressedIDs.contains($0.id)
            },
            "a later item-ID remap of the sealed current turn is silently absorbed"
        )

        let coalescedTurnID = AppServerTurnID(rawValue: "coalesced-live-turn")
        _ = await store.apply(.delta(.init(
            cursor: .init(connection: connection, sequence: 12),
            observedAt: Date(timeIntervalSince1970: 1_850_000_014),
            delta: .turnUpsert(
                threadID: threadID,
                turn: .init(id: coalescedTurnID, status: .inProgress)
            )
        )))
        _ = await store.apply(.delta(.init(
            cursor: .init(connection: connection, sequence: 13),
            observedAt: Date(timeIntervalSince1970: 1_850_000_015),
            delta: .itemUpsert(
                threadID: threadID,
                turnID: coalescedTurnID,
                item: .init(
                    id: .init(rawValue: "coalesced-answer"),
                    kind: .agentMessage,
                    status: .completed,
                    presentation: .agentFinalText("Fast genuine completion")
                )
            )
        )))
        let splitActiveSnapshot = await store.snapshot(
            at: Date(timeIntervalSince1970: 1_850_000_015)
        )
        let splitActivePresentation = AppServerDomainPresentation(
            snapshot: splitActiveSnapshot,
            runtimeStatus: .init(phase: .connected, detail: "Testing split lifecycle."),
            now: Date(timeIntervalSince1970: 1_850_000_015),
            detailedThreadIDs: [threadID]
        )
        let splitActiveNotifications = ShellUserFacingNotificationPolicy.collect(
            from: splitActivePresentation.threads
        )
        let splitActiveSuppressedIDs = seedLedger.consume(
            splitActiveSnapshot.threads,
            notifications: splitActiveNotifications
        )
        let splitGenuineIDs = Set(splitActiveNotifications.compactMap {
            $0.text == "Fast genuine completion" ? $0.id : nil
        })
        suite.check(
            !splitGenuineIDs.isEmpty
                && splitGenuineIDs.isDisjoint(with: splitActiveSuppressedIDs),
            "a live final published before terminal status notifies immediately"
        )
        _ = await store.apply(.delta(.init(
            cursor: .init(connection: connection, sequence: 14),
            observedAt: Date(timeIntervalSince1970: 1_850_000_016),
            delta: .turnUpsert(
                threadID: threadID,
                turn: .init(
                    id: coalescedTurnID,
                    status: .completed,
                    completedAt: Date(timeIntervalSince1970: 1_850_000_016),
                    itemsView: .full,
                    items: [.init(
                        id: .init(rawValue: "coalesced-answer"),
                        kind: .agentMessage,
                        status: .completed,
                        presentation: .agentFinalText("Fast genuine completion")
                    )]
                )
            )
        )))
        let coalescedSnapshot = await store.snapshot(
            at: Date(timeIntervalSince1970: 1_850_000_016)
        )
        let coalescedPresentation = AppServerDomainPresentation(
            snapshot: coalescedSnapshot,
            runtimeStatus: .init(phase: .connected, detail: "Testing coalesced lifecycle."),
            now: Date(timeIntervalSince1970: 1_850_000_016),
            detailedThreadIDs: [threadID]
        )
        let coalescedNotifications = ShellUserFacingNotificationPolicy.collect(
            from: coalescedPresentation.threads
        )
        let coalescedSuppressedIDs = seedLedger.consume(
            coalescedSnapshot.threads,
            notifications: coalescedNotifications
        )
        suite.checkEqual(
            ShellUserFacingNotificationPolicy.unseen(
                coalescedNotifications,
                excluding: coalescedSuppressedIDs.union(splitGenuineIDs)
            ),
            [],
            "terminal status closes the split epoch without duplicating its live final"
        )

        let fullyCoalescedTurnID = AppServerTurnID(rawValue: "fully-coalesced-live-turn")
        _ = await store.apply(.delta(.init(
            cursor: .init(connection: connection, sequence: 15),
            observedAt: Date(timeIntervalSince1970: 1_850_000_017),
            delta: .turnUpsert(
                threadID: threadID,
                turn: .init(id: fullyCoalescedTurnID, status: .inProgress)
            )
        )))
        _ = await store.apply(.delta(.init(
            cursor: .init(connection: connection, sequence: 16),
            observedAt: Date(timeIntervalSince1970: 1_850_000_018),
            delta: .itemUpsert(
                threadID: threadID,
                turnID: fullyCoalescedTurnID,
                item: .init(
                    id: .init(rawValue: "fully-coalesced-answer"),
                    kind: .agentMessage,
                    status: .completed,
                    presentation: .agentFinalText("Fully coalesced completion")
                )
            )
        )))
        _ = await store.apply(.delta(.init(
            cursor: .init(connection: connection, sequence: 17),
            observedAt: Date(timeIntervalSince1970: 1_850_000_019),
            delta: .turnUpsert(
                threadID: threadID,
                turn: .init(
                    id: fullyCoalescedTurnID,
                    status: .completed,
                    items: [.init(
                        id: .init(rawValue: "fully-coalesced-answer"),
                        kind: .agentMessage,
                        status: .completed,
                        presentation: .agentFinalText("Fully coalesced completion")
                    )]
                )
            )
        )))
        let fullyCoalescedSnapshot = await store.snapshot(
            at: Date(timeIntervalSince1970: 1_850_000_019)
        )
        let fullyCoalescedPresentation = AppServerDomainPresentation(
            snapshot: fullyCoalescedSnapshot,
            runtimeStatus: .init(phase: .connected, detail: "Testing one-drain lifecycle."),
            now: Date(timeIntervalSince1970: 1_850_000_019),
            detailedThreadIDs: [threadID]
        )
        let fullyCoalescedNotifications = ShellUserFacingNotificationPolicy.collect(
            from: fullyCoalescedPresentation.threads
        )
        let fullyCoalescedSuppressedIDs = seedLedger.consume(
            fullyCoalescedSnapshot.threads,
            notifications: fullyCoalescedNotifications
        )
        suite.check(
            fullyCoalescedNotifications.contains {
                $0.text == "Fully coalesced completion"
                    && !fullyCoalescedSuppressedIDs.contains($0.id)
            },
            "a full live lifecycle reduced into one publication still notifies"
        )

        let reconnected = AppServerConnectionIdentity(
            instanceID: UUID(uuidString: "11500000-0000-4000-8000-000000000007")!,
            generation: 116
        )
        _ = await store.apply(.connectionActivated(
            identity: reconnected,
            source: .managedDaemon,
            featureSupport: .init(features: [.monitor])
        ))
        let reconnectedSnapshot = await store.snapshot(
            at: Date(timeIntervalSince1970: 1_850_000_020)
        )
        let reconnectedPresentation = AppServerDomainPresentation(
            snapshot: reconnectedSnapshot,
            runtimeStatus: .init(phase: .connected, detail: "Testing reconnect baseline."),
            now: Date(timeIntervalSince1970: 1_850_000_020),
            detailedThreadIDs: [threadID]
        )
        let reconnectedNotifications = ShellUserFacingNotificationPolicy.collect(
            from: reconnectedPresentation.threads
        )
        var reconnectedLedger = ShellUserFacingNotificationSeedLedger()
        let reconnectedSuppressedIDs = reconnectedLedger.consume(
            reconnectedSnapshot.threads,
            notifications: reconnectedNotifications
        )
        suite.check(
            reconnectedNotifications.contains {
                $0.text == "Fast genuine completion"
                    && reconnectedSuppressedIDs.contains($0.id)
            },
            "a new connection generation treats the prior live turn as historical"
        )
    }

    private static func notification(
        _ id: String,
        thread: AppServerThreadID,
        title: String,
        text: String,
        observedAt: Date? = nil,
        sourceOrder: Int = 0,
        isFinalAnswer: Bool = false
    ) -> ShellUserFacingNotification {
        .init(
            id: id,
            threadID: thread,
            threadTitle: title,
            itemID: id,
            text: text,
            observedAt: observedAt ?? Date(timeIntervalSince1970: Double(id.count)),
            sourceOrder: sourceOrder,
            isFinalAnswer: isFinalAnswer
        )
    }
}
