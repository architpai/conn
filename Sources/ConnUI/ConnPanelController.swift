import AppKit
import Carbon
import CoreGraphics
import ConnAppCore
import QuartzCore
import SwiftUI

package struct ConnPanelFrameDecision: Equatable, Sendable {
    package let frame: CGRect
    package let placement: ShellPanelPlacement
}

package enum ConnPanelFramePolicy {
    package static func decide(
        displayFrame: CGRect,
        visibleFrame: CGRect,
        safeAreaTop: CGFloat,
        isBuiltIn: Bool,
        expanded: Bool,
        compactShelfPreferredHeight: CGFloat
    ) -> ConnPanelFrameDecision {
        let placement: ShellPanelPlacement = isBuiltIn && safeAreaTop > 0
            ? .physicalNotch
            : .externalCapsule
        let anchorFrame = placement == .physicalNotch
            ? displayFrame
            : visibleFrame
        let width: CGFloat = expanded
            ? min(840, anchorFrame.width - 32)
            : ConnCompactHeaderLayoutPolicy.compactPanelWidth(
                placement: placement
            )
        let height: CGFloat = expanded
            ? min(620, visibleFrame.height - 44)
            : max(44, compactShelfPreferredHeight)
        let topEdge = displayFrame.maxY
        let frame = CGRect(
            x: anchorFrame.midX - width / 2,
            y: topEdge - height,
            width: width,
            height: height
        ).integral
        return .init(frame: frame, placement: placement)
    }
}

@MainActor
private final class ConnPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

@MainActor
public final class ConnPanelController<IntegrationSettingsContent: View> {
    private let model: ConnViewModel
    private let panel: ConnPanel
    private var selectedScreen: NSScreen?
    private var canRecoverFromHiddenState = false
    // AppKit owns these opaque tokens. Conn mutates them only on the main
    // actor, then synchronously consumes them from deinit to unregister.
    nonisolated(unsafe) private var localEscapeMonitor: Any?
    nonisolated(unsafe) private var globalOutsideClickMonitor: Any?
    nonisolated(unsafe) private var screenObserver: NSObjectProtocol?
    private var lifecycleState: ShellApplicationLifecycleState = .active

    public init(
        model: ConnViewModel,
        @ViewBuilder integrationSettingsContent:
            @escaping () -> IntegrationSettingsContent
    ) {
        self.model = model
        self.panel = ConnPanel(
            contentRect: .init(x: 0, y: 0, width: 350, height: 44),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        configurePanel()
        panel.contentViewController = NSHostingController(
            rootView: ConnSurfaceView(
                model: model,
                integrationSettingsContent: integrationSettingsContent
            )
        )
        panel.onCancel = { [weak self] in self?.collapse() }
        model.onToggleExpansion = { [weak self] in self?.toggleExpansion() }
        model.onCollapse = { [weak self] in self?.collapse() }
        model.onHidePresentation = { [weak self] in self?.panel.orderOut(nil) }
        model.onSelectDisplay = { [weak self] displayID in
            self?.selectDisplay(displayID)
        }
        model.onCompactNotificationVisibilityChanged = { [weak self] in
            self?.applyGeometry(animated: false)
        }
        installEventMonitors()
        refreshDisplays()
        applyGeometry(animated: false)
        panel.orderFrontRegardless()
    }

    deinit {
        if let localEscapeMonitor { NSEvent.removeMonitor(localEscapeMonitor) }
        if let globalOutsideClickMonitor {
            NSEvent.removeMonitor(globalOutsideClickMonitor)
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    public func setGlobalToggleAvailable(_ available: Bool) {
        canRecoverFromHiddenState = available
    }

    public func publishPassiveUpdate() {
        guard lifecycleState == .active else { return }
        applyGeometry(animated: false)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    public func toggleExpansion() {
        if lifecycleState != .active {
            lifecycleState = .active
            panel.orderFrontRegardless()
        }
        if model.isExpanded {
            collapse()
        } else {
            expand()
        }
    }

    public func handleApplicationLifecycle(
        _ state: ShellApplicationLifecycleState
    ) {
        lifecycleState = state
        switch state {
        case .active:
            panel.orderFrontRegardless()
            applyGeometry(animated: false)
        case .sessionInactive:
            collapse()
        case .screenAsleep, .terminating:
            panel.orderOut(nil)
        }
    }

    public func refreshDisplays() {
        let screens = NSScreen.screens
        if selectedScreen == nil || !screens.contains(where: { $0 === selectedScreen }) {
            selectedScreen = NSScreen.main ?? screens.first
        }
        let decision = (selectedScreen ?? NSScreen.main ?? screens.first).map {
            Self.frameDecision(
                for: $0,
                expanded: model.isExpanded,
                compactShelfPreferredHeight: model.compactShelfPreferredHeight
            )
        }
        model.setDisplays(
            screens.compactMap { screen in
                guard let id = Self.displayID(screen) else { return nil }
                return .init(
                    id: id,
                    name: screen.localizedName,
                    isSelected: screen === selectedScreen
                )
            },
            panelPlacement: decision?.placement ?? .externalCapsule
        )
        applyGeometry(animated: false)
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
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDisplays() }
        }
    }

    private func installEventMonitors() {
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return event }
            guard let self,
                  self.model.isExpanded,
                  event.window === self.panel else { return event }
            self.collapse()
            return nil
        }
        globalOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.model.isExpanded else { return }
                let point = NSEvent.mouseLocation
                if !self.panel.frame.contains(point) { self.collapse() }
            }
        }
    }

    private func expand() {
        let transition = model.beginSurfaceGeometryTransition(to: .expanded)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        panel.makeKeyAndOrderFront(nil)
        applyGeometry(animated: true) { [weak self] in
            self?.model.completeSurfaceGeometryTransition(
                to: .expanded,
                generation: transition
            )
        }
    }

    private func collapse() {
        let transition = model.beginSurfaceGeometryTransition(to: .compact)
        applyGeometry(animated: true) { [weak self] in
            self?.model.completeSurfaceGeometryTransition(
                to: .compact,
                generation: transition
            )
        }
        if lifecycleState == .active || canRecoverFromHiddenState {
            panel.orderFrontRegardless()
        }
    }

    private func applyGeometry(
        animated: Bool,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        guard let screen = selectedScreen ?? NSScreen.main ?? NSScreen.screens.first else {
            completion?()
            return
        }
        let frame = Self.frameDecision(
            for: screen,
            expanded: model.isExpanded,
            compactShelfPreferredHeight: model.compactShelfPreferredHeight
        ).frame
        guard animated,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.setFrame(frame, display: true)
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(
                name: .easeInEaseOut
            )
            panel.animator().setFrame(frame, display: true)
        } completionHandler: {
            Task { @MainActor in completion?() }
        }
    }

    private func selectDisplay(_ displayID: UInt32) {
        guard let screen = NSScreen.screens.first(where: {
            Self.displayID($0) == displayID
        }) else { return }
        selectedScreen = screen
        refreshDisplays()
    }

    private static func displayID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber)?.uint32Value
    }

    private static func frameDecision(
        for screen: NSScreen,
        expanded: Bool,
        compactShelfPreferredHeight: CGFloat
    ) -> ConnPanelFrameDecision {
        let displayID = displayID(screen) ?? 0
        return ConnPanelFramePolicy.decide(
            displayFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            isBuiltIn: displayID != 0 && CGDisplayIsBuiltin(displayID) != 0,
            expanded: expanded,
            compactShelfPreferredHeight: compactShelfPreferredHeight
        )
    }
}
