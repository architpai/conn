import Foundation
import ConnAppCore
import ConnDomain

enum Phase87PresentationTestCases {
    private static let baseDate = Date(timeIntervalSince1970: 1_821_100_000)
    private static let connection = AppServerConnectionIdentity(
        instanceID: UUID(uuidString: "88700000-0000-4000-8000-000000000001")!,
        generation: 87
    )

    static func run(into suite: inout TestSuite) async {
        let presentation = await fixturePresentation()
        testUrgencyOrderingAndPills(presentation, into: &suite)
        testGroundedThreadPresentation(presentation, into: &suite)
        testTokenPlanAndTranscript(presentation, into: &suite)
        testContextMathAndInertAffordances(into: &suite)
        await testPlanTurnTruth(into: &suite)
        await testSelectiveTimelineMaterialization(into: &suite)
    }

    private static func testSelectiveTimelineMaterialization(into suite: inout TestSuite) async {
        let store = AppServerProjectionStore()
        _ = await store.apply(.connectionActivated(
            identity: connection,
            source: .managedDaemon,
            featureSupport: .init(features: [.monitor])
        ))
        _ = await store.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: at(1),
            threads: [
                thread(
                    "selected-detail",
                    status: .active([]),
                    updatedAt: 20,
                    turn: activeTurn(
                        "selected-turn",
                        item: item(
                            "selected-item",
                            kind: .agentMessage,
                            at: 20,
                            presentation: .agentText("Selected detail")
                        )
                    )
                ),
                thread(
                    "background-metadata",
                    status: .idle,
                    updatedAt: 19,
                    turn: activeTurn(
                        "background-turn",
                        item: item(
                            "background-item",
                            kind: .agentMessage,
                            at: 19,
                            presentation: .agentText("Background detail")
                        )
                    )
                ),
            ]
        )))

        let presentation = AppServerDomainPresentation(
            snapshot: await store.snapshot(at: at(30)),
            runtimeStatus: .init(phase: .connected, detail: "Selective detail"),
            now: at(30),
            detailedThreadIDs: [.init(rawValue: "selected-detail")]
        )
        let byID = Dictionary(uniqueKeysWithValues: presentation.threads.map { ($0.id, $0) })
        suite.check(byID["selected-detail"]?.timeline.isEmpty == false, "selected threads retain their detailed timeline")
        suite.checkEqual(byID["background-metadata"]?.timeline, [], "background rows avoid materializing an unrelated timeline")
        suite.checkEqual(byID["background-metadata"]?.title, "background-metadata", "background rows retain picker metadata")

        let snapshot = await store.snapshot(at: at(300))
        let oldSelectedIDs = AppServerDomainPresentation.detailedThreadIDs(
            snapshot: snapshot,
            selectedThreadID: "background-metadata",
            now: at(300)
        )
        suite.check(
            oldSelectedIDs.contains(.init(rawValue: "background-metadata")),
            "an explicitly selected cached thread remains detailed after the recency window expires"
        )
    }

    private static func testUrgencyOrderingAndPills(
        _ presentation: AppServerDomainPresentation,
        into suite: inout TestSuite
    ) {
        suite.checkEqual(
            presentation.threads.map(\.id),
            [
                "command", "files", "tool", "working", "system-error",
                "turn-failed", "idle", "approval", "input", "not-loaded", "unknown",
            ],
            "flat Threads mode uses authoritative newest-first ordering"
        )
        suite.checkEqual(
            presentation.urgencySortedThreads.map(\.id),
            [
                "approval", "input", "command", "working", "tool", "files",
                "turn-failed", "system-error", "idle", "not-loaded", "unknown",
            ],
            "urgency ordering keeps attention ahead of newer running and terminal threads"
        )
        suite.checkEqual(
            presentation.statusPills.map(\.visualState),
            [.waitingForApproval, .needsInput, .running, .failed, .idle],
            "compact status pills exclude not-loaded and unknown inventory states"
        )
        suite.checkEqual(
            presentation.statusPills.map(\.count),
            [1, 1, 4, 2, 1],
            "compact status pills aggregate only trustworthy loaded states"
        )
        suite.checkEqual(
            presentation.statusPills.first(where: { $0.visualState == .running })?
                .highestPriorityThreadID,
            "command",
            "a dot pill targets the highest-priority thread in its state"
        )
    }

    private static func testGroundedThreadPresentation(
        _ presentation: AppServerDomainPresentation,
        into suite: inout TestSuite
    ) {
        let byID = Dictionary(uniqueKeysWithValues: presentation.threads.map { ($0.id, $0) })
        suite.checkEqual(byID["approval"]?.visualState, .waitingForApproval, "approval activeFlag maps to needs approval")
        suite.checkEqual(byID["input"]?.visualState, .needsInput, "user-input activeFlag maps to needs input")
        suite.checkEqual(byID["command"]?.visualState, .running, "unflagged active status maps to running")
        suite.checkEqual(byID["system-error"]?.visualState, .failed, "systemError maps to failed")
        suite.checkEqual(byID["turn-failed"]?.visualState, .failed, "latest failed turn maps to failed")
        suite.checkEqual(byID["idle"]?.visualState, .idle, "idle status maps to idle")
        suite.checkEqual(byID["not-loaded"]?.visualState, .notLoaded, "notLoaded remains distinct from completion and unknown status")
        suite.checkEqual(byID["unknown"]?.visualState, .unknown, "unknown status remains neutral and explicit")

        suite.checkEqual(byID["approval"]?.headline, "Awaiting approval · Command approval required", "approval headline uses the selected bounded request kind")
        suite.checkEqual(byID["approval"]?.attention?.responseStyle, .approval, "approval request wins the visible card when mixed with older input")
        suite.checkEqual(byID["approval"]?.attentionCount, 2, "all mixed unresolved requests remain represented in the bounded count")
        suite.checkEqual(byID["input"]?.headline, "Awaiting input · Answer required", "input headline uses request kind without retaining question text")
        suite.checkEqual(byID["input"]?.attention?.responseStyle, .input, "structured questions never present approval controls")
        suite.checkEqual(byID["command"]?.headline, "Running a command · swift build", "command headline uses the bounded command fact")
        suite.checkEqual(byID["files"]?.headline, "Changing files · Updated Sources/UI.swift", "file headline uses the bounded file fact")
        suite.checkEqual(byID["tool"]?.headline, "Using a tool · docs · search", "tool headline uses bounded server and tool names")
        suite.checkEqual(byID["working"]?.headline, "Working · Implementing the panel.", "working headline uses latest bounded activity")
        suite.checkEqual(byID["system-error"]?.headline, "System error", "system-error headline stays grounded")
        suite.checkEqual(byID["turn-failed"]?.headline, "Turn failed", "turn-failure headline stays grounded")
        suite.checkEqual(byID["not-loaded"]?.statusLabel, "Not loaded", "cold daemon rows use a precise status label")
        suite.checkEqual(byID["not-loaded"]?.headline, "Not currently loaded by managed daemon", "cold daemon rows explain their status without claiming completion")
        suite.checkEqual(byID["unknown"]?.headline, "Status unavailable", "unknown headline never claims idle")
        suite.check(
            byID["idle"]?.headline.hasPrefix("Idle · last turn finished ") == true,
            "idle headline qualifies the last terminal-turn time"
        )

        suite.checkEqual(byID["command"]?.workingDirectoryLabel, "/workspace/Conn", "header surfaces bounded cwd metadata")
        suite.checkEqual(byID["command"]?.gitBranchLabel, "feat/mock-alignment", "header surfaces bounded branch metadata")
        suite.checkEqual(byID["command"]?.metaLabel, "/workspace/Conn · feat/mock-alignment", "cwd and branch form one bounded meta line")
        suite.check(
            byID.values.allSatisfy { $0.accessibilityLabel.utf8.count <= 1_024 },
            "thread and status accessibility labels remain bounded"
        )
    }

    private static func testTokenPlanAndTranscript(
        _ presentation: AppServerDomainPresentation,
        into suite: inout TestSuite
    ) {
        guard let command = presentation.threads.first(where: { $0.id == "command" }),
              let working = presentation.threads.first(where: { $0.id == "working" })
        else {
            suite.check(false, "token, plan, and transcript fixtures reach presentation")
            return
        }

        suite.checkEqual(command.tokenUsage?.percentage, 80, "context ring rounds the projected usage percentage")
        suite.checkEqual(command.tokenUsage?.ringProgress, 0.8, "context ring exposes a clamped zero-to-one progress value")
        suite.check(command.tokenUsage?.isWarning == true, "context ring turns warning on at the inclusive 80 percent threshold")
        suite.checkEqual(command.tokenUsage?.percentageLabel, "80%", "context ring has bounded visible percentage copy")

        suite.checkEqual(
            command.plan?.steps.map(\.state),
            [.completed, .inProgress, .pending, .unknown],
            "plan card preserves every bounded plan-step state"
        )
        suite.checkEqual(command.plan?.steps.map(\.text), ["Inspect", "Implement", "Verify", "Future"], "plan card preserves bounded step text")
        suite.check(
            command.plan?.steps.allSatisfy { $0.accessibilityLabel.utf8.count <= 1_024 } == true,
            "plan rows expose bounded accessibility labels"
        )

        suite.checkEqual(
            working.timeline.map(\.category),
            [.userMessage, .agentOutput],
            "transcript timeline is chronological from oldest to newest"
        )
        suite.checkEqual(
            working.timeline.first?.detail,
            "Align this presentation.",
            "bounded runtime user text reaches the user-message bubble presentation"
        )
    }

    private static func testContextMathAndInertAffordances(into suite: inout TestSuite) {
        let belowThreshold = AppServerTokenUsagePresentation(
            usedTokens: 79_499,
            contextWindow: 100_000
        )
        suite.checkEqual(belowThreshold.percentage, 79, "context percentage uses deterministic nearest-integer rounding")
        suite.check(!belowThreshold.isWarning, "79 percent remains below the warning threshold")

        let roundingBoundary = AppServerTokenUsagePresentation(
            usedTokens: 79_500,
            contextWindow: 100_000
        )
        suite.checkEqual(roundingBoundary.percentage, 80, "visible context copy rounds independently")
        suite.check(!roundingBoundary.isWarning, "79.5 percent does not cross the actual 80 percent warning threshold")

        let overCapacity = AppServerTokenUsagePresentation(
            usedTokens: 140_000,
            contextWindow: 100_000
        )
        suite.checkEqual(overCapacity.percentage, 100, "context percentage clamps over-capacity facts to 100")
        suite.checkEqual(overCapacity.ringProgress, 1, "context ring progress clamps at one")

        let unavailable = AppServerTokenUsagePresentation(usedTokens: -5, contextWindow: 0)
        suite.checkEqual(unavailable.usedTokens, 0, "negative token values clamp to zero at presentation")
        suite.checkEqual(unavailable.percentage, nil, "invalid context windows do not manufacture a percentage")
        suite.checkEqual(unavailable.accessibilityLabel, "Context usage unavailable", "unknown context gets honest neutral accessibility copy")

        let affordances = ShellPhase9AffordancePolicy()
        suite.check(
            !affordances.isComposerEnabled
                && !affordances.isSendEnabled
                && !affordances.isStopEnabled
                && !affordances.areApprovalResponsesEnabled,
            "Phase 8.7 composer, send, stop, and approval affordances are all inert"
        )
        suite.checkEqual(
            affordances.detail,
            "Thread actions arrive in a later Conn release.",
            "inert controls explain the later-release boundary without claiming an action"
        )
    }

    private static func testPlanTurnTruth(into suite: inout TestSuite) async {
        let completed = AppServerTurnInput(
            id: .init(rawValue: "planned-completed"),
            status: .completed,
            startedAt: at(10),
            completedAt: at(20)
        )
        let activeWithoutPlan = AppServerTurnInput(
            id: .init(rawValue: "active-without-plan"),
            status: .inProgress,
            startedAt: at(30)
        )
        let store = AppServerProjectionStore()
        _ = await store.apply(.connectionActivated(
            identity: connection,
            source: .managedDaemon,
            featureSupport: .init(features: [.monitor])
        ))
        _ = await store.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: at(1),
            threads: [AppServerThreadInput(
                id: .init(rawValue: "plan-truth"),
                sessionID: .init(rawValue: "plan-truth-session"),
                title: "Plan truth",
                status: .active([]),
                updatedAt: at(30),
                turnsAreAuthoritative: true,
                turns: [completed, activeWithoutPlan]
            )]
        )))
        _ = await store.apply(.delta(.init(
            cursor: cursor(2),
            observedAt: at(21),
            delta: .turnPlanUpdated(
                threadID: .init(rawValue: "plan-truth"),
                turnID: completed.id,
                plan: .init(
                    steps: [.init(step: "Old completed work", status: .completed)],
                    updatedAt: at(21)
                )
            )
        )))
        let presentation = AppServerDomainPresentation(
            snapshot: await store.snapshot(at: at(40)),
            runtimeStatus: .init(phase: .connected, detail: "Plan truth"),
            now: at(40)
        )
        suite.checkEqual(
            presentation.threads.first?.plan,
            nil,
            "an active turn without a plan never inherits an older completed plan"
        )

        let historyStore = AppServerProjectionStore()
        _ = await historyStore.apply(.connectionActivated(
            identity: connection,
            source: .managedDaemon,
            featureSupport: .init(features: [.monitor])
        ))
        _ = await historyStore.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: at(1),
            threads: [thread("plan-history", status: .idle, updatedAt: 20, turn: completed)]
        )))
        _ = await historyStore.apply(.delta(.init(
            cursor: cursor(2),
            observedAt: at(21),
            delta: .turnPlanUpdated(
                threadID: .init(rawValue: "plan-history"),
                turnID: completed.id,
                plan: .init(
                    steps: [.init(step: "Completed work", status: .completed)],
                    updatedAt: at(21)
                )
            )
        )))
        let history = AppServerDomainPresentation(
            snapshot: await historyStore.snapshot(at: at(40)),
            runtimeStatus: .init(phase: .connected, detail: "Plan history"),
            now: at(40)
        )
        suite.checkEqual(
            history.threads.first?.plan?.title,
            "Last turn plan",
            "a terminal turn plan is explicitly labeled as historical"
        )
    }

    private static func fixturePresentation() async -> AppServerDomainPresentation {
        let store = AppServerProjectionStore()
        _ = await store.apply(.connectionActivated(
            identity: connection,
            source: .managedDaemon,
            featureSupport: .init(features: [.monitor])
        ))

        let threads = [
            thread("approval", status: .active([.waitingOnApproval]), updatedAt: 8),
            thread("input", status: .active([.waitingOnUserInput]), updatedAt: 7),
            thread(
                "command",
                status: .active([]),
                updatedAt: 98,
                branch: "feat/mock-alignment",
                turn: activeTurn(
                    "command-turn",
                    item: item("command-item", kind: .commandExecution, at: 98, presentation: .command("swift build"))
                )
            ),
            thread(
                "files",
                status: .active([]),
                updatedAt: 97,
                turn: activeTurn(
                    "files-turn",
                    item: item(
                        "files-item",
                        kind: .fileChange,
                        at: 97,
                        presentation: .fileChanges([.init(path: "Sources/UI.swift", kind: .update)])
                    )
                )
            ),
            thread(
                "tool",
                status: .active([]),
                updatedAt: 96,
                turn: activeTurn(
                    "tool-turn",
                    item: item("tool-item", kind: .mcpToolCall, at: 96, presentation: .tool(name: "search", server: "docs"))
                )
            ),
            thread(
                "working",
                status: .active([]),
                updatedAt: 95,
                turn: .init(
                    id: .init(rawValue: "working-turn"),
                    status: .inProgress,
                    startedAt: at(90),
                    items: [
                        item("user-item", kind: .userMessage, status: .completed, at: 90, presentation: .userText("Align this presentation.")),
                        item("agent-item", kind: .agentMessage, at: 95, presentation: .agentText("Implementing the panel.")),
                    ]
                )
            ),
            thread("system-error", status: .systemError, updatedAt: 94),
            thread(
                "turn-failed",
                status: .idle,
                updatedAt: 93,
                turn: .init(
                    id: .init(rawValue: "failed-turn"),
                    status: .failed,
                    startedAt: at(92),
                    completedAt: at(93)
                )
            ),
            thread(
                "idle",
                status: .idle,
                updatedAt: 10,
                turn: .init(
                    id: .init(rawValue: "idle-turn"),
                    status: .completed,
                    startedAt: at(5),
                    completedAt: at(10)
                )
            ),
            thread("not-loaded", status: .notLoaded, updatedAt: 2),
            thread("unknown", status: .unknown, updatedAt: 1),
        ]

        _ = await store.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: at(1),
            threads: threads
        )))

        var sequence: UInt64 = 2
        for thread in threads {
            _ = await store.apply(.delta(.init(
                cursor: cursor(sequence),
                observedAt: at(Double(sequence)),
                delta: .threadStatus(threadID: thread.id, status: thread.status)
            )))
            sequence += 1
        }

        _ = await store.apply(.delta(.init(
            cursor: cursor(sequence),
            observedAt: at(106),
            delta: .requestOpened(.init(
                requestID: .string("approval-input-first"),
                threadID: .init(rawValue: "approval"),
                turnID: nil,
                itemID: nil,
                kind: .structuredQuestion,
                startedAt: at(106)
            ))
        )))
        sequence += 1
        _ = await store.apply(.delta(.init(
            cursor: cursor(sequence),
            observedAt: at(107),
            delta: .requestOpened(.init(
                requestID: .string("approval-decision-second"),
                threadID: .init(rawValue: "approval"),
                turnID: nil,
                itemID: nil,
                kind: .commandApproval,
                startedAt: at(107)
            ))
        )))
        sequence += 1

        _ = await store.apply(.delta(.init(
            cursor: cursor(sequence),
            observedAt: at(109),
            delta: .requestOpened(.init(
                requestID: .string("input-request"),
                threadID: .init(rawValue: "input"),
                turnID: nil,
                itemID: nil,
                kind: .structuredQuestion,
                startedAt: at(109)
            ))
        )))
        sequence += 1

        _ = await store.apply(.delta(.init(
            cursor: cursor(sequence),
            observedAt: at(110),
            delta: .threadTokenUsage(
                threadID: .init(rawValue: "command"),
                turnID: .init(rawValue: "command-turn"),
                usage: .init(usedTokens: 102_400, contextWindow: 128_000)
            )
        )))
        sequence += 1
        _ = await store.apply(.delta(.init(
            cursor: cursor(sequence),
            observedAt: at(111),
            delta: .turnPlanUpdated(
                threadID: .init(rawValue: "command"),
                turnID: .init(rawValue: "command-turn"),
                plan: .init(
                    steps: [
                        .init(step: "Inspect", status: .completed),
                        .init(step: "Implement", status: .inProgress),
                        .init(step: "Verify", status: .pending),
                        .init(step: "Future", status: .unknown),
                    ],
                    updatedAt: at(111)
                )
            )
        )))

        return AppServerDomainPresentation(
            snapshot: await store.snapshot(at: at(120)),
            runtimeStatus: .init(
                phase: .connected,
                detail: "Monitoring presentation fixtures.",
                listedThreadCount: threads.count,
                hydratedThreadCount: threads.count,
                monitoredThreadCount: threads.count
            ),
            now: at(120)
        )
    }

    private static func thread(
        _ id: String,
        status: AppServerThreadStatus,
        updatedAt: TimeInterval,
        branch: String? = nil,
        turn: AppServerTurnInput? = nil
    ) -> AppServerThreadInput {
        AppServerThreadInput(
            id: .init(rawValue: id),
            sessionID: .init(rawValue: "session-\(id)"),
            title: id,
            workingDirectoryName: "Conn",
            workingDirectoryPath: "/workspace/Conn",
            projectRootPath: "/workspace/Conn",
            gitBranch: branch,
            source: .appServer,
            status: status,
            createdAt: at(0),
            updatedAt: at(updatedAt),
            turnsAreAuthoritative: turn != nil,
            turns: turn.map { [$0] } ?? []
        )
    }

    private static func activeTurn(_ id: String, item: AppServerItemInput) -> AppServerTurnInput {
        .init(
            id: .init(rawValue: id),
            status: .inProgress,
            startedAt: item.startedAt,
            items: [item]
        )
    }

    private static func item(
        _ id: String,
        kind: AppServerItemKind,
        status: AppServerItemStatus = .started,
        at seconds: TimeInterval,
        presentation: AppServerItemPresentationPayload
    ) -> AppServerItemInput {
        .init(
            id: .init(rawValue: id),
            kind: kind,
            status: status,
            startedAt: at(seconds),
            presentation: presentation
        )
    }

    private static func cursor(_ sequence: UInt64) -> AppServerObservationCursor {
        .init(connection: connection, sequence: sequence)
    }

    private static func at(_ seconds: TimeInterval) -> Date {
        baseDate.addingTimeInterval(seconds)
    }
}
