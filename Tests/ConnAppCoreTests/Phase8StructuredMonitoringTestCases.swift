import Foundation
import ConnAppCore
import ConnDomain

enum Phase8StructuredMonitoringTestCases {
    private static let baseDate = Date(timeIntervalSince1970: 1_820_000_000)
    private static let connection = AppServerConnectionIdentity(
        instanceID: UUID(uuidString: "88000000-0000-4000-8000-000000000001")!,
        generation: 8
    )
    private static let threadID = AppServerThreadID(rawValue: "thread-phase8-abcdef12")
    private static let sessionID = AppServerSessionID(rawValue: "session-phase8")
    private static let turnID = AppServerTurnID(rawValue: "turn-phase8-complete")

    static func run(into suite: inout TestSuite) async throws {
        await testManagedDaemonScopeAndHonestDiagnostics(into: &suite)
        await testStructuredThreadAndTimelineMapping(into: &suite)
        await testCompactTitleFreshnessAndPauseGates(into: &suite)
        await testCurrentActiveStatusWinsOverPriorOutcome(into: &suite)
        await testCurrentStatusSurvivesStaleTimelineDetails(into: &suite)
        await testExactThreadNavigationRequiresCapabilityAndAuthority(into: &suite)
        await testUnavailableRuntimeForcesEveryRowStale(into: &suite)
        await testTimelineAccessibilityUsesBoundedVisibleDetail(into: &suite)
        await testTimelineCapPreservesCompiledAnswer(into: &suite)
        await testUntimestampedTimelinePreservesAuthoritativeOrder(into: &suite)
    }

    private static func testManagedDaemonScopeAndHonestDiagnostics(
        into suite: inout TestSuite
    ) async {
        let snapshot = await emptySnapshot(featureSupport: [.monitor])
        let connectedStatus = AppServerRuntimeStatus(
            phase: .connected,
            detail: "Hydrated 1 of 3 listed threads for this connection.",
            cliVersion: "0.144.6",
            appServerVersion: "0.144.6",
            listedThreadCount: 3,
            hydratedThreadCount: 1,
            monitoredThreadCount: 1
        )
        let connected = AppServerDomainPresentation(
            snapshot: snapshot,
            runtimeStatus: connectedStatus,
            now: at(1)
        ).connection

        suite.checkEqual(
            connected.title,
            "Managed daemon connected",
            "connected presentation names the Codex-managed daemon boundary"
        )
        suite.checkEqual(
            connected.sourceLabel,
            "Managed Daemon",
            "connected presentation preserves the observed connection source"
        )
        suite.checkEqual(
            connected.capabilityModeLabel,
            "Stable API",
            "connected presentation reports the qualified capability mode"
        )
        suite.checkEqual(
            connected.scopeLabel,
            "Threads connected through this managed daemon",
            "scope copy is limited to threads visible through this connection"
        )
        suite.checkEqual(
            connected.coverageLabel,
            "1 of 3 connected threads monitored",
            "partial subscription evidence is qualified separately from the stable scope label"
        )
        suite.check(
            !connected.scopeLabel.lowercased().contains("all local"),
            "scope copy never promises all local Codex sessions"
        )
        suite.checkEqual(
            connected.versionLabel,
            "Codex CLI 0.144.6 · App Server 0.144.6",
            "diagnostics retain only qualified CLI and App Server versions"
        )
        suite.check(
            connected.isAuthoritative && !connected.showsDiagnostic,
            "a connected runtime is authoritative without an error diagnostic"
        )

        let unavailableCases: [(
            phase: AppServerRuntimePhase,
            detail: String,
            title: String,
            status: String,
            tone: AppServerPresentationTone
        )] = [
            (
                .reconnecting,
                "Last-known rows are not current while Conn reconnects.",
                "Reconnecting to managed daemon",
                "Reconnecting",
                .warning
            ),
            (
                .incompatible,
                "The discovered App Server schema is unsupported.",
                "App Server version incompatible",
                "Incompatible",
                .unavailable
            ),
            (
                .unsafe,
                "The discovered control endpoint failed ownership validation.",
                "Control endpoint refused",
                "Unsafe endpoint",
                .unavailable
            ),
            (
                .unavailable,
                "The managed daemon could not be reached.",
                "Managed daemon unavailable",
                "Unavailable",
                .unavailable
            ),
        ]

        for value in unavailableCases {
            let status = AppServerRuntimeStatus(
                phase: value.phase,
                detail: value.detail,
                attempt: value.phase == .reconnecting ? 2 : nil
            )
            let connection = AppServerDomainPresentation(
                snapshot: snapshot,
                runtimeStatus: status,
                now: at(2)
            ).connection
            suite.checkEqual(
                connection.title,
                value.title,
                "\(value.phase.rawValue) diagnostic has specific bounded title copy"
            )
            suite.checkEqual(
                connection.statusLabel,
                value.status,
                "\(value.phase.rawValue) diagnostic has an honest status label"
            )
            suite.checkEqual(
                connection.detail,
                value.detail,
                "\(value.phase.rawValue) diagnostic preserves its safe cause detail"
            )
            suite.checkEqual(
                connection.tone,
                value.tone,
                "\(value.phase.rawValue) diagnostic uses a non-success tone"
            )
            suite.check(
                connection.showsDiagnostic && !connection.isAuthoritative,
                "\(value.phase.rawValue) never presents cached rows as current"
            )
        }
    }

    private static func testStructuredThreadAndTimelineMapping(
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
            observedAt: at(10),
            threads: [richThread()]
        )))
        _ = await store.apply(.delta(.init(
            cursor: cursor(2),
            observedAt: at(20),
            delta: .requestOpened(.init(
                requestID: .string("question-8"),
                threadID: threadID,
                turnID: turnID,
                itemID: AppServerItemID(rawValue: "item-agent"),
                kind: .structuredQuestion,
                startedAt: at(20)
            ))
        )))

        let domain = AppServerDomainPresentation(
            snapshot: await store.snapshot(at: at(25)),
            runtimeStatus: .init(
                phase: .connected,
                detail: "Monitoring the hydrated managed-daemon projection.",
                hydratedThreadCount: 1,
                monitoredThreadCount: 1
            ),
            now: at(25)
        )
        guard let thread = domain.threads.first else {
            suite.check(false, "rich App Server thread reaches presentation")
            return
        }

        suite.checkEqual(thread.id, threadID.rawValue, "thread identity round-trips exactly")
        suite.checkEqual(thread.title, "Phase 8 thread", "thread title is trimmed and preferred")
        suite.checkEqual(thread.identifierLabel, "Thread abcdef12", "thread row exposes a bounded stable suffix")
        suite.checkEqual(thread.sourceLabel, "Codex CLI", "thread source comes from typed App Server provenance")
        suite.checkEqual(thread.freshness, .live, "current request delivery marks the thread live")
        suite.checkEqual(thread.freshnessLabel, "Live", "live freshness receives explicit copy")
        suite.check(
            thread.freshnessDetail.contains("current App Server connection"),
            "live freshness explains the authority source"
        )
        suite.checkEqual(thread.activity, .waitingForInput, "structured request maps to waiting-for-input activity")
        suite.checkEqual(thread.activityLabel, "Waiting for input", "activity receives bounded UI copy")
        suite.checkEqual(thread.lastObservedLabel, "Observed just now", "fixed clock produces deterministic recency copy")
        suite.checkEqual(thread.attention?.id, "string:question-8", "string request identity stays type-qualified")
        suite.checkEqual(thread.attention?.title, "Answer required", "structured question maps to attention copy")
        suite.checkEqual(thread.attention?.kindLabel, "Question", "request kind remains visible")
        suite.checkEqual(thread.attentionCount, 1, "thread attention count reflects unresolved requests")
        suite.checkEqual(thread.outcomeLabel, "Turn completed", "structured terminal turn maps to its outcome")
        suite.checkEqual(thread.rowPriority, .attention, "unresolved structured requests pin the thread row")
        suite.checkEqual(thread.tone, .attention, "unresolved structured requests use attention tone")
        suite.check(thread.isActive, "a current unresolved request keeps its thread active")
        suite.check(!thread.supportsExactThreadNavigation, "monitor capability alone exposes no exact-thread action")
        suite.checkEqual(domain.activeCount, 1, "only current active threads contribute to the compact count")
        suite.checkEqual(domain.attentionCount, 1, "only current unresolved requests contribute to attention count")
        suite.checkEqual(domain.compactActivityTitle, "Waiting for input", "compact copy comes from authoritative structured activity")
        suite.checkEqual(
            domain.genericOpenCodexDetail,
            "Opens Codex, but cannot target the selected thread.",
            "generic Open Codex copy does not imply exact-thread navigation"
        )

        let byCategory = Dictionary(
            uniqueKeysWithValues: thread.timeline.map { ($0.category, $0) }
        )
        suite.checkEqual(byCategory[.agentOutput]?.title, "Agent output", "agent output item maps to timeline category")
        suite.checkEqual(byCategory[.agentOutput]?.detail, "Implemented the bounded monitor.", "agent output displays bounded payload")
        suite.checkEqual(byCategory[.finalAnswer]?.title, "Answer", "compiled assistant response receives the final-answer category")
        suite.checkEqual(byCategory[.finalAnswer]?.detail, "The monitor is ready.", "compiled assistant response remains visible")
        suite.checkEqual(byCategory[.reasoning]?.title, "Reasoning summary", "reasoning item is explicitly a summary")
        suite.checkEqual(byCategory[.reasoning]?.detail, "Checked source evidence.\nVerified freshness.", "reasoning summaries map without raw reasoning")
        suite.checkEqual(byCategory[.command]?.detail, "swift test", "command item maps without command output")
        suite.checkEqual(byCategory[.fileChange]?.title, "2 file changes", "patch metadata maps to bounded file-change count")
        suite.checkEqual(
            byCategory[.fileChange]?.detail,
            "Updated Sources/Monitor.swift\nAdded Tests/MonitorTests.swift",
            "file changes show bounded paths and typed verbs"
        )
        suite.checkEqual(byCategory[.plan]?.detail, "1. Map\n2. Verify", "plan item maps to structured plan copy")
        suite.checkEqual(byCategory[.tool]?.detail, "docs · search", "tool item exposes only safe server and tool names")
        suite.checkEqual(byCategory[.outcome]?.statusLabel, "Turn completed", "outcome timeline row derives from structured turn status")
        suite.check(
            thread.timeline.allSatisfy { !$0.observedLabel.isEmpty },
            "every structured timeline row receives deterministic recency copy"
        )
    }

    private static func testCompactTitleFreshnessAndPauseGates(
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
            observedAt: at(30),
            threads: [workingThread()]
        )))
        let rehydratedSnapshot = await store.snapshot(at: at(31))
        let hydrating = AppServerRuntimeStatus(
            phase: .hydrating,
            detail: "Hydrating connected threads."
        )
        let rehydrated = AppServerDomainPresentation(
            snapshot: rehydratedSnapshot,
            runtimeStatus: hydrating,
            now: at(31)
        )
        suite.checkEqual(rehydrated.threads.first?.freshness, .rehydrated, "snapshot rows are visibly rehydrated")
        suite.check(
            rehydrated.compactActivityTitle == nil,
            "rehydrated activity cannot leak into live-sounding compact title"
        )

        _ = await store.apply(.delta(.init(
            cursor: cursor(2),
            observedAt: at(32),
            delta: .threadStatus(threadID: threadID, status: .active([]))
        )))
        let liveSnapshot = await store.snapshot(at: at(33))
        let connected = AppServerRuntimeStatus(
            phase: .connected,
            detail: "Current managed-daemon subscription is active."
        )
        let live = AppServerDomainPresentation(
            snapshot: liveSnapshot,
            runtimeStatus: connected,
            now: at(33)
        )
        suite.checkEqual(live.threads.first?.freshness, .live, "current delta marks the row live")
        suite.checkEqual(live.compactActivityTitle, "Running a command", "live authoritative activity reaches compact title")

        let paused = AppServerDomainPresentation(
            snapshot: liveSnapshot,
            runtimeStatus: connected,
            now: at(33),
            isPresentationPaused: true
        )
        suite.check(paused.isPresentationPaused, "paused presentation state remains explicit")
        suite.check(
            paused.compactActivityTitle == nil,
            "paused monitoring gates compact activity even when domain evidence is live"
        )

        let reconnecting = AppServerDomainPresentation(
            snapshot: liveSnapshot,
            runtimeStatus: .init(
                phase: .reconnecting,
                detail: "Current authority was lost; retrying."
            ),
            now: at(34)
        )
        suite.check(
            reconnecting.compactActivityTitle == nil
                && reconnecting.activeCount == 0
                && reconnecting.attentionCount == 0,
            "a reconnecting runtime gates live-sounding compact state and counts"
        )

        _ = await store.apply(.connectionLost(connection))
        let stale = AppServerDomainPresentation(
            snapshot: await store.snapshot(at: at(35)),
            runtimeStatus: connected,
            now: at(35)
        )
        suite.checkEqual(stale.threads.first?.freshness, .stale, "lost connection qualifies cached row as stale")
        suite.check(
            stale.compactActivityTitle == nil,
            "stale cached activity cannot become compact title even with inconsistent runtime input"
        )
    }

    private static func testCurrentActiveStatusWinsOverPriorOutcome(
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
            observedAt: at(65),
            threads: [.init(
                id: threadID,
                sessionID: sessionID,
                title: "Active after an earlier completion",
                status: .active([]),
                updatedAt: at(65),
                turnsAreAuthoritative: true,
                turns: [.init(id: turnID, status: .completed, completedAt: at(64))]
            )],
            threadFreshness: .live
        )))

        let presentation = AppServerDomainPresentation(
            snapshot: await store.snapshot(at: at(66)),
            runtimeStatus: .init(phase: .connected, detail: "Connected."),
            now: at(66)
        )
        suite.check(
            presentation.threads.first?.visualState == .running
                && presentation.activeCount == 1,
            "current active status outranks an unreviewed outcome from an earlier turn"
        )
    }

    private static func testCurrentStatusSurvivesStaleTimelineDetails(
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
            observedAt: at(70),
            threads: [.init(
                id: threadID,
                sessionID: sessionID,
                title: "Current status with stale details",
                status: .idle,
                updatedAt: at(70),
                turnsAreAuthoritative: true,
                turns: [.init(id: turnID, status: .completed, completedAt: at(70))]
            )]
        )))
        _ = await store.apply(.delta(.init(
            cursor: cursor(2),
            observedAt: at(71),
            delta: .turnUpsert(
                threadID: threadID,
                turn: .init(id: turnID, status: .failed, completedAt: at(71))
            )
        )))
        _ = await store.apply(.snapshot(.init(
            cursor: cursor(3),
            observedAt: at(72),
            threads: [.init(
                id: threadID,
                sessionID: sessionID,
                title: "Current status with stale details",
                status: .active([]),
                updatedAt: at(72)
            )],
            threadFreshness: .live,
            contentAuthority: .metadataOnly
        )))

        let snapshot = await store.snapshot(at: at(73))
        let projected = snapshot.threads.first
        suite.check(
            projected?.status == .active([])
                && projected?.statusFreshness == .live
                && projected?.freshness == .stale,
            "current metadata status remains authoritative while conflicted timeline details stay stale"
        )

        let presentation = AppServerDomainPresentation(
            snapshot: snapshot,
            runtimeStatus: .init(phase: .connected, detail: "Connected."),
            now: at(73)
        )
        suite.check(
            presentation.threads.first?.visualState == .running
                && presentation.threads.first?.freshness == .stale
                && presentation.threads.first?.freshnessLabel == "Stale",
            "the row presents current running status without overstating stale detail authority"
        )
        suite.check(
            presentation.activeCount == 1
                && presentation.compactActivityTitle == "Running",
            "current active metadata contributes to the compact active state"
        )
    }

    private static func testExactThreadNavigationRequiresCapabilityAndAuthority(
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
            observedAt: at(40),
            threads: [workingThread()]
        )))
        _ = await store.apply(.delta(.init(
            cursor: cursor(2),
            observedAt: at(41),
            delta: .threadStatus(threadID: threadID, status: .active([]))
        )))
        let monitorOnlySnapshot = await store.snapshot(at: at(42))
        let connected = AppServerRuntimeStatus(
            phase: .connected,
            detail: "Connected through supported stable APIs."
        )
        let monitorOnly = AppServerDomainPresentation(
            snapshot: monitorOnlySnapshot,
            runtimeStatus: connected,
            now: at(42)
        )
        suite.check(
            monitorOnly.threads.first?.supportsExactThreadNavigation == false,
            "exact-thread action is absent when openInCodex was not qualified"
        )

        _ = await store.apply(.connectionActivated(
            identity: connection,
            source: .managedDaemon,
            featureSupport: .init(features: [.monitor, .openInCodex])
        ))
        let capableSnapshot = await store.snapshot(at: at(43))
        let capable = AppServerDomainPresentation(
            snapshot: capableSnapshot,
            runtimeStatus: connected,
            now: at(43)
        )
        suite.check(
            capable.threads.first?.supportsExactThreadNavigation == false,
            "an enum flag alone cannot expose exact-thread navigation without a reviewed public action"
        )

        let authorityLost = AppServerDomainPresentation(
            snapshot: capableSnapshot,
            runtimeStatus: .init(
                phase: .reconnecting,
                detail: "Exact-thread authority is unavailable while reconnecting."
            ),
            now: at(44)
        )
        suite.check(
            authorityLost.threads.first?.supportsExactThreadNavigation == false,
            "openInCodex capability cannot outlive current connection authority"
        )
    }

    private static func testUnavailableRuntimeForcesEveryRowStale(
        into suite: inout TestSuite
    ) async {
        let secondThreadID = AppServerThreadID(rawValue: "thread-phase8-second")
        let store = AppServerProjectionStore()
        _ = await store.apply(.connectionActivated(
            identity: connection,
            source: .managedDaemon,
            featureSupport: .init(features: [.monitor])
        ))
        _ = await store.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: at(50),
            threads: [
                workingThread(),
                .init(
                    id: secondThreadID,
                    sessionID: .init(rawValue: "session-phase8-second"),
                    title: "Second connected thread",
                    status: .active([]),
                    updatedAt: at(50),
                    turns: []
                ),
            ]
        )))
        _ = await store.apply(.delta(.init(
            cursor: cursor(2),
            observedAt: at(51),
            delta: .threadStatus(threadID: threadID, status: .active([]))
        )))
        _ = await store.apply(.delta(.init(
            cursor: cursor(3),
            observedAt: at(52),
            delta: .threadStatus(threadID: secondThreadID, status: .active([]))
        )))
        _ = await store.apply(.delta(.init(
            cursor: cursor(4),
            observedAt: at(53),
            delta: .requestOpened(.init(
                requestID: .string("must-become-stale"),
                threadID: threadID,
                kind: .structuredQuestion,
                startedAt: at(53)
            ))
        )))
        let stillLiveSnapshot = await store.snapshot(at: at(54))
        suite.check(
            stillLiveSnapshot.connection != nil
                && stillLiveSnapshot.threads.allSatisfy { $0.freshness == .live },
            "persistence-failure fixture deliberately retains live domain authority"
        )

        let unavailable = AppServerDomainPresentation(
            snapshot: stillLiveSnapshot,
            runtimeStatus: .init(
                phase: .reconnecting,
                detail: "Connection loss could not be persisted; cached rows are not current."
            ),
            now: at(55)
        )
        suite.check(
            unavailable.threads.allSatisfy {
                $0.freshness == .stale
                    && $0.freshnessLabel == "Stale"
                    && $0.rowPriority == .noRecentSignals
                    && $0.tone == .warning
                    && !$0.isActive
                    && $0.attention == nil
                    && $0.attentionCount == 0
            },
            "runtime authority loss forces every presented row stale even when the snapshot stayed live"
        )
        suite.check(
            unavailable.activeCount == 0
                && unavailable.attentionCount == 0
                && unavailable.compactActivityTitle == nil,
            "unavailable runtime authority suppresses all live compact and attention state"
        )
    }

    private static func testTimelineAccessibilityUsesBoundedVisibleDetail(
        into suite: inout TestSuite
    ) async {
        let visiblePayload = [
            "Visible line one",
            "Visible line two",
            "Visible line three",
            String(repeating: "🙂", count: 400),
            "VOICEOVER_MUST_NOT_READ_LINE_FIVE",
            "VOICEOVER_MUST_NOT_READ_LINE_SIX",
        ].joined(separator: "\n")
        let store = AppServerProjectionStore()
        _ = await store.apply(.connectionActivated(
            identity: connection,
            source: .managedDaemon,
            featureSupport: .init(features: [.monitor])
        ))
        _ = await store.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: at(60),
            threads: [.init(
                id: threadID,
                sessionID: sessionID,
                title: "Bounded accessibility",
                status: .active([]),
                updatedAt: at(60),
                turnsAreAuthoritative: true,
                turns: [.init(
                    id: turnID,
                    status: .inProgress,
                    items: [.init(
                        id: .init(rawValue: "item-bounded-accessibility"),
                        kind: .agentMessage,
                        status: .started,
                        startedAt: at(60),
                        presentation: .agentText(visiblePayload)
                    )]
                )]
            )]
        )))
        let presentation = AppServerDomainPresentation(
            snapshot: await store.snapshot(at: at(61)),
            runtimeStatus: .init(phase: .connected, detail: "Connected."),
            now: at(61)
        )
        guard let item = presentation.threads.first?.timeline.first,
              let detail = item.detail
        else {
            suite.check(false, "bounded timeline fixture reaches presentation")
            return
        }

        suite.check(
            detail.split(separator: "\n", omittingEmptySubsequences: false).count
                <= AppServerTimelineItemPresentation.maximumFinalAnswerLineCount,
            "assistant commentary uses the readable conversation line bound"
        )
        suite.check(
            detail.count <= AppServerTimelineItemPresentation.maximumFinalAnswerCharacterCount
                && detail.utf8.count
                    <= AppServerTimelineItemPresentation.maximumFinalAnswerUTF8Bytes,
            "assistant commentary enforces the larger conversation character and byte bounds"
        )
        suite.check(
            detail.contains("VOICEOVER_MUST_NOT_READ_LINE_FIVE"),
            "assistant commentary no longer disappears after four lines"
        )
        suite.check(
            item.accessibilityLabel.utf8.count <= 1_024,
            "VoiceOver remains independently byte-bounded for long commentary"
        )
    }

    private static func testTimelineCapPreservesCompiledAnswer(
        into suite: inout TestSuite
    ) async {
        let compiledAnswer = (1...6).map { "Compiled line \($0)" }.joined(separator: "\n")
        let commentary = "I found the regression and I am applying the correction now."
        let store = AppServerProjectionStore()
        _ = await store.apply(.connectionActivated(
            identity: connection,
            source: .managedDaemon,
            featureSupport: .init(features: [.monitor])
        ))
        let activityItems = (0..<45).map { index in
            item(
                "tool-\(index)",
                .mcpToolCall,
                at: TimeInterval(index + 2),
                presentation: .tool(name: "tool-\(index)", server: "test")
            )
        }
        let thread = AppServerThreadInput(
            id: .init(rawValue: "compiled-answer-cap"),
            sessionID: .init(rawValue: "compiled-answer-cap-session"),
            title: "Compiled answer cap",
            source: .appServer,
            status: .idle,
            createdAt: at(0),
            updatedAt: at(50),
            turnsAreAuthoritative: true,
            turns: [.init(
                id: .init(rawValue: "compiled-answer-cap-turn"),
                status: .completed,
                startedAt: at(1),
                completedAt: at(50),
                itemsView: .full,
                items: [
                    item(
                        "compiled-answer",
                        .agentMessage,
                        at: 1,
                        presentation: .agentFinalText(compiledAnswer)
                    ),
                    item(
                        "commentary-before-tools",
                        .agentMessage,
                        at: 1.5,
                        presentation: .agentText(commentary)
                    ),
                ] + activityItems
            )]
        )
        _ = await store.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: at(50),
            threads: [thread]
        )))
        let presentation = AppServerDomainPresentation(
            snapshot: await store.snapshot(at: at(51)),
            runtimeStatus: .init(phase: .connected, detail: "Testing compiled answer cap."),
            now: at(51)
        )
        let timeline = presentation.threads.first?.timeline ?? []
        suite.checkEqual(timeline.count, 40, "timeline remains bounded after prioritizing conversation text")
        suite.check(
            timeline.contains {
                $0.category == .finalAnswer
                    && $0.detail == compiledAnswer
            },
            "compiled final answer survives the cap without the four-line activity truncation"
        )
        suite.check(
            timeline.contains {
                $0.category == .agentOutput && $0.detail == commentary
            },
            "user-facing commentary survives a later burst of forty-five tool calls"
        )
        suite.check(
            timeline.filter { $0.category == .tool }.count >= 16,
            "conversation retention still leaves a bounded inspectable operational trail"
        )
    }

    private static func testUntimestampedTimelinePreservesAuthoritativeOrder(
        into suite: inout TestSuite
    ) async {
        let store = AppServerProjectionStore()
        _ = await store.apply(.connectionActivated(
            identity: connection,
            source: .managedDaemon,
            featureSupport: .init(features: [.monitor])
        ))
        let thread = AppServerThreadInput(
            id: .init(rawValue: "authoritative-item-order"),
            sessionID: .init(rawValue: "authoritative-item-order-session"),
            title: "Authoritative item order",
            source: .appServer,
            status: .idle,
            createdAt: at(70),
            updatedAt: at(80),
            turnsAreAuthoritative: true,
            turns: [.init(
                id: .init(rawValue: "authoritative-item-order-turn"),
                status: .completed,
                startedAt: at(70),
                completedAt: at(80),
                itemsView: .full,
                items: [
                    .init(id: .init(rawValue: "z-user"), kind: .userMessage, status: .completed, presentation: .userText("Question")),
                    .init(id: .init(rawValue: "a-commentary"), kind: .agentMessage, status: .completed, presentation: .agentText("Commentary")),
                    .init(id: .init(rawValue: "m-tool"), kind: .mcpToolCall, status: .completed, presentation: .tool(name: "inspect", server: "test")),
                ]
            )]
        )
        _ = await store.apply(.snapshot(.init(
            cursor: cursor(70),
            observedAt: at(80),
            threads: [thread]
        )))
        let presentation = AppServerDomainPresentation(
            snapshot: await store.snapshot(at: at(81)),
            runtimeStatus: .init(phase: .connected, detail: "Testing item order."),
            now: at(81)
        )
        suite.checkEqual(
            presentation.threads.first?.timeline
                .filter { $0.category != .outcome }
                .map(\.category),
            [.userMessage, .agentOutput, .tool],
            "untimestamped hydrated items preserve authoritative protocol array order instead of lexical IDs"
        )
    }

    private static func emptySnapshot(
        featureSupport: Set<AppServerFeature>
    ) async -> AppServerProjectionSnapshot {
        let store = AppServerProjectionStore()
        _ = await store.apply(.connectionActivated(
            identity: connection,
            source: .managedDaemon,
            featureSupport: .init(features: featureSupport)
        ))
        _ = await store.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: at(0),
            threads: []
        )))
        return await store.snapshot(at: at(1))
    }

    private static func richThread() -> AppServerThreadInput {
        AppServerThreadInput(
            id: threadID,
            sessionID: sessionID,
            title: "  Phase 8 thread  ",
            workingDirectoryName: "FallbackDirectory",
            source: .cli,
            status: .active([.waitingOnApproval]),
            createdAt: at(1),
            updatedAt: at(19),
            turnsAreAuthoritative: true,
            turns: [.init(
                id: turnID,
                status: .completed,
                startedAt: at(2),
                completedAt: at(19),
                itemsView: .full,
                items: [
                    item("item-agent", .agentMessage, at: 3, presentation: .agentText("Implemented the bounded monitor.")),
                    item("item-final", .agentMessage, at: 9, presentation: .agentFinalText("The monitor is ready.")),
                    item("item-reasoning", .reasoning, at: 4, presentation: .reasoningSummary(["Checked source evidence.", "Verified freshness."])),
                    item("item-command", .commandExecution, at: 5, presentation: .command("swift test")),
                    item(
                        "item-file",
                        .fileChange,
                        at: 6,
                        presentation: .fileChanges([
                            .init(path: "Sources/Monitor.swift", kind: .update),
                            .init(path: "Tests/MonitorTests.swift", kind: .add),
                        ])
                    ),
                    item("item-plan", .plan, at: 7, presentation: .planText("1. Map\n2. Verify")),
                    item("item-tool", .mcpToolCall, at: 8, presentation: .tool(name: "search", server: "docs")),
                ]
            )]
        )
    }

    private static func workingThread() -> AppServerThreadInput {
        AppServerThreadInput(
            id: threadID,
            sessionID: sessionID,
            title: "Current work",
            source: .appServer,
            status: .active([]),
            updatedAt: at(30),
            turnsAreAuthoritative: true,
            turns: [.init(
                id: AppServerTurnID(rawValue: "turn-phase8-active"),
                status: .inProgress,
                startedAt: at(30),
                itemsView: .full,
                items: [item(
                    "item-running-command",
                    .commandExecution,
                    status: .started,
                    at: 30,
                    presentation: .command("swift build")
                )]
            )]
        )
    }

    private static func item(
        _ id: String,
        _ kind: AppServerItemKind,
        status: AppServerItemStatus = .completed,
        at seconds: TimeInterval,
        presentation: AppServerItemPresentationPayload
    ) -> AppServerItemInput {
        AppServerItemInput(
            id: AppServerItemID(rawValue: id),
            kind: kind,
            status: status,
            startedAt: Self.at(seconds),
            completedAt: status == .started ? nil : Self.at(seconds),
            presentation: presentation
        )
    }

    private static func cursor(_ sequence: UInt64) -> AppServerObservationCursor {
        AppServerObservationCursor(connection: connection, sequence: sequence)
    }

    private static func at(_ seconds: TimeInterval) -> Date {
        baseDate.addingTimeInterval(seconds)
    }
}
