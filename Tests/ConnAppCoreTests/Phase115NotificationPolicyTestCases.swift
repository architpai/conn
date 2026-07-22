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
        let seededIDs = seedLedger.consume(baseline.threads)
        suite.checkEqual(
            seededIDs.count,
            3,
            "persisted assistant shells seed distinct identities even when raw IDs contain delimiters"
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
        suite.checkEqual(
            seedLedger.consume(laterSnapshot.threads).count,
            1,
            "a completed shell introduced by a later inventory publication is seeded once"
        )
        suite.checkEqual(
            seedLedger.consume(laterSnapshot.threads),
            [],
            "already-scanned thread histories are not repeatedly traversed or seeded"
        )

        _ = await store.apply(.delta(.init(
            cursor: .init(connection: connection, sequence: 3),
            observedAt: Date(timeIntervalSince1970: 1_850_000_004),
            delta: .itemUpsert(
                threadID: threadID,
                turnID: turnID,
                item: .init(
                    id: oldItemID,
                    kind: .agentMessage,
                    status: .completed,
                    completedAt: Date(timeIntervalSince1970: 1_850_000_000),
                    presentation: .agentFinalText("Previous completion")
                )
            )
        )))
        let resumed = AppServerDomainPresentation(
            snapshot: await store.snapshot(at: Date(timeIntervalSince1970: 1_850_000_004)),
            runtimeStatus: .init(phase: .connected, detail: "Testing resume seeding."),
            now: Date(timeIntervalSince1970: 1_850_000_004),
            detailedThreadIDs: [threadID]
        )
        suite.checkEqual(
            ShellUserFacingNotificationPolicy.unseen(
                ShellUserFacingNotificationPolicy.collect(from: resumed.threads),
                excluding: seededIDs
            ).map(\.id),
            [],
            "resume text for a persisted completion is not emitted as a duplicate notification"
        )

        _ = await store.apply(.delta(.init(
            cursor: .init(connection: connection, sequence: 4),
            observedAt: Date(timeIntervalSince1970: 1_850_000_005),
            delta: .itemUpsert(
                threadID: threadID,
                turnID: .init(rawValue: "new-turn"),
                item: .init(
                    id: .init(rawValue: "new-answer"),
                    kind: .agentMessage,
                    status: .completed,
                    completedAt: Date(timeIntervalSince1970: 1_850_000_005),
                    presentation: .agentFinalText("Genuinely new completion")
                )
            )
        )))
        let afterNewCompletion = AppServerDomainPresentation(
            snapshot: await store.snapshot(at: Date(timeIntervalSince1970: 1_850_000_006)),
            runtimeStatus: .init(phase: .connected, detail: "Testing resume seeding."),
            now: Date(timeIntervalSince1970: 1_850_000_006),
            detailedThreadIDs: [threadID]
        )
        let newNotifications = ShellUserFacingNotificationPolicy.unseen(
            ShellUserFacingNotificationPolicy.collect(from: afterNewCompletion.threads),
            excluding: seededIDs
        )
        suite.check(
            newNotifications.count == 1
                && newNotifications.first?.text == "Genuinely new completion",
            "a distinct new completed assistant item still emits exactly once"
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
