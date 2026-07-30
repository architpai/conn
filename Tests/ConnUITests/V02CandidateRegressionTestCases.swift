import AppKit
import CoreGraphics
import ConnAppCore
import ConnDomain
import ConnUI

enum V02CandidateRegressionTestCases {
    @MainActor
    static func run(into suite: inout TestSuite) async {
        let applicationMenu = ConnApplicationMenu.make()
        let editMenu = applicationMenu.item(withTitle: "Edit")?.submenu
        let copyItem = editMenu?.item(withTitle: "Copy")
        let pasteItem = editMenu?.item(withTitle: "Paste")
        suite.checkEqual(
            copyItem?.keyEquivalent,
            "c",
            "the app menu routes Command-C through the focused text responder"
        )
        suite.check(
            copyItem?.action == #selector(NSText.copy(_:)),
            "Copy uses the standard macOS responder action"
        )
        suite.checkEqual(
            pasteItem?.keyEquivalent,
            "v",
            "the app menu routes Command-V through the focused text responder"
        )
        suite.check(
            pasteItem?.action == #selector(NSText.paste(_:)),
            "Paste uses the standard macOS responder action"
        )

        let displayFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1512, height: 949)
        let builtIn = ConnPanelFramePolicy.decide(
            displayFrame: displayFrame,
            visibleFrame: visibleFrame,
            safeAreaTop: 32,
            isBuiltIn: true,
            expanded: true,
            compactShelfPreferredHeight: 34
        )
        suite.checkEqual(
            builtIn.placement,
            .physicalNotch,
            "a built-in display with a camera safe area is notch-anchored"
        )
        suite.checkEqual(
            builtIn.frame.maxY,
            displayFrame.maxY,
            "expanded Conn stays flush with the physical notch edge"
        )

        let external = ConnPanelFramePolicy.decide(
            displayFrame: displayFrame,
            visibleFrame: visibleFrame,
            safeAreaTop: 32,
            isBuiltIn: false,
            expanded: false,
            compactShelfPreferredHeight: 34
        )
        suite.checkEqual(
            external.placement,
            .externalCapsule,
            "an external display cannot borrow built-in notch geometry"
        )
        suite.checkEqual(
            external.frame.maxY,
            displayFrame.maxY,
            "external displays anchor Conn directly to the physical screen edge"
        )
        suite.checkEqual(
            ConnPanelFramePolicy.decide(
                displayFrame: displayFrame,
                visibleFrame: visibleFrame,
                safeAreaTop: 32,
                isBuiltIn: false,
                expanded: true,
                compactShelfPreferredHeight: 34
            ).frame.maxY,
            displayFrame.maxY,
            "expanded Conn remains flush on an external display too"
        )

        let compactNotification = ConnPanelFramePolicy.decide(
            displayFrame: displayFrame,
            visibleFrame: visibleFrame,
            safeAreaTop: 32,
            isBuiltIn: true,
            expanded: false,
            compactShelfPreferredHeight: 92
        )
        suite.checkEqual(
            compactNotification.frame.height,
            92,
            "the integrated notification shelf needs no inter-surface height allowance"
        )
        suite.checkEqual(
            compactNotification.frame.width,
            404,
            "the physical-notch compact surface preserves safe side wings"
        )
        suite.checkEqual(
            ConnCompactNotificationLayoutPolicy.contentWidth(
                placement: .physicalNotch
            ),
            ConnCompactHeaderLayoutPolicy.compactContentWidth(
                placement: .physicalNotch
            ),
            "the notification shelf remains exactly as wide as the collapsed header"
        )
        suite.checkEqual(
            ConnCompactNotificationLayoutPolicy.indicator(isFinal: false),
            .animatedWaveform,
            "an in-progress notification uses a moving waveform"
        )
        suite.checkEqual(
            ConnCompactNotificationLayoutPolicy.indicator(isFinal: true),
            .completion,
            "a final notification replaces the waveform with completion feedback"
        )
        suite.check(
            ConnCompactNotificationLayoutPolicy.usesStackedMessageHierarchy,
            "notification content places its title above the message paragraph"
        )
        suite.checkEqual(
            ConnCompactNotificationLayoutPolicy.messageLineLimit,
            2,
            "notification paragraphs keep the previous compact two-line balance"
        )
        suite.check(
            ConnCompactNotificationLayoutPolicy.rowHeight(
                messageTexts: [String(repeating: "Complete paragraph. ", count: 12)],
                placement: .externalCapsule
            ) > ConnCompactNotificationLayoutPolicy.rowHeight(
                messageTexts: ["Short update."],
                placement: .externalCapsule
            ),
            "the notification shelf grows only to its bounded paragraph preview"
        )
        let notchHeader = ConnCompactHeaderLayoutPolicy.presentation(
            surface: .compact,
            placement: .physicalNotch
        )
        suite.check(
            notchHeader.showsProductName,
            "the Conn wordmark remains visible in the physical-notch left wing"
        )
        suite.check(
            !notchHeader.showsIntegrationStatus,
            "compact integration status does not render behind the physical notch"
        )
        suite.checkEqual(
            notchHeader.minimumCenterGap,
            184,
            "the compact header reserves the measured physical-notch center"
        )
        let externalHeader = ConnCompactHeaderLayoutPolicy.presentation(
            surface: .compact,
            placement: .externalCapsule
        )
        suite.check(
            externalHeader.showsIntegrationStatus,
            "external capsules retain compact Integration status wording"
        )
        suite.checkEqual(
            external.frame.width,
            350,
            "external capsules retain their compact width"
        )
        suite.checkEqual(
            ConnTranscriptAlignmentPolicy.lane(for: .userMessage),
            .trailing,
            "User messages occupy the trailing conversation lane"
        )
        suite.checkEqual(
            ConnTranscriptAlignmentPolicy.contentLane(for: .userMessage),
            .leading,
            "User bubble text retains a stable leading reading edge"
        )
        suite.checkEqual(
            ConnTranscriptAlignmentPolicy.lane(for: .agentMessage),
            .leading,
            "Agent messages occupy the leading conversation lane"
        )
        suite.checkEqual(
            ConnTranscriptAlignmentPolicy.lane(for: .reasoning),
            .leading,
            "Agent reasoning remains grouped in the leading lane"
        )
        suite.checkEqual(
            ConnTranscriptPresentationPolicy.style(for: .userMessage),
            .outgoingBubble,
            "User messages use outgoing chat bubbles"
        )
        suite.checkEqual(
            ConnTranscriptPresentationPolicy.style(for: .agentMessage),
            .incomingBubble,
            "Agent messages use incoming chat bubbles"
        )
        suite.checkEqual(
            ConnTranscriptPresentationPolicy.style(for: .toolCall),
            .activityCard,
            "Tool activity remains visually distinct from speech"
        )
        suite.checkEqual(
            ConnCompositeModelControlPresentation.label(
                modelName: "GPT-5.6-Sol",
                reasoningName: "Medium",
                isLoading: false
            ),
            "GPT-5.6-Sol · Medium",
            "the compact composer control combines Model and Reasoning labels"
        )
        suite.checkEqual(
            ConnCompositeModelControlPresentation.label(
                modelName: nil,
                reasoningName: nil,
                isLoading: true
            ),
            "Loading models…",
            "the compact composer control exposes model-loading state"
        )
        suite.checkEqual(
            ConnMarkMotionPolicy.rotationDegrees(
                elapsed: 1.75,
                reduceMotion: false
            ),
            90,
            "the Conn mark completes one quarter of its orbit in 1.75 seconds"
        )
        suite.checkEqual(
            ConnMarkMotionPolicy.rotationDegrees(
                elapsed: 7,
                reduceMotion: false
            ),
            0,
            "the Conn mark completes one continuous orbit every seven seconds"
        )
        suite.checkEqual(
            ConnMarkMotionPolicy.rotationDegrees(
                elapsed: 3.5,
                reduceMotion: true
            ),
            0,
            "Reduce Motion keeps the Conn mark in its canonical static pose"
        )
        var sleepCount = 0
        var expiredIDs: [String] = []
        let expiryEvents = AsyncStream<String>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        var expiryIterator = expiryEvents.stream.makeAsyncIterator()
        let lifetime = ConnCompactNotificationLifetimeController { _ in
            sleepCount += 1
        }
        suite.check(
            lifetime.present(id: "notification-1", duration: 5) {
                expiredIDs.append($0)
                expiryEvents.continuation.yield($0)
            },
            "a new notification starts its lifetime"
        )
        suite.check(
            !lifetime.present(id: "notification-1", duration: 5) {
                expiredIDs.append($0)
            },
            "re-publishing the same notification does not reset its lifetime"
        )
        let expiredID = await expiryIterator.next()
        suite.checkEqual(sleepCount, 1, "one notification owns one expiry sleep")
        suite.checkEqual(
            expiredID,
            "notification-1",
            "the expiry callback explicitly signals test completion"
        )
        suite.checkEqual(
            expiredIDs,
            ["notification-1"],
            "a notification disappears when its lifetime elapses"
        )

        expiredIDs.removeAll()
        _ = lifetime.present(id: "notification-2", duration: 5) {
            expiredIDs.append($0)
        }
        lifetime.dismiss()
        await Task.yield()
        await Task.yield()
        suite.check(
            expiredIDs.isEmpty,
            "manual dismissal cancels the pending expiry callback"
        )

        do {
            let coordinator = try ConnIntegrationCoordinator(integrations: [])
            let model = ConnViewModel(coordinator: coordinator)
            let expansion = model.beginSurfaceGeometryTransition(to: .expanded)
            suite.check(
                !model.presentsExpandedContent,
                "expansion keeps the transcript unmounted while panel geometry changes"
            )
            model.completeSurfaceGeometryTransition(
                to: .expanded,
                generation: expansion
            )
            suite.check(
                model.presentsExpandedContent,
                "expanded transcript mounts only after panel geometry settles"
            )

            let staleExpansion = model.beginSurfaceGeometryTransition(to: .expanded)
            let collapse = model.beginSurfaceGeometryTransition(to: .compact)
            model.completeSurfaceGeometryTransition(
                to: .expanded,
                generation: staleExpansion
            )
            suite.check(
                !model.presentsExpandedContent,
                "a stale expansion completion cannot remount the transcript after collapse"
            )
            model.completeSurfaceGeometryTransition(
                to: .compact,
                generation: collapse
            )
        } catch {
            suite.recordUnexpected(
                error,
                context: "constructing transition regression model"
            )
        }

        do {
            let integration = NewSessionModelCountingIntegration()
            let coordinator = try ConnIntegrationCoordinator(
                integrations: [integration],
                enabledIntegrationIDs: []
            )
            let model = ConnViewModel(coordinator: coordinator)
            model.start()
            defer { model.stop() }
            for _ in 0..<100 where model.integrationError == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            suite.checkEqual(
                model.integrationError,
                "No integrations enabled",
                "registered but disabled providers produce the actionable empty state"
            )
            suite.check(
                model.integrations.isEmpty && model.sessions.isEmpty,
                "disabled providers expose neither inventory nor stale Session rows"
            )
        } catch {
            suite.recordUnexpected(
                error,
                context: "verifying the zero-provider presentation"
            )
        }

        do {
            let integration = NewSessionModelCountingIntegration()
            let coordinator = try ConnIntegrationCoordinator(
                integrations: [integration],
                retryDelay: .seconds(60)
            )
            let model = ConnViewModel(coordinator: coordinator)
            model.start()
            defer { model.stop() }

            for _ in 0..<100 where model.integrations.first?.state.freshness != .live {
                try await Task.sleep(for: .milliseconds(10))
            }
            model.beginNewSessionDraft()
            for _ in 0..<100 where await integration.modelRequestCount() == 0 {
                try await Task.sleep(for: .milliseconds(10))
            }
            suite.checkEqual(
                await integration.modelRequestCount(),
                1,
                "opening one New Session draft requests the model catalog exactly once"
            )
        } catch {
            suite.recordUnexpected(
                error,
                context: "verifying New Session model catalog request count"
            )
        }

        let draftIntegrationID = IntegrationID(rawValue: "builtin-codex")
        let createdSessionID = ConnSessionID(
            integrationID: draftIntegrationID,
            upstreamID: .init(rawValue: "created-thread")
        )
        var newSessionDraft = ConnNewSessionDraft()
        newSessionDraft.present(
            integrationID: draftIntegrationID,
            defaultWorkspace: "/tmp/default-workspace"
        )
        suite.check(
            newSessionDraft.isPresented
                && newSessionDraft.workspace == "/tmp/default-workspace",
            "New Session opens immediately in the configured default Workspace"
        )
        newSessionDraft.message = "Preserve this draft"
        newSessionDraft.hide()
        newSessionDraft.present(
            integrationID: draftIntegrationID,
            defaultWorkspace: "/tmp/changed-default"
        )
        suite.checkEqual(
            newSessionDraft.message,
            "Preserve this draft",
            "switching away and returning preserves the unsent draft"
        )
        suite.checkEqual(
            newSessionDraft.workspace,
            "/tmp/default-workspace",
            "a changed default does not silently mutate an existing draft"
        )
        newSessionDraft.markCreationAccepted(createdSessionID)
        suite.check(
            newSessionDraft.isAwaitingCreatedSession,
            "an accepted creation remains visible until its Session is projected"
        )
        suite.check(
            newSessionDraft.reconcile(availableSessionIDs: []) == nil,
            "unrelated projection updates do not dismiss the creating draft"
        )
        suite.checkEqual(
            newSessionDraft.reconcile(availableSessionIDs: [createdSessionID]),
            createdSessionID,
            "the draft resolves only when its exact created Session appears"
        )
        suite.check(
            !newSessionDraft.isPresented && newSessionDraft.message.isEmpty,
            "a projected created Session clears the local draft"
        )

        var unconfiguredDraft = ConnNewSessionDraft()
        unconfiguredDraft.present(
            integrationID: draftIntegrationID,
            defaultWorkspace: ""
        )
        suite.check(
            unconfiguredDraft.requiresDefaultWorkspace,
            "an unconfigured draft asks for a default Workspace without creating a Session"
        )
        unconfiguredDraft.applyDefaultWorkspaceIfNeeded("/tmp/configured")
        suite.checkEqual(
            unconfiguredDraft.workspace,
            "/tmp/configured",
            "one-time Workspace setup flows back into the still-empty draft"
        )
    }
}

private actor NewSessionModelCountingIntegration: ConnIntegration {
    nonisolated let descriptor = IntegrationDescriptor(
        id: .init(rawValue: "new-session-counting"),
        harnessID: .init(rawValue: "test-harness"),
        displayName: "Test Harness"
    )
    private var continuation: AsyncStream<IntegrationUpdate>.Continuation?
    private var modelRequests = 0

    func establishFeed() async throws(ConnIntegrationError) -> ConnIntegrationFeed {
        let pair = AsyncStream<IntegrationUpdate>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation = pair.continuation
        return .init(
            snapshot: .init(
                integration: descriptor,
                generation: .init(
                    instanceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                    ordinal: 1
                ),
                throughSequence: 0,
                inventoryAuthority: .complete,
                capabilities: .init(canMonitor: true, actions: [.createSession]),
                sessions: [],
                observedAt: Date()
            ),
            updates: pair.stream
        )
    }

    func sessionModels(
        for sessionID: ConnSessionID?
    ) async -> ConnSessionModelCatalogResult {
        modelRequests += 1
        let effort = ConnReasoningEffortOption(
            id: .init(rawValue: "medium"),
            displayName: "Medium"
        )
        return .init(
            outcome: .available,
            catalog: .init(
                integrationID: descriptor.id,
                options: [.init(
                    id: .init(rawValue: "test-model"),
                    displayName: "Test Model",
                    isDefault: true,
                    reasoningEfforts: [effort],
                    defaultReasoningEffortID: effort.id
                )]
            )
        )
    }

    func perform(_ action: ConnAction) async -> ConnActionOutcome {
        .init(
            integrationID: descriptor.id,
            action: action.kind,
            kind: .unavailable
        )
    }

    func disconnect() {
        continuation?.finish()
        continuation = nil
    }

    func modelRequestCount() -> Int {
        modelRequests
    }
}
