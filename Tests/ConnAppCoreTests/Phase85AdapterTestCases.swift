import Foundation
import ConnAppCore
import ConnAppServerAdapter
import ConnDomain

enum Phase85AdapterTestCases {
    private static let observedAt = Date(timeIntervalSince1970: 1_820_000_100)
    private static let wireConnection = ConnAppServerConnectionIdentity(
        instanceID: UUID(uuidString: "85000000-0000-4000-8000-000000000001")!,
        generation: 1
    )

    static func run(into suite: inout TestSuite) async throws {
        let fixture = try loadFixture()
        try await decodesSchemaFaithfulPagesAndItems(fixture, into: &suite)
        try isolatesMalformedThreadListRows(into: &suite)
        try decodesLoadedThreadPagesConservatively(into: &suite)
        try decodesThreadStatusWithoutTouchingTimeline(into: &suite)
        try keepsRecentLongThreadSuffixes(into: &suite)
        try resolvesRepositoryRootWithoutRetainingGitMetadata(into: &suite)
        cachesRepositoryRootProjectionWithBoundedInvalidation(into: &suite)
    }

    private static func isolatesMalformedThreadListRows(
        into suite: inout TestSuite
    ) throws {
        let adapter = AppServerObservationAdapter()
        var malformedKnown = threadValue(id: "malformed-known", turns: []).objectValue!
        malformedKnown.removeValue(forKey: "sessionId")
        let safePage = try adapter.threadListPage(
            response: .init(
                connection: wireConnection,
                sequence: 10,
                result: .object([
                    "data": .array([
                        threadValue(id: "valid-sibling", turns: []),
                        .object(malformedKnown),
                    ]),
                    "nextCursor": .null,
                ])
            ),
            observedAt: observedAt
        )
        suite.checkEqual(
            safePage.snapshot.threads.map(\.id.rawValue),
            ["valid-sibling"],
            "one malformed thread/list row does not discard its valid sibling"
        )
        suite.checkEqual(
            safePage.inventoryThreadIDs.map(\.rawValue).sorted(),
            ["malformed-known", "valid-sibling"],
            "a malformed row with a valid ID remains in safe inventory membership"
        )
        suite.checkEqual(safePage.malformedRowCount, 1, "malformed row diagnostics expose a bounded count")
        suite.check(safePage.inventoryMembershipIsComplete, "known malformed IDs still permit authoritative membership")

        let unsafePage = try adapter.threadListPage(
            response: .init(
                connection: wireConnection,
                sequence: 11,
                result: .object([
                    "data": .array([
                        threadValue(id: "valid-sibling", turns: []),
                        .object(["sessionId": .string("missing-id")]),
                    ]),
                    "nextCursor": .null,
                ])
            ),
            observedAt: observedAt
        )
        suite.checkEqual(unsafePage.snapshot.threads.count, 1, "unidentified malformed rows remain isolated")
        suite.checkEqual(unsafePage.malformedRowCount, 1, "unidentified malformed rows remain count-only diagnostics")
        suite.check(!unsafePage.inventoryMembershipIsComplete, "an unidentified row prevents unsafe authoritative removal")
    }

    private static func decodesLoadedThreadPagesConservatively(
        into suite: inout TestSuite
    ) throws {
        let adapter = AppServerObservationAdapter()
        let page = try adapter.threadLoadedListPage(response: .init(
            connection: wireConnection,
            sequence: 20,
            result: .object([
                "data": .array([.string("thread-beta"), .string("thread-alpha")]),
                "nextCursor": .string("loaded-page-2"),
            ])
        ))
        suite.checkEqual(
            page.threadIDs.map(\.rawValue),
            ["thread-beta", "thread-alpha"],
            "thread/loaded/list preserves the server's ordered thread IDs"
        )
        suite.checkEqual(
            page.nextCursor,
            "loaded-page-2",
            "thread/loaded/list preserves its opaque continuation cursor"
        )

        let terminalPage = try adapter.threadLoadedListPage(response: .init(
            connection: wireConnection,
            sequence: 21,
            result: .object(["data": .array([]), "nextCursor": .null])
        ))
        suite.checkEqual(terminalPage.threadIDs, [], "an empty loaded page is valid")
        suite.checkEqual(terminalPage.nextCursor, nil, "a null loaded cursor terminates pagination")

        let missingCursorPage = try adapter.threadLoadedListPage(response: .init(
            connection: wireConnection,
            sequence: 22,
            result: .object(["data": .array([.string("thread-only")])])
        ))
        suite.checkEqual(missingCursorPage.nextCursor, nil, "an omitted loaded cursor terminates pagination")

        let recoverablePage = try adapter.threadLoadedListPage(response: .init(
            connection: wireConnection,
            sequence: 23,
            result: .object([
                "data": .array([
                    .string("first"), .string("second"), .string("first"),
                    .string("third"), .string("second"),
                ]),
                "nextCursor": .string(""),
            ])
        ))
        suite.checkEqual(
            recoverablePage.threadIDs.map(\.rawValue),
            ["first", "second", "third"],
            "duplicate loaded IDs collapse to their first occurrence without reordering"
        )
        suite.checkEqual(recoverablePage.nextCursor, nil, "an empty loaded cursor terminates pagination")

        let malformedResults: [(JSONValue, String)] = [
            (.array([]), "object"),
            (.object([:]), "data"),
            (.object(["data": .string("thread-alpha")]), "data"),
            (.object(["data": .array([.integer(1)])]), "data"),
            (.object(["data": .array([.string("")])]), "data"),
            (.object(["data": .array([]), "nextCursor": .integer(2)]), "nextCursor"),
        ]
        for (index, malformed) in malformedResults.enumerated() {
            do {
                _ = try adapter.threadLoadedListPage(response: .init(
                    connection: wireConnection,
                    sequence: UInt64(30 + index),
                    result: malformed.0
                ))
                suite.check(false, "malformed loaded page \(index) is rejected")
            } catch let error as AppServerObservationAdapterError {
                suite.checkEqual(
                    error,
                    .malformed(context: "thread/loaded/list result", field: malformed.1),
                    "malformed loaded page \(index) reports its schema field"
                )
            }
        }
    }

    private static func decodesThreadStatusWithoutTouchingTimeline(
        into suite: inout TestSuite
    ) throws {
        let adapter = AppServerObservationAdapter()
        var activeThread = threadValue(id: "status-only", turns: []).objectValue!
        activeThread["status"] = .object([
            "type": .string("active"),
            "activeFlags": .array([.string("waitingOnApproval")]),
        ])
        activeThread["turns"] = .object([
            "privateTimeline": .string("STATUS_ONLY_MUST_NOT_PARSE_THIS"),
        ])
        let input = try adapter.threadStatusDelta(
            response: .init(
                connection: wireConnection,
                sequence: 50,
                result: .object(["thread": .object(activeThread)])
            ),
            expectedThreadID: .init(rawValue: "status-only"),
            observedAt: observedAt
        )
        guard case let .delta(delta) = input,
              case let .threadUpsert(thread) = delta.delta
        else {
            suite.check(false, "status-only response produces one metadata upsert")
            return
        }
        suite.checkEqual(thread.id.rawValue, "status-only", "status-only response retains the correlated ID")
        suite.checkEqual(thread.status, .active([.waitingOnApproval]), "status-only response retains active flags")
        suite.checkEqual(thread.turns, [], "status-only response never materializes timeline content")
        suite.check(!thread.turnsAreAuthoritative, "status-only timeline absence cannot erase selected detail")

        var unloadedThread = activeThread
        unloadedThread["id"] = .string("unloaded")
        unloadedThread["sessionId"] = .string("session-unloaded")
        unloadedThread["status"] = .object(["type": .string("notLoaded")])
        let unloaded = try adapter.threadStatusDelta(
            response: .init(
                connection: wireConnection,
                sequence: 51,
                result: .object(["thread": .object(unloadedThread)])
            ),
            expectedThreadID: .init(rawValue: "unloaded"),
            observedAt: observedAt
        )
        guard case let .delta(unloadedDelta) = unloaded,
              case let .threadUpsert(unloadedInput) = unloadedDelta.delta
        else {
            suite.check(false, "not-loaded status response produces one metadata upsert")
            return
        }
        suite.checkEqual(unloadedInput.status, .notLoaded, "status-only response preserves notLoaded")

        do {
            _ = try adapter.threadStatusDelta(
                response: .init(
                    connection: wireConnection,
                    sequence: 52,
                    result: .object(["thread": .object(activeThread)])
                ),
                expectedThreadID: .init(rawValue: "different-thread"),
                observedAt: observedAt
            )
            suite.check(false, "status-only response cannot qualify a different thread")
        } catch let error as AppServerObservationAdapterError {
            suite.checkEqual(
                error,
                .malformed(context: "thread status result", field: "thread.id"),
                "status-only response validates request/response thread identity"
            )
        }
    }

    private static func decodesSchemaFaithfulPagesAndItems(
        _ fixture: ObservationFixture,
        into suite: inout TestSuite
    ) async throws {
        suite.checkEqual(fixture.codexVersion, "0.144.6", "fixture pins the qualified stable schema")
        let adapter = AppServerObservationAdapter()
        let pages = try fixture.threadListPages.map {
            try adapter.threadListPage(response: response($0), observedAt: observedAt)
        }

        suite.checkEqual(
            pages.map(\.snapshot.threads.count),
            [1, 0, 1],
            "thread/list pages decode through the stable data key, including an empty page"
        )
        suite.checkEqual(
            pages.map(\.nextCursor),
            ["cursor-empty", "cursor-final", nil],
            "an empty page retains its non-null continuation cursor"
        )

        let listedThreads = pages.flatMap(\.snapshot.threads)
        suite.checkEqual(listedThreads.map(\.id.rawValue), ["thread-alpha", "thread-beta"], "all paginated rows survive adapter decoding")
        suite.checkEqual(listedThreads.map(\.title), ["Alpha work", nil], "Thread.name, including null, maps to the title")
        suite.checkEqual(listedThreads.map(\.workingDirectoryName), ["alpha", "beta"], "Thread.cwd derives the directory basename")
        suite.checkEqual(listedThreads.map(\.workingDirectoryPath), ["/tmp/projects/alpha", "/tmp/projects/beta"], "the full cwd remains available for project identity")

        let read = try adapter.threadReadDelta(
            response: response(fixture.threadRead),
            observedAt: observedAt
        )
        guard case let .delta(readDelta) = read,
              case let .threadUpsert(thread) = readDelta.delta,
              let turn = thread.turns.first
        else {
            suite.check(false, "schema-faithful thread/read produces one thread upsert")
            return
        }

        let statuslessKinds: Set<AppServerItemKind> = [
            .userMessage, .hookPrompt, .agentMessage, .plan, .reasoning,
            .subagentActivity, .webSearch, .imageView, .sleep,
            .enteredReviewMode, .exitedReviewMode, .contextCompaction,
        ]
        let statuslessItems = turn.items.filter { statuslessKinds.contains($0.kind) }
        suite.checkEqual(statuslessItems.count, 12, "fixture covers every stable status-less ThreadItem kind")
        suite.check(
            statuslessItems.allSatisfy { $0.status == .completed },
            "status-less history items decode as completed instead of conflicting unknown terminals"
        )
        suite.check(
            turn.items.contains { $0.kind == .subagentActivity && $0.id.rawValue == "item-subagent" },
            "the schema discriminator subAgentActivity maps to the domain kind"
        )
        suite.check(
            turn.items.contains { $0.id.rawValue == "item-command" && $0.status == .completed }
                && turn.items.contains { $0.id.rawValue == "item-dynamic" && $0.status == .failed },
            "status-bearing items retain their genuine embedded lifecycle status"
        )
        let reflected = String(reflecting: thread)
        suite.check(
            !reflected.contains("PHASE85_READ_PREVIEW_MUST_NOT_CROSS_ADAPTER")
                && !reflected.contains("credential-canary"),
            "preview and credential-bearing git metadata never cross the adapter privacy seam"
        )

        let domainIdentity = adapter.connectionIdentity(from: wireConnection)
        let store = AppServerProjectionStore()
        _ = await store.apply(adapter.connectionActivated(
            identity: domainIdentity,
            source: .managedDaemon,
            serverVersion: .v0_144_6
        ))
        _ = await store.apply(.snapshot(.init(
            cursor: pages.last!.snapshot.cursor,
            observedAt: observedAt,
            threads: listedThreads
        )))
        let readApply = await store.apply(read)
        let postReadMetrics = await store.storageMetrics()
        suite.checkEqual(readApply, .applied, "status-less history is accepted as a real hydration apply")
        suite.check(
            !postReadMetrics.requiresSnapshot && postReadMetrics.bufferedDeltaCount == 0,
            "schema-faithful status-less history does not poison the projection into snapshot recovery"
        )
        let snapshot = await store.snapshot(at: observedAt)
        let presentation = AppServerDomainPresentation(
            snapshot: snapshot,
            runtimeStatus: .init(
                phase: .connected,
                detail: "Fixture inventory connected.",
                listedThreadCount: listedThreads.count,
                hydratedThreadCount: listedThreads.count,
                monitoredThreadCount: listedThreads.count
            ),
            now: observedAt
        )
        suite.checkEqual(snapshot.threads.count, listedThreads.count, "N adapter rows produce N projected store rows")
        suite.checkEqual(presentation.threads.count, listedThreads.count, "N listed threads produce N visible presentation rows")
    }

    private static func keepsRecentLongThreadSuffixes(
        into suite: inout TestSuite
    ) throws {
        let adapter = AppServerObservationAdapter(
            maximumTurnsPerThread: 2,
            maximumItemsPerTurn: 3
        )
        let turns = (0..<4).map { turnIndex in
            JSONValue.object([
                "id": .string("turn-\(turnIndex)"),
                "status": .string("completed"),
                "items": .array((0..<5).map { itemIndex in
                    .object([
                        "id": .string("item-\(turnIndex)-\(itemIndex)"),
                        "type": .string("userMessage"),
                        "content": .array([]),
                    ])
                }),
            ])
        }
        let read = try adapter.threadReadDelta(
            response: .init(
                connection: wireConnection,
                sequence: 30,
                result: .object(["thread": threadValue(id: "long-thread", turns: turns)])
            ),
            observedAt: observedAt
        )
        guard case let .delta(delta) = read,
              case let .threadUpsert(thread) = delta.delta
        else {
            suite.check(false, "long thread decodes to a bounded upsert")
            return
        }
        suite.checkEqual(thread.turns.map(\.id.rawValue), ["turn-2", "turn-3"], "long reads keep the most recent turn suffix")
        suite.checkEqual(
            thread.turns.flatMap { $0.items.map(\.id.rawValue) },
            ["item-2-2", "item-2-3", "item-2-4", "item-3-2", "item-3-3", "item-3-4"],
            "every retained turn keeps its most recent item suffix"
        )

        let commandWithoutStatus = JSONValue.object([
            "id": .string("invalid-command"),
            "type": .string("commandExecution"),
            "command": .string("true"),
            "commandActions": .array([]),
            "cwd": .string("/tmp"),
        ])
        let invalidTurn = JSONValue.object([
            "id": .string("invalid-turn"),
            "status": .string("completed"),
            "items": .array([commandWithoutStatus]),
        ])
        do {
            _ = try adapter.threadReadDelta(
                response: .init(
                    connection: wireConnection,
                    sequence: 32,
                    result: .object([
                        "thread": threadValue(id: "invalid-thread", turns: [invalidTurn]),
                    ])
                ),
                observedAt: observedAt
            )
            suite.check(false, "a status-bearing item cannot use the status-less fallback")
        } catch let error as AppServerObservationAdapterError {
            suite.checkEqual(
                error,
                .malformed(context: "ThreadItem", field: "status"),
                "known status-bearing kinds still require their genuine schema status"
            )
        }
    }

    private static func resolvesRepositoryRootWithoutRetainingGitMetadata(
        into suite: inout TestSuite
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "conn-phase85-repository-\(UUID().uuidString)",
            isDirectory: true
        )
        let nested = root.appendingPathComponent("Sources/Feature", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var object = threadValue(id: "repository-thread", turns: []).objectValue!
        object["cwd"] = .string(nested.path)
        object["gitInfo"] = .object([
            "branch": .string("private-branch"),
            "originUrl": .string("https://credential-canary@example.invalid/private.git"),
            "sha": .string("private-sha"),
        ])
        let page = try AppServerObservationAdapter().threadListPage(
            response: .init(
                connection: wireConnection,
                sequence: 31,
                result: .object(["data": .array([.object(object)]), "nextCursor": .null])
            ),
            observedAt: observedAt
        )
        let thread = page.snapshot.threads.first
        suite.checkEqual(thread?.workingDirectoryPath, nested.path, "adapter retains the exact schema cwd")
        suite.checkEqual(thread?.projectRootPath, root.path, "non-null gitInfo enables deterministic .git ancestor discovery")
        suite.checkEqual(thread?.gitBranch, "private-branch", "adapter retains the bounded branch label for presentation")
        let reflected = String(reflecting: thread)
        suite.check(
            !reflected.contains("credential-canary")
                && !reflected.contains("private-sha"),
            "origin URL and SHA are validated but never retained"
        )
    }

    private static func cachesRepositoryRootProjectionWithBoundedInvalidation(
        into suite: inout TestSuite
    ) {
        let probe = GitProjectionProbe(now: observedAt)
        let cache = AppServerGitProjectionCache(
            maximumEntries: 2,
            timeToLive: 10,
            fileExists: { probe.fileExists($0) },
            now: { probe.currentDate() }
        )

        var lastResolvedRoot: String?
        for _ in 0..<1_000 {
            lastResolvedRoot = cache.repositoryRoot(for: "/repo/a")
        }
        suite.checkEqual(lastResolvedRoot, "/repo", "cached Git projection retains the resolved ancestor")
        suite.checkEqual(probe.callCount(), 2, "one thousand same-cwd rows walk the ancestor chain once")

        _ = cache.repositoryRoot(for: "/repo/b")
        _ = cache.repositoryRoot(for: "/repo/c")
        _ = cache.repositoryRoot(for: "/repo/a")
        suite.checkEqual(probe.callCount(), 8, "bounded LRU eviction causes exactly one fresh walk")

        probe.advance(by: 11)
        _ = cache.repositoryRoot(for: "/repo/a")
        suite.checkEqual(probe.callCount(), 10, "TTL expiry invalidates the cached cwd safely")
        cache.invalidateAll()
        _ = cache.repositoryRoot(for: "/repo/a")
        suite.checkEqual(probe.callCount(), 12, "explicit invalidation causes exactly one fresh walk")
    }

    private static func loadFixture() throws -> ObservationFixture {
        let testsRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = testsRoot.appendingPathComponent(
            "Fixtures/AppServer/0.144.6/phase8_5-observation-fixtures.json"
        )
        return try JSONDecoder().decode(
            ObservationFixture.self,
            from: Data(contentsOf: url)
        )
    }

    private static func response(_ fixture: ResponseFixture) -> ConnAppServerResponseEnvelope {
        .init(
            connection: wireConnection,
            sequence: fixture.sequence,
            result: fixture.result
        )
    }

    private static func threadValue(id: String, turns: [JSONValue]) -> JSONValue {
        .object([
            "id": .string(id),
            "sessionId": .string("session-\(id)"),
            "cliVersion": .string("0.144.6"),
            "name": .null,
            "preview": .string("discarded"),
            "cwd": .string("/tmp/projects/fixture"),
            "gitInfo": .null,
            "modelProvider": .string("openai"),
            "source": .string("appServer"),
            "status": .object(["type": .string("idle")]),
            "ephemeral": .bool(false),
            "createdAt": .integer(1_820_000_000),
            "updatedAt": .integer(1_820_000_001),
            "turns": .array(turns),
        ])
    }
}

private final class GitProjectionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Date
    private var calls = 0

    init(now: Date) { self.now = now }

    func fileExists(_ path: String) -> Bool {
        lock.lock()
        calls += 1
        lock.unlock()
        return path == "/repo/.git"
    }

    func currentDate() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return now
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        now = now.addingTimeInterval(interval)
        lock.unlock()
    }

    func callCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private struct ObservationFixture: Decodable {
    let codexVersion: String
    let threadListPages: [ResponseFixture]
    let threadRead: ResponseFixture
}

private struct ResponseFixture: Decodable {
    let sequence: UInt64
    let result: JSONValue
}
