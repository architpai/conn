import AppKit
import CoreGraphics
import Foundation
import QuartzCore
import ConnAppCore
import SwiftUI

@MainActor
final class ConnPanel: NSPanel {
    var onCancel: (() -> Void)?
    private var lastCancelEventNumber: Int?
    private var lastCancelEventTimestamp: TimeInterval = -.infinity

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        let event = NSApp.currentEvent
        let timestamp = event?.timestamp ?? ProcessInfo.processInfo.systemUptime
        // AppKit can route one Escape key press through both the panel and its
        // hosted SwiftUI responder chain. Treat that burst as one semantic
        // collapse request.
        if let event, event.eventNumber == lastCancelEventNumber,
           timestamp == lastCancelEventTimestamp {
            return
        }
        lastCancelEventNumber = event?.eventNumber
        lastCancelEventTimestamp = timestamp
        onCancel?()
    }
}

@MainActor
final class ShellQuestionInputFocusCoordinator {
    private(set) var isFocused = false
    private var dismissAction: (() -> Void)?

    func installDismissAction(_ action: @escaping () -> Void) {
        dismissAction = action
    }

    func updateFocused(_ focused: Bool) {
        isFocused = focused
    }

    func clear() {
        isFocused = false
        dismissAction = nil
    }

    @discardableResult
    func dismissFocusedInput() -> Bool {
        guard isFocused else { return false }
        isFocused = false
        dismissAction?()
        return true
    }
}

@MainActor
final class ConnPanelController {
    private enum PreferenceKey {
        static let selectedDisplay = "selectedDisplay.v1"
    }

    private let model: ConnViewModel
    private let panel: ConnPanel
    private let questionInputFocus = ShellQuestionInputFocusCoordinator()
    private let geometryPolicy = ShellPanelGeometryPolicy(configuration: .init(
        compactSize: .init(width: 404, height: 34),
        expandedWidth: 720,
        maximumExpandedWidth: 720,
        maximumExpandedHeight: 460,
        expandedChromeHeight: 116,
        expandedDetailBodyMinimumHeight: 344,
        integrationRepairHeight: 44
    ))
    private var lifecycle = ShellLifecycleState()
    private var focus = ShellFocusState()
    private var selectedDisplay: ShellDisplayDescriptor?
    private var persistedSelection: PersistedDisplaySelection
    private var geometryTransitionInFlight = false
    private var panelAnimationTask: Task<Void, Never>?
    private var pendingGeometryRefresh = false
    private var pendingGeometryRefreshShouldAnimate = false
    private var pendingGeometryCompletions: [() -> Void] = []
    // AppKit owns this opaque process-local token. Creation, use, and teardown
    // are main-thread confined even though Swift imports the token as `Any`.
    nonisolated(unsafe) private var localEscapeMonitor: Any?
    nonisolated(unsafe) private var globalOutsideClickMonitor: Any?
    nonisolated(unsafe) private var resignKeyObserver: NSObjectProtocol?
    private(set) var canRecoverFromHiddenState = false

    init(model: ConnViewModel) {
        self.model = model
        persistedSelection = Self.loadDisplaySelection()
        panel = ConnPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configurePanel()
        let hostingView = NSHostingView(rootView: ConnSurfaceView(
            model: model,
            questionInputFocus: questionInputFocus
        ))
        // The panel's pure geometry is authoritative. NSHostingView's default
        // intrinsic/min/max sizing propagation can otherwise resize a window
        // to the ScrollView's effectively unbounded expanded fitting height.
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        panel.onCancel = { [weak self] in self?.stepDownForEscape() }
        installLocalEscapeMonitor()
        globalOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.lifecycle.surface == .expanded,
                      !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.collapse(reason: .outsideClick)
            }
        }
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.lifecycle.surface == .expanded,
                      !self.model.showsSettings,
                      !self.model.showsSharedDesktopLabs else { return }
                self.collapse(reason: .outsideClick)
            }
        }

        model.onToggleExpansion = { [weak self] in self?.toggleExpansion() }
        model.onCollapse = { [weak self] in self?.collapse(reason: .userToggle) }
        model.onRequestExpansion = { [weak self] in self?.expand() }
        model.onCompactShelfVisibilityChanged = { [weak self] _ in
            self?.applyGeometry(animated: true)
        }
        model.onPausePresentation = { [weak self] in self?.pauseAndHide() }
        model.onHidePresentation = { [weak self] in self?.hideOnly() }
        model.onSelectDisplay = { [weak self] id in self?.selectDisplay(id: id) }
        model.onOpenCodex = { [weak self] token in self?.openCodex(token: token) }

        refreshDisplays(reconfigure: false)
        applyGeometry()
        panel.orderFrontRegardless()
    }

    deinit {
        panelAnimationTask?.cancel()
        if let localEscapeMonitor {
            NSEvent.removeMonitor(localEscapeMonitor)
        }
        if let globalOutsideClickMonitor {
            NSEvent.removeMonitor(globalOutsideClickMonitor)
        }
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
        }
    }

    func setGlobalToggleAvailable(_ available: Bool) {
        canRecoverFromHiddenState = available
    }

    func publishPassiveUpdate() {
        lifecycle.apply(.passiveUpdate)
        _ = focus.apply(.passiveUpdate, connApplicationPID: ownPID)
        applyGeometry()
        guard lifecycle.visibility == .visible else { return }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func toggleExpansion() {
        guard !geometryTransitionInFlight else { return }
        switch ShellBarTogglePolicy.action(for: lifecycle) {
        case .resumeAndExpand:
            lifecycle.apply(.resumeAndShow)
            model.isPresentationPaused = false
            expand()
        case .expand:
            expand()
        case .collapse:
            collapse(reason: .userToggle)
        }
    }

    func handleApplicationLifecycle(_ state: ShellApplicationLifecycleState) {
        lifecycle.apply(.applicationLifecycleChanged(state))
        model.setSurfaceState(lifecycle.surface)
        if lifecycle.visibility == .hidden {
            panel.orderOut(nil)
        } else {
            applyGeometry()
            panel.orderFrontRegardless()
        }
    }

    func refreshDisplays(reconfigure _: Bool = true) {
        let displays = NSScreen.screens.compactMap(Self.describe)
        let mainID = NSScreen.main.flatMap(Self.displayID).map(ShellDisplayID.init(rawValue:))
        let resolution = SelectedDisplayResolver.resolve(
            persistedSelection,
            among: displays,
            mainDisplayID: mainID
        )

        _ = focus.apply(.displayChanged, connApplicationPID: ownPID)

        selectedDisplay = resolution.display
        model.setDisplays(
            displays.map { display in
                .init(
                    id: display.id.rawValue,
                    name: display.localizedName,
                    isSelected: display.id == resolution.display?.id
                )
            },
            panelPlacement: resolution.display?.hasPhysicalNotch == true
                ? .physicalNotch
                : .externalCapsule
        )
        applyGeometry()
        if lifecycle.visibility == .visible { panel.orderFrontRegardless() }
    }

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .fullScreenDisallowsTiling,
            .stationary,
            .ignoresCycle,
        ]
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.animationBehavior = .none
    }

    private func installLocalEscapeMonitor() {
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard event.keyCode == 53 else { return event }
            let didConsume = MainActor.assumeIsolated {
                guard let self else { return false }
                guard self.panel.isKeyWindow else { return false }
                if ShellQuestionEscapePolicy.action(
                    isQuestionInputFocused: self.questionInputFocus.isFocused
                ) == .defocusQuestionInput {
                    return self.questionInputFocus.dismissFocusedInput()
                }
                if self.model.showsNewThreadComposer {
                    if !self.model.isCreatingThread { self.model.cancelNewThread() }
                    return true
                }
                if self.model.showsThreadOptions {
                    self.model.showsThreadOptions = false
                    return true
                }
                switch ShellEscapeRoutingPolicy.route(
                    showsSettings: self.model.showsSettings,
                    lifecycle: self.lifecycle
                ) {
                case .ignore:
                    return false
                case .dismissSettings, .stepDown:
                    self.stepDownForEscape()
                    // Consume this exact event so the settings popover and the
                    // panel responder chain cannot also apply it.
                    return true
                }
            }
            return didConsume ? nil : event
        }
    }

    private func expand() {
        guard lifecycle.visibility == .visible else { return }
        let decision = focus.apply(
            .userExpand(frontmostApplicationPID: frontmostPID),
            connApplicationPID: ownPID
        )
        lifecycle.apply(.userExpand)
        model.beginSurfaceGeometryTransition(to: .expanded)
        applyGeometry(animated: true) { [weak self] in
            self?.model.completeSurfaceGeometryTransition(to: .expanded)
        }
        performFocusDecision(decision)
        panel.makeKeyAndOrderFront(nil)
    }

    private func collapse(reason: ShellCollapseReason) {
        guard lifecycle.surface != .compact else { return }
        lifecycle.apply(ShellCollapseRoutingPolicy.lifecycleEvent(for: reason))
        // Outside clicks intentionally leave the workspace sticky. The policy
        // keeps lifecycle and rendered surface aligned, so no compact geometry
        // or focus restoration can run for that no-op transition.
        guard lifecycle.surface == .compact else { return }
        model.beginSurfaceGeometryTransition(to: .compact)
        panel.resignKey()
        applyGeometry(animated: true) { [weak self] in
            self?.model.completeSurfaceGeometryTransition(to: .compact)
        }
        if lifecycle.visibility == .visible { panel.orderFrontRegardless() }
        performFocusDecision(focus.apply(
            .userCollapse(reason: reason, frontmostApplicationPID: currentFocusOwnerPID),
            connApplicationPID: ownPID
        ))
    }

    private func stepDownForEscape() {
        if ShellQuestionEscapePolicy.action(
            isQuestionInputFocused: questionInputFocus.isFocused
        ) == .defocusQuestionInput {
            _ = questionInputFocus.dismissFocusedInput()
            return
        }
        if model.showsThreadOptions {
            model.showsThreadOptions = false
            return
        }
        switch ShellEscapeRoutingPolicy.route(
            showsSettings: model.showsSettings,
            lifecycle: lifecycle
        ) {
        case .ignore:
            return
        case .dismissSettings:
            model.showsSettings = false
            return
        case .stepDown:
            break
        }
        guard !geometryTransitionInFlight else { return }
        collapse(reason: .escape)
    }

    private func pauseAndHide() {
        guard canRecoverFromHiddenState else {
            model.shortcutIssue = "Global shortcut unavailable; Conn stayed visible"
            return
        }
        if lifecycle.surface != .compact {
            collapse(reason: .pauseOrHide)
        }
        // This pauses presentation state only. Bridge ingestion deliberately
        // remains enabled so the bounded inbox does not grow while hidden.
        lifecycle.apply(.pauseAndHide)
        model.isPresentationPaused = true
        panel.orderOut(nil)
    }

    private func hideOnly() {
        guard canRecoverFromHiddenState else {
            model.shortcutIssue = "Global shortcut unavailable; Conn stayed visible"
            return
        }
        if lifecycle.surface != .compact {
            collapse(reason: .pauseOrHide)
        }
        lifecycle.apply(.hide)
        model.setSurfaceState(.compact)
        panel.orderOut(nil)
    }

    private func openCodex(token: ShellActionToken) {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.openai.codex"
        ) else {
            _ = model.finishOpenCodex(
                token,
                error: "Codex is not installed for this macOS user."
            )
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: configuration
        ) { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    _ = self.model.finishOpenCodex(
                        token,
                        error: "Codex could not be opened: \(error.localizedDescription)"
                    )
                    return
                }
                _ = self.model.finishOpenCodex(token)
            }
        }
    }

    private func selectDisplay(id: UInt32) {
        guard let display = NSScreen.screens
            .compactMap(Self.describe)
            .first(where: { $0.id.rawValue == id })
        else { return }
        persistedSelection = .specific(.init(display: display))
        if let data = try? JSONEncoder().encode(persistedSelection) {
            UserDefaults.standard.set(data, forKey: PreferenceKey.selectedDisplay)
        }
        refreshDisplays(reconfigure: true)
    }

    private func applyGeometry(
        animated: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        if geometryTransitionInFlight {
            pendingGeometryRefresh = true
            pendingGeometryRefreshShouldAnimate = pendingGeometryRefreshShouldAnimate || animated
            if let completion { pendingGeometryCompletions.append(completion) }
            return
        }
        guard let selectedDisplay else {
            panel.orderOut(nil)
            return
        }
        let scale = ShellTextScale(
            NSFont.preferredFont(forTextStyle: .body).pointSize / 13
        )
        let geometry = geometryPolicy.geometry(
            for: selectedDisplay,
            surface: lifecycle.surface,
            rowCount: model.sessions.count,
            showsIntegrationRepair: model.showsIntegrationDiagnostic,
            showsSessionDetail: lifecycle.surface == .expanded,
            showsCompactShelf: lifecycle.surface == .compact && model.compactShelf != nil,
            compactShelfHeight: model.compactShelfPreferredHeight,
            textScale: scale
        )
        let motion = ShellMotionPolicy.presentation(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        let shouldAnimate = animated
            && motion.style == .unfurlSpring
            && panel.isVisible

        guard shouldAnimate else {
            guard panel.frame != geometry.frame else {
                completion?()
                return
            }
            lockPanelSize(geometry.frame.size)
            panel.setFrame(geometry.frame, display: true)
            completion?()
            return
        }

        geometryTransitionInFlight = true
        unlockPanelSize()
        let startingFrame = panel.frame
        let destinationFrame = geometry.frame
        guard startingFrame != destinationFrame else {
            geometryTransitionInFlight = false
            lockPanelSize(destinationFrame.size)
            completion?()
            return
        }
        let duration = motion.geometryDuration
        let frameInterval = duration / Double(max(Int(duration * 60), 1))
        let startedAt = ProcessInfo.processInfo.systemUptime
        panelAnimationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while true {
                guard !Task.isCancelled else { return }
                let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
                let linearProgress = ShellMotionPolicy.linearProgress(
                    elapsed: elapsed,
                    duration: duration
                )
                let progress = ShellMotionPolicy.springProgress(linearProgress)
                let frame = Self.interpolate(
                    from: startingFrame,
                    to: destinationFrame,
                    progress: progress
                )
                if self.panel.frame != frame {
                    self.panel.setFrame(frame, display: true)
                }
                guard linearProgress < 1 else { break }
                try? await Task.sleep(for: .seconds(frameInterval))
            }
            self.geometryTransitionInFlight = false
            self.lockPanelSize(destinationFrame.size)
            if self.panel.frame != destinationFrame {
                self.panel.setFrame(destinationFrame, display: true)
            }
            self.panelAnimationTask = nil
            var completions = self.pendingGeometryCompletions
            if let completion { completions.insert(completion, at: 0) }
            self.pendingGeometryCompletions.removeAll(keepingCapacity: true)
            if self.pendingGeometryRefresh {
                let shouldAnimate = self.pendingGeometryRefreshShouldAnimate
                self.pendingGeometryRefresh = false
                self.pendingGeometryRefreshShouldAnimate = false
                self.applyGeometry(animated: shouldAnimate) {
                    completions.forEach { $0() }
                }
            } else {
                completions.forEach { $0() }
            }
        }
    }

    private static func interpolate(
        from start: CGRect,
        to destination: CGRect,
        progress: Double
    ) -> CGRect {
        let progress = CGFloat(progress)
        return CGRect(
            x: start.origin.x + ((destination.origin.x - start.origin.x) * progress),
            y: start.origin.y + ((destination.origin.y - start.origin.y) * progress),
            width: start.width + ((destination.width - start.width) * progress),
            height: start.height + ((destination.height - start.height) * progress)
        )
    }

    private func lockPanelSize(_ size: CGSize) {
        panel.contentMinSize = size
        panel.contentMaxSize = size
        panel.minSize = size
        panel.maxSize = size
    }

    private func unlockPanelSize() {
        let unconstrained = CGSize(width: 10_000, height: 10_000)
        panel.contentMinSize = .zero
        panel.contentMaxSize = unconstrained
        panel.minSize = .init(width: 1, height: 1)
        panel.maxSize = unconstrained
    }

    private func performFocusDecision(_ decision: ShellFocusDecision) {
        switch decision {
        case .none:
            break
        case .activateConn:
            NSApp.activate()
        case let .restoreApplication(pid):
            NSRunningApplication(processIdentifier: pid.rawValue)?.activate(
                options: []
            )
        }
    }

    private var ownPID: ShellApplicationPID? {
        ShellApplicationPID(rawValue: ProcessInfo.processInfo.processIdentifier)
    }

    private var frontmostPID: ShellApplicationPID? {
        ShellApplicationPID(rawValue: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
    }

    private var currentFocusOwnerPID: ShellApplicationPID? {
        if panel.isKeyWindow || NSApp.isActive { return ownPID }
        return frontmostPID
    }

    private static func loadDisplaySelection() -> PersistedDisplaySelection {
        guard let data = UserDefaults.standard.data(forKey: PreferenceKey.selectedDisplay),
              let selection = try? JSONDecoder().decode(
                  PersistedDisplaySelection.self,
                  from: data
              )
        else { return .automatic }
        return selection
    }

    private static func displayID(_ screen: NSScreen) -> UInt32? {
        if let number = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber {
            return number.uint32Value
        }
        return screen.deviceDescription[.init("NSScreenNumber")] as? UInt32
    }

    private static func describe(_ screen: NSScreen) -> ShellDisplayDescriptor? {
        guard let displayID = displayID(screen) else { return nil }
        let persistentIdentifier: String = {
            guard let unmanaged = CGDisplayCreateUUIDFromDisplayID(displayID) else {
                return "display-\(displayID)"
            }
            let uuid = unmanaged.takeRetainedValue()
            return (CFUUIDCreateString(nil, uuid) as String?) ?? "display-\(displayID)"
        }()
        let insets = screen.safeAreaInsets
        return ShellDisplayDescriptor(
            id: .init(rawValue: displayID),
            persistentIdentifier: persistentIdentifier,
            localizedName: screen.localizedName,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaInsets: .init(
                top: insets.top,
                left: insets.left,
                bottom: insets.bottom,
                right: insets.right
            ),
            isBuiltIn: CGDisplayIsBuiltin(displayID) != 0
        )
    }
}
