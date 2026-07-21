import Foundation
import ConnAppCore
import ConnAppServerAdapter
import ConnDomain

enum Phase87ProjectionPrivacyTestCases {
    private static let baseDate = Date(timeIntervalSince1970: 1_830_000_000)
    private static let connection = AppServerConnectionIdentity(
        instanceID: UUID(uuidString: "87000000-0000-4000-8000-000000000001")!,
        generation: 87
    )
    private static let threadID = AppServerThreadID(rawValue: "phase87-thread")
    private static let turnID = AppServerTurnID(rawValue: "phase87-turn")

    static func run(into suite: inout TestSuite) async throws {
        try tokenUsageMatchesPinnedStableSchema(into: &suite)
        try planAndUserTextAreBounded(into: &suite)
        try fileChangeCountsExcludePatchText(into: &suite)
        try gitBranchExcludesOriginAndSHA(into: &suite)
        try await runtimeFactsStayOutOfCheckpoints(into: &suite)
    }

    private static func fileChangeCountsExcludePatchText(
        into suite: inout TestSuite
    ) throws {
        let item = try decodeItem(
            .object([
                "id": .string("file-counts"),
                "type": .string("fileChange"),
                "status": .string("completed"),
                "changes": .array([.object([
                    "path": .string("Sources/Feature.swift"),
                    "kind": .object(["type": .string("update")]),
                    "diff": .string("""
                    --- a/Sources/Feature.swift
                    +++ b/Sources/Feature.swift
                    -PRIVATE-PATCH-CANARY-old
                    +PRIVATE-PATCH-CANARY-new
                    +another added line
                    +++content beginning with two plus signs
                    ---content beginning with two minus signs
                    """),
                ])]),
            ]),
            adapter: AppServerObservationAdapter()
        )
        guard case let .fileChanges(changes) = item.presentation,
              let change = changes.first else {
            suite.check(false, "file-change presentation produces bounded count metadata")
            return
        }
        suite.checkEqual(change.additions, 3, "unified diff additions include content beginning with two plus signs")
        suite.checkEqual(change.deletions, 2, "unified diff deletions include content beginning with two minus signs")
        suite.check(
            !String(reflecting: item).contains("PRIVATE-PATCH-CANARY"),
            "patch text remains outside runtime presentation"
        )
    }

    private static func tokenUsageMatchesPinnedStableSchema(
        into suite: inout TestSuite
    ) throws {
        let adapter = AppServerObservationAdapter()
        let input = try adapter.projectionInput(
            from: .init(
                method: "thread/tokenUsage/updated",
                params: .object([
                    "threadId": .string(threadID.rawValue),
                    "turnId": .string(turnID.rawValue),
                    "tokenUsage": tokenUsage(
                        lastTotalTokens: 24_000,
                        cumulativeTotalTokens: 398_765,
                        contextWindow: .integer(128_000)
                    ),
                ])
            ),
            cursor: cursor(2),
            observedAt: at(2)
        )
        guard case let .delta(delta) = input,
              case let .threadTokenUsage(decodedThreadID, decodedTurnID, usage) = delta.delta
        else {
            suite.check(false, "stable token-usage notification produces a typed delta")
            return
        }
        suite.checkEqual(decodedThreadID, threadID, "token usage retains exact thread correlation")
        suite.checkEqual(decodedTurnID, turnID, "token usage retains exact turn correlation")
        suite.checkEqual(
            usage.usedTokens,
            24_000,
            "current context usage comes from last.totalTokens, never lifetime-cumulative total.totalTokens"
        )
        suite.checkEqual(usage.contextWindow, 128_000, "nullable modelContextWindow is retained")
        let presentation = AppServerTokenUsagePresentation(
            usedTokens: usage.usedTokens,
            contextWindow: usage.contextWindow
        )
        suite.checkEqual(
            presentation.percentageLabel,
            "19%",
            "the user-facing context percentage reflects current usage rather than lifetime accumulation"
        )
        let mockSpelling = try adapter.projectionInput(
            from: .init(method: "thread/tokenUsageUpdated", params: .object([:])),
            cursor: cursor(2),
            observedAt: at(2)
        )
        suite.check(
            mockSpelling == nil,
            "only pinned thread/tokenUsage/updated is recognized, not the mock shorthand"
        )

        var malformed = tokenUsage(
            lastTotalTokens: 1,
            cumulativeTotalTokens: 2,
            contextWindow: .null
        ).objectValue!
        var last = malformed["last"]!.objectValue!
        last.removeValue(forKey: "cachedInputTokens")
        malformed["last"] = .object(last)
        do {
            _ = try adapter.projectionInput(
                from: .init(
                    method: "thread/tokenUsage/updated",
                    params: .object([
                        "threadId": .string(threadID.rawValue),
                        "turnId": .string(turnID.rawValue),
                        "tokenUsage": .object(malformed),
                    ])
                ),
                cursor: cursor(3),
                observedAt: at(3)
            )
            suite.check(false, "missing required TokenUsageBreakdown fields are rejected")
        } catch let error as AppServerObservationAdapterError {
            suite.checkEqual(
                error,
                .malformed(
                    context: "thread/tokenUsage/updated",
                    field: "tokenUsage.last.cachedInputTokens"
                ),
                "token usage validates the exact pinned breakdown shape"
            )
        }
    }

    private static func planAndUserTextAreBounded(
        into suite: inout TestSuite
    ) throws {
        let limits = AppServerItemPresentationLimits(
            maximumTextUTF8Bytes: 24,
            maximumTextLineCount: 2,
            maximumPlanSteps: 2,
            maximumPlanStepUTF8Bytes: 12
        )
        let adapter = AppServerObservationAdapter(presentationLimits: limits)
        let planInput = try adapter.projectionInput(
            from: .init(
                method: "turn/plan/updated",
                params: .object([
                    "threadId": .string(threadID.rawValue),
                    "turnId": .string(turnID.rawValue),
                    "explanation": .string("PLAN-EXPLANATION-MUST-NOT-CROSS"),
                    "plan": .array([
                        planStep(String(repeating: "界", count: 10), "inProgress"),
                        planStep("Verify\nignored suffix", "pending"),
                        planStep("must be dropped", "completed"),
                    ]),
                ])
            ),
            cursor: cursor(4),
            observedAt: at(4)
        )
        guard case let .delta(delta) = planInput,
              case let .turnPlanUpdated(_, _, plan) = delta.delta
        else {
            suite.check(false, "stable plan notification produces a typed delta")
            return
        }
        suite.checkEqual(plan.steps.count, 2, "plan steps obey the explicit count bound")
        suite.check(
            plan.steps.allSatisfy { $0.step.utf8.count <= 12 && !$0.step.contains("\n") },
            "each plan step obeys its byte and single-line bounds"
        )
        suite.checkEqual(plan.steps.map(\.status), [.inProgress, .pending], "plan statuses retain wire order")
        suite.check(
            !String(reflecting: plan).contains("PLAN-EXPLANATION-MUST-NOT-CROSS"),
            "plan explanation is not retained alongside bounded steps"
        )
        let mockSpelling = try adapter.projectionInput(
            from: .init(method: "turn/planUpdated", params: .object([:])),
            cursor: cursor(4),
            observedAt: at(4)
        )
        suite.check(
            mockSpelling == nil,
            "only pinned turn/plan/updated is recognized, not the mock shorthand"
        )

        let user = try decodeItem(
            .object([
                "id": .string("phase87-user"),
                "type": .string("userMessage"),
                "content": .array([
                    .object(["type": .string("text"), "text": .string("Hello from the user")]),
                    .object(["type": .string("image"), "url": .string("USER-IMAGE-URL-CANARY")]),
                    .object([
                        "type": .string("skill"),
                        "name": .string("USER-SKILL-NAME-CANARY"),
                        "path": .string("USER-SKILL-PATH-CANARY"),
                    ]),
                    .object(["type": .string("text"), "text": .string("second line and suffix")]),
                ]),
            ]),
            adapter: adapter
        )
        guard case let .userText(text) = user.presentation else {
            suite.check(false, "user text produces a typed runtime presentation payload")
            return
        }
        suite.check(
            text.utf8.count <= limits.maximumTextUTF8Bytes && lineCount(text) <= 2,
            "user text uses the same aggregate byte and line bounds as agent text"
        )
        suite.check(
            !String(reflecting: user).contains("USER-IMAGE-URL-CANARY")
                && !String(reflecting: user).contains("USER-SKILL-PATH-CANARY"),
            "non-text user inputs are validated without retaining URLs or paths"
        )
    }

    private static func gitBranchExcludesOriginAndSHA(
        into suite: inout TestSuite
    ) throws {
        let branch = String(repeating: "feature/界", count: 100)
        var thread = threadValue().objectValue!
        thread["gitInfo"] = .object([
            "branch": .string(branch),
            "originUrl": .string("https://credential-canary@example.invalid/private.git"),
            "sha": .string("PRIVATE-SHA-CANARY"),
        ])
        let page = try AppServerObservationAdapter().threadListPage(
            response: .init(
                connection: .init(instanceID: connection.instanceID, generation: connection.generation),
                sequence: 5,
                result: .object(["data": .array([.object(thread)]), "nextCursor": .null])
            ),
            observedAt: at(5)
        )
        let decoded = page.snapshot.threads.first
        suite.check(
            (decoded?.gitBranch?.utf8.count ?? 513) <= 512,
            "Git branch obeys the metadata UTF-8 byte bound"
        )
        let reflected = String(reflecting: decoded)
        suite.check(
            reflected.contains("feature/")
                && !reflected.contains("credential-canary")
                && !reflected.contains("PRIVATE-SHA-CANARY"),
            "only the bounded branch crosses the GitInfo privacy seam"
        )
    }

    private static func runtimeFactsStayOutOfCheckpoints(
        into suite: inout TestSuite
    ) async throws {
        let store = AppServerProjectionStore()
        _ = await store.apply(.connectionActivated(
            identity: connection,
            source: .managedDaemon,
            featureSupport: .init(features: [.monitor])
        ))
        _ = await store.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: at(1),
            threads: [.init(
                id: threadID,
                sessionID: .init(rawValue: "phase87-session"),
                title: "Phase 8.7",
                gitBranch: "RUNTIME-BRANCH-CANARY",
                source: .appServer,
                status: .active([]),
                updatedAt: at(1),
                turnsAreAuthoritative: true,
                turns: [.init(id: turnID, status: .inProgress)]
            )]
        )))
        _ = await store.apply(.delta(.init(
            cursor: cursor(2),
            observedAt: at(2),
            delta: .threadTokenUsage(
                threadID: threadID,
                turnID: turnID,
                usage: .init(usedTokens: 987_654_321, contextWindow: 999_999_937)
            )
        )))
        _ = await store.apply(.delta(.init(
            cursor: cursor(3),
            observedAt: at(3),
            delta: .turnPlanUpdated(
                threadID: threadID,
                turnID: turnID,
                plan: .init(
                    steps: [.init(step: "RUNTIME-PLAN-TEXT-CANARY", status: .inProgress)],
                    updatedAt: at(3)
                )
            )
        )))
        _ = await store.apply(.delta(.init(
            cursor: cursor(4),
            observedAt: at(4),
            delta: .itemUpsert(
                threadID: threadID,
                turnID: turnID,
                item: .init(
                    id: .init(rawValue: "phase87-user-item"),
                    kind: .userMessage,
                    status: .completed,
                    presentation: .userText("RUNTIME-USER-TEXT-CANARY")
                )
            )
        )))

        let live = await store.snapshot(at: at(5)).threads.first
        suite.checkEqual(live?.gitBranch, "RUNTIME-BRANCH-CANARY", "live projection exposes branch")
        suite.checkEqual(live?.tokenUsage?.usedTokens, 987_654_321, "live projection reduces token usage")
        suite.checkEqual(live?.turns.first?.plan?.steps.first?.step, "RUNTIME-PLAN-TEXT-CANARY", "live projection reduces plan steps")
        suite.checkEqual(live?.turns.first?.items.first?.presentation, .userText("RUNTIME-USER-TEXT-CANARY"), "live projection retains bounded user text")

        let encoded = try JSONEncoder().encode(await store.checkpoint(at: at(6)))
        let text = String(decoding: encoded, as: UTF8.self)
        for canary in [
            "RUNTIME-BRANCH-CANARY",
            "987654321",
            "999999937",
            "RUNTIME-PLAN-TEXT-CANARY",
            "RUNTIME-USER-TEXT-CANARY",
        ] {
            suite.check(!text.contains(canary), "checkpoint excludes runtime canary \(canary)")
        }

        let restoredStore = AppServerProjectionStore()
        try await restoredStore.restore(
            from: JSONDecoder().decode(AppServerProjectionCheckpoint.self, from: encoded)
        )
        let restored = await restoredStore.snapshot(at: at(7)).threads.first
        suite.check(
            restored?.gitBranch == nil
                && restored?.tokenUsage == nil
                && restored?.turns.first?.plan == nil
                && restored?.turns.first?.items.first?.presentation == nil,
            "restore cannot reconstruct any Phase 8.7 runtime-only fact"
        )
    }

    private static func decodeItem(
        _ item: JSONValue,
        adapter: AppServerObservationAdapter
    ) throws -> AppServerItemInput {
        let input = try adapter.projectionInput(
            from: .init(
                method: "item/completed",
                params: .object([
                    "threadId": .string(threadID.rawValue),
                    "turnId": .string(turnID.rawValue),
                    "item": item,
                    "completedAtMs": .integer(1_830_000_001_000),
                ])
            ),
            cursor: cursor(1),
            observedAt: at(1)
        )
        guard case let .delta(delta) = input,
              case let .itemUpsert(_, _, decoded) = delta.delta else {
            throw Phase87ProjectionTestError.expectedItem
        }
        return decoded
    }

    private static func tokenUsage(
        lastTotalTokens: Int64,
        cumulativeTotalTokens: Int64,
        contextWindow: JSONValue
    ) -> JSONValue {
        func breakdown(totalTokens: Int64) -> JSONValue { .object([
            "cachedInputTokens": .integer(1),
            "inputTokens": .integer(2),
            "outputTokens": .integer(3),
            "reasoningOutputTokens": .integer(4),
            "totalTokens": .integer(totalTokens),
        ]) }
        return .object([
            "last": breakdown(totalTokens: lastTotalTokens),
            "modelContextWindow": contextWindow,
            "total": breakdown(totalTokens: cumulativeTotalTokens),
        ])
    }

    private static func planStep(_ step: String, _ status: String) -> JSONValue {
        .object(["step": .string(step), "status": .string(status)])
    }

    private static func threadValue() -> JSONValue {
        .object([
            "id": .string(threadID.rawValue),
            "sessionId": .string("phase87-session"),
            "cliVersion": .string("0.144.6"),
            "name": .string("Phase 8.7"),
            "preview": .string("discarded"),
            "cwd": .string("/tmp/phase87"),
            "gitInfo": .null,
            "modelProvider": .string("openai"),
            "source": .string("appServer"),
            "status": .object(["type": .string("idle")]),
            "ephemeral": .bool(false),
            "createdAt": .integer(1_830_000_000),
            "updatedAt": .integer(1_830_000_001),
            "turns": .array([]),
        ])
    }

    private static func cursor(_ sequence: UInt64) -> AppServerObservationCursor {
        .init(connection: connection, sequence: sequence)
    }

    private static func at(_ seconds: TimeInterval) -> Date {
        baseDate.addingTimeInterval(seconds)
    }

    private static func lineCount(_ value: String) -> Int {
        1 + value.filter { $0 == "\n" || $0 == "\r" }.count
    }
}

private enum Phase87ProjectionTestError: Error {
    case expectedItem
}
