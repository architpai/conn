import CoreGraphics
import ConnAppCore

enum Phase87ShellTestCases {
    static func run(into suite: inout TestSuite) {
        testTwoStateLifecycle(into: &suite)
        testBarTogglePolicy(into: &suite)
        testExactEscapeRouting(into: &suite)
        testCollapseRouting(into: &suite)
        testPhysicalNotchCompactPillLayout(into: &suite)
        testExpandedGeometryTarget(into: &suite)
        testGraphitePreferences(into: &suite)
        testStickyExpandedLifecycle(into: &suite)
        testManualOrder(into: &suite)
        testPhase9AffordancesFollowCurrentGates(into: &suite)
    }

    private static func testBarTogglePolicy(into suite: inout TestSuite) {
        suite.checkEqual(
            ShellBarTogglePolicy.action(for: .init(surface: .compact)),
            .expand,
            "bar click expands compact Conn"
        )
        suite.checkEqual(
            ShellBarTogglePolicy.action(for: .init(surface: .expanded)),
            .collapse,
            "bar click collapses the expanded workspace"
        )
        suite.checkEqual(
            ShellBarTogglePolicy.action(for: .init(visibility: .hidden)),
            .resumeAndExpand,
            "the global toggle can still recover a deliberately hidden surface"
        )
    }

    private static func testExactEscapeRouting(into suite: inout TestSuite) {
        let expanded = ShellLifecycleState(surface: .expanded)
        suite.checkEqual(
            ShellEscapeRoutingPolicy.route(showsSettings: true, lifecycle: expanded),
            .dismissSettings,
            "Escape dismisses settings before stepping down the island"
        )
        suite.checkEqual(
            ShellEscapeRoutingPolicy.route(showsSettings: false, lifecycle: expanded),
            .stepDown,
            "a distinct immediate Escape is not swallowed after settings dismissal"
        )
        suite.checkEqual(
            ShellEscapeRoutingPolicy.route(
                showsSettings: false,
                lifecycle: .init(surface: .compact)
            ),
            .ignore,
            "compact Conn does not consume unrelated Escape events"
        )
        suite.checkEqual(
            ShellQuestionEscapePolicy.action(isQuestionInputFocused: true),
            .defocusQuestionInput,
            "the first Escape defocuses a question TextField or SecureField"
        )
        suite.checkEqual(
            ShellQuestionEscapePolicy.action(isQuestionInputFocused: false),
            .routePanelEscape,
            "the next Escape routes to the panel step-down policy"
        )
    }

    private static func testCollapseRouting(into suite: inout TestSuite) {
        suite.checkEqual(
            ShellCollapseRoutingPolicy.lifecycleEvent(for: .outsideClick),
            .outsideClick,
            "outside-click routing collapses through the explicit outside-click event"
        )
        suite.checkEqual(
            ShellCollapseRoutingPolicy.lifecycleEvent(for: .escape),
            .userCollapse,
            "Escape routing performs a direct compact transition"
        )
    }

    private static func testTwoStateLifecycle(into suite: inout TestSuite) {
        var state = ShellLifecycleState()

        suite.checkEqual(state.surface, .compact, "the shell starts in the collapsed state")
        suite.check(!state.isInteractive, "collapsed Conn does not claim workspace focus authority")
        suite.check(state.apply(.userExpand), "clicking the island expands directly from compact")
        suite.checkEqual(state.surface, .expanded, "expanded is the only open workspace state")
        suite.check(state.isInteractive, "expanded workspace is focus-interactive")

        suite.check(state.apply(.escape), "Escape collapses expanded Conn directly")
        suite.checkEqual(state.surface, .compact, "one Escape returns to the constant bar")
        suite.check(!state.apply(.escape), "Escape is a no-op once Conn is compact")

        state.apply(.userExpand)
        suite.check(state.apply(.outsideClick), "outside click dismisses expanded monitoring")
        suite.checkEqual(state.surface, .compact, "outside click returns to the constant bar")
    }

    private static func testPhysicalNotchCompactPillLayout(
        into suite: inout TestSuite
    ) {
        let urgencyOrdered = [
            "approval", "input", "running", "failed", "idle", "not-loaded", "unknown",
        ]
        suite.checkEqual(
            ShellStatusPillLayoutPolicy.orderedVisiblePills(
                urgencyOrdered,
                surface: .compact,
                placement: .physicalNotch
            ),
            ["running", "input", "approval"],
            "physical-notch compact keeps the three most urgent pills in the proven safe wing and places them away from the camera edge"
        )
        suite.checkEqual(
            ShellStatusPillLayoutPolicy.orderedVisiblePills(
                urgencyOrdered,
                surface: .compact,
                placement: .externalCapsule
            ),
            urgencyOrdered,
            "external compact capsules retain the complete presentation order"
        )
        suite.checkEqual(
            ShellStatusPillLayoutPolicy.orderedVisiblePills(
                urgencyOrdered,
                surface: .expanded,
                placement: .physicalNotch
            ),
            urgencyOrdered,
            "expanded Conn retains every status pill because it is not the compact notch wing"
        )
    }

    private static func testExpandedGeometryTarget(into suite: inout TestSuite) {
        let display = ShellDisplayDescriptor(
            id: .init(rawValue: 88),
            persistentIdentifier: "phase-87-expanded-display",
            localizedName: "Expanded geometry",
            frame: .init(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: .init(x: 0, y: 24, width: 1_440, height: 876),
            safeAreaInsets: .init(),
            isBuiltIn: false
        )
        let configuration = ShellPanelGeometryConfiguration(
            compactSize: .init(width: 404, height: 34),
            expandedWidth: 720,
            maximumExpandedWidth: 720,
            maximumExpandedHeight: 460,
            expandedDetailBodyMinimumHeight: 344
        )
        let geometry = ShellPanelGeometryPolicy(configuration: configuration).geometry(
            for: display,
            surface: .expanded,
            rowCount: 15,
            showsSessionDetail: true
        )

        suite.checkEqual(geometry.frame.width, 720, "expanded workspace uses the Graphite production width")
        suite.checkEqual(geometry.frame.height, 460, "expanded workspace uses the Graphite production height")
        suite.check(
            display.frame.contains(geometry.frame),
            "expanded production geometry remains within its display bounds"
        )

        let shortDisplay = ShellDisplayDescriptor(
            id: .init(rawValue: 89),
            persistentIdentifier: "phase-87-short-display",
            localizedName: "Short geometry",
            frame: .init(x: 0, y: 0, width: 900, height: 600),
            visibleFrame: .init(x: 0, y: 40, width: 900, height: 540),
            safeAreaInsets: .init(),
            isBuiltIn: false
        )
        let clamped = ShellPanelGeometryPolicy(configuration: configuration).geometry(
            for: shortDisplay,
            surface: .expanded,
            rowCount: 15,
            showsSessionDetail: true
        )
        suite.checkEqual(clamped.frame.height, 460, "expanded target remains within the short screen's visible bounds")
    }

    private static func testGraphitePreferences(into suite: inout TestSuite) {
        suite.checkEqual(
            ShellSidebarMode.allCases,
            [.threads, .projects],
            "Graphite exposes flat and grouped thread switching"
        )
    }

    private static func testStickyExpandedLifecycle(into suite: inout TestSuite) {
        var state = ShellLifecycleState(surface: .expanded)

        suite.check(!state.apply(.passiveUpdate), "passive updates preserve the open workspace")
        suite.check(state.apply(.outsideClick), "focus activity outside Conn collapses the workspace")
        suite.checkEqual(state.surface, .compact, "outside focus returns to the bar")
        suite.check(state.apply(.userExpand), "the user can explicitly reopen after outside collapse")
        suite.check(state.apply(.applicationLifecycleChanged(.screenAsleep)), "sleep hides the surface")
        suite.checkEqual(state.surface, .expanded, "sleep preserves the user's expanded surface intent")
        suite.checkEqual(state.visibility, .hidden, "Conn is suppressed while the screen sleeps")
        suite.check(state.apply(.applicationLifecycleChanged(.active)), "wake restores availability")
        suite.checkEqual(state.surface, .expanded, "wake restores the same manually chosen surface")
        suite.checkEqual(state.visibility, .visible, "wake makes Conn visible again")
        suite.check(state.apply(.userCollapse), "manual collapse remains authoritative")
        suite.checkEqual(state.surface, .compact, "manual collapse closes the workspace")
    }

    private static func testManualOrder(into suite: inout TestSuite) {
        var order = ShellManualOrder()

        suite.check(order.reconcile(latestFirstIDs: ["new", "middle", "old"]), "latest-first baseline is recorded")
        suite.checkEqual(order.orderedIDs, ["new", "middle", "old"], "baseline preserves newest-first input")
        suite.check(order.reconcile(latestFirstIDs: ["middle", "new", "old"]), "baseline follows authoritative recency before manual ordering")
        suite.checkEqual(order.orderedIDs, ["middle", "new", "old"], "pagination and metadata can refine the untouched baseline")
        suite.check(order.move("old", before: "new"), "explicit drag reorders rows")
        suite.check(order.hasManualOverride, "a successful drag records manual authority")
        suite.checkEqual(order.orderedIDs, ["middle", "old", "new"], "manual ordering is stable")
        suite.check(!order.reconcile(latestFirstIDs: ["middle", "new", "old"]), "hydration activity does not reshuffle known rows")
        suite.checkEqual(order.orderedIDs, ["middle", "old", "new"], "opening or updating a known row cannot promote it")
        suite.check(order.reconcile(latestFirstIDs: ["brand-new", "middle", "new", "old", "older-page"]), "newly discovered rows are incorporated")
        suite.checkEqual(order.orderedIDs, ["brand-new", "middle", "old", "new", "older-page"], "newest IDs prepend and older pagination appends around manual order")
        suite.check(order.reconcile(latestFirstIDs: ["brand-new", "old", "middle", "older-page"]), "removed rows are pruned")
        suite.checkEqual(order.orderedIDs, ["brand-new", "middle", "old", "older-page"], "stale identifiers do not remain persisted")

        suite.check(order.move("brand-new", relativeTo: "older-page", placement: .after), "a downward drop can target the end")
        suite.checkEqual(order.orderedIDs, ["middle", "old", "older-page", "brand-new"], "after-placement supports lower-half and final-row drops")
        suite.check(order.move("brand-new", direction: .up), "keyboard and assistive actions can move a row up")
        suite.checkEqual(order.orderedIDs, ["middle", "old", "brand-new", "older-page"], "step-up changes exactly one position")
        suite.check(order.move("middle", direction: .down), "keyboard and assistive actions can move a row down")
        suite.checkEqual(order.orderedIDs, ["old", "middle", "brand-new", "older-page"], "step-down changes exactly one position")
        suite.check(!order.move("old", direction: .up), "the first row cannot move beyond the upper boundary")

        var grouped = ShellManualOrder(
            orderedIDs: ["a-1", "b-1", "a-2", "b-2"],
            hasManualOverride: false
        )
        suite.check(
            grouped.move("a-1", direction: .down, within: ["a-1", "a-2"]),
            "grouped accessibility movement uses the next visible project neighbor"
        )
        suite.checkEqual(
            grouped.orderedIDs,
            ["b-1", "a-2", "a-1", "b-2"],
            "grouped movement preserves unrelated interleaved project rows"
        )
    }

    private static func testPhase9AffordancesFollowCurrentGates(into suite: inout TestSuite) {
        let policy = ShellPhase9AffordancePolicy(
            isComposerEnabled: true,
            isSendEnabled: false,
            isStopEnabled: true,
            areApprovalResponsesEnabled: false,
            areQuestionResponsesEnabled: true,
            detail: "Current capability and authority gates"
        )
        suite.check(policy.isComposerEnabled, "the composer follows its current capability gate")
        suite.check(!policy.isSendEnabled, "send remains disabled when its current gate refuses")
        suite.check(policy.isStopEnabled, "Stop follows active-turn capability and authority")
        suite.check(!policy.areApprovalResponsesEnabled, "approval remains disabled when response authority refuses")
        suite.check(policy.areQuestionResponsesEnabled, "question response follows exact request authority")
        suite.checkEqual(
            policy.detail,
            "Current capability and authority gates",
            "the policy surfaces current gate copy without obsolete release language"
        )
    }
}
