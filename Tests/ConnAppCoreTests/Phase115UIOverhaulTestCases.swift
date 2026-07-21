import CoreGraphics
import Foundation
import ConnAppCore
import ConnAppServerAdapter
import ConnDomain

enum Phase115UIOverhaulTestCases {
    static func run(into suite: inout TestSuite) {
        testCompactShelfGeometry(into: &suite)
        testExpandedGraphiteTarget(into: &suite)
        testCompactShelfIdentity(into: &suite)
        testAcknowledgedNewChatPlaceholder(into: &suite)
        testRequiredNewChatModelSelection(into: &suite)
        testRunningThreadModelLabel(into: &suite)
        testRunningThreadModelResumeAuthority(into: &suite)
        testExpandedIdleThreadRequestsMissingModelAuthority(into: &suite)
        testNewChatUsesDefaultWorkspace(into: &suite)
        testReduceMotionPolicy(into: &suite)
        testGraphiteChromePolicy(into: &suite)
        testTranscriptActivityDisclosurePolicy(into: &suite)
        testSharedDesktopLabsViewport(into: &suite)
    }

    private static func testSharedDesktopLabsViewport(into suite: inout TestSuite) {
        suite.checkEqual(
            SharedDesktopLabsLayoutPolicy.viewportHeight(availableHeight: 900),
            560,
            "Labs uses its preferred height on a roomy display"
        )
        suite.checkEqual(
            SharedDesktopLabsLayoutPolicy.viewportHeight(availableHeight: 576),
            504,
            "Labs leaves enough screen clearance on the reported compact display"
        )
        suite.checkEqual(
            SharedDesktopLabsLayoutPolicy.viewportHeight(availableHeight: 400),
            360,
            "Labs retains a usable minimum scroll viewport"
        )
    }

    private static func testRunningThreadModelLabel(into suite: inout TestSuite) {
        let options = [AppServerNewThreadModelOption(
            id: "gpt-5.4-high",
            model: "gpt-5.4",
            displayName: "GPT-5.4",
            detail: "General-purpose model",
            isDefault: true
        )]
        suite.checkEqual(
            AppServerThreadModelLabelPolicy.label(
                selection: .init(model: "gpt-5.4", reasoningEffort: "high"),
                options: options
            ),
            "GPT-5.4 · High reasoning",
            "a running thread names its authoritative model and reasoning effort"
        )
        suite.checkEqual(
            AppServerThreadModelLabelPolicy.label(selection: nil, options: options),
            "Loading model…",
            "missing live metadata never masquerades as a previous-model choice"
        )
    }

    private static func testRunningThreadModelResumeAuthority(into suite: inout TestSuite) {
        let selection = AppServerMonitoringRuntime.threadModelSelection(from: .object([
            "model": .string("gpt-5.4"),
            "reasoningEffort": .string("xhigh"),
            "thread": .object(["id": .string("running-thread")]),
        ]))
        suite.checkEqual(
            selection,
            .init(model: "gpt-5.4", reasoningEffort: "xhigh"),
            "the correlated resume response supplies the running thread's model authority"
        )
        suite.checkEqual(
            AppServerMonitoringRuntime.threadModelSelection(from: .object([
                "model": .string("gpt-5.4\nspoofed"),
                "reasoningEffort": .string("high"),
            ])),
            nil,
            "unsafe model labels are rejected instead of entering presentation state"
        )
    }

    private static func testExpandedIdleThreadRequestsMissingModelAuthority(
        into suite: inout TestSuite
    ) {
        let threadID = AppServerThreadID(rawValue: "idle-thread")
        suite.check(
            AppServerThreadModelQualificationPolicy.shouldRequestForExpandedPresentation(
                selectedThreadID: threadID,
                knownSelections: [:]
            ),
            "expanding an auto-selected idle thread requests its missing model authority"
        )
        suite.check(
            !AppServerThreadModelQualificationPolicy.shouldRequestForExpandedPresentation(
                selectedThreadID: threadID,
                knownSelections: [
                    threadID: .init(model: "gpt-5.4", reasoningEffort: "high"),
                ]
            ),
            "expansion does not resume a thread whose model authority is already known"
        )
        suite.check(
            !AppServerThreadModelQualificationPolicy.shouldRequestForExpandedPresentation(
                selectedThreadID: nil,
                knownSelections: [:]
            ),
            "expansion without a selected thread sends no qualification request"
        )
    }

    private static func testCompactShelfGeometry(into suite: inout TestSuite) {
        let policy = ShellPanelGeometryPolicy(configuration: graphiteGeometryConfiguration)
        let physicalNotch = display(
            id: 115,
            name: "Physical notch",
            safeTop: 40,
            isBuiltIn: true
        )
        let external = display(
            id: 116,
            name: "External display",
            safeTop: 24,
            isBuiltIn: false
        )

        for target in [physicalNotch, external] {
            let compact = policy.geometry(
                for: target,
                surface: .compact,
                rowCount: 0,
                showsCompactShelf: false
            )
            let withShelf = policy.geometry(
                for: target,
                surface: .compact,
                rowCount: 0,
                showsCompactShelf: true
            )
            let expectedCompactHeight: CGFloat = target.hasPhysicalNotch ? 40 : 34

            suite.checkEqual(
                compact.frame.height,
                expectedCompactHeight,
                "compact geometry without a shelf retains the bar height on \(target.localizedName)"
            )
            suite.checkEqual(
                withShelf.frame.height - compact.frame.height,
                36,
                "compact shelf adds exactly 36 points beneath the bar on \(target.localizedName)"
            )
            suite.checkEqual(
                withShelf.frame.maxY,
                compact.frame.maxY,
                "compact shelf unfolds below the anchored bar on \(target.localizedName)"
            )

            let withTallShelf = policy.geometry(
                for: target,
                surface: .compact,
                rowCount: 0,
                showsCompactShelf: true,
                compactShelfHeight: 112
            )
            suite.checkEqual(
                withTallShelf.frame.height - compact.frame.height,
                112,
                "multi-message shelf receives its full requested height on \(target.localizedName)"
            )
            suite.checkEqual(
                withTallShelf.frame.maxY,
                compact.frame.maxY,
                "multi-message shelf keeps the constant bar top-anchored on \(target.localizedName)"
            )
        }
    }

    private static func testExpandedGraphiteTarget(into suite: inout TestSuite) {
        let geometry = ShellPanelGeometryPolicy(configuration: graphiteGeometryConfiguration).geometry(
            for: display(id: 117, name: "Graphite target", safeTop: 0, isBuiltIn: false),
            surface: .expanded,
            rowCount: 15,
            showsSessionDetail: true
        )

        suite.checkEqual(
            geometry.frame.size,
            CGSize(width: 720, height: 460),
            "expanded Graphite workspace targets exactly 720 by 460 points"
        )
    }

    private static func testCompactShelfIdentity(into suite: inout TestSuite) {
        let connection = AppServerConnectionIdentity(
            instanceID: UUID(uuidString: "11500000-0000-4000-8000-000000000001")!,
            generation: 115
        )
        let request = AppServerScopedRequestID(
            connection: connection,
            requestID: .string("phase-11.5-request")
        )
        let thread = AppServerThreadID(rawValue: "phase-11.5-thread")
        let turn = AppServerTurnID(rawValue: "phase-11.5-turn")
        let shelf = ShellCompactShelfPresentation(
            id: "phase-11.5-shelf",
            mode: .approval,
            verb: "Approval needed",
            detail: "Exact request",
            requestID: request,
            threadID: thread,
            turnID: turn,
            approvalChoices: [.approve, .approveForSession, .deny]
        )

        suite.checkEqual(shelf.requestID, request, "compact shelf preserves exact request authority")
        suite.checkEqual(shelf.threadID, thread, "compact shelf preserves exact thread identity")
        suite.checkEqual(shelf.turnID, turn, "compact shelf preserves exact turn identity")
        suite.checkEqual(
            shelf.approvalChoices,
            [.approve, .approveForSession, .deny],
            "compact approval shelf preserves every displayed response choice in wire-safe order"
        )
        suite.checkEqual(
            ShellCompactApprovalPolicy.visibleChoices(
                from: [.cancel, .deny, .approveForSession, .approve]
            ),
            [.approve, .approveForSession, .deny],
            "compact approval policy presents supported actions deterministically and omits cancel"
        )
        suite.checkEqual(
            ShellCompactApprovalPolicy.visibleChoices(from: [.approve, .deny]),
            [.approve, .deny],
            "legacy two-choice approvals remain compact-actionable"
        )
    }

    private static func testAcknowledgedNewChatPlaceholder(into suite: inout TestSuite) {
        let threadID = AppServerThreadID(rawValue: "phase-11.5-new-chat")
        let placeholder = AppServerThreadPresentation(
            newlyCreatedThreadID: threadID,
            workingDirectory: "/tmp/phase-11.5",
            now: Date(timeIntervalSince1970: 1_785_000_000)
        )

        suite.checkEqual(placeholder.threadID, threadID, "new-chat placeholder preserves the exact acknowledged thread")
        suite.checkEqual(placeholder.title, "New chat", "new-chat placeholder opens the empty transcript state")
        suite.checkEqual(placeholder.timeline, [], "new-chat placeholder never invents conversation content")
        suite.checkEqual(placeholder.workingDirectoryLabel, "/tmp/phase-11.5", "new-chat placeholder shows the configured workspace")
        suite.checkEqual(placeholder.freshness, .live, "exact thread/start acknowledgement is represented as current runtime-only state")
    }

    private static func testRequiredNewChatModelSelection(into suite: inout TestSuite) {
        let options = [
            AppServerNewThreadModelOption(
                id: "default-id",
                model: "gpt-default",
                displayName: "Default",
                detail: "",
                isDefault: true
            ),
            AppServerNewThreadModelOption(
                id: "remembered-id",
                model: "gpt-remembered",
                displayName: "Remembered",
                detail: "",
                isDefault: false
            ),
        ]
        let remembered = AppServerNewThreadModelSelectionPolicy.resolve(
            options: options,
            currentSelectionID: nil,
            preferredSelectionID: "remembered-id"
        )
        suite.checkEqual(
            remembered.selectedID,
            "remembered-id",
            "new chat restores the last explicitly selected available model"
        )
        suite.check(
            !remembered.preferredModelIsUnavailable,
            "an available remembered model needs no fallback warning"
        )

        let fallback = AppServerNewThreadModelSelectionPolicy.resolve(
            options: options,
            currentSelectionID: nil,
            preferredSelectionID: "retired-id"
        )
        suite.checkEqual(
            fallback.selectedID,
            "default-id",
            "an unavailable remembered model falls back to the current server default"
        )
        suite.check(
            fallback.preferredModelIsUnavailable,
            "fallback reports that the remembered model needs review"
        )

        let current = AppServerNewThreadModelSelectionPolicy.resolve(
            options: options,
            currentSelectionID: "default-id",
            preferredSelectionID: "remembered-id"
        )
        suite.checkEqual(
            current.selectedID,
            "default-id",
            "a visible in-progress choice is never overwritten by preference restoration"
        )
    }

    private static func testNewChatUsesDefaultWorkspace(into suite: inout TestSuite) {
        suite.checkEqual(
            AppServerNewChatWorkspacePolicy.resolveDefaultWorkspace("  /tmp/../tmp  "),
            "/tmp",
            "new chat standardizes the configured default workspace without prompting"
        )
        suite.checkEqual(
            AppServerNewChatWorkspacePolicy.resolveDefaultWorkspace("relative/project"),
            "relative/project",
            "invalid relative defaults remain invalid for submit-time validation"
        )
        suite.checkEqual(
            AppServerNewChatWorkspacePolicy.resolveDefaultWorkspace("   "),
            "",
            "an empty default is never rewritten to the process working directory"
        )
    }

    private static func testReduceMotionPolicy(into suite: inout TestSuite) {
        let standard = ShellMotionPolicy.presentation(reduceMotion: false)
        suite.checkEqual(standard.style, .unfurlSpring, "standard motion uses the Graphite unfurl spring")
        suite.check(standard.geometryDuration > 0, "standard motion animates panel geometry")
        suite.check(standard.contentDelay > 0, "standard motion staggers content after geometry begins")
        suite.checkEqual(ShellMotionPolicy.springProgress(0), 0, "unfurl spring begins at the current geometry")
        suite.check(
            ShellMotionPolicy.springProgress(0.5) > 1,
            "unfurl spring has a real damped overshoot instead of a cubic ease label"
        )
        suite.checkEqual(ShellMotionPolicy.springProgress(1), 1, "unfurl spring settles exactly on its destination")

        let reduced = ShellMotionPolicy.presentation(reduceMotion: true)
        suite.checkEqual(reduced.style, .fadeOnly, "Reduce Motion switches to fade-only presentation")
        suite.checkEqual(reduced.geometryDuration, 0, "Reduce Motion removes spatial panel animation")
        suite.checkEqual(reduced.contentDelay, 0, "Reduce Motion removes content staggering")
    }

    private static func testGraphiteChromePolicy(into suite: inout TestSuite) {
        suite.check(
            ShellGraphiteChromePolicy.cornerRadius(for: .compact) > 100,
            "compact shell uses a fully pill-shaped continuous corner radius"
        )
        suite.checkEqual(
            ShellGraphiteChromePolicy.cornerRadius(for: .expanded),
            24,
            "expanded shell rounds its top corners with the Graphite radius"
        )
        suite.checkEqual(
            ShellGraphiteChromePolicy.cornerRadius(
                for: .compact,
                showsCompactShelf: true
            ),
            17,
            "an unfolded shelf uses bounded corners so top-bar controls are not clipped"
        )
        suite.checkEqual(
            ShellGraphiteChromePolicy.connMarkOrbitDegrees(elapsed: 0, reduceMotion: false),
            0,
            "Conn mark orbit begins at zero degrees"
        )
        suite.checkEqual(
            ShellGraphiteChromePolicy.connMarkOrbitDegrees(elapsed: 1.6, reduceMotion: false),
            180,
            "Conn mark dots move halfway around the inner orbit at half a cycle"
        )
        suite.checkEqual(
            ShellGraphiteChromePolicy.connMarkOrbitDegrees(elapsed: 1.6, reduceMotion: true),
            0,
            "Reduce Motion freezes the Conn mark orbit"
        )
    }

    private static func testTranscriptActivityDisclosurePolicy(
        into suite: inout TestSuite
    ) {
        let beforePlan = ShellTranscriptActivityPolicy.segmentID(
            turnID: "turn",
            precedingBoundaryID: nil
        )
        let afterPlan = ShellTranscriptActivityPolicy.segmentID(
            turnID: "turn",
            precedingBoundaryID: "plan-item"
        )
        suite.check(
            beforePlan != afterPlan,
            "same-turn activity groups separated by a plan receive distinct stable identities"
        )
        suite.check(
            ShellTranscriptActivityPolicy.segmentID(
                turnID: "a:b",
                precedingBoundaryID: "c"
            ) != ShellTranscriptActivityPolicy.segmentID(
                turnID: "a",
                precedingBoundaryID: "b:c"
            ),
            "opaque IDs with separators cannot collide in activity segment identity"
        )
        suite.check(
            ShellTranscriptActivityPolicy.segmentID(
                turnID: nil,
                precedingBoundaryID: nil
            ) != ShellTranscriptActivityPolicy.segmentID(
                turnID: "unknown",
                precedingBoundaryID: "start"
            ),
            "nil activity anchors cannot collide with literal upstream IDs"
        )
        suite.check(
            ShellTranscriptActivityPolicy.shouldAutoExpand(
                isLatestActivity: true,
                hasFollowingUserFacingText: false,
                visualState: .running
            ),
            "the newest activity group stays open while work is being generated"
        )
        suite.check(
            !ShellTranscriptActivityPolicy.shouldAutoExpand(
                isLatestActivity: true,
                hasFollowingUserFacingText: true,
                visualState: .running
            ),
            "the activity group collapses when its user-facing summary arrives"
        )
        suite.check(
            !ShellTranscriptActivityPolicy.shouldAutoExpand(
                isLatestActivity: false,
                hasFollowingUserFacingText: false,
                visualState: .running
            ),
            "older activity groups remain collapsed while a newer group runs"
        )
        suite.check(
            !ShellTranscriptActivityPolicy.shouldAutoExpand(
                isLatestActivity: true,
                hasFollowingUserFacingText: false,
                visualState: .idle
            ),
            "idle historical activity remains collapsed"
        )
        suite.checkEqual(
            ShellTranscriptActivityPolicy.maximumVisibleEntryCount,
            40,
            "the eagerly laid out transcript remains strictly bounded"
        )
        suite.check(
            ShellTranscriptActivityPolicy.expansionState(
                stored: nil,
                autoExpand: true
            ),
            "a new live activity group starts expanded"
        )
        suite.check(
            !ShellTranscriptActivityPolicy.expansionState(
                stored: false,
                autoExpand: true
            ),
            "an explicit user collapse wins over automatic expansion"
        )
        suite.checkEqual(
            ShellTranscriptActivityPolicy.expansionUpdate(
                stored: false,
                requested: false
            ),
            nil,
            "an unchanged disclosure request does not mutate view state"
        )
        suite.checkEqual(
            ShellTranscriptActivityPolicy.expansionUpdate(
                stored: nil,
                requested: false
            ),
            false,
            "the first explicit disclosure choice is persisted"
        )
        let firstTail = ShellTranscriptActivityPolicy.autoScrollKey(
            threadID: "thread-a",
            tailID: "entry-1",
            tailRevision: "complete:hello"
        )
        suite.check(
            ShellTranscriptActivityPolicy.shouldAutoScroll(
                previousKey: nil,
                nextKey: firstTail
            ),
            "the initial transcript tail scrolls into view"
        )
        suite.check(
            !ShellTranscriptActivityPolicy.shouldAutoScroll(
                previousKey: firstTail,
                nextKey: firstTail
            ),
            "re-rendering the same transcript tail cannot trigger another scroll"
        )
        suite.check(
            ShellTranscriptActivityPolicy.shouldAutoScroll(
                previousKey: firstTail,
                nextKey: ShellTranscriptActivityPolicy.autoScrollKey(
                    threadID: "thread-a",
                    tailID: "entry-2",
                    tailRevision: "started:"
                )
            ),
            "a genuinely new transcript tail scrolls into view"
        )
        suite.check(
            ShellTranscriptActivityPolicy.shouldAutoScroll(
                previousKey: firstTail,
                nextKey: ShellTranscriptActivityPolicy.autoScrollKey(
                    threadID: "thread-b",
                    tailID: "entry-1",
                    tailRevision: "complete:hello"
                )
            ),
            "switching threads scrolls even when their tail IDs match"
        )
        suite.check(
            ShellTranscriptActivityPolicy.shouldAutoScroll(
                previousKey: firstTail,
                nextKey: ShellTranscriptActivityPolicy.autoScrollKey(
                    threadID: "thread-a",
                    tailID: "entry-1",
                    tailRevision: "complete:hello world"
                )
            ),
            "new content in the same tail entry scrolls into view"
        )
    }

    private static let graphiteGeometryConfiguration = ShellPanelGeometryConfiguration(
        compactSize: .init(width: 404, height: 34),
        compactShelfHeight: 36,
        expandedWidth: 720,
        maximumExpandedWidth: 720,
        maximumExpandedHeight: 460,
        expandedChromeHeight: 116,
        expandedDetailBodyMinimumHeight: 344,
        integrationRepairHeight: 44
    )

    private static func display(
        id: UInt32,
        name: String,
        safeTop: CGFloat,
        isBuiltIn: Bool
    ) -> ShellDisplayDescriptor {
        ShellDisplayDescriptor(
            id: .init(rawValue: id),
            persistentIdentifier: "phase-11.5-\(id)",
            localizedName: name,
            frame: .init(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: .init(x: 0, y: 0, width: 1_440, height: 860),
            safeAreaInsets: .init(top: safeTop),
            isBuiltIn: isBuiltIn
        )
    }
}
