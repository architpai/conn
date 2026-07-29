import ConnAppCore

enum Phase8ShellRegressionTestCases {
    static func run(into suite: inout TestSuite) {
        testSelectionSurvivesReordering(into: &suite)
        testExpandedLayoutRemainsBounded(into: &suite)
        testSameContextReplacementRejectsStaleCompletion(into: &suite)
        testOnlyCurrentSuccessCollapses(into: &suite)
        testEveryMatchingTerminalPathClearsProgress(into: &suite)
        testInvalidationClearsProgressAndAuthority(into: &suite)
    }

    private static func testSelectionSurvivesReordering(
        into suite: inout TestSuite
    ) {
        var selection = ShellSelectionState(selectedSessionID: "thread-beta")

        suite.check(
            !selection.applyPassiveUpdate(
                availableSessionIDs: ["thread-alpha", "thread-beta", "thread-gamma"]
            ),
            "Phase 8 initial projection keeps the selected App Server thread"
        )
        suite.check(
            !selection.applyPassiveUpdate(
                availableSessionIDs: ["thread-gamma", "thread-alpha", "thread-beta"]
            ),
            "App Server thread reordering does not report a selection change"
        )
        suite.checkEqual(
            selection.selectedSessionID,
            "thread-beta",
            "App Server thread reordering preserves identifier-based selection"
        )

        selection.beginUserInteraction()
        suite.check(
            !selection.applyPassiveUpdate(
                availableSessionIDs: ["thread-gamma", "thread-alpha"]
            ),
            "a disappearing App Server row defers fallback during direct interaction"
        )
        suite.checkEqual(
            selection.selectedSessionID,
            "thread-beta",
            "the selected thread cannot move underneath an active interaction"
        )
        suite.check(
            selection.endUserInteraction(),
            "ending interaction applies the latest deterministic fallback"
        )
        suite.checkEqual(
            selection.selectedSessionID,
            "thread-gamma",
            "fallback selects the first current App Server row after interaction"
        )
    }

    private static func testExpandedLayoutRemainsBounded(
        into suite: inout TestSuite
    ) {
        let rows = [
            ShellSessionRow(id: "attention", priority: .attention),
            ShellSessionRow(id: "repair", priority: .integrationRepair),
            ShellSessionRow(id: "outcome", priority: .outcome),
            ShellSessionRow(id: "working-a", priority: .running),
            ShellSessionRow(id: "working-b", priority: .running),
            ShellSessionRow(id: "recent-a", priority: .recent),
            ShellSessionRow(id: "recent-b", priority: .recent),
        ]
        let layout = ExpandedShellRowLayout(rows: rows)

        suite.checkEqual(
            layout.maximumVisibleRows,
            5,
            "Phase 8 preserves the five-row expanded notch viewport"
        )
        suite.checkEqual(
            layout.initialViewportRows.map(\.id),
            ["attention", "repair", "outcome", "working-a", "working-b"],
            "structured attention and repair stay ahead of ordinary App Server rows"
        )
        suite.check(
            layout.requiresScrolling,
            "more than five App Server rows remain scrollable"
        )
        suite.checkEqual(
            layout.hiddenRowCount,
            2,
            "the bounded viewport reports its exact overflow"
        )
    }

    private static func testSameContextReplacementRejectsStaleCompletion(
        into suite: inout TestSuite
    ) {
        var state = ShellActionState()
        let original = state.begin(contextID: "thread-same", isPerforming: true)
        let replacement = state.begin(contextID: "thread-same", isPerforming: true)

        suite.check(
            !state.isCurrent(original) && state.isCurrent(replacement),
            "a replacement action has distinct authority even for the same thread"
        )
        suite.checkEqual(
            state.finish(original, outcome: .success, collapseOnSuccess: true),
            .ignored,
            "the old same-thread success callback is generation-gated"
        )
        suite.check(
            state.isPerforming && state.isCurrent(replacement),
            "an ignored callback cannot clear the replacement action's progress"
        )
        suite.checkEqual(
            state.contextID,
            "thread-same",
            "an ignored callback cannot detach the replacement thread context"
        )
    }

    private static func testOnlyCurrentSuccessCollapses(
        into suite: inout TestSuite
    ) {
        var currentSuccess = ShellActionState()
        let success = currentSuccess.begin(
            contextID: "thread-success",
            isPerforming: true
        )
        suite.checkEqual(
            currentSuccess.finish(
                success,
                outcome: .success,
                collapseOnSuccess: true
            ),
            .finishedAndCollapse,
            "only a current successful Open Codex action requests shell collapse"
        )
        suite.check(
            !currentSuccess.isPerforming,
            "current success clears action progress before collapse"
        )

        var error = ShellActionState()
        let failed = error.begin(contextID: "thread-error", isPerforming: true)
        suite.checkEqual(
            error.finish(failed, outcome: .failure, collapseOnSuccess: true),
            .finished,
            "an Open Codex error stays expanded for diagnostic copy"
        )
        suite.check(
            !error.isPerforming,
            "an Open Codex error clears action progress"
        )

        var noCollapse = ShellActionState()
        let acknowledged = noCollapse.begin(
            contextID: "thread-acknowledge",
            isPerforming: true
        )
        suite.checkEqual(
            noCollapse.finish(
                acknowledged,
                outcome: .success,
                collapseOnSuccess: false
            ),
            .finished,
            "a current successful action collapses only when the caller opts in"
        )
    }

    private static func testEveryMatchingTerminalPathClearsProgress(
        into suite: inout TestSuite
    ) {
        let cases: [(String, ShellActionTerminalOutcome)] = [
            ("success", .success),
            ("failure", .failure),
            ("cancellation", .cancelled),
            ("rejection", .rejected),
        ]

        for (label, outcome) in cases {
            var state = ShellActionState()
            let token = state.begin(
                contextID: "thread-\(label)",
                isPerforming: true
            )
            suite.checkEqual(
                state.finish(token, outcome: outcome),
                .finished,
                "matching \(label) terminal path finishes without implicit collapse"
            )
            suite.check(
                !state.isPerforming,
                "matching \(label) terminal path clears isPerformingAction"
            )
            suite.check(
                state.contextID == nil && !state.isCurrent(token),
                "matching \(label) terminal path consumes action authority"
            )
        }
    }

    private static func testInvalidationClearsProgressAndAuthority(
        into suite: inout TestSuite
    ) {
        var state = ShellActionState()
        let invalidated = state.begin(
            contextID: "thread-invalidated",
            isPerforming: true
        )
        state.invalidate()

        suite.check(
            !state.isPerforming && state.contextID == nil,
            "stale-generation invalidation clears progress and context"
        )
        suite.check(
            !state.isCurrent(invalidated),
            "stale-generation invalidation revokes the old action token"
        )
        suite.checkEqual(
            state.finish(invalidated, outcome: .success, collapseOnSuccess: true),
            .ignored,
            "an invalidated callback cannot later collapse the shell"
        )
    }
}
