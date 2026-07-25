import AppKit
import Darwin
import Foundation
import ConnAppCore
import ConnCodexAdapter
import ConnDomain
import ConnUI

@main
@MainActor
private enum ConnApplication {
    static func main() {
        let singleInstanceClaim: ConnSingleInstanceClaim
        do {
            guard let claim = try ConnSingleInstanceClaim.acquireUserDefault() else {
                if !activateExistingInstance() {
                    showStartupError(
                        "Another copy of Conn owns the single-instance lock, but macOS could not locate its window. Quit the existing Conn process and try again."
                    )
                }
                return
            }
            singleInstanceClaim = claim
        } catch {
            showStartupError(
                "Conn could not establish its private single-instance lock and will not start. \(error.localizedDescription)"
            )
            return
        }
        guard !activateExistingInstance() else { return }

        let application = NSApplication.shared
        let delegate = ConnAppDelegate(singleInstanceClaim: singleInstanceClaim)
        application.delegate = delegate
        application.run()
    }

    @discardableResult
    private static func activateExistingInstance() -> Bool {
        guard let existing = NSRunningApplication
            .runningApplications(withBundleIdentifier: "dev.sidequest.app")
            .first(where: { $0.processIdentifier != getpid() })
        else { return false }
        existing.activate(options: [])
        return true
    }

    static func showStartupError(_ detail: String) {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Conn could not start safely"
        alert.informativeText = detail
        alert.addButton(withTitle: "Quit")
        alert.runModal()
    }
}

@MainActor
private final class ConnAppDelegate: NSObject, NSApplicationDelegate {
    private let singleInstanceClaim: ConnSingleInstanceClaim
    private var coordinator: ConnIntegrationCoordinator?
    private var viewModel: ConnViewModel?
    private var settingsModel: CodexIntegrationSettingsModel?
    private var panelController:
        ConnPanelController<CodexIntegrationSettingsView>?
    private var globalHotKey: GlobalHotKey?
    private var observers: [NSObjectProtocol] = []

    init(singleInstanceClaim: ConnSingleInstanceClaim) {
        self.singleInstanceClaim = singleInstanceClaim
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        do {
            let store = try ConnProjectionCheckpointFileStore.userDefault()
            // The old projection is disposable migration evidence. It never
            // enters the neutral decoder or v0.2 outcome baseline.
            _ = AppServerDomainCheckpointFileStore.quarantineUserDefaultCache()
            let codex = CodexIntegration(
                configuration: .init(
                    pageSize: 100,
                    maximumBulkQualifiedThreads: 0,
                    inventoryRequestTimeout: .seconds(30),
                    qualificationTimeout: .seconds(30),
                    bulkQualificationRequiresActiveStatus: true,
                    activeDiscoveryInterval: 2,
                    activeDiscoveryThreadLimit: 20,
                    approvalRoutingPolicy: .allSubscribedConnectionsQualified
                ),
                legacyHookRetirement: Self.retireLegacyHooks
            )
            let coordinator = try ConnIntegrationCoordinator(
                integrations: [codex],
                checkpointStore: store
            )
            let viewModel = ConnViewModel(
                coordinator: coordinator,
                openHarness: Self.openCodex
            )
            let settingsModel = CodexIntegrationSettingsModel()
            let panel = ConnPanelController(model: viewModel) {
                CodexIntegrationSettingsView(model: settingsModel)
            }
            self.coordinator = coordinator
            self.viewModel = viewModel
            self.settingsModel = settingsModel
            panelController = panel

            configureGlobalToggle(panel: panel, model: viewModel)
            observeSystemLifecycle(panel: panel)
            viewModel.start()
            settingsModel.refresh()
        } catch {
            ConnApplication.showStartupError(
                "The v0.2 Integration runtime could not be initialized. \(error.localizedDescription)"
            )
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelController?.handleApplicationLifecycle(.terminating)
        globalHotKey?.invalidate()
        viewModel?.stop()
        settingsModel?.cancel()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        _ = singleInstanceClaim
    }

    private func configureGlobalToggle(
        panel: ConnPanelController<CodexIntegrationSettingsView>,
        model: ConnViewModel
    ) {
        let hotKey = GlobalHotKey { [weak panel] in
            panel?.toggleExpansion()
        }
        do {
            try hotKey.register()
            panel.setGlobalToggleAvailable(true)
            globalHotKey = hotKey
        } catch {
            panel.setGlobalToggleAvailable(false)
            model.shortcutIssue = "Control-Option-Space unavailable"
        }
    }

    private func observeSystemLifecycle(
        panel: ConnPanelController<CodexIntegrationSettingsView>
    ) {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak panel] _ in
            MainActor.assumeIsolated {
                panel?.handleApplicationLifecycle(.sessionInactive)
            }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak panel] _ in
            MainActor.assumeIsolated { panel?.handleApplicationLifecycle(.active) }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak panel] _ in
            MainActor.assumeIsolated {
                panel?.handleApplicationLifecycle(.screenAsleep)
            }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak panel] _ in
            MainActor.assumeIsolated { panel?.handleApplicationLifecycle(.active) }
        })
    }

    nonisolated private static func retireLegacyHooks() -> String? {
        do {
            switch try LegacyHookRetirementStore.userDefault().retire() {
            case .alreadyCompleted:
                return nil
            case let .completed(removedLegacyRoots, legacyStateReappeared: false):
                return removedLegacyRoots > 0
                    ? "Legacy hook checkpoints were discarded."
                    : nil
            case .completed(_, legacyStateReappeared: true):
                return "Legacy hook state reappeared. Remove the retired Sidequest plugin."
            }
        } catch {
            return "Legacy hook cleanup needs repair; the retired bridge was not re-enabled."
        }
    }

    nonisolated private static func openCodex(
        _ sessionID: ConnSessionID
    ) async -> Bool {
        _ = sessionID
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                guard let applicationURL = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: "com.openai.codex"
                ) else {
                    continuation.resume(returning: false)
                    return
                }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                configuration.createsNewApplicationInstance = false
                NSWorkspace.shared.openApplication(
                    at: applicationURL,
                    configuration: configuration
                ) { _, error in
                    continuation.resume(returning: error == nil)
                }
            }
        }
    }
}
