import Foundation
import ConnDomain

enum Phase7AppServerProjectionTestCases {
    private static let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
    private static let threadID = AppServerThreadID(rawValue: "thread-phase7")
    private static let sessionID = AppServerSessionID(rawValue: "session-phase7")
    private static let turnID = AppServerTurnID(rawValue: "TURN/AbC:0007")
    private static let itemID = AppServerItemID(rawValue: "item-phase7")
    private static let connection = AppServerConnectionIdentity(
        instanceID: UUID(uuidString: "70000000-0000-4000-8000-000000000001")!,
        generation: 7
    )

    static func run(into suite: inout TestSuite) async throws {
        try await testSnapshotDeltaConvergence(into: &suite)
        try await testTerminalDominanceAndConflicts(into: &suite)
        try await testRequestIdentityAndResolution(into: &suite)
        try await testStaleDestructiveFactsDoNotDominate(into: &suite)
        try await testStructuredOutcomesOnly(into: &suite)
        try await testReconnectAndRestoreQualification(into: &suite)
        try await testHydrationBuffersNewerDeltas(into: &suite)
        try await testPhase85RecoveryContracts(into: &suite)
        try await testLongReadTruncation(into: &suite)
        try await testIncrementalReconnectInventory(into: &suite)
        try await testDeltaDuplicateIsolationAtInventoryScale(into: &suite)
        try await testRetentionBounds(into: &suite)
        try await testRuntimeRequestFactsNeverEnterCheckpoint(into: &suite)
    }

    private static func testSnapshotDeltaConvergence(
        into suite: inout TestSuite
    ) async throws {
        let ordered = AppServerProjectionStore()
        let reversed = AppServerProjectionStore()
        for store in [ordered, reversed] {
            _ = await store.apply(activation(connection))
            _ = await store.apply(.snapshot(.init(
                cursor: cursor(1),
                observedAt: at(1),
                threads: [thread(status: .active([]), turns: [])]
            )))
        }

        let startedTurn = delta(
            2,
            .turnUpsert(
                threadID: threadID,
                turn: .init(
                    id: turnID,
                    status: .inProgress,
                    startedAt: at(2),
                    itemsView: .notLoaded
                )
            )
        )
        let startedItem = delta(
            3,
            .itemUpsert(
                threadID: threadID,
                turnID: turnID,
                item: .init(
                    id: itemID,
                    kind: .commandExecution,
                    status: .started,
                    startedAt: at(3)
                )
            )
        )
        let completedItem = delta(
            4,
            .itemUpsert(
                threadID: threadID,
                turnID: turnID,
                item: .init(
                    id: itemID,
                    kind: .commandExecution,
                    status: .completed,
                    completedAt: at(4)
                )
            )
        )
        let completedTurn = delta(
            5,
            .turnUpsert(
                threadID: threadID,
                turn: .init(
                    id: turnID,
                    status: .completed,
                    startedAt: at(2),
                    completedAt: at(5),
                    itemsView: .notLoaded
                )
            )
        )
        let inputs = [startedTurn, startedItem, completedItem, completedTurn]

        for input in inputs {
            _ = await ordered.apply(input)
            _ = await ordered.apply(input)
        }
        for input in inputs.reversed() {
            _ = await reversed.apply(input)
            _ = await reversed.apply(input)
        }

        let orderedSnapshot = await ordered.snapshot(at: at(6))
        let reversedSnapshot = await reversed.snapshot(at: at(6))
        suite.check(
            orderedSnapshot == reversedSnapshot,
            "stable source cursors make ordered, reversed, and duplicate deltas converge"
        )
        let projected = try suite.require(
            orderedSnapshot.threads.first,
            "converged projection retains the hydrated thread"
        )
        suite.check(
            projected.activeTurnIDs.isEmpty,
            "a terminal turn is never resurrected as active by a late started fact"
        )
        suite.check(
            projected.turns.first?.status == .completed,
            "structured terminal turn status dominates late nonterminal delivery"
        )
        suite.check(
            projected.turns.first?.items.first?.status == .completed,
            "terminal item status dominates late item-started delivery"
        )
        suite.check(
            projected.outcome?.kind == .completed,
            "the converged terminal turn produces one structured outcome"
        )
    }

    private static func testTerminalDominanceAndConflicts(
        into suite: inout TestSuite
    ) async throws {
        let store = AppServerProjectionStore()
        _ = await store.apply(activation(connection))
        _ = await store.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: at(1),
            threads: [thread(status: .active([]), turns: [])]
        )))
        _ = await store.apply(delta(
            3,
            .turnUpsert(
                threadID: threadID,
                turn: .init(id: turnID, status: .completed, completedAt: at(3))
            )
        ))
        _ = await store.apply(delta(
            2,
            .turnUpsert(
                threadID: threadID,
                turn: .init(id: turnID, status: .inProgress, startedAt: at(2))
            )
        ))
        var projected = try suite.require(
            await store.snapshot(at: at(4)).threads.first,
            "late-start fixture retains its thread"
        )
        suite.check(
            projected.turns.first?.status == .completed,
            "late turn started cannot regress a structured terminal turn"
        )

        _ = await store.apply(delta(
            4,
            .turnUpsert(
                threadID: threadID,
                turn: .init(id: turnID, status: .failed, completedAt: at(4))
            )
        ))
        projected = try suite.require(
            await store.snapshot(at: at(5)).threads.first,
            "terminal-conflict fixture retains its thread"
        )
        suite.check(
            projected.turns.first?.status == .unknown,
            "conflicting terminal turn facts fail closed to unknown"
        )
        suite.check(
            projected.freshness == .stale,
            "conflicting terminal turn facts qualify the projection as stale"
        )
        suite.check(
            projected.outcome == nil,
            "conflicting terminal facts never invent an outcome"
        )

        let itemStore = AppServerProjectionStore()
        _ = await itemStore.apply(activation(connection))
        _ = await itemStore.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: at(1),
            threads: [thread(status: .active([]), turns: [])]
        )))
        let itemConflict = AppServerItemID(rawValue: "item-terminal-conflict")
        _ = await itemStore.apply(delta(
            2,
            .itemUpsert(
                threadID: threadID,
                turnID: AppServerTurnID(rawValue: "turn-item-conflict"),
                item: .init(id: itemConflict, kind: .fileChange, status: .completed)
            )
        ))
        _ = await itemStore.apply(delta(
            3,
            .itemUpsert(
                threadID: threadID,
                turnID: AppServerTurnID(rawValue: "turn-item-conflict"),
                item: .init(id: itemConflict, kind: .fileChange, status: .failed)
            )
        ))
        let itemTurn = await itemStore.snapshot(at: at(4)).threads.first?.turns.first {
            $0.id.rawValue == "turn-item-conflict"
        }
        suite.check(
            itemTurn?.items.first?.status == .unknown,
            "conflicting terminal item facts fail closed rather than using arrival order"
        )
    }

    private static func testRequestIdentityAndResolution(
        into suite: inout TestSuite
    ) async throws {
        let store = AppServerProjectionStore()
        _ = await store.apply(activation(connection))
        _ = await store.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: at(1),
            threads: [thread(
                status: .active([.waitingOnApproval]),
                turns: [.init(id: turnID, status: .inProgress, startedAt: at(1))]
            )]
        )))

        let numeric = AppServerRequestID.integer(7)
        let textual = AppServerRequestID.string("7")
        _ = await store.apply(delta(4, .requestResolved(threadID: threadID, requestID: numeric)))
        let lateNumeric = await store.apply(delta(
            2,
            .requestOpened(.init(
                requestID: numeric,
                threadID: threadID,
                turnID: turnID,
                itemID: itemID,
                kind: .commandApproval,
                startedAt: at(2)
            ))
        ))
        suite.check(
            lateNumeric == .ignoredTombstoned,
            "resolution-before-request prevents a late request from becoming actionable"
        )

        _ = await store.apply(delta(
            3,
            .requestOpened(.init(
                requestID: textual,
                threadID: threadID,
                turnID: turnID,
                itemID: itemID,
                kind: .structuredQuestion,
                startedAt: at(3)
            ))
        ))
        let projected = try suite.require(
            await store.snapshot(at: at(5)).threads.first,
            "request identity fixture retains its thread"
        )
        let request = try suite.require(
            projected.requests.first,
            "textual request remains actionable"
        )
        suite.check(
            projected.requests.count == 1
                && request.id.requestID == textual,
            "integer 7 and string 7 remain distinct request identities"
        )
        suite.check(
            request.id.connection == connection,
            "presentation request identity retains exact runtime connection authority"
        )
        suite.check(
            request.turnID == turnID
                && projected.activeTurnIDs == [turnID],
            "opaque active turn ID survives request and presentation round trips"
        )

        let encodedNumeric = try JSONEncoder().encode(numeric)
        let encodedTextual = try JSONEncoder().encode(textual)
        let decodedNumeric = try JSONDecoder().decode(
            AppServerRequestID.self,
            from: encodedNumeric
        )
        let decodedTextual = try JSONDecoder().decode(
            AppServerRequestID.self,
            from: encodedTextual
        )
        suite.check(
            decodedNumeric == numeric,
            "numeric request IDs round-trip without string conversion"
        )
        suite.check(
            decodedTextual == textual,
            "string request IDs round-trip without numeric conversion"
        )
    }

    private static func testStructuredOutcomesOnly(
        into suite: inout TestSuite
    ) async throws {
        let statuses: [(AppServerTurnStatus, AppServerOutcomeKind?)] = [
            (.inProgress, nil),
            (.unknown, nil),
            (.completed, .completed),
            (.failed, .failed),
            (.interrupted, .interrupted),
        ]
        for (index, fixture) in statuses.enumerated() {
            let store = AppServerProjectionStore()
            let identity = AppServerConnectionIdentity(
                instanceID: UUID(uuidString: String(
                    format: "70000000-0000-4000-8000-%012d",
                    index + 20
                ))!,
                generation: 1
            )
            _ = await store.apply(activation(identity))
            let turn = AppServerTurnInput(
                id: AppServerTurnID(rawValue: "outcome-turn-\(index)"),
                status: fixture.0,
                completedAt: fixture.0.isTerminal ? at(2) : nil,
                items: [.init(
                    id: AppServerItemID(rawValue: "failed-item-\(index)"),
                    kind: .commandExecution,
                    status: .failed
                )]
            )
            _ = await store.apply(.snapshot(.init(
                cursor: .init(connection: identity, sequence: 1),
                observedAt: at(1),
                threads: [thread(
                    id: AppServerThreadID(rawValue: "outcome-thread-\(index)"),
                    status: .systemError,
                    turns: [turn]
                )]
            )))
            let outcome = await store.snapshot(at: at(3)).threads.first?.outcome?.kind
            suite.check(
                outcome == fixture.1,
                "only structured terminal Turn status derives outcome for \(fixture.0)"
            )
        }
    }

    private static func testStaleDestructiveFactsDoNotDominate(
        into suite: inout TestSuite
    ) async throws {
        let store = AppServerProjectionStore()
        _ = await store.apply(activation(connection))
        _ = await store.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: at(1),
            threads: [thread(status: .active([]), turns: [])]
        )))
        _ = await store.apply(delta(
            10,
            .turnUpsert(
                threadID: threadID,
                turn: .init(id: turnID, status: .inProgress, startedAt: at(10))
            )
        ))
        let staleRemoval = await store.apply(delta(5, .threadRemoved(threadID)))
        let afterStaleRemoval = await store.snapshot(at: at(10))
        suite.check(
            staleRemoval == .duplicate
                && afterStaleRemoval.threads.first?.id == threadID,
            "a lower-cursor thread removal cannot tombstone a newer aggregate"
        )

        let requestID = AppServerRequestID.string("newer-request")
        _ = await store.apply(delta(
            12,
            .requestOpened(.init(
                requestID: requestID,
                threadID: threadID,
                turnID: turnID,
                kind: .structuredQuestion,
                startedAt: at(12)
            ))
        ))
        let staleResolution = await store.apply(delta(
            11,
            .requestResolved(threadID: threadID, requestID: requestID)
        ))
        let afterStaleResolution = await store.snapshot(at: at(12))
        suite.check(
            staleResolution == .duplicate
                && afterStaleResolution.attentionRequests.count == 1,
            "a lower-cursor resolution cannot tombstone a newer live request"
        )

        let reversed = AppServerProjectionStore()
        _ = await reversed.apply(activation(connection))
        _ = await reversed.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: at(1),
            threads: [thread(status: .idle, turns: [])]
        )))
        _ = await reversed.apply(delta(
            5,
            .requestResolved(threadID: threadID, requestID: requestID)
        ))
        let newerRequest = await reversed.apply(delta(
            6,
            .requestOpened(.init(
                requestID: requestID,
                threadID: threadID,
                turnID: turnID,
                kind: .structuredQuestion,
                startedAt: at(6)
            ))
        ))
        let afterNewerRequest = await reversed.snapshot(at: at(6))
        suite.check(
            newerRequest == .applied
                && afterNewerRequest.attentionRequests.count == 1,
            "a higher-cursor request supersedes a stale resolution applied first"
        )
    }

    private static func testReconnectAndRestoreQualification(
        into suite: inout TestSuite
    ) async throws {
        let store = AppServerProjectionStore()
        _ = await store.apply(activation(connection))
        _ = await store.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: at(1),
            threads: [thread(
                status: .active([.waitingOnUserInput]),
                turns: [.init(id: turnID, status: .inProgress, startedAt: at(1))]
            )]
        )))
        _ = await store.apply(delta(
            2,
            .requestOpened(.init(
                requestID: .string("reconnect-request"),
                threadID: threadID,
                turnID: turnID,
                kind: .structuredQuestion,
                startedAt: at(2)
            ))
        ))
        let checkpoint = await store.checkpoint(at: at(3))
        _ = await store.apply(.connectionLost(connection))
        var disconnected = try suite.require(
            await store.snapshot(at: at(4)).threads.first,
            "disconnect retains qualified cache"
        )
        suite.check(
            disconnected.freshness == .stale && disconnected.requests.isEmpty,
            "disconnect marks cache stale and removes runtime request authority"
        )
        let disconnectedSnapshot = await store.snapshot(at: at(4))
        suite.check(
            disconnectedSnapshot.connection == nil,
            "disconnect clears active connection identity"
        )

        let replacement = AppServerConnectionIdentity(
            instanceID: UUID(uuidString: "70000000-0000-4000-8000-000000000002")!,
            generation: 8
        )
        _ = await store.apply(activation(replacement))
        let staleResult = await store.apply(delta(
            5,
            .threadStatus(threadID: threadID, status: .idle)
        ))
        suite.check(
            staleResult == .rejectedStaleConnection,
            "an old connection identity cannot mutate a replacement projection"
        )
        _ = await store.apply(.snapshot(.init(
            cursor: .init(connection: replacement, sequence: 1),
            observedAt: at(5),
            threads: [thread(status: .idle, turns: [])]
        )))
        disconnected = try suite.require(
            await store.snapshot(at: at(6)).threads.first,
            "replacement hydration revalidates the cached thread"
        )
        suite.check(
            disconnected.freshness == .rehydrated,
            "replacement snapshot explicitly qualifies rehydrated state"
        )

        let restoredStore = AppServerProjectionStore()
        try await restoredStore.restore(from: checkpoint)
        let restoredSnapshot = await restoredStore.snapshot(at: at(6))
        let restored = try suite.require(
            restoredSnapshot.threads.first,
            "bounded checkpoint restores a presentation cache"
        )
        suite.check(
            restored.freshness == .stale
                && restored.requests.isEmpty
                && restoredSnapshot.connection == nil,
            "restored cache is stale and non-actionable until live rehydration"
        )
        suite.check(
            restoredSnapshot.featureSupport.features.isEmpty,
            "runtime feature authority is never restored from persistence"
        )
    }

    private static func testRetentionBounds(into suite: inout TestSuite) async throws {
        let configuration = AppServerProjectionConfiguration(
            maximumThreads: 2,
            maximumTurnsPerThread: 2,
            maximumItemsPerTurn: 2,
            maximumUnresolvedRequests: 2,
            maximumThreadTombstones: 2,
            maximumResolvedRequestTombstones: 2,
            maximumStringBytes: 64
        )
        let store = AppServerProjectionStore(configuration: configuration)
        _ = await store.apply(activation(connection))
        _ = await store.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: at(1),
            threads: []
        )))

        var sequence: UInt64 = 2
        for threadOrdinal in 0..<3 {
            let boundedThreadID = AppServerThreadID(rawValue: "bounded-thread-\(threadOrdinal)")
            for turnOrdinal in 0..<3 {
                let boundedTurnID = AppServerTurnID(rawValue: "bounded-turn-\(threadOrdinal)-\(turnOrdinal)")
                _ = await store.apply(.delta(.init(
                    cursor: .init(connection: connection, sequence: sequence),
                    observedAt: at(TimeInterval(sequence)),
                    delta: .turnUpsert(
                        threadID: boundedThreadID,
                        turn: .init(id: boundedTurnID, status: .inProgress)
                    )
                )))
                sequence += 1
                for itemOrdinal in 0..<3 {
                    _ = await store.apply(.delta(.init(
                        cursor: .init(connection: connection, sequence: sequence),
                        observedAt: at(TimeInterval(sequence)),
                        delta: .itemUpsert(
                            threadID: boundedThreadID,
                            turnID: boundedTurnID,
                            item: .init(
                                id: AppServerItemID(
                                    rawValue: "bounded-item-\(threadOrdinal)-\(turnOrdinal)-\(itemOrdinal)"
                                ),
                                kind: .mcpToolCall,
                                status: .completed
                            )
                        )
                    )))
                    sequence += 1
                }
            }
        }
        for ordinal in 0..<3 {
            _ = await store.apply(.delta(.init(
                cursor: .init(connection: connection, sequence: sequence),
                observedAt: at(TimeInterval(sequence)),
                delta: .requestOpened(.init(
                    requestID: .integer(Int64(ordinal)),
                    threadID: AppServerThreadID(rawValue: "bounded-thread-2"),
                    kind: .commandApproval,
                    startedAt: at(TimeInterval(sequence))
                ))
            )))
            sequence += 1
        }

        let metrics = await store.storageMetrics()
        suite.check(metrics.threadCount > 0, "retention fixture materializes bounded threads")
        suite.check(metrics.turnCount > 0, "retention fixture materializes bounded turns")
        suite.check(metrics.itemCount > 0, "retention fixture materializes bounded items")
        suite.check(
            metrics.unresolvedRequestCount > 0,
            "retention fixture materializes runtime requests before measuring bounds"
        )
        suite.check(metrics.threadCount <= 2, "App Server thread retention is bounded")
        suite.check(metrics.turnCount <= 4, "App Server turn retention is bounded per thread")
        suite.check(metrics.itemCount <= 8, "App Server item retention is bounded per turn")
        suite.check(metrics.unresolvedRequestCount <= 2, "runtime request retention is bounded")
        let boundedSnapshot = await store.snapshot(at: at(TimeInterval(sequence)))
        suite.check(
            Set(boundedSnapshot.threads.map(\.id)) == Set([
                AppServerThreadID(rawValue: "bounded-thread-1"),
                AppServerThreadID(rawValue: "bounded-thread-2"),
            ]),
            "thread retention keeps the two most recently observed upstream identities"
        )
        suite.check(
            Set(boundedSnapshot.attentionRequests.map { $0.id.requestID }) == Set([
                AppServerRequestID.integer(1),
                AppServerRequestID.integer(2),
            ]),
            "request retention keeps the two highest-cursor request identities"
        )

        for ordinal in 0..<3 {
            _ = await store.apply(.delta(.init(
                cursor: .init(connection: connection, sequence: sequence),
                observedAt: at(TimeInterval(sequence)),
                delta: .requestResolved(
                    threadID: AppServerThreadID(rawValue: "tombstone-thread-\(ordinal)"),
                    requestID: .string("tombstone-request-\(ordinal)")
                )
            )))
            sequence += 1
        }
        let tombstoneMetrics = await store.storageMetrics()
        suite.check(
            tombstoneMetrics.resolvedRequestTombstoneCount == 2,
            "request-resolution tombstones remain bounded"
        )

        let checkpoint = await store.checkpoint(at: at(100))
        suite.check(checkpoint.threads.count <= 2, "durable cache preserves the thread bound")
        suite.check(
            checkpoint.threads.allSatisfy { $0.turns.count <= 2 },
            "durable cache preserves the per-thread turn bound"
        )
        suite.check(
            checkpoint.threads.flatMap(\.turns).allSatisfy { $0.items.count <= 2 },
            "durable cache preserves the per-turn item bound"
        )
    }

    private static func testHydrationBuffersNewerDeltas(
        into suite: inout TestSuite
    ) async throws {
        let store = AppServerProjectionStore()
        _ = await store.apply(activation(connection))
        let buffered = await store.apply(delta(
            3,
            .threadStatus(
                threadID: threadID,
                status: .active([.waitingOnApproval])
            )
        ))
        suite.check(
            buffered == .appliedPendingSnapshot,
            "a current-generation delta reports that it is pending a snapshot"
        )
        let bufferedMetrics = await store.storageMetrics()
        suite.check(
            bufferedMetrics.threadCount == 0
                && bufferedMetrics.bufferedDeltaCount == 1
                && bufferedMetrics.requiresSnapshot
                && !bufferedMetrics.rejectsDeltasUntilReconnect,
            "a buffered hydration delta is not published before its snapshot"
        )

        _ = await store.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: at(1),
            threads: [thread(status: .idle, turns: [])]
        )))
        let hydrated = try suite.require(
            await store.snapshot(at: at(4)).threads.first,
            "hydration publishes the authoritative thread and buffered delta"
        )
        suite.check(
            hydrated.status == .active([.waitingOnApproval]),
            "a buffered higher-cursor delta is reduced after the hydration snapshot"
        )
        suite.check(
            hydrated.freshness == .live,
            "a buffered post-snapshot delta upgrades rehydrated state to live"
        )

        let conflicted = AppServerProjectionStore()
        _ = await conflicted.apply(activation(connection))
        _ = await conflicted.apply(delta(
            3,
            .turnUpsert(
                threadID: threadID,
                turn: .init(id: turnID, status: .completed, completedAt: at(3))
            )
        ))
        _ = await conflicted.apply(delta(
            4,
            .turnUpsert(
                threadID: threadID,
                turn: .init(id: turnID, status: .failed, completedAt: at(4))
            )
        ))
        _ = await conflicted.apply(delta(
            5,
            .threadStatus(threadID: threadID, status: .active([.waitingOnApproval]))
        ))
        _ = await conflicted.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: at(1),
            threads: [thread(status: .idle, turns: [])]
        )))
        let gated = try suite.require(
            await conflicted.snapshot(at: at(5)).threads.first,
            "conflicting buffered replay retains its snapshot thread"
        )
        suite.check(
            gated.status == .idle && gated.freshness == .stale,
            "a replay conflict gates subsequent buffered deltas instead of mutating stale state"
        )

        _ = await conflicted.apply(.snapshot(.init(
            cursor: cursor(4),
            observedAt: at(4),
            threads: [thread(
                status: .idle,
                turns: [.init(id: turnID, status: .failed, completedAt: at(4))]
            )]
        )))
        let recovered = try suite.require(
            await conflicted.snapshot(at: at(5)).threads.first,
            "replacement snapshot replays facts held behind the conflict gate"
        )
        suite.check(
            recovered.status == .active([.waitingOnApproval]),
            "a later authoritative snapshot heals the conflict and replays the newer delta"
        )
    }

    private static func testPhase85RecoveryContracts(
        into suite: inout TestSuite
    ) async throws {
        suite.check(
            AppServerItemKind.subagentActivity.rawValue == "subAgentActivity",
            "subagent activity uses the stable schema's exact discriminator"
        )

        let store = AppServerProjectionStore()
        _ = await store.apply(activation(connection))
        _ = await store.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: at(1),
            threads: [thread(status: .idle, turns: [])]
        )))
        _ = await store.apply(delta(
            2,
            .turnUpsert(
                threadID: threadID,
                turn: .init(id: turnID, status: .completed, completedAt: at(2))
            )
        ))
        let conflict = await store.apply(delta(
            3,
            .turnUpsert(
                threadID: threadID,
                turn: .init(id: turnID, status: .failed, completedAt: at(3))
            )
        ))
        let metrics = await store.storageMetrics()
        suite.check(
            conflict == .appliedPendingSnapshot && metrics.requiresSnapshot,
            "a terminal conflict makes the caller-visible snapshot requirement explicit"
        )
    }

    private static func testLongReadTruncation(
        into suite: inout TestSuite
    ) async throws {
        let store = AppServerProjectionStore(configuration: .init(
            maximumTurnsPerThread: 2,
            maximumItemsPerTurn: 2
        ))
        _ = await store.apply(activation(connection))
        let turns = (0..<3).map { turnOrdinal in
            AppServerTurnInput(
                id: .init(rawValue: "long-turn-\(turnOrdinal)"),
                status: .completed,
                startedAt: at(TimeInterval(10 + turnOrdinal)),
                completedAt: at(TimeInterval(20 + turnOrdinal)),
                items: (0..<3).map { itemOrdinal in
                    AppServerItemInput(
                        id: .init(rawValue: "long-item-\(turnOrdinal)-\(itemOrdinal)"),
                        kind: .agentMessage,
                        status: .completed,
                        startedAt: at(TimeInterval(30 + itemOrdinal)),
                        completedAt: at(TimeInterval(40 + itemOrdinal))
                    )
                }
            )
        }
        let result = await store.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: at(50),
            threads: [thread(status: .idle, turns: turns)]
        )))
        let projected = try suite.require(
            await store.snapshot(at: at(51)).threads.first,
            "a long authoritative read remains eligible for projection"
        )
        suite.check(result == .applied, "a valid long read is accepted instead of rejected")
        suite.check(
            projected.turns.map(\.id.rawValue) == ["long-turn-2", "long-turn-1"],
            "long reads retain the deterministically most recent turns"
        )
        suite.check(
            projected.turns.allSatisfy {
                $0.items.map(\.id.rawValue) == [
                    "long-item-\($0.id.rawValue.suffix(1))-1",
                    "long-item-\($0.id.rawValue.suffix(1))-2",
                ]
            },
            "long turns retain the deterministically most recent items"
        )
        let metrics = await store.storageMetrics()
        suite.check(
            metrics.turnCount == 2 && metrics.itemCount == 4,
            "storage metrics count accepted bounded history only"
        )
    }

    private static func testIncrementalReconnectInventory(
        into suite: inout TestSuite
    ) async throws {
        let original = AppServerProjectionStore()
        _ = await original.apply(activation(connection))
        _ = await original.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: at(1),
            threads: [
                thread(
                    status: .idle,
                    turns: [],
                    workingDirectoryPath: "/Users/example/SideQuest/Sources",
                    projectRootPath: "/Users/example/SideQuest"
                ),
                thread(
                    id: .init(rawValue: "thread-absent-after-reconnect"),
                    status: .idle,
                    turns: []
                ),
            ]
        )))
        let checkpoint = await original.checkpoint(at: at(2))
        let projectCheckpoint = checkpoint.threads.first { $0.id == threadID }
        suite.check(
            projectCheckpoint?.workingDirectoryPath
                == "/Users/example/SideQuest/Sources"
                && projectCheckpoint?.projectRootPath
                    == "/Users/example/SideQuest",
            "bounded privacy-safe project paths survive checkpoint creation"
        )

        let restored = AppServerProjectionStore()
        try await restored.restore(from: checkpoint)
        let reconnect = AppServerConnectionIdentity(
            instanceID: UUID(uuidString: "70000000-0000-4000-8000-000000000085")!,
            generation: 85
        )
        _ = await restored.apply(activation(reconnect))
        _ = await restored.apply(.snapshot(.init(
            cursor: .init(connection: reconnect, sequence: 1),
            observedAt: at(3),
            threads: [],
            inventoryAuthority: .incremental
        )))
        let gated = await restored.snapshot(at: at(4))
        suite.check(
            Set(gated.threads.map(\.id)) == Set([
                threadID,
                .init(rawValue: "thread-absent-after-reconnect"),
            ])
                && gated.threads.allSatisfy { $0.freshness == .stale }
                && gated.threads.first(where: { $0.id == threadID })?.workingDirectoryPath
                    == "/Users/example/SideQuest/Sources"
                && gated.threads.first(where: { $0.id == threadID })?.projectRootPath
                    == "/Users/example/SideQuest",
            "an empty reconnect gate preserves restored rows as visibly stale"
        )

        _ = await restored.apply(.snapshot(.init(
            cursor: .init(connection: reconnect, sequence: 2),
            observedAt: at(5),
            threads: [],
            inventoryAuthority: .authoritative,
            authoritativeThreadIDs: [threadID]
        )))
        let partiallyQualified = await restored.snapshot(at: at(6))
        suite.check(
            partiallyQualified.threads.map(\.id) == [threadID]
                && partiallyQualified.threads.first?.freshness == .stale,
            "authoritative inventory retains a listed but unqualified cached row as stale"
        )

        _ = await restored.apply(.snapshot(.init(
            cursor: .init(connection: reconnect, sequence: 3),
            observedAt: at(7),
            threads: [],
            inventoryAuthority: .authoritative,
            authoritativeThreadIDs: []
        )))
        let removed = await restored.snapshot(at: at(8))
        suite.check(
            removed.threads.isEmpty,
            "a completed authoritative inventory may remove a missing restored row"
        )
    }

    private static func testDeltaDuplicateIsolationAtInventoryScale(
        into suite: inout TestSuite
    ) async throws {
        let rowCount = 500
        let store = AppServerProjectionStore(configuration: .init(maximumThreads: 600))
        _ = await store.apply(activation(connection))
        let rows = (0..<rowCount).map { ordinal in
            thread(
                id: .init(rawValue: "inventory-thread-\(ordinal)"),
                status: .idle,
                turns: []
            )
        }
        _ = await store.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: at(1),
            threads: rows
        )))

        let target = AppServerThreadID(rawValue: "inventory-thread-250")
        let statusDelta = delta(2, .threadStatus(threadID: target, status: .active([])))
        let applied = await store.apply(statusDelta)
        suite.check(
            applied == .applied,
            "a lifecycle delta applies with hundreds of unrelated inventory rows"
        )
        let beforeDuplicate = await store.snapshot(at: at(3))
        let duplicate = await store.apply(statusDelta)
        suite.check(
            duplicate == .duplicate,
            "a repeated touched-thread delta retains exact duplicate semantics"
        )
        let afterDuplicate = await store.snapshot(at: at(3))
        suite.check(
            afterDuplicate == beforeDuplicate
                && afterDuplicate.threads.count == rowCount
                && afterDuplicate.threads.first(where: { $0.id == target })?.status
                    == .active([]),
            "duplicate detection leaves every unrelated row unchanged at inventory scale"
        )

        let threadUpsert = delta(3, .threadUpsert(rows[250]))
        let threadApplied = await store.apply(threadUpsert)
        suite.check(
            threadApplied == .applied,
            "a touched-thread metadata upsert applies without whole-inventory comparison"
        )
        let beforeThreadDuplicate = await store.snapshot(at: at(4))
        let threadDuplicate = await store.apply(threadUpsert)
        let afterThreadDuplicate = await store.snapshot(at: at(4))
        suite.check(
            threadDuplicate == .duplicate
                && afterThreadDuplicate == beforeThreadDuplicate
                && afterThreadDuplicate.threads.count == rowCount,
            "per-thread comparison preserves exact upsert duplicate semantics at inventory scale"
        )
    }

    private static func testRuntimeRequestFactsNeverEnterCheckpoint(
        into suite: inout TestSuite
    ) async throws {
        let store = AppServerProjectionStore()
        _ = await store.apply(activation(connection))
        _ = await store.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: at(1),
            threads: [thread(status: .active([.waitingOnUserInput]), turns: [])]
        )))
        let facts = AppServerStructuredQuestionFacts(
            questions: [.init(
                id: "phase9-question-id",
                header: "Phase 9 header",
                prompt: "PHASE9-QUESTION-CANARY",
                options: [.init(
                    label: "PHASE9-OPTION-CANARY",
                    detail: "PHASE9-OPTION-DETAIL-CANARY"
                )],
                permitsOther: true,
                isSecret: true
            )],
            autoResolutionMilliseconds: 60_000
        )
        _ = await store.apply(delta(2, .requestOpened(.init(
            requestID: .string("phase9-request"),
            threadID: threadID,
            turnID: turnID,
            itemID: itemID,
            kind: .structuredQuestion,
            facts: .structuredQuestions(facts),
            startedAt: at(2)
        ))))

        let snapshot = await store.snapshot(at: at(3))
        suite.check(
            snapshot.threads.first?.requests.first?.facts == AppServerRequestFacts.structuredQuestions(facts),
            "bounded request facts round-trip through the runtime projection"
        )

        let checkpoint = await store.checkpoint(at: at(3))
        let encoded = String(decoding: try JSONEncoder().encode(checkpoint), as: UTF8.self)
        for canary in [
            "phase9-request", "phase9-question-id", "PHASE9-QUESTION-CANARY",
            "PHASE9-OPTION-CANARY", "PHASE9-OPTION-DETAIL-CANARY",
        ] {
            suite.check(
                !encoded.contains(canary),
                "runtime-only request fact canary \(canary) is absent from checkpoints"
            )
        }
    }

    private static func activation(
        _ identity: AppServerConnectionIdentity
    ) -> AppServerProjectionInput {
        .connectionActivated(
            identity: identity,
            source: .managedDaemon,
            featureSupport: .init(features: [.monitor, .steer])
        )
    }

    private static func cursor(_ sequence: UInt64) -> AppServerObservationCursor {
        .init(connection: connection, sequence: sequence)
    }

    private static func delta(
        _ sequence: UInt64,
        _ value: AppServerProjectionDelta
    ) -> AppServerProjectionInput {
        .delta(.init(cursor: cursor(sequence), observedAt: at(TimeInterval(sequence)), delta: value))
    }

    private static func thread(
        id: AppServerThreadID = threadID,
        status: AppServerThreadStatus,
        turns: [AppServerTurnInput],
        workingDirectoryPath: String? = nil,
        projectRootPath: String? = nil
    ) -> AppServerThreadInput {
        .init(
            id: id,
            sessionID: sessionID,
            title: "Phase 7",
            workingDirectoryName: "SideQuest",
            workingDirectoryPath: workingDirectoryPath,
            projectRootPath: projectRootPath,
            source: .appServer,
            status: status,
            createdAt: at(0),
            updatedAt: at(1),
            turnsAreAuthoritative: true,
            turns: turns
        )
    }

    private static func at(_ seconds: TimeInterval) -> Date {
        baseDate.addingTimeInterval(seconds)
    }
}
