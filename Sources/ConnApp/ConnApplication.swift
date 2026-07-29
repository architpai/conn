import AppKit
import CoreImage
import Darwin
import Foundation
import ConnAppCore
import ConnCodexAdapter
import ConnDomain
import ConnPiAdapter
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
        application.mainMenu = ConnApplicationMenu.make()
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
    private var piSettingsModel: PiIntegrationSettingsModel?
    private var panelController:
        ConnPanelController<ConnIntegrationSettingsView>?
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
            let pi = PiExternalIntegration.userDefault(
                enabled: UserDefaults.standard.bool(
                    forKey: PiIntegrationSettingsModel.enabledKey
                )
            )
            let coordinator = try ConnIntegrationCoordinator(
                integrations: [codex, pi],
                checkpointStore: store
            )
            var harnessAssets = Self.registerCodexHarnessAsset().map {
                [CodexIntegrationIdentity.harnessID: $0]
            } ?? [:]
            if let piHarnessAsset = Self.registerPiHarnessAsset() {
                harnessAssets[PiExternalIntegrationIdentity.harnessID] =
                    piHarnessAsset
            }
            let codexOpenAvailable = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.openai.codex"
            ) != nil
            let sessionOpener = AnyConnSessionOpener(
                availability: { sessionID in
                    sessionID.integrationID == CodexIntegrationIdentity.integrationID
                        && codexOpenAvailable
                        ? .available
                        : .unavailable(
                            reason: sessionID.integrationID.rawValue == "pi.external"
                                ? "Exact Pi terminal activation is unavailable"
                                : "The original Harness is unavailable"
                        )
                },
                open: Self.openCodex
            )
            let viewModel = ConnViewModel(
                coordinator: coordinator,
                harnessAssets: harnessAssets,
                sessionOpener: sessionOpener
            )
            let settingsModel = CodexIntegrationSettingsModel(integration: codex)
            let piSettingsModel = PiIntegrationSettingsModel(
                integration: pi,
                coordinator: coordinator
            )
            let panel = ConnPanelController(model: viewModel) {
                ConnIntegrationSettingsView(
                    codex: settingsModel,
                    pi: piSettingsModel
                )
            }
            self.coordinator = coordinator
            self.viewModel = viewModel
            self.settingsModel = settingsModel
            self.piSettingsModel = piSettingsModel
            panelController = panel

            configureGlobalToggle(panel: panel, model: viewModel)
            observeSystemLifecycle(panel: panel)
            viewModel.start()
            settingsModel.refresh()
            piSettingsModel.refresh()
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
        piSettingsModel?.cancel()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        _ = singleInstanceClaim
    }

    private func configureGlobalToggle(
        panel: ConnPanelController<ConnIntegrationSettingsView>,
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
        panel: ConnPanelController<ConnIntegrationSettingsView>
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

    private static func registerCodexHarnessAsset() -> String? {
        let assetName = NSImage.Name("CodexHarness")
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.openai.codex"
        ) else { return nil }
        let image = highResolutionOpenAIMark(applicationURL: applicationURL)
            ?? NSWorkspace.shared.icon(forFile: applicationURL.path)
        return image.setName(assetName) ? assetName : nil
    }

    private static func registerPiHarnessAsset() -> String? {
        let assetName = NSImage.Name("PiHarness")
        guard let image = NSImage(
            contentsOf: PiHarnessAsset.bundledBadgeURL
        ) else { return nil }
        return image.setName(assetName) ? assetName : nil
    }

    private static func highResolutionOpenAIMark(
        applicationURL: URL
    ) -> NSImage? {
        let iconURL = applicationURL
            .appendingPathComponent("Contents/Resources/icon-chatgpt.png")
        guard let source = CIImage(contentsOf: iconURL) else { return nil }

        // The supplied application icon contains the OpenAI mark on a light
        // rounded-square plate. Crop inside that plate, then map luminance to
        // alpha so the dark mark becomes a high-resolution template image.
        let side = min(source.extent.width, source.extent.height) * 0.68
        let crop = CGRect(
            x: source.extent.midX - side / 2,
            y: source.extent.midY - side / 2,
            width: side,
            height: side
        )
        let cropped = source.cropped(to: crop)
        guard let mask = CIFilter(
            name: "CIColorMatrix",
            parameters: [
                kCIInputImageKey: cropped,
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(
                    x: -1.0 / 3.0,
                    y: -1.0 / 3.0,
                    z: -1.0 / 3.0,
                    w: 0
                ),
                "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 1),
            ]
        )?.outputImage,
        let rendered = CIContext().createCGImage(mask, from: crop)
        else {
            return nil
        }

        let image = NSImage(
            cgImage: rendered,
            size: NSSize(width: side, height: side)
        )
        image.isTemplate = true
        return image
    }
}
