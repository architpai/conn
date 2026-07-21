import Foundation
import ConnAppCore
import ConnDomain

enum Phase92OutcomeReviewTestCases {
    private static let baseDate = Date(timeIntervalSince1970: 1_852_000_000)
    private static let connection = AppServerConnectionIdentity(
        instanceID: UUID(uuidString: "92000000-0000-4000-8000-000000000092")!,
        generation: 92
    )
    private static let threadID = AppServerThreadID(rawValue: "phase92-review-thread")
    private static let historicalTurn = AppServerTurnID(rawValue: "phase92-historical-turn")
    private static let newTurn = AppServerTurnID(rawValue: "phase92-new-turn")

    static func run(into suite: inout TestSuite) async {
        await baselinesHistoryAndTracksOnlyTheExactNewOutcome(into: &suite)
        await tracksATimestampLessOutcomeAfterTheAuthoritativeBaseline(into: &suite)
        await presentsAndClearsTheGreenUnreviewedPill(into: &suite)
        await persistsOnlyBoundedIdentityMetadata(into: &suite)
    }

    private static func tracksATimestampLessOutcomeAfterTheAuthoritativeBaseline(
        into suite: inout TestSuite
    ) async {
        let lateThreadID = AppServerThreadID(rawValue: "phase92-late-history-thread")
        let store = AppServerProjectionStore()
        _ = await store.apply(.connectionActivated(
            identity: connection,
            source: .managedDaemon,
            featureSupport: .init(features: [.monitor])
        ))
        _ = await store.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: at(11),
            threads: [AppServerThreadInput(
                id: threadID,
                sessionID: .init(rawValue: "phase92-no-timestamp-session"),
                title: "No timestamp",
                source: .appServer,
                status: .idle,
                createdAt: at(0),
                updatedAt: at(11),
                turnsAreAuthoritative: true,
                turns: []
            )],
            threadFreshness: .live
        )))
        var ledger = AppServerOutcomeReviewLedger(baselineAt: at(10))
        _ = ledger.reconcile(
            with: await store.snapshot(at: at(11)),
            hasCurrentAuthority: true,
            observedAt: at(11)
        )
        _ = await store.apply(.snapshot(.init(
            cursor: cursor(2),
            observedAt: at(12),
            threads: [
                AppServerThreadInput(
                    id: threadID,
                    sessionID: .init(rawValue: "phase92-no-timestamp-session"),
                    title: "No timestamp",
                    source: .appServer,
                    status: .active([]),
                    createdAt: at(0),
                    updatedAt: at(12),
                    turnsAreAuthoritative: true,
                    turns: [.init(id: newTurn, status: .inProgress, startedAt: at(12))]
                ),
                AppServerThreadInput(
                    id: lateThreadID,
                    sessionID: .init(rawValue: "phase92-late-history-session"),
                    title: "Late historical hydration",
                    source: .appServer,
                    status: .idle,
                    createdAt: at(0),
                    updatedAt: at(5),
                    turnsAreAuthoritative: true,
                    turns: [.init(
                        id: historicalTurn,
                        status: .completed,
                        startedAt: nil,
                        completedAt: nil
                    )]
                ),
            ],
            threadFreshness: .live
        )))
        _ = ledger.reconcile(
            with: await store.snapshot(at: at(12)),
            hasCurrentAuthority: true,
            observedAt: at(12)
        )
        let lateIdentity = AppServerOutcomeIdentity(
            threadID: lateThreadID,
            turnID: historicalTurn
        )
        suite.check(
            ledger.unreviewedOutcomeIDs.isEmpty
                && ledger.reviewedOutcomeIDs.contains(lateIdentity),
            "late hydration of timestamp-less historical completion stays reviewed"
        )

        _ = await store.apply(.snapshot(.init(
            cursor: cursor(3),
            observedAt: at(13),
            threads: [
                AppServerThreadInput(
                    id: threadID,
                    sessionID: .init(rawValue: "phase92-no-timestamp-session"),
                    title: "No timestamp",
                    source: .appServer,
                    status: .idle,
                    createdAt: at(0),
                    updatedAt: at(13),
                    turnsAreAuthoritative: true,
                    turns: [.init(
                        id: historicalTurn,
                        status: .completed,
                        startedAt: nil,
                        completedAt: nil
                    )]
                ),
                AppServerThreadInput(
                    id: lateThreadID,
                    sessionID: .init(rawValue: "phase92-late-history-session"),
                    title: "Late historical hydration",
                    source: .appServer,
                    status: .idle,
                    createdAt: at(0),
                    updatedAt: at(5),
                    turnsAreAuthoritative: true,
                    turns: [.init(
                        id: historicalTurn,
                        status: .completed,
                        startedAt: nil,
                        completedAt: nil
                    )]
                ),
            ],
            threadFreshness: .live
        )))
        _ = ledger.reconcile(
            with: await store.snapshot(at: at(13)),
            hasCurrentAuthority: true,
            observedAt: at(13)
        )
        suite.check(
            !ledger.unreviewedOutcomeIDs.contains(
                AppServerOutcomeIdentity(threadID: threadID, turnID: historicalTurn)
            ),
            "an intervening timestamp-less historical outcome stays reviewed"
        )

        _ = await store.apply(.snapshot(.init(
            cursor: cursor(4),
            observedAt: at(14),
            threads: [
                AppServerThreadInput(
                    id: threadID,
                    sessionID: .init(rawValue: "phase92-no-timestamp-session"),
                    title: "No timestamp",
                    source: .appServer,
                    status: .idle,
                    createdAt: at(0),
                    updatedAt: at(14),
                    turnsAreAuthoritative: true,
                    turns: [.init(
                        id: newTurn,
                        status: .completed,
                        startedAt: at(12),
                        completedAt: nil
                    )]
                ),
                AppServerThreadInput(
                    id: lateThreadID,
                    sessionID: .init(rawValue: "phase92-late-history-session"),
                    title: "Late historical hydration",
                    source: .appServer,
                    status: .idle,
                    createdAt: at(0),
                    updatedAt: at(5),
                    turnsAreAuthoritative: true,
                    turns: [.init(
                        id: historicalTurn,
                        status: .completed,
                        startedAt: nil,
                        completedAt: nil
                    )]
                ),
            ],
            threadFreshness: .live
        )))
        _ = ledger.reconcile(
            with: await store.snapshot(at: at(14)),
            hasCurrentAuthority: true,
            observedAt: at(14)
        )
        suite.checkEqual(
            ledger.unreviewedOutcomeIDs,
            [AppServerOutcomeIdentity(threadID: threadID, turnID: newTurn)],
            "an exact active-to-terminal timestamp-less transition becomes unreviewed"
        )
    }

    private static func baselinesHistoryAndTracksOnlyTheExactNewOutcome(
        into suite: inout TestSuite
    ) async {
        let store = await makeStore(turnID: historicalTurn, completedAt: at(5))
        var ledger = AppServerOutcomeReviewLedger(baselineAt: at(10))
        let historicalSnapshot = await store.snapshot(at: at(11))
        suite.check(
            ledger.reconcile(
                with: historicalSnapshot,
                hasCurrentAuthority: true,
                observedAt: at(11)
            ),
            "first authoritative outcome establishes a local review marker"
        )
        let historicalIdentity = AppServerOutcomeIdentity(
            threadID: threadID,
            turnID: historicalTurn
        )
        suite.check(
            ledger.reviewedOutcomeIDs.contains(historicalIdentity)
                && ledger.unreviewedOutcomeIDs.isEmpty,
            "pre-baseline terminal history is reviewed and never causes a green migration flood"
        )

        _ = await store.apply(.snapshot(.init(
            cursor: cursor(2),
            observedAt: at(21),
            threads: [thread(turnID: newTurn, completedAt: at(20))],
            threadFreshness: .live
        )))
        let newSnapshot = await store.snapshot(at: at(21))
        _ = ledger.reconcile(with: newSnapshot, hasCurrentAuthority: true, observedAt: at(21))
        let newIdentity = AppServerOutcomeIdentity(threadID: threadID, turnID: newTurn)
        suite.checkEqual(
            ledger.unreviewedOutcomeIDs,
            [newIdentity],
            "a different exact completion after the baseline becomes unreviewed"
        )
        suite.check(
            !ledger.markReviewed(historicalIdentity, at: at(22)),
            "reviewing an older captured turn is a no-op after a newer completion races it"
        )
        suite.check(
            ledger.markReviewed(newIdentity, at: at(22)),
            "the exact current completion can be marked reviewed"
        )
        suite.check(
            ledger.unreviewedOutcomeIDs.isEmpty
                && ledger.reviewedOutcomeIDs.contains(newIdentity),
            "reviewing the exact current outcome clears only its green state"
        )
    }

    private static func presentsAndClearsTheGreenUnreviewedPill(
        into suite: inout TestSuite
    ) async {
        let store = await makeStore(turnID: newTurn, completedAt: at(20))
        let snapshot = await store.snapshot(at: at(21))
        let identity = AppServerOutcomeIdentity(threadID: threadID, turnID: newTurn)
        let unreviewed = AppServerDomainPresentation(
            snapshot: snapshot,
            runtimeStatus: .init(phase: .connected, detail: "Phase 9.2"),
            now: at(21),
            unreviewedOutcomeIDs: [identity]
        )
        suite.checkEqual(unreviewed.threads.first?.visualState, .unreviewedOutcome, "new completed turn presents as the green state")
        suite.checkEqual(unreviewed.statusPills.map(\.visualState), [.unreviewedOutcome], "green completion receives one compact pill")
        suite.checkEqual(unreviewed.activeCount, 1, "unreviewed completion participates in canonical Active Thread count")
        suite.check(
            unreviewed.threads.first?.statusAccessibilityLabel.contains("not reviewed") == true,
            "green state exposes explicit not-reviewed accessibility copy"
        )

        let reviewed = AppServerDomainPresentation(
            snapshot: snapshot,
            runtimeStatus: .init(phase: .connected, detail: "Phase 9.2"),
            now: at(22),
            reviewedOutcomeIDs: [identity]
        )
        suite.checkEqual(reviewed.threads.first?.visualState, .idle, "reviewed completion returns to neutral idle")
        suite.check(
            !reviewed.statusPills.contains { $0.visualState == .unreviewedOutcome },
            "reviewed completion leaves the green pill without hiding its thread"
        )
        suite.checkEqual(reviewed.activeCount, 0, "reviewed completion no longer contributes live activity")

        let stale = AppServerDomainPresentation(
            snapshot: snapshot,
            runtimeStatus: .init(phase: .reconnecting, detail: "Stale"),
            now: at(23),
            unreviewedOutcomeIDs: [identity]
        )
        suite.checkEqual(stale.threads.first?.visualState, .unknown, "stale authority hides green rather than claiming unread completion")
    }

    private static func persistsOnlyBoundedIdentityMetadata(
        into suite: inout TestSuite
    ) async {
        let suiteName = "phase92-outcome-review-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            suite.check(false, "isolated UserDefaults suite is available")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppServerOutcomeReviewPreferenceStore(defaults: defaults)
        var ledger = AppServerOutcomeReviewLedger(baselineAt: at(10))
        let emptySnapshot = await AppServerProjectionStore().snapshot(at: at(11))
        _ = ledger.reconcile(with: emptySnapshot, hasCurrentAuthority: false, observedAt: at(11))
        suite.check(store.save(ledger), "valid bounded review ledger persists")
        suite.checkEqual(store.load(orBaselineAt: at(99)), ledger, "review ledger restores exactly")
        let encoded = defaults.data(forKey: AppServerOutcomeReviewPreferenceStore.defaultKey) ?? Data()
        let text = String(decoding: encoded, as: UTF8.self)
        suite.check(
            encoded.count <= AppServerOutcomeReviewPreferenceStore.maximumEncodedBytes,
            "review ledger obeys its explicit encoded byte bound"
        )
        for canary in ["prompt", "agentText", "reasoning", "tool output", "patch"] {
            suite.check(!text.contains(canary), "review ledger structurally excludes \(canary)")
        }

        defaults.set(Data("corrupt".utf8), forKey: AppServerOutcomeReviewPreferenceStore.defaultKey)
        let fallback = store.load(orBaselineAt: at(100))
        suite.checkEqual(fallback.baselineAt, at(100), "corrupt review data starts a safe fresh baseline")
        suite.check(fallback.markers.isEmpty, "corrupt review data never invents unreviewed outcomes")
    }

    private static func makeStore(
        turnID: AppServerTurnID,
        completedAt: Date
    ) async -> AppServerProjectionStore {
        let store = AppServerProjectionStore()
        _ = await store.apply(.connectionActivated(
            identity: connection,
            source: .managedDaemon,
            featureSupport: .init(features: [.monitor])
        ))
        _ = await store.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: completedAt,
            threads: [thread(turnID: turnID, completedAt: completedAt)],
            threadFreshness: .live
        )))
        return store
    }

    private static func thread(
        turnID: AppServerTurnID,
        completedAt: Date
    ) -> AppServerThreadInput {
        .init(
            id: threadID,
            sessionID: .init(rawValue: "phase92-review-session"),
            title: "Review outcome",
            source: .appServer,
            status: .idle,
            createdAt: at(0),
            updatedAt: completedAt,
            turnsAreAuthoritative: true,
            turns: [.init(
                id: turnID,
                status: .completed,
                startedAt: completedAt.addingTimeInterval(-1),
                completedAt: completedAt
            )]
        )
    }

    private static func cursor(_ sequence: UInt64) -> AppServerObservationCursor {
        .init(connection: connection, sequence: sequence)
    }

    private static func at(_ seconds: TimeInterval) -> Date {
        baseDate.addingTimeInterval(seconds)
    }
}
