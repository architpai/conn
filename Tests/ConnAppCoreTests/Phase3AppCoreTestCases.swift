import CoreGraphics
import Foundation
import ConnAppCore

enum Phase3AppCoreTestCases {
    static func run(into suite: inout TestSuite) async throws {
        testLifecycle(into: &suite)
        testStableSelection(into: &suite)
        testDisplayResolution(into: &suite)
        testGeometry(into: &suite)
        testFocusRestoration(into: &suite)
        testExpandedRowLayout(into: &suite)
    }

    private static func testLifecycle(into suite: inout TestSuite) {
        var state = ShellLifecycleState(surface: .expanded)
        suite.check(state.isInteractive, "expanded visible shell is interactive")
        suite.check(!state.apply(.passiveUpdate), "passive update is a lifecycle no-op")
        suite.checkEqual(state.surface, .expanded, "passive update does not collapse")
        suite.checkEqual(state.visibility, .visible, "passive update does not hide")
        suite.checkEqual(state.monitoring, .monitoring, "passive update does not pause monitoring")

        suite.check(
            state.apply(.applicationLifecycleChanged(.sessionInactive)),
            "inactive user session changes shell state"
        )
        suite.checkEqual(state.surface, .expanded, "inactive session preserves expansion intent while hidden")
        suite.checkEqual(state.visibility, .hidden, "inactive session suppresses visibility")
        suite.checkEqual(state.monitoring, .monitoring, "inactive session preserves monitoring")
        suite.check(!state.apply(.passiveUpdate), "passive update cannot reveal inactive shell")
        suite.checkEqual(state.visibility, .hidden, "inactive shell remains hidden after update")
        suite.check(!state.apply(.userExpand), "user cannot expand while lifecycle-suppressed")

        suite.check(state.apply(.applicationLifecycleChanged(.active)), "active session reveals shell")
        suite.checkEqual(state.visibility, .visible, "active session restores non-user-hidden visibility")
        suite.checkEqual(state.surface, .expanded, "reactivation restores the user's manually expanded surface")
        suite.check(!state.apply(.userExpand), "repeated explicit expansion is idempotent")
        suite.check(state.apply(.applicationLifecycleChanged(.screenAsleep)), "sleep suppresses shell")
        suite.checkEqual(state.visibility, .hidden, "sleep hides shell")
        suite.checkEqual(state.surface, .expanded, "sleep preserves expansion intent while hidden")
        suite.check(state.apply(.applicationLifecycleChanged(.active)), "wake refreshes visibility")

        suite.check(state.apply(.hide), "user hide changes visibility")
        suite.checkEqual(state.visibility, .hidden, "user hide hides shell")
        suite.checkEqual(state.monitoring, .monitoring, "user hide keeps monitoring enabled")
        suite.check(state.isUserHidden, "user-hidden intent is retained")
        suite.check(state.apply(.applicationLifecycleChanged(.sessionInactive)), "lifecycle still advances while hidden")
        suite.check(state.apply(.applicationLifecycleChanged(.active)), "lifecycle resumes while user-hidden")
        suite.checkEqual(state.visibility, .hidden, "wake does not override user-hidden intent")
        suite.check(state.apply(.show), "explicit show clears user-hidden intent")
        suite.checkEqual(state.visibility, .visible, "explicit show restores visibility")
        suite.checkEqual(state.monitoring, .monitoring, "show does not alter monitoring")

        suite.check(state.apply(.pauseAndHide), "pause-and-hide applies both user intents")
        suite.checkEqual(state.monitoring, .paused, "pause-and-hide pauses monitoring")
        suite.checkEqual(state.visibility, .hidden, "pause-and-hide hides shell")
        suite.check(state.apply(.resumeAndShow), "resume-and-show applies both user intents")
        suite.checkEqual(state.monitoring, .monitoring, "resume-and-show resumes monitoring")
        suite.checkEqual(state.visibility, .visible, "resume-and-show reveals shell")

        var availability = ShellSystemAvailability()
        availability.apply(.userSessionActive(false))
        availability.apply(.screensAwake(false))
        availability.apply(.screensAwake(true))
        suite.checkEqual(
            availability.lifecycleState,
            .sessionInactive,
            "screen wake cannot reveal Conn while the user session remains inactive"
        )
        availability.apply(.userSessionActive(true))
        suite.checkEqual(
            availability.lifecycleState,
            .active,
            "Conn becomes available only after both independent suppressors clear"
        )
    }

    private static func testStableSelection(into suite: inout TestSuite) {
        var selection = ShellSelectionState(selectedSessionID: "beta")
        suite.check(
            !selection.applyPassiveUpdate(availableSessionIDs: ["gamma", "beta", "alpha"]),
            "reordering rows preserves identifier-based selection"
        )
        suite.checkEqual(selection.selectedSessionID, "beta", "selected session stays stable across reorder")

        selection.beginUserInteraction()
        suite.check(selection.isUserInteracting, "selection records active user interaction")
        suite.check(
            !selection.applyPassiveUpdate(availableSessionIDs: ["gamma", "alpha", "gamma"]),
            "missing selection does not jump during interaction"
        )
        suite.checkEqual(selection.selectedSessionID, "beta", "disappeared row remains selected until interaction ends")
        suite.check(
            !selection.applyPassiveUpdate(availableSessionIDs: ["alpha", "gamma"]),
            "latest passive fallback remains deferred"
        )
        suite.check(selection.endUserInteraction(), "ending interaction applies deferred fallback")
        suite.checkEqual(selection.selectedSessionID, "alpha", "fallback uses latest deterministic first row")
        suite.check(!selection.isUserInteracting, "interaction flag clears")
        suite.check(
            !selection.selectSession("missing", availableSessionIDs: ["alpha", "gamma"]),
            "unavailable direct selection is rejected"
        )
        suite.checkEqual(selection.selectedSessionID, "alpha", "rejected selection does not mutate state")
        suite.check(
            selection.selectSession("gamma", availableSessionIDs: ["alpha", "gamma", "gamma"]),
            "available selection succeeds with duplicate rows"
        )
        suite.checkEqual(selection.selectedSessionID, "gamma", "direct selection stores session identifier")
    }

    private static func testDisplayResolution(into suite: inout TestSuite) {
        let externalLeft = display(
            id: 30, persistentID: "external-left", name: "Left",
            frame: CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        )
        let mainExternal = display(
            id: 20, persistentID: "external-main", name: "Main",
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )
        let builtIn = display(
            id: 10, persistentID: "builtin", name: "Built-in",
            frame: CGRect(x: 1920, y: 0, width: 1512, height: 982),
            safeTop: 32, builtIn: true
        )
        let displays = [mainExternal, builtIn, externalLeft]

        let exact = SelectedDisplayResolver.resolve(
            .specific(.init(persistentIdentifier: "external-main", lastKnownName: "Old name")),
            among: displays,
            mainDisplayID: mainExternal.id
        )
        suite.checkEqual(exact.display?.id, mainExternal.id, "persistent identifier wins over fallbacks")
        suite.checkEqual(exact.source, .persistedIdentifier, "exact display reports identifier source")
        suite.check(!exact.usedFallback, "exact display is not marked as fallback")

        let builtInFallback = SelectedDisplayResolver.resolve(
            .specific(.init(persistentIdentifier: "disconnected", lastKnownName: "Gone")),
            among: displays,
            mainDisplayID: mainExternal.id
        )
        suite.checkEqual(builtInFallback.display?.id, builtIn.id, "built-in display is first fallback")
        suite.checkEqual(builtInFallback.source, .builtInFallback, "built-in fallback source is explicit")
        suite.check(builtInFallback.usedFallback, "built-in resolution is marked as fallback")

        let mainFallback = SelectedDisplayResolver.resolve(
            .automatic,
            among: [externalLeft, mainExternal],
            mainDisplayID: mainExternal.id
        )
        suite.checkEqual(mainFallback.display?.id, mainExternal.id, "main display follows absent built-in")
        suite.checkEqual(mainFallback.source, .mainDisplayFallback, "main fallback source is explicit")

        let firstFallback = SelectedDisplayResolver.resolve(
            .automatic,
            among: [mainExternal, externalLeft],
            mainDisplayID: nil
        )
        suite.checkEqual(firstFallback.display?.id, externalLeft.id, "first fallback is geometry-deterministic")
        suite.checkEqual(firstFallback.source, .firstAvailableFallback, "first fallback source is explicit")

        let unavailable = SelectedDisplayResolver.resolve(.automatic, among: [], mainDisplayID: nil)
        suite.check(unavailable.display == nil, "empty display inventory resolves to nil")
        suite.checkEqual(unavailable.source, .unavailable, "empty inventory reports unavailable")
    }

    private static func testGeometry(into suite: inout TestSuite) {
        let policy = ShellPanelGeometryPolicy()
        let notch = display(
            id: 1, persistentID: "notch", name: "Notch",
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            safeTop: 32, builtIn: true
        )
        let notchCompact = policy.geometry(for: notch, surface: .compact, rowCount: 20)
        suite.check(notch.hasPhysicalNotch, "built-in safe-area inset identifies physical notch")
        suite.checkEqual(notchCompact.placement, .physicalNotch, "notched display uses notch placement")
        suite.checkEqual(notchCompact.frame, CGRect(x: 624, y: 944, width: 264, height: 38), "notch capsule anchors at physical top center")
        suite.checkEqual(notchCompact.visibleRowCount, 0, "compact geometry exposes no rows")

        let repairedExpansion = policy.geometry(
            for: notch,
            surface: .expanded,
            rowCount: 1,
            showsIntegrationRepair: true
        )
        suite.checkEqual(
            repairedExpansion.frame.height,
            273,
            "expanded geometry includes header, footer, row padding, and repair banner"
        )
        let emptyExpansion = policy.geometry(for: notch, surface: .expanded, rowCount: 0)
        suite.checkEqual(
            emptyExpansion.frame.height,
            248,
            "empty expanded geometry preserves the full idle state"
        )

        let external = display(
            id: 2, persistentID: "external", name: "External",
            frame: CGRect(x: -1920, y: -200, width: 1920, height: 1080),
            visibleFrame: CGRect(x: -1920, y: -200, width: 1920, height: 1056),
            safeTop: 24, builtIn: false
        )
        let externalCompact = policy.geometry(for: external, surface: .compact, rowCount: 3)
        suite.check(!external.hasPhysicalNotch, "external safe area is not treated as physical notch")
        suite.checkEqual(externalCompact.placement, .externalCapsule, "external display uses capsule placement")
        suite.checkEqual(externalCompact.frame, CGRect(x: -1092, y: 810, width: 264, height: 38), "external capsule honors negative origin and visible top gap")

        let expanded = policy.geometry(
            for: external,
            surface: .expanded,
            rowCount: 12,
            textScale: .init(1.5)
        )
        suite.checkEqual(expanded.visibleRowCount, 5, "expanded geometry caps visible rows at five")
        suite.checkEqual(expanded.textScale.value, 1.5, "geometry retains requested text scale")
        suite.checkEqual(expanded.frame.width, 640, "expanded width respects the compact-view ceiling")
        suite.checkEqual(expanded.frame.height, 520, "expanded height cannot grow to screen size")
        suite.checkEqual(expanded.frame.midX, external.frame.midX, "negative-origin expanded panel remains centered")

        let tiny = display(
            id: 3, persistentID: "tiny", name: "Tiny",
            frame: CGRect(x: -50, y: -20, width: 100, height: 40)
        )
        let tinyGeometry = policy.geometry(
            for: tiny,
            surface: .expanded,
            rowCount: 99,
            textScale: .init(9)
        )
        suite.checkEqual(tinyGeometry.textScale.value, 2, "text scale clamps to supported maximum")
        suite.checkEqual(tinyGeometry.frame, CGRect(x: -38, y: -20, width: 76, height: 32), "tiny display clamps panel inside usable bounds")
        suite.checkEqual(tinyGeometry.visibleRowCount, 5, "tiny display retains logical five-row cap")
        suite.checkEqual(ShellTextScale(.nan).value, 1, "non-finite text scale defaults to one")
        suite.checkEqual(ShellTextScale(0.5).value, 1, "text scale clamps to supported minimum")
    }

    private static func testFocusRestoration(into suite: inout TestSuite) {
        let conn = ShellApplicationPID(rawValue: 100)!
        let editor = ShellApplicationPID(rawValue: 200)!
        let browser = ShellApplicationPID(rawValue: 300)!
        var focus = ShellFocusState()

        suite.checkEqual(
            focus.apply(.passiveAttention, connApplicationPID: conn), .none,
            "passive attention never takes focus"
        )
        suite.check(focus.priorApplicationPID == nil, "passive focus event stores no prior app")
        suite.checkEqual(
            focus.apply(.userExpand(frontmostApplicationPID: editor), connApplicationPID: conn),
            .activateConn,
            "user expansion explicitly activates Conn"
        )
        suite.checkEqual(focus.priorApplicationPID, editor, "expansion remembers prior frontmost app")
        suite.checkEqual(
            focus.apply(
                .userCollapse(reason: .escape, frontmostApplicationPID: conn),
                connApplicationPID: conn
            ),
            .restoreApplication(editor),
            "escape restores prior app while Conn still owns focus"
        )
        suite.check(focus.priorApplicationPID == nil, "collapse consumes prior focus record")

        _ = focus.apply(.userExpand(frontmostApplicationPID: editor), connApplicationPID: conn)
        suite.checkEqual(
            focus.apply(
                .userCollapse(reason: .outsideClick, frontmostApplicationPID: browser),
                connApplicationPID: conn
            ),
            .none,
            "outside click never races the newly focused app"
        )
        suite.check(focus.priorApplicationPID == nil, "outside click clears stale restoration target")

        _ = focus.apply(.userExpand(frontmostApplicationPID: editor), connApplicationPID: conn)
        suite.checkEqual(
            focus.apply(
                .userCollapse(reason: .escape, frontmostApplicationPID: browser),
                connApplicationPID: conn
            ),
            .none,
            "collapse does not restore after Conn has lost focus"
        )
        suite.check(focus.priorApplicationPID == nil, "lost-focus collapse clears restoration target")

        suite.checkEqual(
            focus.apply(.userExpand(frontmostApplicationPID: conn), connApplicationPID: conn),
            .activateConn,
            "expanding while already frontmost remains an explicit activation decision"
        )
        suite.check(focus.priorApplicationPID == nil, "Conn never stores itself as restoration target")
        suite.checkEqual(
            focus.apply(
                .displayReconfiguration(frontmostApplicationPID: conn),
                connApplicationPID: conn
            ),
            .none,
            "display collapse without a prior app has nothing to restore"
        )
    }

    private static func testExpandedRowLayout(into suite: inout TestSuite) {
        let rows = [
            ShellSessionRow(id: "run-1", priority: .running),
            ShellSessionRow(id: "repair-1", priority: .integrationRepair),
            ShellSessionRow(id: "recent-1", priority: .recent),
            ShellSessionRow(id: "attention-1", priority: .attention),
            ShellSessionRow(id: "outcome-1", priority: .outcome),
            ShellSessionRow(id: "attention-2", priority: .attention),
            ShellSessionRow(id: "run-2", priority: .running),
        ]
        let layout = ExpandedShellRowLayout(rows: rows)
        suite.checkEqual(layout.maximumVisibleRows, 5, "expanded layout defaults to five-row viewport")
        suite.checkEqual(
            layout.pinnedRows.map(\.id),
            ["attention-1", "attention-2", "repair-1"],
            "attention and repair rows are pinned in stable priority order"
        )
        suite.checkEqual(
            layout.scrollingRows.map(\.id),
            ["outcome-1", "run-1", "run-2", "recent-1"],
            "ordinary rows remain in stable priority order"
        )
        suite.checkEqual(
            layout.initialViewportRows.map(\.id),
            ["attention-1", "attention-2", "repair-1", "outcome-1", "run-1"],
            "first paint fills five rows after pinned priorities"
        )
        suite.check(layout.requiresScrolling, "overflow beyond five rows requires scrolling")
        suite.checkEqual(layout.hiddenRowCount, 2, "overflow reports exact hidden-row count")

        let pinnedOverflow = ExpandedShellRowLayout(rows: (1...6).map {
            ShellSessionRow(id: "attention-\($0)", priority: .attention)
        })
        suite.checkEqual(pinnedOverflow.pinnedRows.count, 6, "pinned section never drops attention rows")
        suite.checkEqual(pinnedOverflow.initialViewportRows.count, 5, "pinned overflow still bounds first viewport")
        suite.check(pinnedOverflow.requiresScrolling, "pinned overflow remains scrollable")
        suite.checkEqual(pinnedOverflow.hiddenRowCount, 1, "pinned overflow reports hidden row")
    }

    private static func display(
        id: UInt32,
        persistentID: String,
        name: String,
        frame: CGRect,
        visibleFrame: CGRect? = nil,
        safeTop: CGFloat = 0,
        builtIn: Bool = false
    ) -> ShellDisplayDescriptor {
        ShellDisplayDescriptor(
            id: ShellDisplayID(rawValue: id),
            persistentIdentifier: persistentID,
            localizedName: name,
            frame: frame,
            visibleFrame: visibleFrame ?? frame,
            safeAreaInsets: ShellEdgeInsets(top: safeTop),
            isBuiltIn: builtIn
        )
    }

}
