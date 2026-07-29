import CoreGraphics
import Foundation
import ConnAppCore
import ConnDomain

enum Phase115UIOverhaulTestCases {
    static func run(into suite: inout TestSuite) {
        testCompactShelfGeometry(into: &suite)
        testExpandedGraphiteTarget(into: &suite)
        testCompactShelfIdentity(into: &suite)
        testAcknowledgedNewChatPlaceholder(into: &suite)
        testReduceMotionPolicy(into: &suite)
        testExpandedContentTransitionPolicy(into: &suite)
        testSurfaceGeometryTransitionGeneration(into: &suite)
        testGraphiteChromePolicy(into: &suite)
        testTranscriptActivityDisclosurePolicy(into: &suite)
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
        let integrationID = IntegrationID(rawValue: "openai.codex")
        let requestID = AttentionRequestID(rawValue: "phase-11.5-request")
        let authority = AttentionResponseAuthority(
            requestID: requestID,
            generation: .init(
                instanceID: UUID(
                    uuidString: "11500000-0000-4000-8000-000000000001"
                )!,
                ordinal: 115
            )
        )
        let session = ConnSessionID(
            integrationID: integrationID,
            upstreamID: .init(rawValue: "phase-11.5-session")
        )
        let run = RunID(rawValue: "phase-11.5-run")
        let shelf = ShellCompactShelfPresentation(
            id: "phase-11.5-shelf",
            mode: .approval,
            verb: "Approval needed",
            detail: "Exact request",
            responseAuthority: authority,
            sessionID: session,
            runID: run,
            approvalChoices: [.approve, .approveForSession, .deny]
        )

        suite.checkEqual(
            shelf.responseAuthority,
            authority,
            "compact shelf preserves exact response authority"
        )
        suite.checkEqual(
            shelf.sessionID,
            session,
            "compact shelf preserves exact Session identity"
        )
        suite.checkEqual(shelf.runID, run, "compact shelf preserves exact Run identity")
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
        let integrationID = IntegrationID(rawValue: "openai.codex")
        let sessionID = ConnSessionID(
            integrationID: integrationID,
            upstreamID: .init(rawValue: "phase-11.5-new-session")
        )
        let session = ConnSession(
            id: sessionID,
            title: "New Session",
            workspace: .init(canonicalPath: "/tmp/phase-11.5"),
            origin: .conn,
            retention: .ephemeral,
            status: .idle,
            updatedAt: Date(timeIntervalSince1970: 1_785_000_000)
        )
        let placeholder = ConnSessionPresentation(
            state: .init(
                session: session,
                integration: .init(
                    id: integrationID,
                    harnessID: .init(rawValue: "codex"),
                    displayName: "Codex"
                ),
                freshness: .live,
                actionAvailability: .init(available: [], unavailable: [:]),
                attention: []
            ),
            title: "New Session",
            workspaceLabel: "/tmp/phase-11.5",
            statusLabel: "Idle",
            visualState: .idle,
            tone: .neutral,
            harness: .init(harnessID: .init(rawValue: "codex"), label: "Codex"),
            activities: [],
            attention: []
        )

        suite.checkEqual(
            placeholder.id,
            sessionID,
            "new-Session placeholder preserves the exact acknowledged identity"
        )
        suite.checkEqual(
            placeholder.title,
            "New Session",
            "new-Session placeholder opens the empty activity state"
        )
        suite.checkEqual(
            placeholder.activities,
            [],
            "new-Session placeholder never invents activity"
        )
        suite.checkEqual(
            placeholder.workspaceLabel,
            "/tmp/phase-11.5",
            "new-Session placeholder shows the configured Workspace"
        )
        suite.checkEqual(
            placeholder.state.freshness,
            .live,
            "exact create acknowledgement is represented as current runtime-only state"
        )
    }

    private static func testReduceMotionPolicy(into suite: inout TestSuite) {
        let standard = ShellMotionPolicy.presentation(reduceMotion: false)
        suite.checkEqual(standard.style, .unfurlSpring, "standard motion uses the Graphite unfurl spring")
        suite.check(standard.geometryDuration > 0, "standard motion animates panel geometry")
        suite.check(standard.contentDelay > 0, "standard motion staggers content after geometry begins")
        suite.checkEqual(ShellMotionPolicy.springProgress(0), 0, "unfurl spring begins at the current geometry")
        suite.check(
            ShellMotionPolicy.springProgress(0.2) < 0.6,
            "unfurl spring does not present a full-size empty panel near the start"
        )
        suite.check(
            ShellMotionPolicy.springProgress(0.5) < 0.95,
            "unfurl spring keeps visible geometry moving through the content delay"
        )
        suite.check(
            ShellMotionPolicy.springProgress(0.9) > 1,
            "unfurl spring retains a small late overshoot instead of becoming a cubic ease"
        )
        suite.check(
            abs(ShellMotionPolicy.springProgress(0.999) - ShellMotionPolicy.springProgress(1)) < 0.001,
            "unfurl spring approaches its destination continuously without a final-frame snap"
        )
        suite.checkEqual(ShellMotionPolicy.springProgress(1), 1, "unfurl spring settles exactly on its destination")
        suite.checkEqual(
            ShellMotionPolicy.linearProgress(elapsed: -0.1, duration: 0.5),
            0,
            "elapsed-time motion clamps callbacks before the animation start"
        )
        suite.checkEqual(
            ShellMotionPolicy.linearProgress(elapsed: 0.25, duration: 0.5),
            0.5,
            "elapsed-time motion derives progress from the monotonic clock"
        )
        suite.checkEqual(
            ShellMotionPolicy.linearProgress(elapsed: 0.75, duration: 0.5),
            1,
            "a delayed callback skips stale frames and completes on time"
        )
        suite.check(
            !ShellMotionPolicy.shouldRevealExpandedContent(
                linearProgress: ShellMotionPolicy.expandedContentRevealLinearProgress - 0.01,
                hasPendingAnimatedGeometryRefresh: false
            ),
            "expanded content stays unmounted before the reveal threshold"
        )
        suite.check(
            ShellMotionPolicy.shouldRevealExpandedContent(
                linearProgress: ShellMotionPolicy.expandedContentRevealLinearProgress,
                hasPendingAnimatedGeometryRefresh: false
            ),
            "expanded content begins fading at the reveal threshold"
        )
        suite.check(
            !ShellMotionPolicy.shouldRevealExpandedContent(
                linearProgress: 1,
                hasPendingAnimatedGeometryRefresh: true
            ),
            "a queued animated geometry correction defers content until the final frame settles"
        )
        suite.check(
            ShellMotionPolicy.shouldRevealExpandedContent(
                linearProgress: 1,
                hasPendingAnimatedGeometryRefresh: false
            ),
            "a passive geometry refresh does not recreate the post-expansion gap"
        )
        suite.check(
            ShellMotionPolicy.springProgress(
                ShellMotionPolicy.expandedContentRevealLinearProgress
            ) > 0.92,
            "the reveal threshold waits until the panel is substantially unfolded"
        )
        suite.check(
            (1 - ShellMotionPolicy.expandedContentRevealLinearProgress) * standard.geometryDuration
                > ShellMotionPolicy.expandedContentFadeDuration,
            "expanded content finishes fading in before panel geometry settles"
        )

        let reduced = ShellMotionPolicy.presentation(reduceMotion: true)
        suite.checkEqual(reduced.style, .fadeOnly, "Reduce Motion switches to fade-only presentation")
        suite.checkEqual(reduced.geometryDuration, 0, "Reduce Motion removes spatial panel animation")
        suite.checkEqual(reduced.contentDelay, 0, "Reduce Motion removes content staggering")
    }

    private static func testExpandedContentTransitionPolicy(into suite: inout TestSuite) {
        suite.check(
            !ShellExpandedContentPresentationPolicy.presentsExpandedContent(
                surface: .expanded,
                isRevealReady: false
            ),
            "expanded content stays unmounted while panel geometry changes"
        )
        suite.check(
            ShellExpandedContentPresentationPolicy.presentsExpandedContent(
                surface: .expanded,
                isRevealReady: true
            ),
            "expanded content mounts after panel geometry settles"
        )
        suite.check(
            !ShellExpandedContentPresentationPolicy.presentsExpandedContent(
                surface: .compact,
                isRevealReady: true
            ),
            "compact presentation never constructs expanded content"
        )
    }

    private static func testSurfaceGeometryTransitionGeneration(into suite: inout TestSuite) {
        var gate = ShellSurfaceGeometryTransitionGenerationGate()
        let expansion = gate.begin()
        suite.check(gate.isCurrent(expansion), "a new geometry transition owns its callbacks")

        let collapse = gate.begin()
        suite.check(
            !gate.isCurrent(expansion),
            "a superseding collapse invalidates queued expansion callbacks"
        )
        suite.check(gate.isCurrent(collapse), "the superseding transition remains current")

        gate.invalidate()
        suite.check(
            !gate.isCurrent(collapse),
            "an immediate surface update invalidates all queued transition callbacks"
        )
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
                visualState: .working
            ),
            "the newest activity group stays open while work is being generated"
        )
        suite.check(
            !ShellTranscriptActivityPolicy.shouldAutoExpand(
                isLatestActivity: true,
                hasFollowingUserFacingText: true,
                visualState: .working
            ),
            "the activity group collapses when its user-facing summary arrives"
        )
        suite.check(
            !ShellTranscriptActivityPolicy.shouldAutoExpand(
                isLatestActivity: false,
                hasFollowingUserFacingText: false,
                visualState: .working
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
        suite.checkEqual(
            Array(ShellTranscriptActivityPolicy.visibleSuffix(Array(0..<100))),
            Array(60..<100),
            "the transcript renders only its newest bounded activity suffix"
        )
        suite.check(
            !ShellTranscriptActivityPolicy.shouldRenderDetails(isExpanded: false)
                && ShellTranscriptActivityPolicy.shouldRenderDetails(isExpanded: true),
            "collapsed Runs do not construct hidden transcript detail rows"
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
