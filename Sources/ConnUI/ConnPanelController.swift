import AppKit
import Carbon
import CoreGraphics
import ConnAppCore
import QuartzCore
import SwiftUI

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
    private var localEscapeMonitor: Any?
    private var globalOutsideClickMonitor: Any?
    private var screenObserver: NSObjectProtocol?
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
        installEventMonitors()
        refreshDisplays()
        applyGeometry(animated: false)
        panel.orderFrontRegardless()
    }

    isolated deinit {
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
        model.setDisplays(
            screens.compactMap { screen in
                guard let id = Self.displayID(screen) else { return nil }
                return .init(
                    id: id,
                    name: screen.localizedName,
                    isSelected: screen === selectedScreen
                )
            },
            panelPlacement: selectedScreen.map(Self.hasPhysicalNotch) == true
                ? .physicalNotch
                : .externalCapsule
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
            self?.collapse()
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
        model.setSurfaceState(.expanded)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        panel.makeKeyAndOrderFront(nil)
        applyGeometry(animated: true)
    }

    private func collapse() {
        model.setSurfaceState(.compact)
        applyGeometry(animated: true)
        if lifecycleState == .active || canRecoverFromHiddenState {
            panel.orderFrontRegardless()
        }
    }

    private func applyGeometry(animated: Bool) {
        guard let screen = selectedScreen ?? NSScreen.main ?? NSScreen.screens.first else {
            return
        }
        let visible = screen.visibleFrame
        let expanded = model.isExpanded
        let width: CGFloat = expanded ? min(840, visible.width - 32) : 350
        let height: CGFloat = expanded
            ? min(620, visible.height - 44)
            : max(44, model.compactShelfPreferredHeight + 8)
        let frame = NSRect(
            x: visible.midX - width / 2,
            y: visible.maxY - height - 8,
            width: width,
            height: height
        ).integral
        guard animated,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(
                name: .easeInEaseOut
            )
            panel.animator().setFrame(frame, display: true)
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

    private static func hasPhysicalNotch(_ screen: NSScreen) -> Bool {
        if #available(macOS 12.0, *) {
            return screen.safeAreaInsets.top > 0
        }
        return false
    }
}
