import Darwin
import Foundation
import ConnAppCore
import ConnAppServerAdapter
import ConnDomain

enum Phase7PersistenceMigrationTestCases {
    private static let baseDate = Date(timeIntervalSince1970: 1_800_100_000)
    private static let connection = AppServerConnectionIdentity(
        instanceID: UUID(uuidString: "71000000-0000-4000-8000-000000000001")!,
        generation: 1
    )

    static func run(into suite: inout TestSuite) async throws {
        try testDistinctRootAndLegacyExclusion(into: &suite)
        try testTwoSlotRecoveryAndBounds(into: &suite)
        try testByteAwareTrimmingAtCountCaps(into: &suite)
        try await testCoordinatorRestoreAndRollback(into: &suite)
        try await testCacheFailureFallbackAndDebounce(into: &suite)
        try await testCursorBearingHydrationOrdering(into: &suite)
        try await testPrivacyCanariesStopAtAdapter(into: &suite)
        try await testAppServerCommitGate(into: &suite)
    }

    private static func testCacheFailureFallbackAndDebounce(
        into suite: inout TestSuite
    ) async throws {
        let liveOnly = AppServerDomainCoordinator(domain: AppServerProjectionStore())
        let liveResult = try await liveOnly.applyAndPersist(
            activation(connection),
            checkpointedAt: baseDate
        )
        suite.checkEqual(liveResult, .applied, "monitoring remains live when cache open or restore is unavailable")
        let liveSnapshot = await liveOnly.snapshot(at: baseDate)
        suite.check(liveSnapshot.connection == connection, "cache fallback preserves current live authority")
        let fallbackDiagnostic = await liveOnly.persistenceDiagnostic()
        suite.check(fallbackDiagnostic != nil, "cache fallback surfaces a presentation-safe diagnostic")

        let support = try Phase3TestScaffolding.temporaryApplicationSupport(
            "phase85-debounced-persistence"
        )
        defer { try? FileManager.default.removeItem(at: support) }
        let store = try AppServerDomainCheckpointFileStore(applicationSupportDirectory: support)
        let coordinator = AppServerDomainCoordinator(
            domain: AppServerProjectionStore(),
            checkpointStore: store,
            persistenceDebounce: .seconds(60)
        )
        _ = try await coordinator.applyAndPersist(activation(connection), checkpointedAt: baseDate)
        _ = try await coordinator.applyAndPersist(.snapshot(.init(
            cursor: .init(connection: connection, sequence: 1),
            observedAt: baseDate,
            threads: []
        )), checkpointedAt: baseDate)
        let generationBeforeFlush = try store.loadGeneration()
        suite.check(generationBeforeFlush == nil, "input bursts do not fsync before the debounce window")
        await coordinator.flushPersistence()
        suite.checkEqual(try store.loadGeneration(), 1, "a burst persists as one durable generation after flush")
    }

    private static func testByteAwareTrimmingAtCountCaps(
        into suite: inout TestSuite
    ) throws {
        let support = try Phase3TestScaffolding.temporaryApplicationSupport(
            "phase85-byte-aware-count-caps"
        )
        defer { try? FileManager.default.removeItem(at: support) }
        let configuration = AppServerProjectionConfiguration(
            maximumThreads: 12,
            maximumTurnsPerThread: 5,
            maximumItemsPerTurn: 8
        )
        let maximumBytes = 24 * 1_024
        let store = try AppServerDomainCheckpointFileStore(
            applicationSupportDirectory: support,
            maximumCheckpointBytes: maximumBytes,
            projectionConfiguration: configuration
        )
        let longTitle = String(repeating: "x", count: configuration.maximumStringBytes)
        let threads = (0..<configuration.maximumThreads).map { threadIndex in
            AppServerCachedThread(
                id: .init(rawValue: "stress-thread-\(threadIndex)"),
                sessionID: .init(rawValue: "stress-session-\(threadIndex)"),
                title: longTitle,
                workingDirectoryName: "project-\(threadIndex)",
                workingDirectoryPath: "/tmp/projects/project-\(threadIndex)",
                projectRootPath: "/tmp/projects/project-\(threadIndex)",
                source: .appServer,
                parentThreadID: nil,
                forkedFromThreadID: nil,
                status: .idle,
                createdAt: baseDate,
                updatedAt: baseDate.addingTimeInterval(TimeInterval(threadIndex)),
                lastObservedAt: baseDate,
                turns: (0..<configuration.maximumTurnsPerThread).map { turnIndex in
                    AppServerProjectedTurn(
                        id: .init(rawValue: "stress-turn-\(threadIndex)-\(turnIndex)"),
                        status: .completed,
                        startedAt: baseDate,
                        completedAt: baseDate,
                        itemsView: .full,
                        items: (0..<configuration.maximumItemsPerTurn).map { itemIndex in
                            AppServerProjectedItem(input: .init(
                                id: .init(rawValue: "stress-item-\(threadIndex)-\(turnIndex)-\(itemIndex)"),
                                kind: .agentMessage,
                                status: .completed,
                                startedAt: baseDate,
                                completedAt: baseDate
                            ))
                        }
                    )
                }
            )
        }
        let checkpoint = AppServerProjectionCheckpoint(
            savedAt: baseDate,
            connectionSource: .managedDaemon,
            threads: threads
        )
        _ = try store.save(checkpoint)
        let loaded = try store.load()
        let slotSizes = ["checkpoint-a.json", "checkpoint-b.json"].compactMap { name -> Int? in
            let url = store.rootDirectory.appendingPathComponent(name)
            return (try? Data(contentsOf: url).count)
        }
        suite.check(slotSizes.allSatisfy { $0 <= maximumBytes }, "byte-aware persistence never writes beyond its envelope")
        suite.check(loaded != nil, "count-cap stress checkpoint remains restorable after byte trimming")
        suite.check(
            (loaded?.threads.flatMap(\.turns).count ?? 0)
                < configuration.maximumThreads * configuration.maximumTurnsPerThread,
            "oldest durable turn detail is deterministically shed before live monitoring is affected"
        )
        suite.checkEqual(loaded?.threads.first?.id, threads.first?.id, "recent thread rows are retained first")
    }

    private static func testDistinctRootAndLegacyExclusion(
        into suite: inout TestSuite
    ) throws {
        let support = try Phase3TestScaffolding.temporaryApplicationSupport(
            "phase7-legacy-exclusion"
        )
        defer { try? FileManager.default.removeItem(at: support) }

        let appServerStore = try AppServerDomainCheckpointFileStore(
            applicationSupportDirectory: support
        )
        suite.check(
            appServerStore.rootDirectory.path.hasSuffix("/Conn/AppServerDomain/v1"),
            "App Server cache uses the distinct Conn/AppServerDomain/v1 root"
        )
        let initiallyLoadedAppServer = try appServerStore.load()
        suite.check(
            initiallyLoadedAppServer == nil,
            "a new App Server cache starts empty without importing retired hook state"
        )

        var rootInfo = stat()
        var lockInfo = stat()
        suite.check(
            lstat(appServerStore.rootDirectory.path, &rootInfo) == 0
                && (rootInfo.st_mode & 0o777) == 0o700,
            "App Server checkpoint root is current-user private"
        )
        let lock = appServerStore.rootDirectory.appendingPathComponent("checkpoint.lock")
        suite.check(
            lstat(lock.path, &lockInfo) == 0
                && (lockInfo.st_mode & S_IFMT) == S_IFREG
                && lockInfo.st_nlink == 1
                && lockInfo.st_uid == getuid()
                && (lockInfo.st_mode & 0o777) == 0o600,
            "App Server checkpoint lock is a private single-link current-owner file"
        )
    }

    private static func testTwoSlotRecoveryAndBounds(
        into suite: inout TestSuite
    ) throws {
        let support = try Phase3TestScaffolding.temporaryApplicationSupport(
            "phase7-two-slot"
        )
        defer { try? FileManager.default.removeItem(at: support) }
        let store = try AppServerDomainCheckpointFileStore(
            applicationSupportDirectory: support,
            maximumCheckpointBytes: 8 * 1_024
        )
        let first = checkpoint(threadID: "persisted-first", savedAt: baseDate)
        let second = checkpoint(
            threadID: "persisted-second",
            savedAt: baseDate.addingTimeInterval(1)
        )
        suite.checkEqual(try store.save(first), 1, "first App Server checkpoint is generation one")
        suite.checkEqual(try store.save(second), 2, "second App Server checkpoint advances generation")
        suite.checkEqual(try store.loadGeneration(), 2, "load exposes the selected generation")
        suite.checkEqual(try store.load(), second, "newest valid App Server slot round-trips")

        let newest = store.rootDirectory.appendingPathComponent("checkpoint-b.json")
        try Data("corrupt-newest".utf8).write(to: newest)
        guard chmod(newest.path, 0o600) == 0 else {
            throw AppServerDomainCheckpointFileStoreError.fileSystem(
                operation: "chmod-test-corrupt-slot",
                code: errno
            )
        }
        suite.checkEqual(
            try store.load(),
            first,
            "a corrupt newest slot falls back to the older valid generation"
        )

        let oversizeSupport = try Phase3TestScaffolding.temporaryApplicationSupport(
            "phase7-oversized-slot"
        )
        defer { try? FileManager.default.removeItem(at: oversizeSupport) }
        let maximumBytes = 8 * 1_024
        let oversizeStore = try AppServerDomainCheckpointFileStore(
            applicationSupportDirectory: oversizeSupport,
            maximumCheckpointBytes: maximumBytes
        )
        _ = try oversizeStore.save(first)
        _ = try oversizeStore.save(second)
        let oversizedNewest = oversizeStore.rootDirectory.appendingPathComponent(
            "checkpoint-b.json"
        )
        try Data(repeating: 0x61, count: maximumBytes + 1).write(to: oversizedNewest)
        guard chmod(oversizedNewest.path, 0o600) == 0 else {
            throw AppServerDomainCheckpointFileStoreError.fileSystem(
                operation: "chmod-test-oversized-slot",
                code: errno
            )
        }
        suite.checkEqual(
            try oversizeStore.load(),
            first,
            "an oversized newest slot is rejected before allocation and falls back"
        )

        let tinySupport = try Phase3TestScaffolding.temporaryApplicationSupport(
            "phase7-save-bound"
        )
        defer { try? FileManager.default.removeItem(at: tinySupport) }
        let tinyStore = try AppServerDomainCheckpointFileStore(
            applicationSupportDirectory: tinySupport,
            maximumCheckpointBytes: 1
        )
        do {
            _ = try tinyStore.save(first)
            suite.check(false, "one-byte persistence bound rejects an App Server checkpoint")
        } catch let error as AppServerDomainCheckpointFileStoreError {
            suite.checkEqual(
                error,
                .checkpointTooLarge(maximumBytes: 1),
                "App Server save enforces its configured byte bound"
            )
        }

        let fifoSupport = try Phase3TestScaffolding.temporaryApplicationSupport(
            "phase7-fifo-slot"
        )
        defer { try? FileManager.default.removeItem(at: fifoSupport) }
        let fifoStore = try AppServerDomainCheckpointFileStore(
            applicationSupportDirectory: fifoSupport
        )
        let fifo = fifoStore.rootDirectory.appendingPathComponent("checkpoint-a.json")
        guard mkfifo(fifo.path, 0o600) == 0 else {
            throw AppServerDomainCheckpointFileStoreError.fileSystem(
                operation: "mkfifo-test-app-server-slot",
                code: errno
            )
        }
        do {
            _ = try fifoStore.load()
            suite.check(false, "FIFO checkpoint candidates are rejected without blocking")
        } catch let error as AppServerDomainCheckpointFileStoreError {
            suite.checkEqual(
                error,
                .unexpectedFileType(fifo.path),
                "nonblocking slot open reaches file-type validation for a FIFO candidate"
            )
        }
    }

    private static func testCoordinatorRestoreAndRollback(
        into suite: inout TestSuite
    ) async throws {
        let restoreSupport = try Phase3TestScaffolding.temporaryApplicationSupport(
            "phase7-coordinator-restore"
        )
        defer { try? FileManager.default.removeItem(at: restoreSupport) }
        let restoreStore = try AppServerDomainCheckpointFileStore(
            applicationSupportDirectory: restoreSupport
        )
        let durable = checkpoint(threadID: "restore-stale", savedAt: baseDate)
        _ = try restoreStore.save(durable)
        let restoredDomain = AppServerProjectionStore()
        let restoredCoordinator = AppServerDomainCoordinator(
            domain: restoredDomain,
            checkpointStore: restoreStore
        )
        let didRestore = try await restoredCoordinator.restoreCheckpoint()
        suite.check(
            didRestore,
            "coordinator restores the separately discriminated App Server cache"
        )
        let restoredSnapshot = await restoredCoordinator.snapshot(
            at: baseDate.addingTimeInterval(1)
        )
        suite.check(
            restoredSnapshot.connection == nil
                && restoredSnapshot.featureSupport.features.isEmpty
                && restoredSnapshot.threads.first?.freshness == .stale
                && restoredSnapshot.threads.first?.requests.isEmpty == true,
            "coordinator restore is stale and restores no connection, feature, or request authority"
        )

        let rollbackSupport = try Phase3TestScaffolding.temporaryApplicationSupport(
            "phase7-coordinator-rollback"
        )
        defer { try? FileManager.default.removeItem(at: rollbackSupport) }
        let failingStore = try AppServerDomainCheckpointFileStore(
            applicationSupportDirectory: rollbackSupport,
            maximumCheckpointBytes: 1
        )
        let rollbackDomain = AppServerProjectionStore()
        let rollbackCoordinator = AppServerDomainCoordinator(
            domain: rollbackDomain,
            checkpointStore: failingStore
        )
        let degradedResult = try await rollbackCoordinator.applyAndPersist(
            activation(connection),
            checkpointedAt: baseDate
        )
        await rollbackCoordinator.flushPersistence()
        suite.checkEqual(
            degradedResult,
            .applied,
            "a cache write wall does not reject live projection mutation"
        )
        let rolledBack = await rollbackCoordinator.snapshot(at: baseDate)
        suite.check(
            rolledBack.connection == connection
                && rolledBack.threads.isEmpty
                && !rolledBack.featureSupport.features.isEmpty,
            "checkpoint failure preserves live runtime authority and projection state"
        )
        let persistenceDiagnostic = await rollbackCoordinator.persistenceDiagnostic()
        suite.check(
            persistenceDiagnostic != nil,
            "checkpoint failure surfaces a bounded presentation-safe diagnostic"
        )
        let failedLoad = try failingStore.load()
        suite.check(
            failedLoad == nil,
            "checkpoint failure commits no durable App Server generation"
        )
    }

    private static func testPrivacyCanariesStopAtAdapter(
        into suite: inout TestSuite
    ) async throws {
        let promptCanary = "PHASE7_PROMPT_SECRET_CANARY"
        let reasoningCanary = "PHASE7_RAW_REASONING_CANARY"
        let agentOutputCanary = "PHASE8_AGENT_OUTPUT_RUNTIME_CANARY"
        let reasoningSummaryCanary = "PHASE8_REASONING_SUMMARY_RUNTIME_CANARY"
        let commandCanary = "PHASE7_COMMAND_OUTPUT_CANARY"
        let patchCanary = "PHASE7_COMPLETE_PATCH_CANARY"
        let toolCanary = "PHASE7_TOOL_PAYLOAD_CANARY"
        let requestQuestionCanary = "PHASE7_REQUEST_QUESTION_CANARY"
        let canaries = [
            promptCanary,
            reasoningCanary,
            agentOutputCanary,
            reasoningSummaryCanary,
            commandCanary,
            patchCanary,
            toolCanary,
            requestQuestionCanary,
        ]

        let adapter = AppServerObservationAdapter()
        let domain = AppServerProjectionStore()
        _ = await domain.apply(activation(connection))
        _ = await domain.apply(.snapshot(.init(
            cursor: .init(connection: connection, sequence: 0),
            observedAt: baseDate,
            threads: []
        )))
        var sequence: UInt64 = 1
        var privacySafeValues: [String] = []
        let items: [[String: JSONValue]] = [
            [
                "id": .string("privacy-user"),
                "type": .string("userMessage"),
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string(promptCanary),
                ])]),
            ],
            [
                "id": .string("privacy-agent"),
                "type": .string("agentMessage"),
                "text": .string(agentOutputCanary),
            ],
            [
                "id": .string("privacy-reasoning"),
                "type": .string("reasoning"),
                "content": .array([.string(reasoningCanary)]),
                "summary": .array([.string(reasoningSummaryCanary)]),
            ],
            [
                "id": .string("privacy-command"),
                "type": .string("commandExecution"),
                "command": .string("printf private"),
                "commandActions": .array([]),
                "cwd": .string("/tmp"),
                "status": .string("completed"),
                "aggregatedOutput": .string(commandCanary),
            ],
            [
                "id": .string("privacy-patch"),
                "type": .string("fileChange"),
                "changes": .array([.object([
                    "path": .string("Sources/Private.swift"),
                    "kind": .object(["type": .string("update")]),
                    "diff": .string(patchCanary),
                ])]),
                "status": .string("completed"),
            ],
            [
                "id": .string("privacy-tool"),
                "type": .string("mcpToolCall"),
                "arguments": .object(["secret": .string(toolCanary)]),
                "server": .string("test"),
                "tool": .string("test"),
                "status": .string("completed"),
                "result": .object(["secret": .string(toolCanary)]),
            ],
        ]

        for item in items {
            let notification = JSONRPCNotification(
                method: "item/completed",
                params: .object([
                    "threadId": .string("privacy-thread"),
                    "turnId": .string("privacy-turn"),
                    "completedAtMs": .integer(1_800_100_000_000 + Int64(sequence)),
                    "item": .object(item),
                ])
            )
            let input = try adapter.projectionInput(
                from: notification,
                cursor: .init(connection: connection, sequence: sequence),
                observedAt: baseDate.addingTimeInterval(TimeInterval(sequence))
            )
            if let input {
                privacySafeValues.append(String(reflecting: input))
                _ = await domain.apply(input)
            }
            sequence += 1
        }

        let question = JSONRPCRequest(
            id: .string("privacy-request"),
            method: "item/tool/requestUserInput",
            params: .object([
                "threadId": .string("privacy-thread"),
                "turnId": .string("privacy-turn"),
                "itemId": .string("privacy-question"),
                "questions": .array([.object([
                    "id": .string("secret"),
                    "header": .string("Secret"),
                    "question": .string(requestQuestionCanary),
                    "options": .array([.object([
                        "label": .string("Reveal"),
                        "description": .string(requestQuestionCanary),
                    ])]),
                ])]),
            ])
        )
        let requestInput = try adapter.projectionInput(
            from: question,
            cursor: .init(connection: connection, sequence: sequence),
            observedAt: baseDate.addingTimeInterval(TimeInterval(sequence))
        )
        if let requestInput {
            privacySafeValues.append(String(reflecting: requestInput))
            _ = await domain.apply(requestInput)
        }
        let liveSnapshot = await domain.snapshot(at: baseDate.addingTimeInterval(20))
        privacySafeValues.append(String(reflecting: liveSnapshot))
        suite.check(
            liveSnapshot.attentionRequests.count == 1,
            "privacy-safe request identity remains available only at runtime"
        )
        suite.check(
            [reasoningCanary, commandCanary, patchCanary, toolCanary]
                .allSatisfy { canary in
                privacySafeValues.allSatisfy { !$0.contains(canary) }
            },
            "live presentation excludes raw reasoning, output, diffs, and tool payloads"
        )
        suite.check(
            privacySafeValues.contains { $0.contains(promptCanary) }
                && privacySafeValues.contains { $0.contains(agentOutputCanary) }
                && privacySafeValues.contains { $0.contains(reasoningSummaryCanary) }
                && privacySafeValues.contains { $0.contains(requestQuestionCanary) },
            "bounded user, agent, reasoning-summary, and request-question text remains available only to live presentation"
        )

        let checkpoint = await domain.checkpoint(at: baseDate.addingTimeInterval(20))
        suite.check(
            checkpoint.threads.flatMap(\.turns).flatMap(\.items)
                .allSatisfy { $0.presentation == nil },
            "the in-memory checkpoint seam strips every runtime presentation payload"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(checkpoint)
        let encoded = String(decoding: data, as: UTF8.self)
        suite.check(
            canaries.allSatisfy { !encoded.contains($0) },
            "runtime presentation, prompt, raw reasoning, output, patch, tool, and request-question canaries never enter persistence"
        )
        let restored = AppServerProjectionStore()
        try await restored.restore(from: checkpoint)
        let restoredSnapshot = await restored.snapshot(at: baseDate.addingTimeInterval(21))
        suite.check(
            restoredSnapshot.attentionRequests.isEmpty,
            "runtime requests and their private payloads are absent after checkpoint restore"
        )
    }

    private static func testCursorBearingHydrationOrdering(
        into suite: inout TestSuite
    ) async throws {
        let adapter = AppServerObservationAdapter()
        let wireIdentity = ConnAppServerConnectionIdentity(
            instanceID: connection.instanceID,
            generation: connection.generation
        )
        let domain = AppServerProjectionStore()
        _ = await domain.apply(adapter.connectionActivated(
            identity: connection,
            source: .managedDaemon,
            serverVersion: .v0_144_6
        ))

        let olderStatus = JSONRPCNotification(
            method: "thread/status/changed",
            params: .object([
                "threadId": .string("hydrate-thread"),
                "status": activeStatus(),
            ])
        )
        let olderInput = try adapter.projectionInput(
            from: olderStatus,
            cursor: .init(connection: connection, sequence: 2),
            observedAt: baseDate
        )
        if let olderInput { _ = await domain.apply(olderInput) }

        let listResponse = ConnAppServerResponseEnvelope(
            connection: wireIdentity,
            sequence: 3,
            result: .object([
                "data": .array([threadValue(
                    id: "hydrate-thread",
                    status: idleStatus(),
                    turns: []
                )]),
                "nextCursor": .null,
            ])
        )
        _ = await domain.apply(try adapter.threadListSnapshot(
            response: listResponse,
            observedAt: baseDate.addingTimeInterval(1)
        ))

        let newerTurn = JSONRPCNotification(
            method: "turn/started",
            params: .object([
                "threadId": .string("hydrate-thread"),
                "turn": turnValue(id: "hydrate-turn", status: "inProgress"),
            ])
        )
        let newerInput = try adapter.projectionInput(
            from: newerTurn,
            cursor: .init(connection: connection, sequence: 4),
            observedAt: baseDate.addingTimeInterval(2)
        )
        if let newerInput { _ = await domain.apply(newerInput) }

        let hydrated = await domain.snapshot(at: baseDate.addingTimeInterval(2))
        suite.check(
            hydrated.threads.first?.status == .idle
                && hydrated.threads.first?.activeTurnIDs == [.init(rawValue: "hydrate-turn")],
            "list response cursor drops an older status while replaying the newer turn fact"
        )

        let readResponse = ConnAppServerResponseEnvelope(
            connection: wireIdentity,
            sequence: 5,
            result: .object([
                "thread": threadValue(
                    id: "hydrate-thread",
                    status: idleStatus(),
                    turns: []
                ),
            ])
        )
        _ = await domain.apply(try adapter.threadReadDelta(
            response: readResponse,
            observedAt: baseDate.addingTimeInterval(3)
        ))
        let read = await domain.snapshot(at: baseDate.addingTimeInterval(3))
        suite.check(
            read.threads.first?.activeTurnIDs.isEmpty == true,
            "authoritative thread/read removes an older active turn without deleting peer threads"
        )

        let paginated = ConnAppServerResponseEnvelope(
            connection: wireIdentity,
            sequence: 6,
            result: .object(["data": .array([]), "nextCursor": .string("more")])
        )
        do {
            _ = try adapter.threadListSnapshot(response: paginated, observedAt: baseDate)
            suite.check(false, "paginated thread/list cannot claim global snapshot authority")
        } catch let error as AppServerObservationAdapterError {
            suite.checkEqual(
                error,
                .malformed(context: "thread/list result", field: "nextCursor"),
                "paginated hydration fails closed until all inventory is represented atomically"
            )
        }


        let unknown = try adapter.projectionInput(
            from: JSONRPCNotification(method: "future/notification", params: .string("opaque")),
            cursor: .init(connection: connection, sequence: 7),
            observedAt: baseDate
        )
        suite.check(
            unknown == nil,
            "unknown notifications are ignored without decoding arbitrary peer payloads"
        )

        let malformedItemsView = JSONRPCNotification(
            method: "turn/started",
            params: .object([
                "threadId": .string("hydrate-thread"),
                "turn": .object([
                    "id": .string("malformed-turn"),
                    "status": .string("inProgress"),
                    "itemsView": .integer(1),
                    "items": .array([]),
                ]),
            ])
        )
        do {
            _ = try adapter.projectionInput(
                from: malformedItemsView,
                cursor: .init(connection: connection, sequence: 8),
                observedAt: baseDate
            )
            suite.check(false, "present non-string itemsView does not default to full authority")
        } catch let error as AppServerObservationAdapterError {
            suite.checkEqual(
                error,
                .malformed(context: "Turn", field: "itemsView"),
                "malformed itemsView fails closed instead of widening item authority"
            )
        }
    }

    @MainActor
    private static func testAppServerCommitGate(
        into suite: inout TestSuite
    ) async throws {
        let firstSupport = try Phase3TestScaffolding.temporaryApplicationSupport(
            "phase7-commit-first"
        )
        let secondSupport = try Phase3TestScaffolding.temporaryApplicationSupport(
            "phase7-commit-second"
        )
        defer {
            try? FileManager.default.removeItem(at: firstSupport)
            try? FileManager.default.removeItem(at: secondSupport)
        }
        let firstCheckpointStore = try AppServerDomainCheckpointFileStore(
            applicationSupportDirectory: firstSupport
        )
        let firstCoordinator = AppServerDomainCoordinator(
            domain: AppServerProjectionStore(),
            checkpointStore: firstCheckpointStore
        )
        let replacementConnection = AppServerConnectionIdentity(
            instanceID: UUID(uuidString: "71000000-0000-4000-8000-000000000002")!,
            generation: 2
        )
        let replacementCheckpointStore = try AppServerDomainCheckpointFileStore(
            applicationSupportDirectory: secondSupport
        )
        let replacementCoordinator = AppServerDomainCoordinator(
            domain: AppServerProjectionStore(),
            checkpointStore: replacementCheckpointStore
        )
        let staleIdentity = AppServerDomainCommitIdentity(
            connection: connection,
            coordinator: firstCoordinator
        )
        let currentIdentity = AppServerDomainCommitIdentity(
            connection: replacementConnection,
            coordinator: replacementCoordinator
        )
        let harness = Phase7CommitRaceHarness(identity: staleIdentity)
        harness.replace(with: currentIdentity)

        let staleResult = try await AppServerDomainCommitGate.performIfCurrent(
            captured: staleIdentity,
            current: { harness.currentIdentity }
        ) {
            try await firstCoordinator.applyAndPersist(
                activation(connection),
                checkpointedAt: baseDate
            )
        }
        suite.check(
            staleResult == nil,
            "old coordinator and connection authority are rejected before durable commit"
        )
        let staleGeneration = try firstCheckpointStore.loadGeneration()
        suite.check(
            staleGeneration == nil,
            "rejected stale authority writes no checkpoint generation"
        )

        let currentResult = try await AppServerDomainCommitGate.performIfCurrent(
            captured: currentIdentity,
            current: { harness.currentIdentity }
        ) {
            try await replacementCoordinator.applyAndPersist(
                activation(replacementConnection),
                checkpointedAt: baseDate
            )
        }
        suite.check(
            currentResult == .applied,
            "current coordinator and connection authority may commit"
        )
        await replacementCoordinator.flushPersistence()
        suite.checkEqual(
            try replacementCheckpointStore.loadGeneration(),
            1,
            "current authority commits exactly one durable generation"
        )
    }

    private static func checkpoint(
        threadID: String,
        savedAt: Date
    ) -> AppServerProjectionCheckpoint {
        AppServerProjectionCheckpoint(
            savedAt: savedAt,
            connectionSource: .managedDaemon,
            threads: [AppServerCachedThread(
                id: .init(rawValue: threadID),
                sessionID: .init(rawValue: "session-\(threadID)"),
                title: "Phase 7",
                workingDirectoryName: "SideQuest",
                source: .appServer,
                parentThreadID: nil,
                forkedFromThreadID: nil,
                status: .idle,
                createdAt: savedAt,
                updatedAt: savedAt,
                lastObservedAt: savedAt,
                turns: []
            )]
        )
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

    private static func threadValue(
        id: String,
        status: JSONValue,
        turns: [JSONValue]
    ) -> JSONValue {
        .object([
            "id": .string(id),
            "sessionId": .string("session-\(id)"),
            "cliVersion": .string("0.144.6"),
            "cwd": .string("/tmp/SideQuest"),
            "modelProvider": .string("openai"),
            "preview": .string("content deliberately discarded"),
            "source": .string("appServer"),
            "status": status,
            "ephemeral": .bool(false),
            "createdAt": .integer(1_800_100_000),
            "updatedAt": .integer(1_800_100_001),
            "turns": .array(turns),
        ])
    }

    private static func turnValue(id: String, status: String) -> JSONValue {
        .object([
            "id": .string(id),
            "status": .string(status),
            "items": .array([]),
        ])
    }

    private static func idleStatus() -> JSONValue {
        .object(["type": .string("idle")])
    }

    private static func activeStatus() -> JSONValue {
        .object([
            "type": .string("active"),
            "activeFlags": .array([]),
        ])
    }
}

@MainActor
private final class Phase7CommitRaceHarness {
    private(set) var currentIdentity: AppServerDomainCommitIdentity

    init(identity: AppServerDomainCommitIdentity) {
        currentIdentity = identity
    }

    func replace(with identity: AppServerDomainCommitIdentity) {
        currentIdentity = identity
    }
}
