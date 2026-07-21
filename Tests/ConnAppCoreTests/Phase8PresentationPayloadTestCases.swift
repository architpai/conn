import Foundation
import ConnAppCore
import ConnAppServerAdapter
import ConnDomain

enum Phase8PresentationPayloadTestCases {
    private static let baseDate = Date(timeIntervalSince1970: 1_810_000_000)
    private static let connection = AppServerConnectionIdentity(
        instanceID: UUID(uuidString: "80000000-0000-4000-8000-000000000001")!,
        generation: 8
    )
    private static let threadID = AppServerThreadID(rawValue: "phase8-payload-thread")
    private static let turnID = AppServerTurnID(rawValue: "phase8-payload-turn")

    static func run(into suite: inout TestSuite) async throws {
        try testSupportedExtractionAndSensitiveExclusion(into: &suite)
        try testStablePresentationDeltaExtraction(into: &suite)
        try testUTF8LineAndCountBounds(into: &suite)
        try await testDeterministicReplacement(into: &suite)
        await testStreamingPresentationAccumulation(into: &suite)
        testPresentationDeltaCoalescing(into: &suite)
        await testDirectStoreSingleLineValidation(into: &suite)
        try await testMonitoringAggregateRetention(into: &suite)
        await testTurnRetentionKeepsNewestUntimestampedItems(into: &suite)
        await testEqualCursorThreadConflicts(into: &suite)
        try await testCheckpointExclusionAndLegacyDecoding(into: &suite)
    }

    private static func testStablePresentationDeltaExtraction(
        into suite: inout TestSuite
    ) throws {
        let agent = try decodePresentationDelta(
            method: "item/agentMessage/delta",
            extra: ["delta": .string("streamed answer")]
        )
        suite.checkEqual(
            agent,
            .agentText("streamed answer"),
            "stable agent-message deltas cross the adapter as typed presentation text"
        )

        let part = try decodePresentationDelta(
            method: "item/reasoning/summaryPartAdded",
            extra: ["summaryIndex": .integer(1)]
        )
        suite.checkEqual(
            part,
            .reasoningSummaryPartAdded(index: 1),
            "reasoning summary part notifications retain only their bounded index"
        )

        let summary = try decodePresentationDelta(
            method: "item/reasoning/summaryTextDelta",
            extra: [
                "summaryIndex": .integer(1),
                "delta": .string("safe summary"),
            ]
        )
        suite.checkEqual(
            summary,
            .reasoningSummaryText(index: 1, text: "safe summary"),
            "reasoning summary text deltas retain only safe presentation text"
        )
    }

    private static func testSupportedExtractionAndSensitiveExclusion(
        into suite: inout TestSuite
    ) throws {
        let agent = try decodeItem(.object([
            "id": .string("agent"),
            "type": .string("agentMessage"),
            "text": .string("Bounded agent output"),
        ]))
        suite.checkEqual(
            agent.presentation,
            .agentText("Bounded agent output"),
            "agent text becomes a typed runtime presentation payload"
        )

        let finalAnswer = try decodeItem(.object([
            "id": .string("final-agent"),
            "type": .string("agentMessage"),
            "text": .string("Compiled answer"),
            "phase": .string("final_answer"),
        ]))
        suite.checkEqual(
            finalAnswer.presentation,
            .agentFinalText("Compiled answer"),
            "explicit final-answer phase preserves the compiled assistant response"
        )

        let commentary = try decodeItem(.object([
            "id": .string("commentary-agent"),
            "type": .string("agentMessage"),
            "text": .string("Still working"),
            "phase": .string("commentary"),
        ]))
        suite.checkEqual(
            commentary.presentation,
            .agentText("Still working"),
            "commentary remains compatible generic assistant output"
        )

        do {
            _ = try decodeItem(.object([
                "id": .string("malformed-phase-agent"),
                "type": .string("agentMessage"),
                "text": .string("Invalid phase"),
                "phase": .integer(1),
            ]))
            suite.check(false, "non-string assistant phase must be rejected")
        } catch {
            suite.check(true, "non-string assistant phase is isolated as malformed")
        }

        let plan = try decodeItem(.object([
            "id": .string("plan"),
            "type": .string("plan"),
            "text": .string("1. Inspect\n2. Verify"),
        ]))
        suite.checkEqual(
            plan.presentation,
            .planText("1. Inspect\n2. Verify"),
            "plan text becomes a typed runtime presentation payload"
        )

        let reasoning = try decodeItem(.object([
            "id": .string("reasoning"),
            "type": .string("reasoning"),
            "summary": .array([.string("Checked the bounded state")]),
            "content": .array([.string("RAW-REASONING-CANARY")]),
        ]))
        suite.checkEqual(
            reasoning.presentation,
            .reasoningSummary(["Checked the bounded state"]),
            "only reasoning summary parts cross the adapter seam"
        )

        let command = try decodeItem(.object([
            "id": .string("command"),
            "type": .string("commandExecution"),
            "command": .string("swift build"),
            "commandActions": .array([]),
            "cwd": .string("/tmp/project"),
            "status": .string("completed"),
            "aggregatedOutput": .string("COMMAND-OUTPUT-CANARY"),
        ]))
        suite.checkEqual(
            command.presentation,
            .command("swift build"),
            "command presentation retains the command without its output"
        )

        let fileChange = try decodeItem(.object([
            "id": .string("file-change"),
            "type": .string("fileChange"),
            "status": .string("completed"),
            "changes": .array([
                .object([
                    "path": .string("Sources/Feature.swift"),
                    "kind": .object(["type": .string("update")]),
                    "diff": .string("PATCH-DIFF-CANARY"),
                ]),
                .object([
                    "path": .string("Sources/New.swift"),
                    "kind": .object(["type": .string("add")]),
                    "diff": .string("PATCH-DIFF-CANARY-2"),
                ]),
            ]),
        ]))
        suite.checkEqual(
            fileChange.presentation,
            .fileChanges([
                .init(path: "Sources/Feature.swift", kind: .update, additions: 0, deletions: 0),
                .init(path: "Sources/New.swift", kind: .add, additions: 0, deletions: 0),
            ]),
            "file presentation retains bounded paths and typed kinds only"
        )

        let tool = try decodeItem(.object([
            "id": .string("tool"),
            "type": .string("mcpToolCall"),
            "arguments": .object(["secret": .string("TOOL-ARGUMENT-CANARY")]),
            "result": .object(["value": .string("TOOL-RESULT-CANARY")]),
            "server": .string("docs"),
            "status": .string("completed"),
            "tool": .string("search"),
        ]))
        suite.checkEqual(
            tool.presentation,
            .tool(name: "search", server: "docs"),
            "tool presentation retains only the tool and server names"
        )

        let rendered = [reasoning, command, fileChange, tool]
            .compactMap(\.presentation)
            .map(String.init(describing:))
            .joined(separator: "\n")
        for canary in [
            "RAW-REASONING-CANARY",
            "COMMAND-OUTPUT-CANARY",
            "PATCH-DIFF-CANARY",
            "TOOL-ARGUMENT-CANARY",
            "TOOL-RESULT-CANARY",
        ] {
            suite.check(
                !rendered.contains(canary),
                "unsupported sensitive field \(canary) is absent from presentation payloads"
            )
        }
    }

    private static func testUTF8LineAndCountBounds(
        into suite: inout TestSuite
    ) throws {
        let limits = AppServerItemPresentationLimits.standard
        let lineSeparators = ["\r\n", "\r", "\u{2028}", "\u{2029}"]
        let oversizedText = (0..<120).map { ordinal in
            String(repeating: "🛰️", count: 200)
                + lineSeparators[ordinal % lineSeparators.count]
        }.joined()
        let agent = try decodeItem(.object([
            "id": .string("bounded-agent"),
            "type": .string("agentMessage"),
            "text": .string(oversizedText),
        ]))
        guard case let .agentText(agentText) = agent.presentation else {
            suite.check(false, "oversized agent text still produces a typed payload")
            return
        }
        suite.check(
            agentText.utf8.count <= limits.maximumTextUTF8Bytes,
            "agent text obeys the UTF-8 byte bound"
        )
        suite.check(
            lineCount(agentText) <= limits.maximumTextLineCount,
            "agent text obeys the line-count bound"
        )
        suite.check(
            String(data: Data(agentText.utf8), encoding: .utf8) == agentText,
            "UTF-8 truncation never splits a grapheme into invalid text"
        )

        let summary = try decodeItem(.object([
            "id": .string("bounded-summary"),
            "type": .string("reasoning"),
            "summary": .array((0..<40).map {
                .string("summary-\($0)\n" + String(repeating: "界", count: 1_000))
            }),
            "content": .array([.string("RAW-REASONING-BOUND-CANARY")]),
        ]))
        guard case let .reasoningSummary(parts) = summary.presentation else {
            suite.check(false, "oversized reasoning summary still produces a typed payload")
            return
        }
        suite.check(
            parts.count <= limits.maximumReasoningSummaryParts,
            "reasoning summaries obey the part-count bound"
        )
        suite.check(
            parts.reduce(0) { $0 + $1.utf8.count } <= limits.maximumTextUTF8Bytes,
            "reasoning summaries share one aggregate UTF-8 byte budget"
        )
        suite.check(
            parts.reduce(0) { $0 + lineCount($1) } <= limits.maximumTextLineCount,
            "reasoning summaries share one aggregate line budget"
        )

        let changes = (0..<90).map { ordinal in
            JSONValue.object([
                "path": .string(String(repeating: "界", count: 300) + "/\(ordinal)"),
                "kind": .object(["type": .string(ordinal == 0 ? "future" : "update")]),
                "diff": .string("DIFF-\(ordinal)"),
            ])
        }
        let fileChange = try decodeItem(.object([
            "id": .string("bounded-files"),
            "type": .string("fileChange"),
            "status": .string("completed"),
            "changes": .array(changes),
        ]))
        guard case let .fileChanges(files) = fileChange.presentation else {
            suite.check(false, "oversized file changes still produce a typed payload")
            return
        }
        suite.check(
            files.count == limits.maximumFileChanges,
            "file changes are capped at the explicit item count"
        )
        suite.check(
            files.allSatisfy { $0.path.utf8.count <= limits.maximumPathUTF8Bytes },
            "every retained file path obeys the UTF-8 byte bound"
        )
        suite.checkEqual(
            files.first?.kind,
            .unknown,
            "future file-change kinds fail closed to a typed unknown value"
        )

        let tool = try decodeItem(.object([
            "id": .string("bounded-tool"),
            "type": .string("dynamicToolCall"),
            "arguments": .object([:]),
            "status": .string("completed"),
            "tool": .string(String(repeating: "🧰", count: 200)),
        ]))
        guard case let .tool(name, server) = tool.presentation else {
            suite.check(false, "oversized tool name still produces a typed payload")
            return
        }
        suite.check(
            name.utf8.count <= limits.maximumNameUTF8Bytes,
            "tool names obey the UTF-8 byte bound"
        )
        suite.check(server == nil, "non-MCP tools do not invent a server name")
    }

    private static func testDeterministicReplacement(
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
            threads: []
        )))

        let old = itemDelta(
            sequence: 2,
            presentation: .agentText("old authoritative text")
        )
        let replacement = itemDelta(
            sequence: 3,
            presentation: .agentText("replacement authoritative text")
        )
        _ = await store.apply(old)
        _ = await store.apply(replacement)
        _ = await store.apply(old)

        let projected = await store.snapshot(at: at(4))
            .threads.first?.turns.first?.items.first
        suite.checkEqual(
            projected?.presentation,
            .agentText("replacement authoritative text"),
            "the highest-cursor item upsert deterministically replaces presentation content"
        )

        let authoritativeStore = AppServerProjectionStore()
        _ = await authoritativeStore.apply(.connectionActivated(
            identity: connection,
            source: .managedDaemon,
            featureSupport: .init(features: [.monitor])
        ))
        _ = await authoritativeStore.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: at(1),
            threads: []
        )))
        _ = await authoritativeStore.apply(authoritativeThreadDelta(
            sequence: 3,
            presentation: .agentText("newer read")
        ))
        _ = await authoritativeStore.apply(authoritativeThreadDelta(
            sequence: 2,
            presentation: .agentText("older delayed read")
        ))
        let afterDelayedRead = await authoritativeStore.snapshot(at: at(4))
            .threads.first?.turns.first?.items.first
        suite.checkEqual(
            afterDelayedRead?.presentation,
            .agentText("newer read"),
            "an older authoritative thread read cannot overwrite a newer item cursor"
        )

        let leftFirst = AppServerProjectionStore()
        let rightFirst = AppServerProjectionStore()
        for candidate in [leftFirst, rightFirst] {
            _ = await candidate.apply(.connectionActivated(
                identity: connection,
                source: .managedDaemon,
                featureSupport: .init(features: [.monitor])
            ))
            _ = await candidate.apply(.snapshot(.init(
                cursor: cursor(1),
                observedAt: at(1),
                threads: []
            )))
        }
        let left = itemDelta(sequence: 2, presentation: .agentText("left"))
        let right = itemDelta(sequence: 2, presentation: .agentText("right"))
        _ = await leftFirst.apply(left)
        _ = await leftFirst.apply(right)
        _ = await rightFirst.apply(right)
        _ = await rightFirst.apply(left)
        let leftResult = await leftFirst.snapshot(at: at(3))
        let rightResult = await rightFirst.snapshot(at: at(3))
        suite.checkEqual(
            leftResult,
            rightResult,
            "conflicting equal-cursor item facts fail closed independent of arrival order"
        )
        let conflicted = leftResult.threads.first?.turns.first?.items.first
        suite.check(
            conflicted?.kind == .unknown
                && conflicted?.status == .unknown
                && conflicted?.presentation == nil,
            "an equal-cursor item conflict retains no ambiguous presentation content"
        )
    }

    private static func testStreamingPresentationAccumulation(
        into suite: inout TestSuite
    ) async {
        let store = AppServerProjectionStore()
        _ = await store.apply(.connectionActivated(
            identity: connection,
            source: .managedDaemon,
            featureSupport: .init(features: [.monitor])
        ))
        _ = await store.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: at(1),
            threads: []
        )))
        _ = await store.apply(directItemDelta(
            sequence: 2,
            item: .init(
                id: .init(rawValue: "streaming-agent"),
                kind: .agentMessage,
                status: .started
            )
        ))
        _ = await store.apply(presentationDelta(
            sequence: 3,
            itemID: "streaming-agent",
            delta: .agentText("Hello ")
        ))
        _ = await store.apply(presentationDelta(
            sequence: 4,
            itemID: "streaming-agent",
            delta: .agentText("world")
        ))
        _ = await store.apply(presentationDelta(
            sequence: 3,
            itemID: "streaming-agent",
            delta: .agentText(" delayed duplicate")
        ))
        var projected = await store.snapshot(at: at(5))
            .threads.first?.turns.first?.items.first { $0.id.rawValue == "streaming-agent" }
        suite.checkEqual(
            projected?.presentation,
            .agentText("Hello world"),
            "ordered agent-message fragments accumulate while delayed fragments are ignored"
        )

        _ = await store.apply(directItemDelta(
            sequence: 5,
            item: .init(
                id: .init(rawValue: "streaming-agent"),
                kind: .agentMessage,
                status: .completed,
                completedAt: at(5),
                presentation: .agentText("Final authoritative answer")
            )
        ))
        projected = await store.snapshot(at: at(6))
            .threads.first?.turns.first?.items.first { $0.id.rawValue == "streaming-agent" }
        suite.checkEqual(
            projected?.presentation,
            .agentText("Final authoritative answer"),
            "the completed item replaces partial streamed text with authoritative content"
        )

        _ = await store.apply(directItemDelta(
            sequence: 6,
            item: .init(
                id: .init(rawValue: "streaming-final-agent"),
                kind: .agentMessage,
                status: .started,
                presentation: .agentFinalText("Compiled ")
            )
        ))
        _ = await store.apply(presentationDelta(
            sequence: 7,
            itemID: "streaming-final-agent",
            delta: .agentText("answer")
        ))
        let streamedFinal = await store.snapshot(at: at(7))
            .threads.first?.turns.first?.items.first {
                $0.id.rawValue == "streaming-final-agent"
            }
        suite.checkEqual(
            streamedFinal?.presentation,
            .agentFinalText("Compiled answer"),
            "streamed deltas preserve an explicitly final assistant message"
        )

        _ = await store.apply(directItemDelta(
            sequence: 8,
            item: .init(
                id: .init(rawValue: "streaming-reasoning"),
                kind: .reasoning,
                status: .started
            )
        ))
        _ = await store.apply(presentationDelta(
            sequence: 9,
            itemID: "streaming-reasoning",
            delta: .reasoningSummaryPartAdded(index: 0)
        ))
        _ = await store.apply(presentationDelta(
            sequence: 10,
            itemID: "streaming-reasoning",
            delta: .reasoningSummaryText(index: 0, text: "Checked ")
        ))
        _ = await store.apply(presentationDelta(
            sequence: 11,
            itemID: "streaming-reasoning",
            delta: .reasoningSummaryText(index: 0, text: "state")
        ))
        let reasoning = await store.snapshot(at: at(12))
            .threads.first?.turns.first?.items.first { $0.id.rawValue == "streaming-reasoning" }
        suite.checkEqual(
            reasoning?.presentation,
            .reasoningSummary(["Checked state"]),
            "reasoning summary fragments accumulate without projecting raw reasoning"
        )

        let missingStore = AppServerProjectionStore()
        _ = await missingStore.apply(.connectionActivated(
            identity: connection,
            source: .managedDaemon,
            featureSupport: .init(features: [.monitor])
        ))
        _ = await missingStore.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: at(1),
            threads: []
        )))
        let missing = await missingStore.apply(presentationDelta(
            sequence: 2,
            itemID: "missing-item",
            delta: .agentText("must not invent parents")
        ))
        suite.checkEqual(
            missing,
            .appliedPendingSnapshot,
            "a presentation delta without exact parent identity requests authoritative hydration"
        )
        let missingSnapshot = await missingStore.snapshot(at: at(3))
        suite.check(
            missingSnapshot.threads.isEmpty,
            "a missing-parent presentation delta never invents a thread, turn, or item"
        )

        let narrowLimits = AppServerItemPresentationLimits(
            maximumTextLineCount: 3,
            maximumReasoningSummaryParts: 2
        )
        let narrowStore = AppServerProjectionStore(configuration: .init(
            itemPresentationLimits: narrowLimits
        ))
        _ = await narrowStore.apply(.connectionActivated(
            identity: connection,
            source: .managedDaemon,
            featureSupport: .init(features: [.monitor])
        ))
        _ = await narrowStore.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: at(1),
            threads: []
        )))
        _ = await narrowStore.apply(directItemDelta(
            sequence: 2,
            item: .init(
                id: .init(rawValue: "narrow-reasoning"),
                kind: .reasoning,
                status: .started,
                presentation: .reasoningSummary(["one\ntwo\nthree"])
            )
        ))
        let excessPart = await narrowStore.apply(presentationDelta(
            sequence: 3,
            itemID: "narrow-reasoning",
            delta: .reasoningSummaryPartAdded(index: 1)
        ))
        suite.checkEqual(
            excessPart,
            .ignoredInvalidIdentity,
            "a new summary part cannot exceed a line budget already consumed by existing text"
        )
    }

    private static func testPresentationDeltaCoalescing(
        into suite: inout TestSuite
    ) {
        let adapterConnection = ConnAppServerConnectionIdentity(
            instanceID: UUID(uuidString: "80000000-0000-4000-8000-000000000002")!,
            generation: 8
        )
        func envelope(sequence: UInt64, method: String, delta: String? = nil) -> ConnAppServerInboundEnvelope {
            var params: [String: JSONValue] = [
                "threadId": .string(threadID.rawValue),
                "turnId": .string(turnID.rawValue),
                "itemId": .string("streaming-agent"),
            ]
            if let delta { params["delta"] = .string(delta) }
            return .init(
                connection: adapterConnection,
                sequence: sequence,
                message: .notification(.init(method: method, params: .object(params)))
            )
        }

        let coalesced = AppServerPresentationDeltaCoalescer.coalesced([
            envelope(sequence: 1, method: "item/agentMessage/delta", delta: "Hel"),
            envelope(sequence: 2, method: "item/agentMessage/delta", delta: "lo"),
            envelope(sequence: 3, method: "item/completed"),
            envelope(sequence: 4, method: "item/agentMessage/delta", delta: " later"),
        ])
        suite.checkEqual(
            coalesced.count,
            3,
            "only consecutive fragments for the exact same item are coalesced"
        )
        guard case let .notification(first) = coalesced.first?.message,
              case let .object(firstParams)? = first.params,
              case let .string(firstText)? = firstParams["delta"] else {
            suite.check(false, "coalesced delta remains a notification with text")
            return
        }
        suite.check(
            firstText == "Hello" && coalesced.first?.sequence == 2,
            "coalescing preserves concatenated text at the last receive sequence"
        )
        suite.check(
            coalesced.last?.sequence == 4,
            "a lifecycle notification prevents fragments on either side from being merged"
        )

        let sequenceGap = AppServerPresentationDeltaCoalescer.coalesced([
            envelope(sequence: 10, method: "item/agentMessage/delta", delta: "before response"),
            envelope(sequence: 12, method: "item/agentMessage/delta", delta: "after response"),
        ])
        suite.checkEqual(
            sequenceGap.count,
            2,
            "a receive-sequence gap preserves fragments around an omitted correlated response"
        )

        let limits = AppServerProjectionConfiguration.monitoring.itemPresentationLimits
        let oversizedSingle = AppServerPresentationDeltaCoalescer.coalesced(
            [envelope(
                sequence: 1,
                method: "item/agentMessage/delta",
                delta: String(repeating: "界", count: 5_000)
            )],
            presentationLimits: limits
        )
        guard case let .notification(single) = oversizedSingle.first?.message,
              case let .object(singleParams)? = single.params,
              case let .string(singleText)? = singleParams["delta"] else {
            suite.check(false, "standalone bounded delta remains decodable")
            return
        }
        suite.check(
            singleText.utf8.count <= limits.maximumTextUTF8Bytes,
            "a standalone fragment is bounded before it reaches the adapter"
        )
        let oversized = AppServerPresentationDeltaCoalescer.coalesced(
            (1...4).map {
                envelope(
                    sequence: UInt64($0),
                    method: "item/agentMessage/delta",
                    delta: String(repeating: "界", count: 1_000)
                )
            },
            presentationLimits: limits
        )
        guard case let .notification(bounded) = oversized.first?.message,
              case let .object(boundedParams)? = bounded.params,
              case let .string(boundedText)? = boundedParams["delta"] else {
            suite.check(false, "bounded coalesced delta remains decodable")
            return
        }
        suite.check(
            boundedText.utf8.count <= limits.maximumTextUTF8Bytes,
            "pre-adapter coalescing never grows beyond the presentation byte ceiling"
        )
    }

    private static func testDirectStoreSingleLineValidation(
        into suite: inout TestSuite
    ) async {
        let store = AppServerProjectionStore()
        _ = await store.apply(.connectionActivated(
            identity: connection,
            source: .managedDaemon,
            featureSupport: .init(features: [.monitor])
        ))
        _ = await store.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: at(1),
            threads: []
        )))

        let multilinePath = await store.apply(directItemDelta(
            sequence: 2,
            item: .init(
                id: .init(rawValue: "multiline-path"),
                kind: .fileChange,
                status: .completed,
                presentation: .fileChanges([
                    .init(path: "Sources\r\nSecret.swift", kind: .update),
                ])
            )
        ))
        suite.checkEqual(
            multilinePath,
            .ignoredInvalidIdentity,
            "direct domain input rejects a multiline file path presentation"
        )

        let multilineTool = await store.apply(directItemDelta(
            sequence: 3,
            item: .init(
                id: .init(rawValue: "multiline-tool"),
                kind: .mcpToolCall,
                status: .completed,
                presentation: .tool(name: "search\u{2028}hidden", server: "docs")
            )
        ))
        suite.checkEqual(
            multilineTool,
            .ignoredInvalidIdentity,
            "direct domain input rejects Unicode line separators in tool names"
        )
    }

    private static func testMonitoringAggregateRetention(
        into suite: inout TestSuite
    ) async throws {
        let monitoring = AppServerProjectionConfiguration.monitoring
        suite.checkEqual(
            monitoring.maximumAggregatePresentationBytes,
            8 * 1_024 * 1_024,
            "production monitoring has an explicit eight-MiB aggregate presentation ceiling"
        )
        suite.checkEqual(monitoring.maximumTurnsPerThread, 100, "monitoring retains long chat histories")
        suite.checkEqual(monitoring.maximumItemsPerTurn, 300, "monitoring retains large historical turns")
        suite.checkEqual(
            monitoring.itemPresentationLimits.maximumTextUTF8Bytes,
            4 * 1_024,
            "production monitoring uses a smaller per-item text ceiling"
        )

        let limits = AppServerItemPresentationLimits(
            maximumTextUTF8Bytes: 8,
            maximumTextLineCount: 2,
            maximumReasoningSummaryParts: 2,
            maximumFileChanges: 2,
            maximumPathUTF8Bytes: 8,
            maximumNameUTF8Bytes: 8
        )
        let adapter = AppServerObservationAdapter(presentationLimits: limits)
        let decoded = try decodeItem(.object([
            "id": .string("adapter-bound"),
            "type": .string("agentMessage"),
            "text": .string("1234567890123456"),
        ]), adapter: adapter)
        suite.checkEqual(
            decoded.presentation,
            .agentText("12345678"),
            "the adapter applies the exact limits supplied to the monitoring store"
        )

        let store = AppServerProjectionStore(configuration: .init(
            maximumAggregatePresentationBytes: 12,
            itemPresentationLimits: limits
        ))
        _ = await store.apply(.connectionActivated(
            identity: connection,
            source: .managedDaemon,
            featureSupport: .init(features: [.monitor])
        ))
        _ = await store.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: at(1),
            threads: []
        )))
        _ = await store.apply(directItemDelta(
            sequence: 2,
            item: .init(
                id: .init(rawValue: "older-presentation"),
                kind: .agentMessage,
                status: .completed,
                presentation: .agentText("12345678")
            )
        ))
        _ = await store.apply(directItemDelta(
            sequence: 3,
            item: .init(
                id: .init(rawValue: "newer-presentation"),
                kind: .agentMessage,
                status: .completed,
                presentation: .agentText("ABCDEFGH")
            )
        ))

        let metrics = await store.storageMetrics()
        suite.check(
            metrics.presentationByteCount <= 12,
            "aggregate runtime presentation bytes never exceed configuration"
        )
        let items = await store.snapshot(at: at(4)).threads
            .flatMap(\.turns).flatMap(\.items)
        suite.checkEqual(
            items.first { $0.id.rawValue == "newer-presentation" }?.presentation,
            .agentText("ABCDEFGH"),
            "aggregate trimming keeps the newest cursor presentation"
        )
        suite.check(
            items.first { $0.id.rawValue == "older-presentation" }?.presentation == nil,
            "aggregate trimming sheds older content without deleting its item metadata"
        )

        let priorityStore = AppServerProjectionStore(configuration: .init(
            maximumAggregatePresentationBytes: 8,
            itemPresentationLimits: limits
        ))
        _ = await priorityStore.apply(.connectionActivated(
            identity: connection,
            source: .managedDaemon,
            featureSupport: .init(features: [.monitor])
        ))
        _ = await priorityStore.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: at(1),
            threads: []
        )))
        _ = await priorityStore.apply(directItemDelta(
            sequence: 2,
            item: .init(
                id: .init(rawValue: "historical-user-message"),
                kind: .userMessage,
                status: .completed,
                presentation: .userText("CHAT-TXT")
            )
        ))
        _ = await priorityStore.apply(directItemDelta(
            sequence: 3,
            item: .init(
                id: .init(rawValue: "newer-command"),
                kind: .commandExecution,
                status: .completed,
                presentation: .command("COMMAND!")
            )
        ))
        let priorityItems = await priorityStore.snapshot(at: at(4)).threads
            .flatMap(\.turns).flatMap(\.items)
        suite.checkEqual(
            priorityItems.first { $0.id.rawValue == "historical-user-message" }?.presentation,
            .userText("CHAT-TXT"),
            "aggregate trimming prioritizes historical conversation over newer command detail"
        )
        suite.check(
            priorityItems.first { $0.id.rawValue == "newer-command" }?.presentation == nil,
            "lower-priority command detail is shed before conversation text"
        )
    }

    private static func testEqualCursorThreadConflicts(
        into suite: inout TestSuite
    ) async {
        let first = AppServerProjectionStore()
        let second = AppServerProjectionStore()
        for store in [first, second] {
            _ = await store.apply(.connectionActivated(
                identity: connection,
                source: .managedDaemon,
                featureSupport: .init(features: [.monitor])
            ))
            _ = await store.apply(.snapshot(.init(
                cursor: cursor(1),
                observedAt: at(1),
                threads: []
            )))
        }
        let alpha = threadMetadataDelta(
            sequence: 2,
            title: "Alpha",
            source: .cli,
            status: .idle
        )
        let beta = threadMetadataDelta(
            sequence: 2,
            title: "Beta",
            source: .vscode,
            status: .systemError
        )
        _ = await first.apply(alpha)
        _ = await first.apply(beta)
        _ = await second.apply(beta)
        _ = await second.apply(alpha)

        let firstSnapshot = await first.snapshot(at: at(3))
        let secondSnapshot = await second.snapshot(at: at(3))
        suite.checkEqual(
            firstSnapshot,
            secondSnapshot,
            "equal-cursor thread metadata and status conflicts converge across arrival order"
        )
        let conflicted = firstSnapshot.threads.first
        suite.check(
            conflicted?.title == nil
                && conflicted?.workingDirectoryName == nil
                && conflicted?.source == .unknown
                && conflicted?.status == .unknown
                && conflicted?.freshness == .stale,
            "equal-cursor thread conflicts fail closed to stale unknown presentation"
        )

        let statusFirst = AppServerProjectionStore()
        let statusSecond = AppServerProjectionStore()
        for store in [statusFirst, statusSecond] {
            _ = await store.apply(.connectionActivated(
                identity: connection,
                source: .managedDaemon,
                featureSupport: .init(features: [.monitor])
            ))
            _ = await store.apply(.snapshot(.init(
                cursor: cursor(1),
                observedAt: at(1),
                threads: []
            )))
        }
        let idle = threadStatusDelta(sequence: 2, status: .idle)
        let failed = threadStatusDelta(sequence: 2, status: .systemError)
        _ = await statusFirst.apply(idle)
        _ = await statusFirst.apply(failed)
        _ = await statusSecond.apply(failed)
        _ = await statusSecond.apply(idle)
        let statusFirstSnapshot = await statusFirst.snapshot(at: at(3))
        let statusSecondSnapshot = await statusSecond.snapshot(at: at(3))
        suite.checkEqual(
            statusFirstSnapshot,
            statusSecondSnapshot,
            "equal-cursor standalone status notifications converge across arrival order"
        )
        suite.check(
            statusFirstSnapshot.threads.first?.status == .unknown
                && statusFirstSnapshot.threads.first?.freshness == .stale,
            "equal-cursor status conflicts require authoritative rehydration"
        )
    }

    private static func testCheckpointExclusionAndLegacyDecoding(
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
            threads: []
        )))
        _ = await store.apply(itemDelta(
            sequence: 2,
            presentation: .agentFinalText("RUNTIME-PRESENTATION-CANARY")
        ))

        let checkpoint = await store.checkpoint(at: at(3))
        suite.check(
            checkpoint.threads.flatMap(\.turns).flatMap(\.items)
                .allSatisfy { $0.presentation == nil },
            "checkpoint construction strips runtime item presentation"
        )
        let encoded = try JSONEncoder().encode(checkpoint)
        let encodedText = String(decoding: encoded, as: UTF8.self)
        suite.check(
            !encodedText.contains("RUNTIME-PRESENTATION-CANARY")
                && !encodedText.contains("presentation"),
            "checkpoint Codable omits runtime presentation content and its key"
        )

        let decoded = try JSONDecoder().decode(
            AppServerProjectionCheckpoint.self,
            from: encoded
        )
        let restoredStore = AppServerProjectionStore()
        try await restoredStore.restore(from: decoded)
        let restored = await restoredStore.snapshot(at: at(4))
        suite.check(
            restored.threads.flatMap(\.turns).flatMap(\.items)
                .allSatisfy { $0.presentation == nil },
            "restored projected items have no runtime presentation payload"
        )

        let legacyItem = """
        {
          "id": "legacy-item",
          "kind": "agentMessage",
          "status": "completed",
          "startedAt": null,
          "completedAt": null
        }
        """
        let decodedLegacy = try JSONDecoder().decode(
            AppServerProjectedItem.self,
            from: Data(legacyItem.utf8)
        )
        suite.check(
            decodedLegacy.presentation == nil,
            "pre-Phase 8 projected-item JSON remains decodable with nil presentation"
        )
    }

    private static func testTurnRetentionKeepsNewestUntimestampedItems(
        into suite: inout TestSuite
    ) async {
        let store = AppServerProjectionStore(configuration: .init(maximumItemsPerTurn: 100))
        _ = await store.apply(.connectionActivated(
            identity: connection,
            source: .managedDaemon,
            featureSupport: .init(features: [.monitor])
        ))
        let originalItems = (0..<100).map { index in
            AppServerItemInput(
                id: .init(rawValue: "call-\(index)"),
                kind: .commandExecution,
                status: .completed
            )
        }
        _ = await store.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: at(1),
            threads: [.init(
                id: threadID,
                sessionID: .init(rawValue: "retention-session"),
                title: "Retention",
                source: .appServer,
                status: .active([]),
                updatedAt: at(1),
                turnsAreAuthoritative: true,
                turns: [.init(
                    id: turnID,
                    status: .inProgress,
                    items: originalItems
                )]
            )]
        )))
        for (sequence, id, presentation) in [
            (UInt64(2), "item-143", AppServerItemPresentationPayload.agentText("latest commentary")),
            (UInt64(3), "item-145", AppServerItemPresentationPayload.agentFinalText("latest final")),
        ] {
            _ = await store.apply(.delta(.init(
                cursor: cursor(sequence),
                observedAt: at(TimeInterval(sequence)),
                delta: .itemUpsert(
                    threadID: threadID,
                    turnID: turnID,
                    item: .init(
                        id: .init(rawValue: id),
                        kind: .agentMessage,
                        status: .completed,
                        presentation: presentation
                    )
                )
            )))
        }

        let items = await store.snapshot(at: at(4)).threads.first?.turns.first?.items ?? []
        let retainedIDs = Set(items.map(\.id.rawValue))
        suite.checkEqual(items.count, 100, "turn retention remains bounded after dense tool activity")
        suite.check(
            retainedIDs.contains("item-143") && retainedIDs.contains("item-145"),
            "newest untimestamped commentary and final text survive turn trimming"
        )
        suite.check(
            !retainedIDs.contains("call-0") && !retainedIDs.contains("call-1"),
            "oldest authoritative items yield to newer live deltas"
        )
    }

    private static func decodeItem(
        _ item: JSONValue,
        adapter: AppServerObservationAdapter = .init()
    ) throws -> AppServerItemInput {
        let notification = JSONRPCNotification(
            method: "item/completed",
            params: .object([
                "threadId": .string(threadID.rawValue),
                "turnId": .string(turnID.rawValue),
                "item": item,
                "completedAtMs": .integer(1_810_000_001_000),
            ])
        )
        let input = try adapter.projectionInput(
            from: notification,
            cursor: cursor(1),
            observedAt: at(1)
        )
        guard case let .delta(delta) = input,
              case let .itemUpsert(_, _, decoded) = delta.delta
        else {
            throw Phase8PayloadTestError.expectedItemUpsert
        }
        return decoded
    }

    private static func decodePresentationDelta(
        method: String,
        extra: [String: JSONValue]
    ) throws -> AppServerItemPresentationDelta {
        var params: [String: JSONValue] = [
            "threadId": .string(threadID.rawValue),
            "turnId": .string(turnID.rawValue),
            "itemId": .string("streaming-item"),
        ]
        for (key, value) in extra { params[key] = value }
        let input = try AppServerObservationAdapter().projectionInput(
            from: .init(method: method, params: .object(params)),
            cursor: cursor(1),
            observedAt: at(1)
        )
        guard case let .delta(envelope) = input,
              case let .itemPresentationDelta(_, _, _, delta) = envelope.delta else {
            throw Phase8PayloadTestError.expectedPresentationDelta
        }
        return delta
    }

    private static func itemDelta(
        sequence: UInt64,
        presentation: AppServerItemPresentationPayload?
    ) -> AppServerProjectionInput {
        .delta(.init(
            cursor: cursor(sequence),
            observedAt: at(TimeInterval(sequence)),
            delta: .itemUpsert(
                threadID: threadID,
                turnID: turnID,
                item: .init(
                    id: .init(rawValue: "replacement-item"),
                    kind: .agentMessage,
                    status: .completed,
                    completedAt: at(TimeInterval(sequence)),
                    presentation: presentation
                )
            )
        ))
    }

    private static func authoritativeThreadDelta(
        sequence: UInt64,
        presentation: AppServerItemPresentationPayload
    ) -> AppServerProjectionInput {
        .delta(.init(
            cursor: cursor(sequence),
            observedAt: at(TimeInterval(sequence)),
            delta: .threadUpsert(.init(
                id: threadID,
                sessionID: .init(rawValue: "phase8-payload-session"),
                title: "Payload",
                source: .appServer,
                status: .idle,
                updatedAt: at(TimeInterval(sequence)),
                turnsAreAuthoritative: true,
                turns: [.init(
                    id: turnID,
                    status: .completed,
                    completedAt: at(TimeInterval(sequence)),
                    itemsView: .full,
                    items: [.init(
                        id: .init(rawValue: "replacement-item"),
                        kind: .agentMessage,
                        status: .completed,
                        completedAt: at(TimeInterval(sequence)),
                        presentation: presentation
                    )]
                )]
            ))
        ))
    }

    private static func directItemDelta(
        sequence: UInt64,
        item: AppServerItemInput
    ) -> AppServerProjectionInput {
        .delta(.init(
            cursor: cursor(sequence),
            observedAt: at(TimeInterval(sequence)),
            delta: .itemUpsert(
                threadID: threadID,
                turnID: turnID,
                item: item
            )
        ))
    }

    private static func presentationDelta(
        sequence: UInt64,
        itemID: String,
        delta: AppServerItemPresentationDelta
    ) -> AppServerProjectionInput {
        .delta(.init(
            cursor: cursor(sequence),
            observedAt: at(TimeInterval(sequence)),
            delta: .itemPresentationDelta(
                threadID: threadID,
                turnID: turnID,
                itemID: .init(rawValue: itemID),
                delta: delta
            )
        ))
    }

    private static func threadMetadataDelta(
        sequence: UInt64,
        title: String,
        source: AppServerThreadSource,
        status: AppServerThreadStatus
    ) -> AppServerProjectionInput {
        .delta(.init(
            cursor: cursor(sequence),
            observedAt: at(TimeInterval(sequence)),
            delta: .threadUpsert(.init(
                id: threadID,
                sessionID: .init(rawValue: "session-\(title)"),
                title: title,
                workingDirectoryName: title,
                source: source,
                status: status,
                createdAt: at(0),
                updatedAt: at(TimeInterval(sequence))
            ))
        ))
    }

    private static func threadStatusDelta(
        sequence: UInt64,
        status: AppServerThreadStatus
    ) -> AppServerProjectionInput {
        .delta(.init(
            cursor: cursor(sequence),
            observedAt: at(TimeInterval(sequence)),
            delta: .threadStatus(threadID: threadID, status: status)
        ))
    }

    private static func cursor(_ sequence: UInt64) -> AppServerObservationCursor {
        .init(connection: connection, sequence: sequence)
    }

    private static func at(_ seconds: TimeInterval) -> Date {
        baseDate.addingTimeInterval(seconds)
    }

    private static func lineCount(_ value: String) -> Int {
        var count = 1
        var previousWasCarriageReturn = false
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x0A:
                if !previousWasCarriageReturn { count += 1 }
                previousWasCarriageReturn = false
            case 0x0D:
                count += 1
                previousWasCarriageReturn = true
            case 0x85, 0x2028, 0x2029:
                count += 1
                previousWasCarriageReturn = false
            default:
                previousWasCarriageReturn = false
            }
        }
        return count
    }
}

private enum Phase8PayloadTestError: Error {
    case expectedItemUpsert
    case expectedPresentationDelta
}
