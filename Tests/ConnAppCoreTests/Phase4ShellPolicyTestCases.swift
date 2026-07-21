import CoreGraphics
import Foundation
import ConnAppCore

enum Phase4ShellPolicyTestCases {
    static func run(into suite: inout TestSuite) {
        testOpenCodexHandoff(into: &suite)
        testDetailAwareGeometry(into: &suite)
        testExpandedRowScrollingPolicy(into: &suite)
    }

    private static func testOpenCodexHandoff(into suite: inout TestSuite) {
        let conn = ShellApplicationPID(rawValue: 100)!
        let editor = ShellApplicationPID(rawValue: 200)!
        let codex = ShellApplicationPID(rawValue: 300)!

        var focus = ShellFocusState()
        _ = focus.apply(
            .userExpand(frontmostApplicationPID: editor),
            connApplicationPID: conn
        )
        suite.checkEqual(
            focus.apply(
                .userCollapse(reason: .openCodex, frontmostApplicationPID: conn),
                connApplicationPID: conn
            ),
            .none,
            "Open Codex handoff never restores the prior application"
        )
        suite.check(
            focus.priorApplicationPID == nil,
            "Open Codex handoff consumes the prior focus owner"
        )

        _ = focus.apply(
            .userExpand(frontmostApplicationPID: editor),
            connApplicationPID: conn
        )
        suite.checkEqual(
            focus.apply(
                .userCollapse(reason: .openCodex, frontmostApplicationPID: codex),
                connApplicationPID: conn
            ),
            .none,
            "completed Codex activation is not raced by focus restoration"
        )
        suite.check(
            focus.priorApplicationPID == nil,
            "completed Codex handoff clears stale restoration state"
        )

        _ = focus.apply(
            .userExpand(frontmostApplicationPID: editor),
            connApplicationPID: conn
        )
        suite.checkEqual(
            focus.apply(
                .userCollapse(reason: .outsideClick, frontmostApplicationPID: codex),
                connApplicationPID: conn
            ),
            .none,
            "outside click continues to preserve the newly focused application"
        )
        suite.check(
            focus.priorApplicationPID == nil,
            "outside click continues to consume stale restoration state"
        )

        _ = focus.apply(
            .userExpand(frontmostApplicationPID: editor),
            connApplicationPID: conn
        )
        suite.checkEqual(
            focus.apply(
                .userCollapse(reason: .escape, frontmostApplicationPID: conn),
                connApplicationPID: conn
            ),
            .restoreApplication(editor),
            "ordinary explicit dismissal still restores the prior application"
        )
    }

    private static func testDetailAwareGeometry(into suite: inout TestSuite) {
        let policy = ShellPanelGeometryPolicy()
        let display = externalDisplay()

        let legacyEmpty = policy.geometry(
            for: display,
            surface: .expanded,
            rowCount: 0
        )
        suite.checkEqual(
            legacyEmpty.frame.height,
            248,
            "detail opt-in preserves the existing empty expanded height"
        )

        let zeroRows = policy.geometry(
            for: display,
            surface: .expanded,
            rowCount: 0,
            showsSessionDetail: true
        )
        suite.checkEqual(zeroRows.frame.width, 600, "detail expansion uses the wider master-detail width")
        suite.checkEqual(zeroRows.frame.height, 416, "zero rows retain enough height for session detail")
        suite.checkEqual(zeroRows.visibleRowCount, 0, "zero-row detail reports no visible rows")

        let oneRow = policy.geometry(
            for: display,
            surface: .expanded,
            rowCount: 1,
            showsSessionDetail: true
        )
        suite.checkEqual(oneRow.frame.height, 416, "one row cannot collapse the detail body")
        suite.checkEqual(oneRow.visibleRowCount, 1, "one-row detail reports one visible row")

        let fiveRows = policy.geometry(
            for: display,
            surface: .expanded,
            rowCount: 5,
            showsSessionDetail: true
        )
        suite.checkEqual(fiveRows.frame.height, 425, "five rows use their larger row-driven body height")
        suite.checkEqual(fiveRows.visibleRowCount, 5, "five-row detail fills the viewport")

        let overflow = policy.geometry(
            for: display,
            surface: .expanded,
            rowCount: 20,
            showsSessionDetail: true
        )
        suite.checkEqual(overflow.frame.height, fiveRows.frame.height, "overflow cannot grow the panel beyond five rows")
        suite.checkEqual(overflow.visibleRowCount, 5, "overflow remains capped at five visible rows")

        let repaired = policy.geometry(
            for: display,
            surface: .expanded,
            rowCount: 0,
            showsIntegrationRepair: true,
            showsSessionDetail: true
        )
        suite.checkEqual(repaired.frame.height, 492, "detail geometry reserves the integration diagnostic strip")
        suite.check(repaired.frame.height <= 520, "diagnostic detail remains inside the height ceiling")

        let repairedFiveRows = policy.geometry(
            for: display,
            surface: .expanded,
            rowCount: 5,
            showsIntegrationRepair: true,
            showsSessionDetail: true
        )
        suite.checkEqual(repairedFiveRows.frame.height, 501, "five rows and diagnostics fit without clipping")

        let largeText = policy.geometry(
            for: display,
            surface: .expanded,
            rowCount: 20,
            showsIntegrationRepair: true,
            showsSessionDetail: true,
            textScale: .init(1.5)
        )
        suite.checkEqual(largeText.frame.width, 640, "large text respects the hard width cap")
        suite.checkEqual(largeText.frame.height, 520, "large text respects the hard height cap")
        suite.checkEqual(largeText.visibleRowCount, 5, "large text preserves the logical row cap")
    }

    private static func testExpandedRowScrollingPolicy(into suite: inout TestSuite) {
        let mixed = ExpandedShellRowLayout(rows: [
            ShellSessionRow(id: "running-1", priority: .running),
            ShellSessionRow(id: "repair-1", priority: .integrationRepair),
            ShellSessionRow(id: "attention-1", priority: .attention),
            ShellSessionRow(id: "recent-1", priority: .recent),
            ShellSessionRow(id: "attention-2", priority: .attention),
            ShellSessionRow(id: "outcome-1", priority: .outcome),
        ])
        suite.checkEqual(
            mixed.initialViewportRows.map(\.id),
            ["attention-1", "attention-2", "repair-1", "outcome-1", "running-1"],
            "mixed layout preserves pinned priority and the five-row first viewport"
        )
        suite.check(!mixed.requiresUnifiedScrolling, "mixed layout keeps its pinned and ordinary scroll regions split")
        suite.check(mixed.requiresScrolling, "mixed layout remains scroll-reachable after the first five rows")

        let fivePinnedAndOrdinary = ExpandedShellRowLayout(rows:
            (1...5).map { ShellSessionRow(id: "attention-\($0)", priority: .attention) }
                + [ShellSessionRow(id: "running-1", priority: .running)]
        )
        suite.checkEqual(
            fivePinnedAndOrdinary.initialViewportRows.map(\.id),
            (1...5).map { "attention-\($0)" },
            "five pinned rows retain priority and fill the bounded viewport"
        )
        suite.check(
            fivePinnedAndOrdinary.requiresUnifiedScrolling,
            "an ordinary row after exactly five pinned rows shares one reachable scroll region"
        )
        suite.checkEqual(
            fivePinnedAndOrdinary.hiddenRowCount,
            1,
            "exactly five pinned rows do not weaken the five-row cap"
        )

        let pinnedOverflow = ExpandedShellRowLayout(rows:
            (1...6).map { ShellSessionRow(id: "attention-\($0)", priority: .attention) }
        )
        suite.check(pinnedOverflow.requiresUnifiedScrolling, "six pinned rows use the bounded unified scroll region")
        suite.checkEqual(pinnedOverflow.initialViewportRows.count, 5, "pinned overflow remains capped at five visible rows")
        suite.checkEqual(pinnedOverflow.hiddenRowCount, 1, "pinned overflow keeps every excess row scroll-reachable")
    }

    private static func externalDisplay() -> ShellDisplayDescriptor {
        ShellDisplayDescriptor(
            id: .init(rawValue: 2),
            persistentIdentifier: "phase4-external",
            localizedName: "Phase 4 External",
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1056),
            safeAreaInsets: .init(top: 24),
            isBuiltIn: false
        )
    }
}
