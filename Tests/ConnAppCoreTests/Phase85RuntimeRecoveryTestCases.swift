import Foundation
import ConnAppCore
import ConnAppServerAdapter
import ConnDomain

enum Phase85RuntimeRecoveryTestCases {
    private static let observedAt = Date(timeIntervalSince1970: 1_830_000_000)
    private static let wireIdentity = ConnAppServerConnectionIdentity(
        instanceID: UUID(uuidString: "85000000-0000-4000-8000-000000000001")!,
        generation: 1
    )

    static func run(into suite: inout TestSuite) async throws {
        assertsProductionMonitoringTimeoutDefaults(into: &suite)
        resetsRetryLadderAfterHealthyInterval(into: &suite)
        boundsHydrationQualificationBatch(into: &suite)
        try await boundsHungInventoryRequest(into: &suite)
        try await paginatesAcrossEmptyCursorPage(into: &suite)
        try await ceilingMarksInventoryIncompleteWithoutRemoval(into: &suite)
        try await oversizedFinalPageRemainsNonAuthoritative(into: &suite)
        try await rendersMetadataBeforeQualification(into: &suite)
        try await qualifiesDefaultVisibleTierWithoutTurns(into: &suite)
        try await productionTierSubscribesOnlyActiveLoadedThreads(into: &suite)
        try await discoversNewlyActiveCrossProjectThread(into: &suite)
        try await skipsResumeWhenLoadedThreadBecameNotLoaded(into: &suite)
        try await metadataRefreshDoesNotRepeatStatusQualification(into: &suite)
        try await routineRefreshLocallyCapsNonconformingPage(into: &suite)
        try await optionalMetadataRefreshFailureKeepsConnectedInventory(into: &suite)
        try await newSessionResetsStatusQualificationTier(into: &suite)
        try await loadedListDiscoveryFailsOpen(into: &suite)
        try await cleansUpTimedOutResumeBeforeReturning(into: &suite)
        try await metadataRefreshUpdatesLiveTilesWithoutDetails(into: &suite)
        preservesQualifiedMetricAndLabelsInventoryAccurately(into: &suite)
        try await metadataRefreshPreservesRacingRuntimeFacts(into: &suite)
        await coalescesManualAndSchedulesPeriodicMetadataRefresh(into: &suite)
        try await drainsFiveHundredThreadResumeBursts(into: &suite)
        try await qualifiesOpenedThreadWithTurnsOnDemand(into: &suite)
        try await qualifiesAcknowledgedCreatedThreadWithoutResume(into: &suite)
        try await qualifiesAcknowledgedCreatedThreadDuringInitialHydration(into: &suite)
        try await refusesAcknowledgedCreatedThreadAfterConnectionChange(into: &suite)
        try await ignoresUnrequestedMalformedTurnsDuringStatusQualification(into: &suite)
        try await reconnectsWhenStoreDemandsAuthoritativeSnapshot(into: &suite)
        try await incompleteInitialInventoryPreservesSnapshotDemand(into: &suite)
        try await isolatesMalformedInventoryRowsWithoutUnsafeDeletion(into: &suite)
        try await boundsMetadataRefreshMembershipAcrossMalformedPages(into: &suite)
        try await metadataObservationOnlyRefreshIsCheckpointDuplicate(into: &suite)
        try await reconnectRequalifiesCachedRowsAfterEmptyPage(into: &suite)
        try await qualifiesNewThreadStartedDuringLiveSession(into: &suite)
        try await qualifiesAttentionRequestOutsideInitialScope(into: &suite)
        try await skipsMalformedKnownNotificationOnly(into: &suite)
    }

    private static func assertsProductionMonitoringTimeoutDefaults(
        into suite: inout TestSuite
    ) {
        let configuration = AppServerMonitoringRuntimeConfiguration()
        suite.checkEqual(
            configuration.inventoryRequestTimeout,
            .seconds(15),
            "production inventory requests use the reviewed 15-second budget"
        )
        suite.checkEqual(
            configuration.qualificationTimeout,
            .seconds(5),
            "production qualification reads use the reviewed 5-second budget"
        )
    }

    private static func boundsHydrationQualificationBatch(
        into suite: inout TestSuite
    ) {
        let listed: Set<AppServerThreadID> = [
            .init(rawValue: "selected-b"),
            .init(rawValue: "selected-a"),
        ]
        let batch = AppServerMonitoringRuntime.hydrationQualificationBatch(
            requested: listed.union([.init(rawValue: "not-listed")]),
            listed: listed
        )
        suite.checkEqual(
            batch.map(\.rawValue),
            ["selected-a", "selected-b"],
            "initial hydration consumes one deterministic snapshot of listed selection requests"
        )
    }

    private static func qualifiesAcknowledgedCreatedThreadWithoutResume(
        into suite: inout TestSuite
    ) async throws {
        let threadID = AppServerThreadID(rawValue: "acknowledged-ephemeral")
        let fake = ScriptedMonitoringConnection(identity: wireIdentity, responses: [
            .init(method: "thread/read", response: read(sequence: 1, id: threadID.rawValue)),
        ])
        let coordinator = try await activatedCoordinator(snapshotSequence: 0)
        let connection = AppServerObservationAdapter().connectionIdentity(from: wireIdentity)
        let result = await AppServerMonitoringRuntime().qualifyAcknowledgedCreatedThreadForTesting(
            threadID,
            acknowledgedConnection: connection,
            connection: fake,
            coordinator: coordinator
        )

        suite.check(result.didQualify, "exact acknowledged ephemeral thread qualifies from its bounded read")
        suite.checkEqual(result.scope.count, 1, "acknowledged ephemeral thread enters live monitoring scope")
        suite.checkEqual(await fake.requestedMethods(), ["thread/read"], "acknowledged ephemeral qualification never sends thread/resume")
        let snapshot = await coordinator.snapshot(at: observedAt)
        suite.checkEqual(snapshot.threads.first?.id, threadID, "read-only qualification publishes the exact acknowledged thread")
    }

    private static func refusesAcknowledgedCreatedThreadAfterConnectionChange(
        into suite: inout TestSuite
    ) async throws {
        let threadID = AppServerThreadID(rawValue: "stale-acknowledged-ephemeral")
        let fake = ScriptedMonitoringConnection(identity: wireIdentity, responses: [])
        let coordinator = try await activatedCoordinator(snapshotSequence: 0)
        let staleConnection = AppServerConnectionIdentity(
            instanceID: UUID(uuidString: "85000000-0000-4000-8000-000000000099")!,
            generation: 99
        )
        let result = await AppServerMonitoringRuntime().qualifyAcknowledgedCreatedThreadForTesting(
            threadID,
            acknowledgedConnection: staleConnection,
            connection: fake,
            coordinator: coordinator
        )

        suite.check(!result.didQualify, "stale acknowledged thread cannot qualify on a replacement connection")
        suite.checkEqual(result.scope.count, 0, "connection mismatch grants no monitoring scope")
        suite.checkEqual(await fake.requestedMethods(), [], "connection mismatch is rejected before any thread/read send")
    }

    private static func qualifiesAcknowledgedCreatedThreadDuringInitialHydration(
        into suite: inout TestSuite
    ) async throws {
        let threadID = AppServerThreadID(rawValue: "hydrating-acknowledged-ephemeral")
        let fake = ScriptedMonitoringConnection(identity: wireIdentity, responses: [
            .init(method: "thread/list", response: list(sequence: 1, ids: [threadID.rawValue], next: nil)),
            .init(method: "thread/loaded/list", response: loadedList(sequence: 2, ids: [], next: nil)),
            .init(method: "thread/read", response: .init(
                connection: wireIdentity,
                sequence: 2,
                result: .object(["thread": .object(threadInputValue(id: threadID.rawValue))])
            )),
        ])
        let coordinator = try await activatedCoordinator()
        let connection = AppServerObservationAdapter().connectionIdentity(from: wireIdentity)
        let runtime = AppServerMonitoringRuntime(configuration: .init(
            maximumBulkQualifiedThreads: 0
        ))
        await runtime.installAcknowledgedCreatedThreadQualificationForTesting(
            threadID,
            connection: connection
        )
        let result = try await runtime.hydrateInventoryForTesting(
            connection: fake,
            coordinator: coordinator
        )

        suite.check(result.qualifiedThreadIDs.contains(threadID), "initial hydration consumes the acknowledged empty-thread lease")
        suite.checkEqual(
            await fake.requestedMethods(),
            ["thread/list"],
            "initial hydration consumes authoritative list membership without read or resume"
        )
    }

    private static func metadataRefreshPreservesRacingRuntimeFacts(
        into suite: inout TestSuite
    ) async throws {
        let coordinator = try await activatedCoordinator(
            snapshotSequence: 1,
            threads: [threadInput(
                id: "race",
                turnsAreAuthoritative: true,
                turns: [.init(id: .init(rawValue: "preserved-turn"), status: .completed)]
            )]
        )
        let connection = AppServerObservationAdapter().connectionIdentity(from: wireIdentity)
        let threadID = AppServerThreadID(rawValue: "race")

        _ = try await coordinator.applyAndPersist(.delta(.init(
            cursor: .init(connection: connection, sequence: 2),
            observedAt: observedAt.addingTimeInterval(2),
            delta: .requestOpened(.init(
                requestID: .string("before-list"),
                threadID: threadID,
                kind: .structuredQuestion,
                startedAt: observedAt.addingTimeInterval(2)
            ))
        )))
        _ = try await coordinator.applyAndPersist(.snapshot(.init(
            cursor: .init(connection: connection, sequence: 4),
            observedAt: observedAt.addingTimeInterval(4),
            threads: [threadInput(
                id: "race",
                status: .active([]),
                turnsAreAuthoritative: true,
                turns: []
            )],
            contentAuthority: .metadataOnly
        )))
        let queuedResult = try await coordinator.applyAndPersist(.delta(.init(
            cursor: .init(connection: connection, sequence: 3),
            observedAt: observedAt.addingTimeInterval(3),
            delta: .requestOpened(.init(
                requestID: .string("queued-during-list"),
                threadID: threadID,
                kind: .structuredQuestion,
                startedAt: observedAt.addingTimeInterval(3)
            ))
        )))

        let snapshot = await coordinator.snapshot(at: observedAt.addingTimeInterval(5))
        suite.checkEqual(queuedResult, .applied, "metadata-only refresh does not fence a queued notification")
        suite.checkEqual(
            Set(snapshot.attentionRequests.map(\.id.requestID)),
            Set([.string("before-list"), .string("queued-during-list")]),
            "metadata-only refresh preserves existing requests and accepts the notification queued during thread/list"
        )
        suite.checkEqual(snapshot.threads.first?.status, .active([]), "metadata Sync refreshes an existing live tile's status")
        suite.checkEqual(snapshot.threads.first?.turns.map(\.id.rawValue), ["preserved-turn"], "metadata-only authority cannot prune existing turns")

        _ = try await coordinator.applyAndPersist(.snapshot(.init(
            cursor: .init(connection: connection, sequence: 5),
            observedAt: observedAt.addingTimeInterval(5),
            threads: [threadInput(id: "race", status: .unknown)],
            contentAuthority: .metadataOnly
        )))
        let afterUnknownSync = await coordinator.snapshot(at: observedAt.addingTimeInterval(5))
        suite.checkEqual(
            afterUnknownSync.threads.first?.status,
            .active([]),
            "unknown metadata refresh preserves the last trustworthy live status"
        )

        _ = try await coordinator.applyAndPersist(.snapshot(.init(
            cursor: .init(connection: connection, sequence: 6),
            observedAt: observedAt.addingTimeInterval(6),
            threads: [threadInput(id: "race", status: .idle)],
            contentAuthority: .metadataOnly
        )))
        let afterSecondSync = await coordinator.snapshot(at: observedAt.addingTimeInterval(7))
        suite.checkEqual(afterSecondSync.threads.first?.status, .idle, "a later metadata Sync can transition a live tile back to idle")
    }

    private static func ceilingMarksInventoryIncompleteWithoutRemoval(
        into suite: inout TestSuite
    ) async throws {
        let coordinator = try await activatedCoordinator(
            snapshotSequence: 1,
            threads: [threadInput(id: "cached-beyond-ceiling")]
        )
        let fake = ScriptedMonitoringConnection(identity: wireIdentity, responses: [
            .init(method: "thread/list", response: list(sequence: 2, ids: ["visible-at-ceiling"], next: "more")),
        ])
        let result = try await AppServerMonitoringRuntime(configuration: .init(
            pageSize: 1,
            maximumThreads: 1,
            maximumBulkQualifiedThreads: 0
        )).hydrateInventoryForTesting(connection: fake, coordinator: coordinator)
        let snapshot = await coordinator.snapshot(at: observedAt)
        suite.check(result.inventoryIsTruncated, "non-null cursor at the safety ceiling marks inventory incomplete")
        suite.checkEqual(result.listedCount, 1, "ceiling bounds only the newly listed inventory")
        suite.checkEqual(
            snapshot.threads.map(\.id.rawValue).sorted(),
            ["cached-beyond-ceiling", "visible-at-ceiling"],
            "incomplete ceiling inventory cannot authoritatively remove an out-of-window cached row"
        )
    }

    private static func oversizedFinalPageRemainsNonAuthoritative(
        into suite: inout TestSuite
    ) async throws {
        let coordinator = try await activatedCoordinator(
            snapshotSequence: 1,
            threads: [threadInput(id: "cached-beyond-final-page")]
        )
        let fake = ScriptedMonitoringConnection(identity: wireIdentity, responses: [
            .init(method: "thread/list", response: list(
                sequence: 2,
                ids: ["one", "two"],
                next: "final"
            )),
            .init(method: "thread/list", response: list(
                sequence: 3,
                ids: ["three", "four"],
                next: nil
            )),
        ])
        let result = try await AppServerMonitoringRuntime(configuration: .init(
            pageSize: 2,
            maximumThreads: 3,
            maximumBulkQualifiedThreads: 0
        )).hydrateInventoryForTesting(
            connection: fake,
            coordinator: coordinator,
            qualifyRecentThreads: false
        )
        let snapshot = await coordinator.snapshot(at: observedAt)
        suite.checkEqual(result.listedCount, 3, "non-divisible ceiling retains exactly the configured unique-row bound")
        suite.check(result.inventoryIsTruncated, "oversized nil-cursor final page is explicitly incomplete")
        suite.check(!result.inventoryMembershipIsComplete, "omitted final-page membership is explicitly non-authoritative")
        suite.check(
            snapshot.threads.contains { $0.id.rawValue == "cached-beyond-final-page" },
            "omitted unique final-page row prevents authoritative cached-row deletion"
        )
        suite.checkEqual(
            await fake.requestedListCursors(),
            [nil, "final"],
            "overflow is detected on the actual final page rather than inferred only from a cursor"
        )
    }

    private static func rendersMetadataBeforeQualification(
        into suite: inout TestSuite
    ) async throws {
        let fake = ScriptedMonitoringConnection(identity: wireIdentity, responses: [
            .init(method: "thread/list", response: list(sequence: 1, ids: ["recent", "older", "oldest"], next: nil)),
            .init(method: "thread/loaded/list", response: loadedList(sequence: 2, ids: ["recent"], next: nil)),
            .init(method: "thread/read", response: read(sequence: 3, id: "recent")),
            .init(method: "thread/resume", response: read(sequence: 4, id: "recent")),
        ])
        let coordinator = try await activatedCoordinator()
        let probe = HydrationProgressProbe()
        _ = try await AppServerMonitoringRuntime(configuration: .init(
            maximumBulkQualifiedThreads: 1
        )).hydrateInventoryForTesting(
            connection: fake,
            coordinator: coordinator,
            onProgress: { progress in
                let snapshot = await coordinator.snapshot(at: observedAt)
                await probe.recordFirst(
                    listedCount: progress.listedCount,
                    visibleCount: snapshot.threads.count,
                    readCount: await fake.requestedReadIncludeTurns().count
                )
            }
        )
        let first = await probe.first
        suite.checkEqual(first?.listedCount, 3, "metadata progress reports the complete listed inventory")
        suite.checkEqual(first?.visibleCount, 3, "metadata rows render before qualification completes")
        suite.checkEqual(first?.readCount, 0, "first metadata publication precedes every thread/read")
    }

    private static func qualifiesDefaultVisibleTierWithoutTurns(
        into suite: inout TestSuite
    ) async throws {
        let ids = (0..<17).map { "recent-\($0)" }
        var sequence: UInt64 = 1
        var responses: [ScriptedMonitoringConnection.Expected] = [
            .init(method: "thread/list", response: list(sequence: sequence, ids: ids, next: nil)),
        ]
        sequence += 1
        responses.append(.init(
            method: "thread/loaded/list",
            response: loadedList(sequence: sequence, ids: Array(ids.reversed()), next: nil)
        ))
        for id in ids.prefix(15) {
            sequence += 1
            responses.append(.init(method: "thread/read", response: read(sequence: sequence, id: id)))
            sequence += 1
            responses.append(.init(method: "thread/resume", response: read(sequence: sequence, id: id)))
        }
        let fake = ScriptedMonitoringConnection(identity: wireIdentity, responses: responses)
        let coordinator = try await activatedCoordinator()
        let inventoryTimeout = Duration.seconds(12)
        let qualificationTimeout = Duration.seconds(2)

        let result = try await AppServerMonitoringRuntime(configuration: .init(
            maximumConcurrentHydrations: 1,
            inventoryRequestTimeout: inventoryTimeout,
            qualificationTimeout: qualificationTimeout
        )).hydrateInventoryForTesting(connection: fake, coordinator: coordinator)

        let methods = await fake.requestedMethods()
        let snapshot = await coordinator.snapshot(at: observedAt.addingTimeInterval(100))
        suite.checkEqual(result.listedCount, 17, "initial inventory retains rows beyond the visible status tier")
        suite.checkEqual(result.hydratedCount, 15, "a new session qualifies the default visible 15-thread tier")
        suite.checkEqual(methods.filter { $0 == "thread/list" }.count, 1, "initial inventory lists metadata exactly once")
        suite.checkEqual(methods.filter { $0 == "thread/loaded/list" }.count, 1, "initial inventory discovers the in-memory set exactly once")
        suite.checkEqual(methods.filter { $0 == "thread/read" }.count, 15, "initial status tier performs exactly 15 reads")
        suite.checkEqual(methods.filter { $0 == "thread/resume" }.count, 15, "initial status tier performs exactly 15 resumes")
        suite.checkEqual(await fake.requestedReadThreadIDs(), Array(ids.prefix(15)), "loaded IDs are qualified in authoritative newest-first thread/list order")
        suite.checkEqual(Set(await fake.requestedReadIncludeTurns()), [false], "initial status qualification never loads turns")
        let timeoutRecords = await fake.requestedTimeouts()
        suite.checkEqual(
            Set(timeoutRecords.filter { $0.method == "thread/list" || $0.method == "thread/loaded/list" }.map(\.timeout)),
            [inventoryTimeout],
            "inventory and loaded-list requests receive the configured long per-request budget"
        )
        suite.checkEqual(
            Set(timeoutRecords.filter { $0.method == "thread/read" || $0.method == "thread/resume" }.map(\.timeout)),
            [qualificationTimeout],
            "detail read and resume requests receive the configured short per-request budget"
        )
        suite.check(snapshot.threads.allSatisfy(\.turns.isEmpty), "turn-bearing read/resume responses cannot populate timelines during status qualification")
    }

    private static func skipsResumeWhenLoadedThreadBecameNotLoaded(
        into suite: inout TestSuite
    ) async throws {
        var notLoaded = threadInputValue(id: "unloaded-race", status: "notLoaded")
        notLoaded["turns"] = .string("private timeline shape must not be decoded")
        let fake = ScriptedMonitoringConnection(identity: wireIdentity, responses: [
            .init(method: "thread/list", response: list(sequence: 1, ids: ["unloaded-race"], next: nil)),
            .init(method: "thread/loaded/list", response: loadedList(sequence: 2, ids: ["unloaded-race"], next: nil)),
            .init(method: "thread/read", response: .init(
                connection: wireIdentity,
                sequence: 3,
                result: .object(["thread": .object(notLoaded)])
            )),
        ])
        let coordinator = try await activatedCoordinator()

        let result = try await AppServerMonitoringRuntime(configuration: .init(
            maximumBulkQualifiedThreads: 1
        )).hydrateInventoryForTesting(connection: fake, coordinator: coordinator)
        let snapshot = await coordinator.snapshot(at: observedAt.addingTimeInterval(100))

        suite.checkEqual(result.hydratedCount, 0, "a loaded-list race to notLoaded is not counted as status-qualified")
        suite.checkEqual(await fake.requestedMethods(), ["thread/list", "thread/loaded/list", "thread/read"], "notLoaded metadata read skips thread/resume")
        suite.checkEqual(snapshot.threads.first?.status, .notLoaded, "the fail-open session still publishes the current notLoaded status")
        suite.checkEqual(snapshot.threads.first?.turns, [], "status-only decoding never inspects or retains malformed private timeline content")
    }

    private static func productionTierSubscribesOnlyActiveLoadedThreads(
        into suite: inout TestSuite
    ) async throws {
        let response = ConnAppServerResponseEnvelope(
            connection: wireIdentity,
            sequence: 1,
            result: .object([
                "data": .array([
                    .object(threadInputValue(id: "active", status: "active")),
                    .object(threadInputValue(id: "idle", status: "idle")),
                ]),
                "nextCursor": .null,
            ])
        )
        let fake = ScriptedMonitoringConnection(identity: wireIdentity, responses: [
            .init(method: "thread/list", response: response),
            .init(method: "thread/loaded/list", response: loadedList(
                sequence: 2,
                ids: ["active", "idle"],
                next: nil
            )),
            .init(method: "thread/read", response: read(sequence: 3, id: "active")),
            .init(method: "thread/resume", response: read(sequence: 4, id: "active")),
        ])
        let result = try await AppServerMonitoringRuntime(configuration: .init(
            maximumConcurrentHydrations: 1,
            maximumBulkQualifiedThreads: 2,
            bulkQualificationRequiresActiveStatus: true
        )).hydrateInventoryForTesting(
            connection: fake,
            coordinator: try await activatedCoordinator()
        )

        suite.checkEqual(result.hydratedCount, 1, "production startup subscribes only the active loaded tier")
        suite.checkEqual(await fake.requestedReadThreadIDs(), ["active"], "idle metadata rows are never read or resumed")
        suite.checkEqual(await fake.requestedReadIncludeTurns(), [false], "active startup subscription preflight remains turn-free")
    }

    private static func discoversNewlyActiveCrossProjectThread(
        into suite: inout TestSuite
    ) async throws {
        let activeList = ConnAppServerResponseEnvelope(
            connection: wireIdentity,
            sequence: 1,
            result: .object([
                "data": .array([.object(threadInputValue(
                    id: "ai-playground-task",
                    status: "active"
                ))]),
                "nextCursor": .null,
                "backwardsCursor": .null,
            ])
        )
        let fake = ScriptedMonitoringConnection(identity: wireIdentity, responses: [
            .init(method: "thread/list", response: activeList),
            .init(method: "thread/read", response: read(sequence: 2, id: "ai-playground-task")),
            .init(method: "thread/resume", response: read(sequence: 3, id: "ai-playground-task")),
        ])
        let coordinator = try await activatedCoordinator(snapshotSequence: 0)
        let result = await AppServerMonitoringRuntime(configuration: .init(
            activeDiscoveryInterval: 2,
            activeDiscoveryThreadLimit: 20
        )).refreshActiveSubscriptionsForTesting(
            connection: fake,
            coordinator: coordinator,
            scope: .init(),
            activeQualifiedThreadIDs: []
        )

        suite.checkEqual(
            result.newlyQualifiedThreadIDs,
            [.init(rawValue: "ai-playground-task")],
            "active discovery subscribes a task started in another project"
        )
        suite.check(result.scope.monitoredThreadIDs.contains(.init(rawValue: "ai-playground-task")), "newly active task enters live notification scope")
        suite.checkEqual(
            await fake.requestedMethods(),
            ["thread/list", "thread/read", "thread/resume"],
            "active discovery performs one bounded detailed qualification"
        )
        suite.checkEqual(await fake.requestedListLimits(), [20], "active discovery scans only the newest small working set")
        suite.checkEqual(await fake.requestedReadIncludeTurns(), [false], "active discovery avoids duplicate full-history reads")
        let snapshot = await coordinator.snapshot(at: observedAt)
        suite.check(snapshot.threads.first?.turns.isEmpty == false, "resume hydrates current prose so later user-facing deltas can notify")

        let unchanged = ScriptedMonitoringConnection(identity: wireIdentity, responses: [
            .init(method: "thread/list", response: .init(
                connection: wireIdentity,
                sequence: 4,
                result: .object([
                    "data": .array([.object(threadInputValue(id: "ai-playground-task", status: "active"))]),
                    "nextCursor": .null,
                    "backwardsCursor": .null,
                ])
            )),
        ])
        let repeated = await AppServerMonitoringRuntime(configuration: .init(
            activeDiscoveryInterval: 2,
            activeDiscoveryThreadLimit: 20
        )).refreshActiveSubscriptionsForTesting(
            connection: unchanged,
            coordinator: coordinator,
            scope: result.scope,
            activeQualifiedThreadIDs: result.activeQualifiedThreadIDs
        )
        suite.checkEqual(await unchanged.requestedMethods(), ["thread/list"], "unchanged active tasks are not repeatedly read or resumed")
        suite.check(!repeated.didApply, "unchanged active discovery does not rebuild or persist the projection")

        let recoveryCoordinator = try await activatedCoordinator()
        let domainConnection = AppServerObservationAdapter().connectionIdentity(from: wireIdentity)
        _ = try await recoveryCoordinator.applyAndPersist(.delta(.init(
            cursor: .init(connection: domainConnection, sequence: 1),
            observedAt: observedAt,
            delta: .requestOpened(.init(
                requestID: .string("requires-authority"),
                threadID: .init(rawValue: "ai-playground-task"),
                kind: .structuredQuestion,
                startedAt: observedAt
            ))
        )))
        let recovery = ScriptedMonitoringConnection(identity: wireIdentity, responses: [
            .init(method: "thread/list", response: .init(
                connection: wireIdentity,
                sequence: 2,
                result: activeList.result
            )),
        ])
        let recoveryResult = await AppServerMonitoringRuntime(configuration: .init(
            activeDiscoveryInterval: 2
        )).refreshActiveSubscriptionsForTesting(
            connection: recovery,
            coordinator: recoveryCoordinator,
            scope: .init(),
            activeQualifiedThreadIDs: []
        )
        suite.check(recoveryResult.requiresSnapshot, "active discovery propagates projection authority recovery instead of retrying silently")
        suite.checkEqual(await recovery.requestedMethods(), ["thread/list"], "authority recovery begins before any speculative read or resume")
    }

    private static func metadataRefreshDoesNotRepeatStatusQualification(
        into suite: inout TestSuite
    ) async throws {
        let fake = ScriptedMonitoringConnection(identity: wireIdentity, responses: [
            .init(method: "thread/list", response: list(sequence: 1, ids: ["recent", "older"], next: nil)),
            .init(method: "thread/loaded/list", response: loadedList(sequence: 2, ids: ["older"], next: nil)),
            .init(method: "thread/read", response: read(sequence: 3, id: "older")),
            .init(method: "thread/resume", response: read(sequence: 4, id: "older")),
            .init(method: "thread/list", response: list(sequence: 5, ids: ["recent", "older"], next: nil)),
        ])
        let coordinator = try await activatedCoordinator()
        let runtime = AppServerMonitoringRuntime(configuration: .init(
            maximumConcurrentHydrations: 1,
            maximumBulkQualifiedThreads: 2
        ))

        let initial = try await runtime.hydrateInventoryForTesting(
            connection: fake,
            coordinator: coordinator,
            qualifyRecentThreads: true
        )
        guard let refresh = try await runtime.optionalInventoryRefreshForTesting(
            connection: fake,
            coordinator: coordinator,
            initialScope: initial.scope
        ) else {
            suite.check(false, "healthy metadata Sync applies its staged inventory")
            return
        }

        let methods = await fake.requestedMethods()
        suite.checkEqual(refresh.listedCount, 2, "metadata refresh retains the current inventory")
        suite.checkEqual(methods.filter { $0 == "thread/list" }.count, 2, "initial inventory and later Sync each issue one thread/list")
        suite.checkEqual(methods.filter { $0 == "thread/loaded/list" }.count, 1, "metadata Sync does not repeat loaded-thread discovery")
        suite.checkEqual(methods.filter { $0 == "thread/read" }.count, 1, "metadata Sync does not repeat the session's initial read")
        suite.checkEqual(methods.filter { $0 == "thread/resume" }.count, 1, "metadata Sync does not repeat the session's initial resume")
        suite.checkEqual(await fake.requestedReadThreadIDs(), ["older"], "cold persisted rows are never resumed by the status tier")
        suite.checkEqual(await fake.requestedReadIncludeTurns(), [false], "status qualification remains turn-free before metadata-only Sync")
        suite.checkEqual(
            await fake.requestedListLimits(),
            [500, 100],
            "initial inventory uses the full page size while routine Sync requests only the recent working set"
        )
        suite.checkEqual(
            await fake.requestedListStateDBOnly(),
            [true, true],
            "initial inventory and routine Sync read indexed metadata without forcing full JSONL scans"
        )
    }

    private static func optionalMetadataRefreshFailureKeepsConnectedInventory(
        into suite: inout TestSuite
    ) async throws {
        let firstRefreshPage = ConnAppServerResponseEnvelope(
            connection: wireIdentity,
            sequence: 5,
            result: .object([
                "data": .array([
                    .object(threadInputValue(
                        id: "known",
                        status: "active",
                        updatedAt: 1_830_000_100
                    )),
                    .object(threadInputValue(id: "staged-only")),
                ]),
                "nextCursor": .string("late-page"),
                "backwardsCursor": .null,
            ])
        )
        let timeout = ScriptedMonitoringConnection(identity: wireIdentity, responses: [
            .init(method: "thread/list", response: list(sequence: 1, ids: ["known"], next: nil)),
            .init(method: "thread/loaded/list", response: loadedList(sequence: 2, ids: ["known"], next: nil)),
            .init(method: "thread/read", response: read(sequence: 3, id: "known")),
            .init(method: "thread/resume", response: read(sequence: 4, id: "known")),
            .init(method: "thread/list", response: firstRefreshPage),
            .init(
                method: "thread/list",
                response: list(sequence: 6, ids: ["late-row"], next: nil),
                delay: .seconds(60)
            ),
        ])
        let timeoutCoordinator = try await activatedCoordinator()
        let runtime = AppServerMonitoringRuntime(configuration: .init(
            maximumConcurrentHydrations: 1,
            maximumBulkQualifiedThreads: 1,
            inventoryRequestTimeout: .milliseconds(10)
        ))
        let initial = try await runtime.hydrateInventoryForTesting(
            connection: timeout,
            coordinator: timeoutCoordinator
        )
        let timedOutRefresh = try await runtime.optionalInventoryRefreshForTesting(
            connection: timeout,
            coordinator: timeoutCoordinator,
            initialScope: initial.scope
        )
        let afterTimeout = await timeoutCoordinator.snapshot(at: observedAt)

        suite.check(timedOutRefresh != nil, "bounded metadata refresh completes from its newest working-set page")
        suite.checkEqual(
            afterTimeout.threads.map(\.id.rawValue).sorted(),
            ["known", "staged-only"],
            "bounded metadata refresh merges its recent rows without waiting for a later page"
        )
        suite.checkEqual(initial.hydratedCount, 1, "the preserved inventory retains its initial qualification lower bound")
        suite.checkEqual(
            await timeout.requestedMethods(),
            ["thread/list", "thread/loaded/list", "thread/read", "thread/resume", "thread/list"],
            "routine metadata refresh performs one list request and repeats no qualification"
        )
        suite.checkEqual(await timeout.requestedListCursors(), [nil, nil], "routine metadata refresh never follows the working-set cursor")
        suite.check(
            timedOutRefresh?.scope.monitoredThreadIDs.contains(.init(rawValue: "staged-only")) == true,
            "recent working-set rows enter the live runtime scope"
        )
        suite.checkEqual(await timeout.disconnectCount(), 0, "optional metadata timeout does not disconnect the healthy session")
        suite.checkEqual(
            await timeout.monitoringState(),
            .ready(generation: wireIdentity.generation, version: .v0_144_6),
            "optional metadata timeout leaves the App Server connection ready"
        )
        suite.checkEqual(
            AppServerMonitoringRuntime.metadataRefreshUnavailableDiagnostic,
            "Metadata refresh unavailable; showing last-known inventory from this connected session.",
            "optional refresh failure remains connected with an honest last-known diagnostic"
        )

        let malformed = ScriptedMonitoringConnection(identity: wireIdentity, responses: [
            .init(method: "thread/list", response: list(sequence: 1, ids: ["known"], next: nil)),
            .init(method: "thread/loaded/list", response: loadedList(sequence: 2, ids: ["known"], next: nil)),
            .init(method: "thread/read", response: read(sequence: 3, id: "known")),
            .init(method: "thread/resume", response: read(sequence: 4, id: "known")),
            .init(method: "thread/list", response: .init(
                connection: wireIdentity,
                sequence: 5,
                result: .object(["data": .string("malformed")])
            )),
        ])
        let malformedCoordinator = try await activatedCoordinator()
        let malformedInitial = try await runtime.hydrateInventoryForTesting(
            connection: malformed,
            coordinator: malformedCoordinator
        )
        let malformedRefresh = try await runtime.optionalInventoryRefreshForTesting(
            connection: malformed,
            coordinator: malformedCoordinator,
            initialScope: malformedInitial.scope
        )
        suite.checkEqual(malformedRefresh, nil, "malformed later metadata is an optional unavailable refresh")
        suite.checkEqual(await malformed.disconnectCount(), 0, "malformed optional refresh does not disconnect the healthy session")
        let malformedMethods = await malformed.requestedMethods()
        suite.checkEqual(Array(malformedMethods.suffix(1)), ["thread/list"], "malformed optional refresh performs no status qualification fallback")

        let cancellationConnection = ScriptedMonitoringConnection(
            identity: wireIdentity,
            responses: [.init(
                method: "thread/list",
                response: list(sequence: 1, ids: ["known"], next: nil),
                delay: .seconds(60)
            )]
        )
        let cancellationTask = Task {
            try await runtime.optionalInventoryRefreshForTesting(
                connection: cancellationConnection,
                coordinator: try await activatedCoordinator(
                    snapshotSequence: 1,
                    threads: [threadInput(id: "known")]
                ),
                initialScope: .init()
            )
        }
        try await Task.sleep(for: .milliseconds(1))
        cancellationTask.cancel()
        do {
            _ = try await cancellationTask.value
            suite.check(false, "optional refresh cannot swallow cancellation")
        } catch is CancellationError {
            suite.check(true, "optional refresh propagates cancellation")
        } catch {
            suite.check(false, "optional refresh cancellation remains typed")
        }
    }

    private static func routineRefreshLocallyCapsNonconformingPage(
        into suite: inout TestSuite
    ) async throws {
        let response = ConnAppServerResponseEnvelope(
            connection: wireIdentity,
            sequence: 2,
            result: .object([
                "data": .array(["one", "two", "three"].map {
                    .object(threadInputValue(id: $0))
                }),
                "nextCursor": .null,
            ])
        )
        let coordinator = try await activatedCoordinator(snapshotSequence: 1)
        let result = try await AppServerMonitoringRuntime(configuration: .init(
            metadataRefreshThreadLimit: 2
        )).optionalInventoryRefreshForTesting(
            connection: ScriptedMonitoringConnection(identity: wireIdentity, responses: [
                .init(method: "thread/list", response: response),
            ]),
            coordinator: coordinator,
            initialScope: .init()
        )
        let snapshot = await coordinator.snapshot(at: observedAt)

        suite.checkEqual(result?.listedCount, 2, "routine refresh locally enforces its working-set limit")
        suite.checkEqual(result?.scope.count, 2, "oversized server pages cannot grow live scope past the local limit")
        suite.check(result?.inventoryIsTruncated == true, "locally omitted rows are reported as bounded")
        suite.checkEqual(
            snapshot.threads.map(\.id.rawValue),
            ["one", "two"],
            "only the newest locally bounded rows reach projection storage"
        )
    }

    private static func newSessionResetsStatusQualificationTier(
        into suite: inout TestSuite
    ) async throws {
        let runtime = AppServerMonitoringRuntime(configuration: .init(
            maximumConcurrentHydrations: 1,
            maximumBulkQualifiedThreads: 1
        ))
        let first = ScriptedMonitoringConnection(identity: wireIdentity, responses: [
            .init(method: "thread/list", response: list(sequence: 1, ids: ["first-session"], next: nil)),
            .init(method: "thread/loaded/list", response: loadedList(sequence: 2, ids: ["first-session"], next: nil)),
            .init(method: "thread/read", response: read(sequence: 3, id: "first-session")),
            .init(method: "thread/resume", response: read(sequence: 4, id: "first-session")),
        ])
        let second = ScriptedMonitoringConnection(identity: wireIdentity, responses: [
            .init(method: "thread/list", response: list(sequence: 1, ids: ["second-session"], next: nil)),
            .init(method: "thread/loaded/list", response: loadedList(sequence: 2, ids: ["second-session"], next: nil)),
            .init(method: "thread/read", response: read(sequence: 3, id: "second-session")),
            .init(method: "thread/resume", response: read(sequence: 4, id: "second-session")),
        ])

        _ = try await runtime.hydrateInventoryForTesting(
            connection: first,
            coordinator: try await activatedCoordinator()
        )
        _ = try await runtime.hydrateInventoryForTesting(
            connection: second,
            coordinator: try await activatedCoordinator()
        )

        suite.checkEqual(await first.requestedMethods(), ["thread/list", "thread/loaded/list", "thread/read", "thread/resume"], "first App Server session qualifies its recent loaded tier exactly once")
        suite.checkEqual(await second.requestedMethods(), ["thread/list", "thread/loaded/list", "thread/read", "thread/resume"], "a genuinely new App Server session receives a fresh loaded qualification tier")
        suite.checkEqual(await second.requestedReadIncludeTurns(), [false], "reconnected status qualification remains turn-free")
    }

    private static func loadedListDiscoveryFailsOpen(
        into suite: inout TestSuite
    ) async throws {
        let cursorCycle = ScriptedMonitoringConnection(identity: wireIdentity, responses: [
            .init(method: "thread/list", response: list(sequence: 1, ids: ["known"], next: nil)),
            .init(method: "thread/loaded/list", response: loadedList(sequence: 2, ids: ["known"], next: "repeat")),
            .init(method: "thread/loaded/list", response: loadedList(sequence: 3, ids: ["known"], next: "repeat")),
            .init(method: "thread/read", response: read(sequence: 4, id: "known")),
            .init(method: "thread/resume", response: read(sequence: 5, id: "known")),
        ])
        let cycleResult = try await AppServerMonitoringRuntime(configuration: .init(
            pageSize: 1,
            maximumThreads: 2,
            maximumBulkQualifiedThreads: 1
        )).hydrateInventoryForTesting(
            connection: cursorCycle,
            coordinator: try await activatedCoordinator()
        )
        suite.checkEqual(cycleResult.hydratedCount, 1, "a cursor cycle retains the safely discovered loaded prefix")
        suite.checkEqual(
            await cursorCycle.requestedMethods(),
            ["thread/list", "thread/loaded/list", "thread/loaded/list", "thread/read", "thread/resume"],
            "cursor-cycle detection stops discovery and keeps the healthy metadata session"
        )

        let malformed = ScriptedMonitoringConnection(identity: wireIdentity, responses: [
            .init(method: "thread/list", response: list(sequence: 1, ids: ["known"], next: nil)),
            .init(method: "thread/loaded/list", response: .init(
                connection: wireIdentity,
                sequence: 2,
                result: .object(["data": .string("malformed")])
            )),
        ])
        let malformedResult = try await AppServerMonitoringRuntime(configuration: .init(
            maximumBulkQualifiedThreads: 1
        )).hydrateInventoryForTesting(
            connection: malformed,
            coordinator: try await activatedCoordinator()
        )
        suite.checkEqual(malformedResult.listedCount, 1, "malformed optional discovery preserves metadata inventory")
        suite.checkEqual(malformedResult.hydratedCount, 0, "malformed optional discovery qualifies no uncertain rows")
        suite.checkEqual(await malformed.requestedMethods(), ["thread/list", "thread/loaded/list"], "malformed optional discovery fails open without resume")

        let timeout = LoadedListHangingMonitoringConnection(identity: wireIdentity)
        let timeoutResult = try await AppServerMonitoringRuntime(configuration: .init(
            maximumBulkQualifiedThreads: 1,
            inventoryRequestTimeout: .milliseconds(10)
        )).hydrateInventoryForTesting(
            connection: timeout,
            coordinator: try await activatedCoordinator()
        )
        suite.checkEqual(timeoutResult.listedCount, 1, "loaded-list timeout preserves the healthy metadata inventory")
        suite.checkEqual(timeoutResult.hydratedCount, 0, "loaded-list timeout resumes no uncertain row")
        suite.checkEqual(await timeout.requestedMethods(), ["thread/list", "thread/loaded/list"], "loaded-list timeout fails open without reconnect or resume")
    }

    private static func metadataRefreshUpdatesLiveTilesWithoutDetails(
        into suite: inout TestSuite
    ) async throws {
        let active = threadInputValue(id: "conn-latest", status: "active", updatedAt: 1_830_000_020)
        let idle = threadInputValue(id: "older-idle", status: "idle", updatedAt: 1_830_000_010)
        let fake = ScriptedMonitoringConnection(identity: wireIdentity, responses: [
            .init(method: "thread/list", response: .init(
                connection: wireIdentity,
                sequence: 1,
                result: .object([
                    "data": .array([.object(active), .object(idle)]),
                    "nextCursor": .null,
                    "backwardsCursor": .null,
                ])
            )),
        ])
        let coordinator = try await activatedCoordinator()
        let result = try await AppServerMonitoringRuntime().hydrateInventoryForTesting(
            connection: fake,
            coordinator: coordinator,
            qualifyRecentThreads: false
        )
        let snapshot = await coordinator.snapshot(at: observedAt)
        let presentation = AppServerDomainPresentation(
            snapshot: snapshot,
            runtimeStatus: .init(phase: .connected, detail: "metadata current"),
            now: observedAt
        )

        suite.checkEqual(result.listedCount, 2, "metadata refresh lists every current tile")
        suite.checkEqual(result.hydratedCount, 0, "metadata refresh performs no status qualification or detail hydration")
        suite.checkEqual(result.scope.count, 2, "listed rows enter the live notification scope")
        suite.checkEqual(await fake.requestedMethods(), ["thread/list"], "manual or periodic refresh is metadata-only")
        suite.checkEqual(snapshot.threads.map(\.id.rawValue), ["conn-latest", "older-idle"], "latest Conn metadata is visible first")
        suite.check(snapshot.threads.allSatisfy { $0.freshness == .live }, "current list rows are live tile evidence")
        suite.checkEqual(
            presentation.statusPills.map(\.visualState),
            [.running, .idle],
            "status aggregation uses current list metadata instead of hydration gaps"
        )
        suite.checkEqual(presentation.statusPills.map(\.count), [1, 1], "live metadata counts every status tile")
    }

    private static func cleansUpTimedOutResumeBeforeReturning(
        into suite: inout TestSuite
    ) async throws {
        let connection = SlowResumeCancellationMonitoringConnection(identity: wireIdentity)
        let coordinator = try await activatedCoordinator()
        let result = try await AppServerMonitoringRuntime(configuration: .init(
            maximumBulkQualifiedThreads: 1,
            qualificationTimeout: .milliseconds(20)
        )).hydrateInventoryForTesting(
            connection: connection,
            coordinator: coordinator
        )

        suite.checkEqual(result.hydratedCount, 0, "timed-out resume never qualifies the thread")
        let didStartResume = await connection.didStartResume()
        let wasResumeCancelled = await connection.wasResumeCancelled()
        let didCompleteResume = await connection.didCompleteResume()
        suite.check(didStartResume, "fast read reaches the slow resume stage")
        suite.check(wasResumeCancelled, "timeout cancels the losing resume request")
        suite.check(!didCompleteResume, "cancelled resume cannot subscribe successfully later")
        suite.checkEqual(await connection.pendingWorkCount(), 0, "bounded qualification awaits all losing request work before returning")
        suite.checkEqual(
            await connection.requestedMethods(),
            ["thread/list", "thread/loaded/list", "thread/read", "thread/resume"],
            "cleanup performs no retry or late follow-up request"
        )
        let snapshot = await coordinator.snapshot(at: observedAt)
        suite.checkEqual(snapshot.threads.first?.status, .idle, "late resume response cannot mutate the projection after timeout")
    }

    private static func preservesQualifiedMetricAndLabelsInventoryAccurately(
        into suite: inout TestSuite
    ) {
        var currentScope = AppServerMonitoringScope()
        currentScope.include(.init(rawValue: "still-listed"))
        currentScope.include(.init(rawValue: "newly-opened"))
        let retained = AppServerMonitoringRuntime.retainedQualifiedThreadIDs(
            previous: [
                .init(rawValue: "still-listed"),
                .init(rawValue: "no-longer-listed"),
            ],
            currentScope: currentScope,
            newlyQualified: [.init(rawValue: "newly-opened")]
        )
        suite.checkEqual(
            retained,
            [.init(rawValue: "still-listed"), .init(rawValue: "newly-opened")],
            "metadata Sync retains the initial qualification lower bound while pruning rows no longer in inventory"
        )
        suite.checkEqual(
            AppServerMonitoringRuntime.connectedInventoryDetail(
                listedCount: 20,
                qualifiedCount: 7,
                scopeCount: 20
            ),
            "Inventory metadata: 20 managed-daemon threads; 7 are status-qualified or opened. Detailed content is loaded only when opened. 20 tiles are in live notification scope.",
            "connected diagnostics distinguish inventory, qualification, detail, and notification scope"
        )
        suite.checkEqual(
            AppServerMonitoringRuntime.hydratingInventoryDetail(
                listedCount: 20,
                qualifiedCount: 7,
                scopeCount: 20
            ),
            "Inventory metadata: 20 threads; 7 are status-qualified or opened. 20 tiles are in live notification scope.",
            "hydration progress does not claim every listed row is qualified"
        )
    }

    private static func coalescesManualAndSchedulesPeriodicMetadataRefresh(
        into suite: inout TestSuite
    ) async {
        let runtime = AppServerMonitoringRuntime(configuration: .init(
            metadataRefreshInterval: 10
        ))
        suite.checkEqual(
            AppServerMonitoringRuntimeConfiguration().metadataRefreshInterval,
            60,
            "production metadata polling defaults to one bounded inventory pass per minute"
        )
        await runtime.requestInventoryRefresh()
        await runtime.requestInventoryRefresh()
        let firstRequest = await runtime.consumeInventoryRefreshRequestForTesting()
        let secondRequest = await runtime.consumeInventoryRefreshRequestForTesting()
        suite.check(
            firstRequest,
            "manual Sync coalesces into one read-only inventory request"
        )
        suite.check(
            !secondRequest,
            "manual Sync request is consumed exactly once"
        )
        suite.check(
            AppServerMonitoringRuntime.metadataRefreshIsDue(
                now: observedAt.addingTimeInterval(10),
                nextRefresh: observedAt.addingTimeInterval(10)
            ),
            "periodic metadata refresh becomes due at its bounded deadline"
        )
        suite.check(
            !AppServerMonitoringRuntime.metadataRefreshIsDue(
                now: observedAt.addingTimeInterval(9),
                nextRefresh: observedAt.addingTimeInterval(10)
            ),
            "periodic metadata refresh does not run early"
        )
    }

    private static func drainsFiveHundredThreadResumeBursts(
        into suite: inout TestSuite
    ) async throws {
        let fake = BurstingMonitoringConnection(identity: wireIdentity, threadCount: 500)
        let coordinator = try await activatedCoordinator()
        let result = try await AppServerMonitoringRuntime(configuration: .init(
            pageSize: 500,
            maximumConcurrentHydrations: 1,
            maximumBulkQualifiedThreads: 500,
            qualificationTimeout: .seconds(1)
        )).hydrateInventoryForTesting(connection: fake, coordinator: coordinator)
        suite.checkEqual(result.listedCount, 500, "500-thread metadata inventory completes")
        suite.checkEqual(result.hydratedCount, 500, "500 read/resume subscriptions complete")
        suite.checkEqual(await fake.sessionFailureCount(), 0, "resume notification load never overflows the hydration session")
        let maximumQueueDepth = await fake.maximumQueueDepth()
        suite.check(maximumQueueDepth <= 2, "inbound is drained between every one-thread qualification batch")
        suite.checkEqual(Set(await fake.requestedReadIncludeTurns()), [false], "bulk qualification never requests turns")
    }

    private static func qualifiesOpenedThreadWithTurnsOnDemand(
        into suite: inout TestSuite
    ) async throws {
        let fake = ScriptedMonitoringConnection(identity: wireIdentity, responses: [
            .init(method: "thread/list", response: .init(
                connection: wireIdentity,
                sequence: 1,
                result: .object([
                    "data": .array([
                        .object(threadInputValue(id: "recent", updatedAt: 1_830_000_020)),
                    ]),
                    "nextCursor": .string("page-2"),
                    "backwardsCursor": .null,
                ])
            )),
            .init(method: "thread/read", response: read(sequence: 2, id: "opened-old")),
            .init(method: "thread/resume", response: read(sequence: 3, id: "opened-old")),
            .init(method: "thread/list", response: .init(
                connection: wireIdentity,
                sequence: 4,
                result: .object([
                    "data": .array([
                        .object(threadInputValue(id: "opened-old", updatedAt: 1_830_000_010)),
                    ]),
                    "nextCursor": .null,
                    "backwardsCursor": .null,
                ])
            )),
            .init(method: "thread/loaded/list", response: loadedList(sequence: 5, ids: ["recent"], next: nil)),
            .init(method: "thread/read", response: read(sequence: 6, id: "recent")),
            .init(method: "thread/resume", response: read(sequence: 7, id: "recent")),
        ])
        let coordinator = try await activatedCoordinator()
        let runtime = AppServerMonitoringRuntime(configuration: .init(
            maximumConcurrentHydrations: 1,
            maximumBulkQualifiedThreads: 1
        ))
        await runtime.requestThreadQualification("opened-old")
        let result = try await runtime.hydrateInventoryForTesting(
            connection: fake,
            coordinator: coordinator
        )
        suite.checkEqual(result.scope.count, 2, "opening an older metadata row adds it to live scope")
        suite.checkEqual(
            await fake.requestedReadIncludeTurns(),
            [false, false],
            "selected-thread preflight remains metadata-only because resume supplies its bounded turns once"
        )
        suite.checkEqual(
            await fake.requestedMethods(),
            ["thread/list", "thread/read", "thread/resume", "thread/list", "thread/loaded/list", "thread/read", "thread/resume"],
            "the opened row receives its turn-bearing read/resume pair before its later inventory page and bulk status qualification"
        )
        let snapshot = await coordinator.snapshot(at: observedAt.addingTimeInterval(100))
        suite.checkEqual(
            snapshot.threads.map(\.id.rawValue),
            ["recent", "opened-old"],
            "opening and hydrating an older thread never promotes it above newer authoritative activity"
        )
        suite.checkEqual(
            snapshot.threads.first(where: { $0.id.rawValue == "opened-old" })?.turns.map(\.id.rawValue),
            ["turn-opened-old"],
            "explicitly opening a row retains its selected turn-bearing detail"
        )
    }

    private static func reconnectsWhenStoreDemandsAuthoritativeSnapshot(
        into suite: inout TestSuite
    ) async throws {
        // Production shape: activation begins snapshot-gated, and the first
        // complete thread/list establishes inventory without a preseeded
        // full-content snapshot.
        let coordinator = try await activatedCoordinator()
        let runtime = AppServerMonitoringRuntime(configuration: .init(
            maximumConcurrentHydrations: 1,
            maximumBulkQualifiedThreads: 0
        ))
        let initial = ScriptedMonitoringConnection(identity: wireIdentity, responses: [
            .init(method: "thread/list", response: list(sequence: 1, ids: ["recover-live"], next: nil)),
        ])
        _ = try await runtime.hydrateInventoryForTesting(
            connection: initial,
            coordinator: coordinator,
            qualifyRecentThreads: false
        )
        let initialMetrics = await coordinator.storageMetrics()
        suite.check(!initialMetrics.requiresSnapshot, "complete initial thread/list establishes metadata authority")

        let domainConnection = AppServerObservationAdapter().connectionIdentity(from: wireIdentity)
        _ = try await coordinator.applyAndPersist(.delta(.init(
            cursor: .init(connection: domainConnection, sequence: 2),
            observedAt: observedAt,
            delta: .threadStatus(
                threadID: .init(rawValue: "recover-live"),
                status: .active([])
            )
        )))
        let metadataPending = try await coordinator.applyAndPersist(.delta(.init(
            cursor: .init(connection: domainConnection, sequence: 2),
            observedAt: observedAt,
            delta: .threadStatus(
                threadID: .init(rawValue: "recover-live"),
                status: .idle
            )
        )))
        suite.checkEqual(metadataPending, .appliedPendingSnapshot, "same-sequence status conflict requests authoritative tile recovery")

        var scope = AppServerMonitoringScope()
        scope.include(.init(rawValue: "recover-live"))
        let metadataRecovery = ScriptedMonitoringConnection(identity: wireIdentity, responses: [
            .init(method: "thread/list", response: list(sequence: 3, ids: ["recover-live"], next: nil)),
        ])
        let recovered = try await runtime.hydrateInventoryForTesting(
            connection: metadataRecovery,
            coordinator: coordinator,
            initialScope: scope,
            qualifyRecentThreads: false
        )
        let metadataRecoveryMetrics = await coordinator.storageMetrics()
        suite.check(!metadataRecoveryMetrics.requiresSnapshot, "complete authoritative thread/list repairs mid-session inventory/status authority")
        suite.checkEqual(recovered.scope.monitoredThreadIDs.map(\.rawValue).sorted(), ["recover-live"], "metadata recovery retains authoritative live scope")

        let conflictThread = AppServerThreadInput(
            id: .init(rawValue: "recover-live"),
            sessionID: .init(rawValue: "session-recover-live"),
            title: "recover-live",
            workingDirectoryName: "project",
            workingDirectoryPath: "/tmp/project",
            status: .idle,
            updatedAt: observedAt,
            turnsAreAuthoritative: true,
            turns: [.init(
                id: .init(rawValue: "turn-recover-live"),
                status: .completed,
                items: [.init(
                    id: .init(rawValue: "item-recover-live"),
                    kind: .commandExecution,
                    status: .unknown
                )]
            )]
        )
        let pending = try await coordinator.applyAndPersist(.delta(.init(
            cursor: .init(
                connection: domainConnection,
                sequence: 4
            ),
            observedAt: observedAt,
            delta: .threadUpsert(conflictThread)
        )))
        suite.checkEqual(pending, .appliedPendingSnapshot, "detailed turn/item conflict exposes content snapshot demand")

        let optional = ScriptedMonitoringConnection(identity: wireIdentity, responses: [])
        do {
            _ = try await runtime.optionalInventoryRefreshForTesting(
                connection: optional,
                coordinator: coordinator,
                initialScope: scope
            )
            suite.check(false, "optional refresh cannot fail open while authoritative recovery is required")
        } catch {
            suite.check(true, "optional refresh propagates a projection snapshot requirement")
        }
        suite.checkEqual(await optional.requestedMethods(), [], "snapshot requirement is detected before optional thread/list")

        let recovery = ScriptedMonitoringConnection(identity: wireIdentity, responses: [
            .init(method: "thread/list", response: list(sequence: 5, ids: ["recover-live"], next: nil)),
        ])
        do {
            _ = try await AppServerMonitoringRuntime(configuration: .init(
                maximumBulkQualifiedThreads: 0,
                snapshotRecoveryAttempts: 0
            )).hydrateInventoryForTesting(
                connection: recovery,
                coordinator: coordinator,
                initialScope: scope,
                qualifyRecentThreads: false
            )
            suite.check(false, "metadata-only thread/list cannot claim a detailed conflict was repaired")
        } catch {
            suite.check(true, "detailed content conflict remains fail-closed after metadata recovery attempt")
        }
        let metrics = await coordinator.storageMetrics()
        suite.check(metrics.requiresSnapshot, "complete thread/list preserves detailed content snapshot demand")
    }

    private static func incompleteInitialInventoryPreservesSnapshotDemand(
        into suite: inout TestSuite
    ) async throws {
        let coordinator = try await activatedCoordinator()
        let fake = ScriptedMonitoringConnection(identity: wireIdentity, responses: [
            .init(method: "thread/list", response: list(sequence: 1, ids: ["visible"], next: "more")),
        ])
        do {
            _ = try await AppServerMonitoringRuntime(configuration: .init(
                pageSize: 1,
                maximumThreads: 1,
                maximumBulkQualifiedThreads: 0,
                snapshotRecoveryAttempts: 0
            )).hydrateInventoryForTesting(
                connection: fake,
                coordinator: coordinator,
                qualifyRecentThreads: false
            )
            suite.check(false, "truncated initial inventory cannot satisfy snapshot demand")
        } catch {
            suite.check(true, "truncated initial inventory exits through bounded recovery")
        }
        let metrics = await coordinator.storageMetrics()
        suite.check(metrics.requiresSnapshot, "truncated initial inventory never clears authority")
    }

    private static func isolatesMalformedInventoryRowsWithoutUnsafeDeletion(
        into suite: inout TestSuite
    ) async throws {
        let safeCoordinator = try await activatedCoordinator(
            snapshotSequence: 1,
            threads: [threadInput(id: "malformed-known"), threadInput(id: "remove-absent")]
        )
        var malformedKnown = threadInputValue(id: "malformed-known")
        malformedKnown.removeValue(forKey: "sessionId")
        let safeResponse = ConnAppServerResponseEnvelope(
            connection: wireIdentity,
            sequence: 2,
            result: .object([
                "data": .array([
                    .object(threadInputValue(id: "valid-sibling")),
                    .object(malformedKnown),
                ]),
                "nextCursor": .null,
            ])
        )
        var safeScope = AppServerMonitoringScope()
        safeScope.include(contentsOf: Set(["malformed-known", "remove-absent"].map {
            AppServerThreadID(rawValue: $0)
        }))
        let safe = try await AppServerMonitoringRuntime(configuration: .init(
            maximumBulkQualifiedThreads: 0
        )).optionalInventoryRefreshForTesting(
            connection: ScriptedMonitoringConnection(identity: wireIdentity, responses: [
                .init(method: "thread/list", response: safeResponse),
            ]),
            coordinator: safeCoordinator,
            initialScope: safeScope
        )
        suite.checkEqual(safe?.malformedRowCount, 1, "runtime exposes the isolated malformed row count")
        suite.check(safe?.inventoryMembershipIsComplete == false, "bounded refresh never claims complete inventory authority")
        suite.checkEqual(
            (await safeCoordinator.snapshot(at: observedAt)).threads.map(\.id.rawValue).sorted(),
            ["malformed-known", "remove-absent", "valid-sibling"],
            "valid sibling applies while absence from a bounded refresh never deletes cached rows"
        )

        let unsafeCoordinator = try await activatedCoordinator(
            snapshotSequence: 1,
            threads: [threadInput(id: "must-not-delete")]
        )
        let unsafeResponse = ConnAppServerResponseEnvelope(
            connection: wireIdentity,
            sequence: 2,
            result: .object([
                "data": .array([
                    .object(threadInputValue(id: "valid-sibling")),
                    .object(["sessionId": .string("unknown-id")]),
                ]),
                "nextCursor": .null,
            ])
        )
        let unsafe = try await AppServerMonitoringRuntime(configuration: .init(
            maximumBulkQualifiedThreads: 0
        )).optionalInventoryRefreshForTesting(
            connection: ScriptedMonitoringConnection(identity: wireIdentity, responses: [
                .init(method: "thread/list", response: unsafeResponse),
            ]),
            coordinator: unsafeCoordinator,
            initialScope: .init()
        )
        suite.check(unsafe?.inventoryMembershipIsComplete == false, "unknown malformed row marks inventory membership incomplete")
        suite.checkEqual(
            (await unsafeCoordinator.snapshot(at: observedAt)).threads.map(\.id.rawValue).sorted(),
            ["must-not-delete", "valid-sibling"],
            "unknown malformed membership prevents unsafe authoritative deletion"
        )
    }

    private static func boundsMetadataRefreshMembershipAcrossMalformedPages(
        into suite: inout TestSuite
    ) async throws {
        let coordinator = try await activatedCoordinator(
            snapshotSequence: 1,
            threads: [
                threadInput(id: "malformed-known"),
                threadInput(id: "cached-absent"),
            ]
        )
        var malformedKnown = threadInputValue(id: "malformed-known")
        malformedKnown.removeValue(forKey: "sessionId")
        let firstPage = ConnAppServerResponseEnvelope(
            connection: wireIdentity,
            sequence: 2,
            result: .object([
                "data": .array([.object(malformedKnown)]),
                "nextCursor": .string("second"),
            ])
        )
        let secondPage = ConnAppServerResponseEnvelope(
            connection: wireIdentity,
            sequence: 3,
            result: .object([
                "data": .array([
                    .object(threadInputValue(id: "valid-one")),
                    .object(threadInputValue(id: "valid-two")),
                ]),
                "nextCursor": .null,
            ])
        )
        let connection = ScriptedMonitoringConnection(identity: wireIdentity, responses: [
            .init(method: "thread/list", response: firstPage),
            .init(method: "thread/list", response: secondPage),
        ])
        let result = try await AppServerMonitoringRuntime(configuration: .init(
            pageSize: 1,
            maximumThreads: 2,
            maximumBulkQualifiedThreads: 0
        )).optionalInventoryRefreshForTesting(
            connection: connection,
            coordinator: coordinator,
            initialScope: .init()
        )
        let snapshot = await coordinator.snapshot(at: observedAt)

        suite.checkEqual(result?.listedCount, 1, "identified malformed membership is retained from the single working-set page")
        suite.checkEqual(result?.scope.count, 1, "metadata refresh scope contains only IDs observed on its working-set page")
        suite.check(result?.inventoryIsTruncated == true, "a returned cursor records that the working set is intentionally bounded")
        suite.check(result?.inventoryMembershipIsComplete == false, "omitted membership prevents authoritative refresh")
        suite.checkEqual(
            snapshot.threads.map(\.id.rawValue).sorted(),
            ["cached-absent", "malformed-known"],
            "incremental refresh preserves cached rows and does not fetch later-page rows"
        )
        suite.checkEqual(await connection.requestedListCursors(), [nil], "routine refresh deliberately stops after the newest page")
    }

    private static func metadataObservationOnlyRefreshIsCheckpointDuplicate(
        into suite: inout TestSuite
    ) async throws {
        let coordinator = try await activatedCoordinator(
            snapshotSequence: 1,
            threads: [threadInput(id: "unchanged")]
        )
        let connection = AppServerObservationAdapter().connectionIdentity(from: wireIdentity)
        let observationOnly = try await coordinator.applyAndPersist(.snapshot(.init(
            cursor: .init(connection: connection, sequence: 2),
            observedAt: observedAt.addingTimeInterval(10),
            threads: [threadInput(id: "unchanged")],
            contentAuthority: .metadataOnly,
            inventoryAuthority: .authoritative
        )))
        suite.checkEqual(observationOnly, .duplicate, "lastObservedAt-only metadata refresh does not schedule checkpoint churn")
        suite.checkEqual(
            (await coordinator.snapshot(at: observedAt.addingTimeInterval(10))).threads.first?.lastObservedAt,
            observedAt.addingTimeInterval(10),
            "checkpoint duplicate still advances the live observation timestamp"
        )
        let meaningful = try await coordinator.applyAndPersist(.snapshot(.init(
            cursor: .init(connection: connection, sequence: 3),
            observedAt: observedAt.addingTimeInterval(20),
            threads: [threadInput(id: "unchanged", status: .active([]))],
            contentAuthority: .metadataOnly,
            inventoryAuthority: .authoritative
        )))
        suite.checkEqual(meaningful, .applied, "meaningful tile status changes remain checkpoint-worthy")
    }

    private static func boundsHungInventoryRequest(
        into suite: inout TestSuite
    ) async throws {
        let coordinator = try await activatedCoordinator()
        let runtime = AppServerMonitoringRuntime(configuration: .init(
            inventoryRequestTimeout: .milliseconds(10),
            qualificationTimeout: .milliseconds(10)
        ))
        do {
            _ = try await runtime.hydrateInventoryForTesting(
                connection: HangingMonitoringConnection(identity: wireIdentity),
                coordinator: coordinator
            )
            suite.check(false, "hung thread/list cannot leave runtime hydrating forever")
        } catch {
            suite.check(true, "hung thread/list exits through the bounded recovery path")
        }
    }

    private static func reconnectRequalifiesCachedRowsAfterEmptyPage(
        into suite: inout TestSuite
    ) async throws {
        let firstDomainIdentity = AppServerConnectionIdentity(
            instanceID: wireIdentity.instanceID,
            generation: 0
        )
        let adapter = AppServerObservationAdapter()
        let domain = AppServerProjectionStore(configuration: .monitoring)
        let coordinator = AppServerDomainCoordinator(domain: domain)
        _ = try await coordinator.applyAndPersist(adapter.connectionActivated(
            identity: firstDomainIdentity,
            source: .managedDaemon,
            serverVersion: .v0_144_6
        ))
        _ = try await coordinator.applyAndPersist(.snapshot(.init(
            cursor: .init(connection: firstDomainIdentity, sequence: 1),
            observedAt: observedAt,
            threads: [threadInput(id: "cached-reconnect")]
        )))
        _ = try await coordinator.applyAndPersist(.connectionLost(firstDomainIdentity))
        _ = try await coordinator.applyAndPersist(adapter.connectionActivated(
            identity: adapter.connectionIdentity(from: wireIdentity),
            source: .managedDaemon,
            serverVersion: .v0_144_6
        ))

        let fake = ScriptedMonitoringConnection(identity: wireIdentity, responses: [
            .init(method: "thread/list", response: list(sequence: 2, ids: [], next: "continue")),
            .init(method: "thread/list", response: list(sequence: 3, ids: ["cached-reconnect"], next: nil)),
            .init(method: "thread/loaded/list", response: loadedList(sequence: 4, ids: [], next: nil)),
        ])
        let result = try await AppServerMonitoringRuntime(configuration: .init(pageSize: 1))
            .hydrateInventoryForTesting(connection: fake, coordinator: coordinator)
        let snapshot = await coordinator.snapshot(at: observedAt)
        suite.checkEqual(result.hydratedCount, 0, "reconnect refreshes metadata without eager detail hydration")
        suite.checkEqual(snapshot.threads.map(\.id.rawValue), ["cached-reconnect"], "empty reconnect page does not persist deletion")
        suite.checkEqual(snapshot.threads.first?.freshness, .live, "current list metadata upgrades the cached tile to live")
    }

    private static func resetsRetryLadderAfterHealthyInterval(
        into suite: inout TestSuite
    ) {
        suite.checkEqual(
            AppServerMonitoringRuntime.nextRetryAttempt(
                previousAttempt: 3,
                healthyDuration: 31,
                resetInterval: 30
            ),
            1,
            "a healthy interval resets reconnect backoff to the first rung"
        )
        suite.checkEqual(
            AppServerMonitoringRuntime.nextRetryAttempt(
                previousAttempt: 3,
                healthyDuration: 29,
                resetInterval: 30
            ),
            4,
            "short sessions continue the current outage backoff ladder"
        )
    }

    private static func qualifiesAttentionRequestOutsideInitialScope(
        into suite: inout TestSuite
    ) async throws {
        let request = ConnAppServerInboundEnvelope(
            connection: wireIdentity,
            sequence: 2,
            message: .request(.init(
                id: .string("request-live"),
                method: "item/tool/requestUserInput",
                params: .object([
                    "threadId": .string("attention-new"),
                    "turnId": .string("turn-attention-new"),
                    "itemId": .string("item-attention-new"),
                    "questions": .array([]),
                ])
            ))
        )
        let fake = ScriptedMonitoringConnection(
            identity: wireIdentity,
            responses: [
                .init(method: "thread/read", response: read(sequence: 3, id: "attention-new")),
                .init(method: "thread/resume", response: read(sequence: 4, id: "attention-new")),
            ],
            inbound: [request]
        )
        let coordinator = try await activatedCoordinator(snapshotSequence: 1)
        let result = try await AppServerMonitoringRuntime().processInboundForTesting(
            connection: fake,
            coordinator: coordinator,
            monitoringScope: .init()
        )
        let snapshot = await coordinator.snapshot(at: observedAt)
        suite.checkEqual(result.scope.count, 1, "attention request expands qualification scope before reduction")
        suite.checkEqual(snapshot.attentionRequests.count, 1, "request outside initial hydration is retained after qualification")
        suite.checkEqual(snapshot.attentionRequests.first?.id.requestID, .string("request-live"), "attention correlation remains exact")
    }

    private static func paginatesAcrossEmptyCursorPage(
        into suite: inout TestSuite
    ) async throws {
        let fake = ScriptedMonitoringConnection(identity: wireIdentity, responses: [
            .init(method: "thread/list", response: list(sequence: 1, ids: ["page-one"], next: "empty")),
            .init(method: "thread/list", response: list(sequence: 2, ids: [], next: "last")),
            .init(method: "thread/list", response: list(sequence: 3, ids: ["page-three"], next: nil)),
            .init(method: "thread/loaded/list", response: loadedList(sequence: 4, ids: ["page-three"], next: "loaded-last")),
            .init(method: "thread/loaded/list", response: loadedList(sequence: 5, ids: ["page-three", "page-one"], next: nil)),
            .init(method: "thread/read", response: read(sequence: 6, id: "page-one")),
            .init(method: "thread/resume", response: read(sequence: 7, id: "page-one")),
            .init(method: "thread/read", response: read(sequence: 8, id: "page-three")),
            .init(method: "thread/resume", response: read(sequence: 9, id: "page-three")),
        ])
        let coordinator = try await activatedCoordinator()
        let runtime = AppServerMonitoringRuntime(configuration: .init(
            pageSize: 1,
            maximumConcurrentHydrations: 1,
            maximumBulkQualifiedThreads: 2
        ))
        let result = try await runtime.hydrateInventoryForTesting(
            connection: fake,
            coordinator: coordinator
        )
        let snapshot = await coordinator.snapshot(at: observedAt)
        suite.checkEqual(result.listedCount, 2, "pagination counts rows across every page")
        suite.checkEqual(result.hydratedCount, 2, "both paginated rows qualify")
        suite.checkEqual(
            snapshot.threads.map(\.id.rawValue).sorted(),
            ["page-one", "page-three"],
            "an empty data page with nextCursor does not terminate inventory"
        )
        suite.checkEqual(await fake.requestedListCursors(), [nil, "empty", "last"], "runtime follows every returned cursor")
        suite.checkEqual(await fake.requestedLoadedListCursors(), [nil, "loaded-last"], "runtime follows every loaded-thread cursor")
        suite.checkEqual(await fake.requestedReadThreadIDs(), ["page-one", "page-three"], "duplicate loaded IDs across pages collapse before authoritative recency ordering")
    }

    private static func ignoresUnrequestedMalformedTurnsDuringStatusQualification(
        into suite: inout TestSuite
    ) async throws {
        let fake = ScriptedMonitoringConnection(identity: wireIdentity, responses: [
            .init(method: "thread/list", response: list(sequence: 10, ids: ["conflict", "later"], next: nil)),
            .init(method: "thread/loaded/list", response: loadedList(sequence: 11, ids: ["conflict", "later"], next: nil)),
            .init(method: "thread/read", response: read(sequence: 12, id: "conflict", conflict: true)),
            .init(method: "thread/resume", response: read(sequence: 13, id: "conflict", conflict: true)),
            .init(method: "thread/read", response: read(sequence: 14, id: "later")),
            .init(method: "thread/resume", response: read(sequence: 15, id: "later")),
        ])
        let coordinator = try await activatedCoordinator()
        let runtime = AppServerMonitoringRuntime(configuration: .init(
            maximumConcurrentHydrations: 1,
            maximumBulkQualifiedThreads: 2,
            snapshotRecoveryAttempts: 2
        ))
        let result = try await runtime.hydrateInventoryForTesting(
            connection: fake,
            coordinator: coordinator
        )
        let metrics = await coordinator.storageMetrics()
        let snapshot = await coordinator.snapshot(at: observedAt)
        suite.checkEqual(result.recoveryCount, 0, "turn-free status qualification cannot poison the store with unrequested detail")
        suite.checkEqual(result.hydratedCount, 2, "both metadata-only status qualifications are accepted")
        suite.checkEqual(
            snapshot.threads.map(\.id.rawValue).sorted(),
            ["conflict", "later"],
            "a qualification conflict at thread k leaves its metadata row visible and does not hide k+1 through N"
        )
        suite.check(!metrics.requiresSnapshot && metrics.bufferedDeltaCount == 0, "conflict preflight leaves no false snapshot gate")
    }

    private static func qualifiesNewThreadStartedDuringLiveSession(
        into suite: inout TestSuite
    ) async throws {
        let started = ConnAppServerInboundEnvelope(
            connection: wireIdentity,
            sequence: 2,
            message: .notification(.init(
                method: "thread/started",
                params: .object(["thread": thread(id: "live-new")])
            ))
        )
        let fake = ScriptedMonitoringConnection(
            identity: wireIdentity,
            responses: [],
            inbound: [started]
        )
        let coordinator = try await activatedCoordinator(snapshotSequence: 1)
        let runtime = AppServerMonitoringRuntime()
        let result = try await runtime.processInboundForTesting(
            connection: fake,
            coordinator: coordinator,
            monitoringScope: .init()
        )
        let snapshot = await coordinator.snapshot(at: observedAt)
        suite.checkEqual(result.scope.count, 1, "thread/started expands the live metadata scope")
        suite.checkEqual(snapshot.threads.map(\.id.rawValue), ["live-new"], "new thread appears without reconnect")
        suite.checkEqual(snapshot.threads.first?.turns.count, 0, "new-thread discovery defers timeline content until selection")
        suite.checkEqual(await fake.requestedMethods(), [], "new-thread discovery needs no eager detail request")
    }

    private static func skipsMalformedKnownNotificationOnly(
        into suite: inout TestSuite
    ) async throws {
        let malformed = ConnAppServerInboundEnvelope(
            connection: wireIdentity,
            sequence: 3,
            message: .notification(.init(
                method: "thread/status/changed",
                params: .object(["status": .object([
                    "type": .string("active"),
                    "activeFlags": .array([]),
                ])])
            ))
        )
        let valid = ConnAppServerInboundEnvelope(
            connection: wireIdentity,
            sequence: 4,
            message: .notification(.init(
                method: "thread/status/changed",
                params: .object([
                    "threadId": .string("known"),
                    "status": .object([
                        "type": .string("active"),
                        "activeFlags": .array([]),
                    ]),
                ])
            ))
        )
        let fake = ScriptedMonitoringConnection(identity: wireIdentity, responses: [], inbound: [malformed, valid])
        let coordinator = try await activatedCoordinator(snapshotSequence: 1, threads: [threadInput(id: "known")])
        var scope = AppServerMonitoringScope()
        scope.include(.init(rawValue: "known"))
        let result = try await AppServerMonitoringRuntime().processInboundForTesting(
            connection: fake,
            coordinator: coordinator,
            monitoringScope: scope
        )
        let snapshot = await coordinator.snapshot(at: observedAt)
        suite.check(result.didApply, "valid notification after malformed known method still applies")
        suite.checkEqual(snapshot.threads.first?.status, .active([]), "malformation is isolated to one envelope")
    }

    private static func activatedCoordinator(
        snapshotSequence: UInt64? = nil,
        threads: [AppServerThreadInput] = []
    ) async throws -> AppServerDomainCoordinator {
        let domain = AppServerProjectionStore(configuration: .monitoring)
        let coordinator = AppServerDomainCoordinator(domain: domain)
        let adapter = AppServerObservationAdapter()
        _ = try await coordinator.applyAndPersist(adapter.connectionActivated(
            identity: adapter.connectionIdentity(from: wireIdentity),
            source: .managedDaemon,
            serverVersion: .v0_144_6
        ))
        if let snapshotSequence {
            _ = try await coordinator.applyAndPersist(.snapshot(.init(
                cursor: .init(
                    connection: adapter.connectionIdentity(from: wireIdentity),
                    sequence: snapshotSequence
                ),
                observedAt: observedAt,
                threads: threads
            )))
        }
        return coordinator
    }

    private static func list(sequence: UInt64, ids: [String], next: String?) -> ConnAppServerResponseEnvelope {
        .init(
            connection: wireIdentity,
            sequence: sequence,
            result: .object([
                "data": .array(ids.map { .object(threadInputValue(id: $0)) }),
                "nextCursor": next.map(JSONValue.string) ?? .null,
                "backwardsCursor": .null,
            ])
        )
    }

    private static func loadedList(
        sequence: UInt64,
        ids: [String],
        next: String?
    ) -> ConnAppServerResponseEnvelope {
        .init(
            connection: wireIdentity,
            sequence: sequence,
            result: .object([
                "data": .array(ids.map(JSONValue.string)),
                "nextCursor": next.map(JSONValue.string) ?? .null,
            ])
        )
    }

    private static func read(sequence: UInt64, id: String, conflict: Bool = false) -> ConnAppServerResponseEnvelope {
        .init(
            connection: wireIdentity,
            sequence: sequence,
            result: .object(["thread": thread(id: id, conflict: conflict)])
        )
    }

    private static func thread(id: String, conflict: Bool = false) -> JSONValue {
        let item: JSONValue = conflict
            ? .object([
                "id": .string("item-\(id)"),
                "type": .string("commandExecution"),
                "status": .string("future-status"),
                "command": .string("true"),
                "commandActions": .array([]),
                "cwd": .string("/tmp/project"),
            ])
            : .object([
                "id": .string("item-\(id)"),
                "type": .string("agentMessage"),
                "text": .string("runtime only"),
                "phase": .null,
            ])
        var value = threadInputValue(id: id)
        value["turns"] = .array([.object([
            "id": .string("turn-\(id)"),
            "status": .string("completed"),
            "items": .array([item]),
        ])])
        return .object(value)
    }

    private static func threadInputValue(
        id: String,
        status: String = "idle",
        updatedAt: Int64 = 1_830_000_001
    ) -> [String: JSONValue] {
        [
            "id": .string(id),
            "sessionId": .string("session-\(id)"),
            "cliVersion": .string("0.144.6"),
            "name": .string("Thread \(id)"),
            "preview": .string("discarded"),
            "cwd": .string("/tmp/project"),
            "gitInfo": .null,
            "modelProvider": .string("openai"),
            "source": .string("appServer"),
            "status": .object(["type": .string(status), "activeFlags": .array([])]),
            "ephemeral": .bool(false),
            "createdAt": .integer(1_830_000_000),
            "updatedAt": .integer(updatedAt),
            "turns": .array([]),
        ]
    }

    private static func threadInput(
        id: String,
        status: AppServerThreadStatus = .idle,
        turnsAreAuthoritative: Bool = false,
        turns: [AppServerTurnInput] = []
    ) -> AppServerThreadInput {
        .init(
            id: .init(rawValue: id),
            sessionID: .init(rawValue: "session-\(id)"),
            title: id,
            workingDirectoryName: "project",
            workingDirectoryPath: "/tmp/project",
            status: status,
            updatedAt: observedAt,
            turnsAreAuthoritative: turnsAreAuthoritative,
            turns: turns
        )
    }
}

private actor ScriptedMonitoringConnection: AppServerMonitoringConnection {
    struct TimeoutRecord: Equatable, Sendable {
        let method: String
        let timeout: Duration?
    }

    struct Expected: Sendable {
        let method: String
        let response: ConnAppServerResponseEnvelope
        let delay: Duration?

        init(
            method: String,
            response: ConnAppServerResponseEnvelope,
            delay: Duration? = nil
        ) {
            self.method = method
            self.response = response
            self.delay = delay
        }
    }

    enum Failure: Error { case unexpectedRequest(String) }

    private let identity: ConnAppServerConnectionIdentity
    private var responses: [Expected]
    private var inbound: [ConnAppServerInboundEnvelope]
    private var methods: [String] = []
    private var timeouts: [TimeoutRecord] = []
    private var listCursors: [String?] = []
    private var listLimits: [Int] = []
    private var listStateDBOnly: [Bool] = []
    private var loadedListCursors: [String?] = []
    private var readIncludeTurns: [Bool] = []
    private var readThreadIDs: [String] = []
    private var disconnects = 0

    init(
        identity: ConnAppServerConnectionIdentity,
        responses: [Expected],
        inbound: [ConnAppServerInboundEnvelope] = []
    ) {
        self.identity = identity
        self.responses = responses
        self.inbound = inbound
    }

    func connect(
        to endpoint: ControlEndpoint,
        serverVersion: SupportedAppServerVersion,
        mode: AppServerCapabilityMode
    ) async throws -> InitializeResponse {
        throw Failure.unexpectedRequest("connect")
    }

    func requestEnvelope(
        method: String,
        params: JSONValue?,
        timeout: Duration?
    ) async throws -> ConnAppServerResponseEnvelope {
        methods.append(method)
        timeouts.append(.init(method: method, timeout: timeout))
        if method == "thread/list" {
            listCursors.append(params?.objectValue?["cursor"]?.stringValue)
            if case let .integer(value) = params?.objectValue?["limit"] {
                listLimits.append(Int(value))
            }
            listStateDBOnly.append(params?.objectValue?["useStateDbOnly"] == .bool(true))
        } else if method == "thread/loaded/list" {
            loadedListCursors.append(params?.objectValue?["cursor"]?.stringValue)
        } else if method == "thread/read" {
            if let threadID = params?.objectValue?["threadId"]?.stringValue {
                readThreadIDs.append(threadID)
            }
            readIncludeTurns.append(
                params?.objectValue?["includeTurns"] == .bool(true)
            )
        }
        guard !responses.isEmpty, responses[0].method == method else {
            throw Failure.unexpectedRequest(method)
        }
        let expected = responses.removeFirst()
        if let delay = expected.delay { try await Task.sleep(for: delay) }
        return expected.response
    }

    func drainInboundEnvelopes() async -> [ConnAppServerInboundEnvelope] {
        let result = inbound
        inbound.removeAll()
        return result
    }

    func monitoringState() async -> ConnAppServerConnectionState {
        .ready(generation: identity.generation, version: .v0_144_6)
    }

    func monitoringIdentity() async -> ConnAppServerConnectionIdentity? { identity }
    func disconnect() async { disconnects += 1 }
    func requestedMethods() -> [String] { methods }
    func requestedTimeouts() -> [TimeoutRecord] { timeouts }
    func requestedListCursors() -> [String?] { listCursors }
    func requestedListLimits() -> [Int] { listLimits }
    func requestedListStateDBOnly() -> [Bool] { listStateDBOnly }
    func requestedLoadedListCursors() -> [String?] { loadedListCursors }
    func requestedReadIncludeTurns() -> [Bool] { readIncludeTurns }
    func requestedReadThreadIDs() -> [String] { readThreadIDs }
    func disconnectCount() -> Int { disconnects }
}

private actor HydrationProgressProbe {
    struct Value: Sendable {
        let listedCount: Int
        let visibleCount: Int
        let readCount: Int
    }

    private(set) var first: Value?

    func recordFirst(listedCount: Int, visibleCount: Int, readCount: Int) {
        guard first == nil else { return }
        first = .init(
            listedCount: listedCount,
            visibleCount: visibleCount,
            readCount: readCount
        )
    }
}

private actor BurstingMonitoringConnection: AppServerMonitoringConnection {
    enum Failure: Error { case inboundQueueOverflow }

    private let identity: ConnAppServerConnectionIdentity
    private let threadCount: Int
    private var nextSequence: UInt64 = 1
    private var didList = false
    private var didListLoaded = false
    private var inbound: [ConnAppServerInboundEnvelope] = []
    private var peakQueueDepth = 0
    private var failures = 0
    private var readIncludeTurns: [Bool] = []

    init(identity: ConnAppServerConnectionIdentity, threadCount: Int) {
        self.identity = identity
        self.threadCount = threadCount
    }

    func connect(
        to endpoint: ControlEndpoint,
        serverVersion: SupportedAppServerVersion,
        mode: AppServerCapabilityMode
    ) async throws -> InitializeResponse {
        throw ScriptedMonitoringConnection.Failure.unexpectedRequest("connect")
    }

    func requestEnvelope(
        method: String,
        params: JSONValue?,
        timeout: Duration?
    ) async throws -> ConnAppServerResponseEnvelope {
        let sequence = nextSequence
        nextSequence += 1
        switch method {
        case "thread/list":
            guard !didList else {
                throw ScriptedMonitoringConnection.Failure.unexpectedRequest(method)
            }
            didList = true
            return .init(
                connection: identity,
                sequence: sequence,
                result: .object([
                    "data": .array((0..<threadCount).map { index in
                        .object(Self.threadInputValue(id: "fixture-\(index)"))
                    }),
                    "nextCursor": .null,
                    "backwardsCursor": .null,
                ])
            )
        case "thread/loaded/list":
            guard !didListLoaded else {
                throw ScriptedMonitoringConnection.Failure.unexpectedRequest(method)
            }
            didListLoaded = true
            return .init(
                connection: identity,
                sequence: sequence,
                result: .object([
                    "data": .array((0..<threadCount).map { .string("fixture-\($0)") }),
                    "nextCursor": .null,
                ])
            )
        case "thread/read", "thread/resume":
            guard let threadID = params?.objectValue?["threadId"]?.stringValue else {
                throw ScriptedMonitoringConnection.Failure.unexpectedRequest(method)
            }
            if method == "thread/read" {
                readIncludeTurns.append(
                    params?.objectValue?["includeTurns"] == .bool(true)
                )
            } else {
                try enqueueResumeNoise(threadID: threadID)
            }
            return .init(
                connection: identity,
                sequence: sequence,
                result: .object(["thread": .object(Self.threadInputValue(id: threadID))])
            )
        default:
            throw ScriptedMonitoringConnection.Failure.unexpectedRequest(method)
        }
    }

    private func enqueueResumeNoise(threadID: String) throws {
        for method in ["thread/tokenUsage/updated", "thread/goal/cleared"] {
            let envelope = ConnAppServerInboundEnvelope(
                connection: identity,
                sequence: nextSequence,
                message: .notification(.init(
                    method: method,
                    params: .object(["threadId": .string(threadID)])
                ))
            )
            nextSequence += 1
            inbound.append(envelope)
            peakQueueDepth = max(peakQueueDepth, inbound.count)
            if inbound.count > 512 {
                failures += 1
                throw Failure.inboundQueueOverflow
            }
        }
    }

    func drainInboundEnvelopes() async -> [ConnAppServerInboundEnvelope] {
        let result = inbound
        inbound.removeAll(keepingCapacity: true)
        return result
    }

    func monitoringState() async -> ConnAppServerConnectionState {
        .ready(generation: identity.generation, version: .v0_144_6)
    }

    func monitoringIdentity() async -> ConnAppServerConnectionIdentity? { identity }
    func disconnect() async {}
    func sessionFailureCount() -> Int { failures }
    func maximumQueueDepth() -> Int { peakQueueDepth }
    func requestedReadIncludeTurns() -> [Bool] { readIncludeTurns }

    private static func threadInputValue(id: String) -> [String: JSONValue] {
        [
            "id": .string(id),
            "sessionId": .string("session-\(id)"),
            "cliVersion": .string("0.144.6"),
            "name": .string("Thread \(id)"),
            "preview": .string("discarded"),
            "cwd": .string("/tmp/project"),
            "gitInfo": .null,
            "modelProvider": .string("openai"),
            "source": .string("appServer"),
            "status": .object(["type": .string("idle")]),
            "ephemeral": .bool(false),
            "createdAt": .integer(1_830_000_000),
            "updatedAt": .integer(1_830_000_001),
            "turns": .array([]),
        ]
    }
}

private actor SlowResumeCancellationMonitoringConnection: AppServerMonitoringConnection {
    private let identity: ConnAppServerConnectionIdentity
    private var methods: [String] = []
    private var sequence: UInt64 = 1
    private var pendingWork = 0
    private var resumeStarted = false
    private var resumeCancelled = false
    private var resumeCompleted = false

    init(identity: ConnAppServerConnectionIdentity) { self.identity = identity }

    func connect(
        to endpoint: ControlEndpoint,
        serverVersion: SupportedAppServerVersion,
        mode: AppServerCapabilityMode
    ) async throws -> InitializeResponse {
        throw ScriptedMonitoringConnection.Failure.unexpectedRequest("connect")
    }

    func requestEnvelope(
        method: String,
        params: JSONValue?,
        timeout: Duration?
    ) async throws -> ConnAppServerResponseEnvelope {
        methods.append(method)
        pendingWork += 1
        defer { pendingWork -= 1 }
        let currentSequence = sequence
        sequence += 1

        switch method {
        case "thread/list":
            return .init(
                connection: identity,
                sequence: currentSequence,
                result: .object([
                    "data": .array([.object(Self.threadValue)]),
                    "nextCursor": .null,
                ])
            )
        case "thread/loaded/list":
            return .init(
                connection: identity,
                sequence: currentSequence,
                result: .object([
                    "data": .array([.string("slow-resume")]),
                    "nextCursor": .null,
                ])
            )
        case "thread/read":
            return Self.readResponse(identity: identity, sequence: currentSequence)
        case "thread/resume":
            resumeStarted = true
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                resumeCancelled = true
                throw error
            }
            resumeCompleted = true
            return Self.readResponse(identity: identity, sequence: currentSequence)
        default:
            throw ScriptedMonitoringConnection.Failure.unexpectedRequest(method)
        }
    }

    func drainInboundEnvelopes() async -> [ConnAppServerInboundEnvelope] { [] }
    func monitoringState() async -> ConnAppServerConnectionState {
        .ready(generation: identity.generation, version: .v0_144_6)
    }
    func monitoringIdentity() async -> ConnAppServerConnectionIdentity? { identity }
    func disconnect() async {}

    func requestedMethods() -> [String] { methods }
    func pendingWorkCount() -> Int { pendingWork }
    func didStartResume() -> Bool { resumeStarted }
    func wasResumeCancelled() -> Bool { resumeCancelled }
    func didCompleteResume() -> Bool { resumeCompleted }

    private static func readResponse(
        identity: ConnAppServerConnectionIdentity,
        sequence: UInt64
    ) -> ConnAppServerResponseEnvelope {
        .init(
            connection: identity,
            sequence: sequence,
            result: .object(["thread": .object(threadValue)])
        )
    }

    private static let threadValue: [String: JSONValue] = [
        "id": .string("slow-resume"),
        "sessionId": .string("session-slow-resume"),
        "cliVersion": .string("0.144.6"),
        "name": .string("Slow resume"),
        "preview": .string("discarded"),
        "cwd": .string("/tmp/project"),
        "gitInfo": .null,
        "modelProvider": .string("openai"),
        "source": .string("appServer"),
        "status": .object(["type": .string("idle")]),
        "ephemeral": .bool(false),
        "createdAt": .integer(1_830_000_000),
        "updatedAt": .integer(1_830_000_001),
        "turns": .array([]),
    ]
}

private actor HangingMonitoringConnection: AppServerMonitoringConnection {
    private let identity: ConnAppServerConnectionIdentity
    init(identity: ConnAppServerConnectionIdentity) { self.identity = identity }

    func connect(
        to endpoint: ControlEndpoint,
        serverVersion: SupportedAppServerVersion,
        mode: AppServerCapabilityMode
    ) async throws -> InitializeResponse {
        throw ScriptedMonitoringConnection.Failure.unexpectedRequest("connect")
    }

    func requestEnvelope(
        method: String,
        params: JSONValue?,
        timeout: Duration?
    ) async throws -> ConnAppServerResponseEnvelope {
        try await Task.sleep(for: .seconds(60))
        throw ScriptedMonitoringConnection.Failure.unexpectedRequest(method)
    }

    func drainInboundEnvelopes() async -> [ConnAppServerInboundEnvelope] { [] }
    func monitoringState() async -> ConnAppServerConnectionState {
        .ready(generation: identity.generation, version: .v0_144_6)
    }
    func monitoringIdentity() async -> ConnAppServerConnectionIdentity? { identity }
    func disconnect() async {}
}

private actor LoadedListHangingMonitoringConnection: AppServerMonitoringConnection {
    private let identity: ConnAppServerConnectionIdentity
    private var methods: [String] = []

    init(identity: ConnAppServerConnectionIdentity) { self.identity = identity }

    func connect(
        to endpoint: ControlEndpoint,
        serverVersion: SupportedAppServerVersion,
        mode: AppServerCapabilityMode
    ) async throws -> InitializeResponse {
        throw ScriptedMonitoringConnection.Failure.unexpectedRequest("connect")
    }

    func requestEnvelope(
        method: String,
        params: JSONValue?,
        timeout: Duration?
    ) async throws -> ConnAppServerResponseEnvelope {
        methods.append(method)
        if method == "thread/list" {
            return .init(
                connection: identity,
                sequence: 1,
                result: .object([
                    "data": .array([.object([
                        "id": .string("known"),
                        "sessionId": .string("session-known"),
                        "cliVersion": .string("0.144.6"),
                        "name": .string("Thread known"),
                        "preview": .string("discarded"),
                        "cwd": .string("/tmp/project"),
                        "gitInfo": .null,
                        "modelProvider": .string("openai"),
                        "source": .string("appServer"),
                        "status": .object(["type": .string("idle")]),
                        "ephemeral": .bool(false),
                        "createdAt": .integer(1_830_000_000),
                        "updatedAt": .integer(1_830_000_001),
                        "turns": .array([]),
                    ])]),
                    "nextCursor": .null,
                    "backwardsCursor": .null,
                ])
            )
        }
        if method == "thread/loaded/list" {
            try await Task.sleep(for: .seconds(60))
        }
        throw ScriptedMonitoringConnection.Failure.unexpectedRequest(method)
    }

    func drainInboundEnvelopes() async -> [ConnAppServerInboundEnvelope] { [] }
    func monitoringState() async -> ConnAppServerConnectionState {
        .ready(generation: identity.generation, version: .v0_144_6)
    }
    func monitoringIdentity() async -> ConnAppServerConnectionIdentity? { identity }
    func disconnect() async {}
    func requestedMethods() -> [String] { methods }
}
