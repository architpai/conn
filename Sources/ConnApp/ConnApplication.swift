import AppKit
import Darwin
import Foundation
import ConnAppCore
import ConnDomain

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
        // The stable lock closes current-version launch races. This post-lock
        // bundle check also hands off to an already-running legacy build that
        // predates the Application Support lock without reopening that race.
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

    private static func showStartupError(_ detail: String) {
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
    private let viewModel = ConnViewModel()
    private var panelController: ConnPanelController?
    private var globalHotKey: GlobalHotKey?
    private var appServerTask: Task<Void, Never>?
    private var controlTask: Task<Void, Never>?
    private var newThreadTask: Task<Void, Never>?
    private var newThreadModelTask: Task<Void, Never>?
    private var newThreadHydrationTask: Task<Void, Never>?
    private var legacyPluginRetirementTask: Task<Void, Never>?
    private let sharedDesktopDiagnostics = SharedDesktopDiagnosticsCoordinator()
    private let sharedDesktopSetup = SharedDesktopSetupCoordinator()
    private var sharedDesktopDiagnosticsTask: Task<Void, Never>?
    private var sharedDesktopSetupTask: Task<Void, Never>?
    private var sharedDesktopDiagnosticsRefreshTask: Task<Void, Never>?
    private var sharedDesktopProofTask: Task<Void, Never>?
    private var appServerRuntime: AppServerMonitoringRuntime?
    private var appServerRuntimeGeneration: UUID?
    private var observers: [NSObjectProtocol] = []
    private var systemAvailability = ShellSystemAvailability()

    init(singleInstanceClaim: ConnSingleInstanceClaim) {
        self.singleInstanceClaim = singleInstanceClaim
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let controller = ConnPanelController(model: viewModel)
        panelController = controller
        viewModel.onDiagnoseSharedDesktop = { [weak self] labsEnabled, generation in
            self?.diagnoseSharedDesktop(
                labsEnabled: labsEnabled,
                generation: generation
            )
        }
        viewModel.onSetUpSharedDesktop = { [weak self] in
            guard let self else { return }
            sharedDesktopSetupTask?.cancel()
            sharedDesktopSetupTask = Task { [weak self] in
                guard let self else { return }
                let result = await sharedDesktopSetup.setUp()
                viewModel.finishSharedDesktopSetup(result)
            }
        }
        viewModel.onTurnOffSharedDesktop = { [weak self] in
            guard let self else { return }
            sharedDesktopSetupTask?.cancel()
            sharedDesktopSetupTask = Task { [weak self] in
                guard let self else { return }
                let result = await sharedDesktopSetup.turnOff()
                viewModel.finishSharedDesktopTurnOff(result)
            }
        }
        configureGlobalToggle(controller: controller)
        observeSystemLifecycle(controller: controller)
        startAppServerMonitoring()
        if viewModel.sharedDesktopSetupEnabled {
            viewModel.beginSharedDesktopSetup()
        } else if viewModel.sharedDesktopSetupExplicitlyDisabled {
            viewModel.beginSharedDesktopTurnOff()
        } else if viewModel.sharedDesktopLabsEnabled {
            viewModel.requestSharedDesktopDiagnosis()
        }
        sharedDesktopDiagnosticsRefreshTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self else { return }
                viewModel.refreshSharedDesktopDiagnosticsFreshness()
                tick += 1
                if tick.isMultiple(of: 2), viewModel.sharedDesktopLabsEnabled {
                    viewModel.requestSharedDesktopDiagnosis()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelController?.handleApplicationLifecycle(.terminating)
        globalHotKey?.invalidate()
        appServerRuntimeGeneration = nil
        appServerRuntime = nil
        appServerTask?.cancel()
        controlTask?.cancel()
        newThreadTask?.cancel()
        newThreadModelTask?.cancel()
        newThreadHydrationTask?.cancel()
        legacyPluginRetirementTask?.cancel()
        sharedDesktopDiagnosticsTask?.cancel()
        sharedDesktopSetupTask?.cancel()
        sharedDesktopDiagnosticsRefreshTask?.cancel()
        sharedDesktopProofTask?.cancel()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func configureGlobalToggle(controller: ConnPanelController) {
        let hotKey = GlobalHotKey { [weak controller] in
            controller?.toggleExpansion()
        }
        do {
            try hotKey.register()
            controller.setGlobalToggleAvailable(true)
            globalHotKey = hotKey
        } catch {
            controller.setGlobalToggleAvailable(false)
            viewModel.shortcutIssue = "Control-Option-Space unavailable"
        }
    }

    private func observeSystemLifecycle(controller: ConnPanelController) {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.systemAvailability.apply(.userSessionActive(false))
                self?.refreshShellLifecycle()
            }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.systemAvailability.apply(.userSessionActive(true))
                self?.refreshShellLifecycle()
            }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.systemAvailability.apply(.screensAwake(false))
                self?.refreshShellLifecycle()
            }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.systemAvailability.apply(.screensAwake(true))
                self?.refreshShellLifecycle()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak controller] _ in
            MainActor.assumeIsolated { controller?.refreshDisplays() }
        })
    }

    private func refreshShellLifecycle() {
        panelController?.handleApplicationLifecycle(systemAvailability.lifecycleState)
    }

    private func diagnoseSharedDesktop(
        labsEnabled: Bool,
        generation: SharedDesktopDiagnosisGeneration
    ) {
        sharedDesktopDiagnosticsTask?.cancel()
        let candidate = viewModel.sharedDesktopCandidateEvidence()
        let verificationConfirmed = viewModel.confirmsDesktopObservedCandidateEvent
        sharedDesktopDiagnosticsTask = Task { [weak self] in
            guard let self else { return }
            let snapshot = await sharedDesktopDiagnostics.diagnose(
                isLabsFeatureEnabled: labsEnabled,
                isAppManagedSetupEnabled: viewModel.sharedDesktopSetupEnabled,
                candidate: candidate,
                verificationConfirmed: verificationConfirmed
            )
            guard !Task.isCancelled else { return }
            guard viewModel.finishSharedDesktopDiagnosis(
                snapshot,
                generation: generation
            ) else { return }
        }
    }

    /// Starts the sole production state source. Conn observes and controls
    /// Codex only through the stable App Server protocol.
    private func startAppServerMonitoring() {
        let generation = UUID()
        let runtime = AppServerMonitoringRuntime(configuration: .init(
            // Keep large local histories responsive. The managed daemon can
            // exceed the generic 15-second bound when asked to materialize
            // hundreds of rows at once; smaller pages retain full cursor
            // authority without forcing the session into reconnect churn.
            pageSize: 100,
            // Detailed history is selected-thread/on-demand. Avoid holding the
            // entire shell in Hydrating while advisory startup resumes consume
            // their timeout budget; the bounded active-discovery loop below
            // still qualifies other running threads after connection.
            maximumBulkQualifiedThreads: 0,
            inventoryRequestTimeout: .seconds(30),
            // Selected long-running tasks can carry tens of megabytes of
            // bounded history. Keep their read/resume qualification alive
            // long enough to replace metadata-only checkpoint shells.
            qualificationTimeout: .seconds(30),
            bulkQualificationRequiresActiveStatus: true,
            activeDiscoveryInterval: 2,
            activeDiscoveryThreadLimit: 20,
            approvalRoutingPolicy: .allSubscribedConnectionsQualified
        ))
        appServerRuntime = runtime
        viewModel.onQualifySelectedSession = { [weak self] threadID in
            guard self?.appServerRuntime === runtime else { return }
            Task { await runtime.requestThreadQualification(threadID) }
        }
        viewModel.onRequestSync = { [weak self] in
            guard self?.appServerRuntime === runtime else { return }
            Task { await runtime.requestInventoryRefresh() }
        }
        viewModel.onControlSelectionChanged = { [weak self] selectionGeneration in
            guard self?.appServerRuntime === runtime else { return }
            Task { await runtime.updateControlSelectionGeneration(selectionGeneration) }
        }
        viewModel.onBeginSharedDesktopThreadProof = { [weak self] rawThreadID in
            guard let self, self.appServerRuntime === runtime else { return }
            self.sharedDesktopProofTask?.cancel()
            self.sharedDesktopProofTask = Task { [weak self] in
                guard let self, self.appServerRuntime === runtime else { return }
                _ = await runtime.beginSharedDesktopThreadProof(rawThreadID)
                let status = await runtime.sharedDesktopThreadProofStatus()
                guard self.appServerRuntime === runtime else { return }
                if self.viewModel.publishSharedDesktopThreadProofStatus(status) {
                    self.viewModel.requestSharedDesktopDiagnosis()
                }
            }
        }
        viewModel.onCancelSharedDesktopThreadProof = { [weak self] in
            guard let self, self.appServerRuntime === runtime else { return }
            self.sharedDesktopProofTask?.cancel()
            self.sharedDesktopProofTask = Task { [weak self] in
                guard let self, self.appServerRuntime === runtime else { return }
                await runtime.cancelSharedDesktopThreadProof()
            }
        }
        viewModel.onSubmitControl = { [weak self] intent, selectionGeneration, token in
            guard let self, self.appServerRuntime === runtime else { return }
            self.controlTask = Task { [weak self] in
                let result = await runtime.executeControl(
                    intent,
                    selectionGeneration: selectionGeneration
                )
                guard let self, self.appServerRuntime === runtime else { return }
                _ = self.viewModel.finishControlAction(token, intent: intent, result: result)
                self.viewModel.setControlAvailability(await runtime.controlAvailability())
            }
        }
        viewModel.onSubmitNewThread = { [weak self] intent in
            guard let self, self.appServerRuntime === runtime else { return }
            self.newThreadHydrationTask?.cancel()
            self.newThreadTask = Task { [weak self] in
                let result = await runtime.executeNewThread(intent)
                guard let self, self.appServerRuntime === runtime else { return }
                self.viewModel.finishNewThreadCreation(result)
                self.viewModel.setControlAvailability(await runtime.controlAvailability())
                guard result.outcome == .accepted,
                      let threadID = result.createdThreadID else { return }
                // The first immediate qualification can race App Server's
                // durable turn write. These are bounded monitoring
                // qualifications of the exact returned thread; no
                // creation/turn control is replayed.
                self.newThreadHydrationTask = Task { [weak self] in
                    for delay in [Duration.milliseconds(500), .milliseconds(1_500)] {
                        do { try await Task.sleep(for: delay) } catch { return }
                        guard let self, self.appServerRuntime === runtime else { return }
                        await runtime.requestThreadQualification(threadID.rawValue)
                    }
                }
            }
        }
        viewModel.onRequestNewThreadModels = { [weak self] requestGeneration in
            guard let self, self.appServerRuntime === runtime else { return }
            self.newThreadModelTask?.cancel()
            self.newThreadModelTask = Task { [weak self] in
                let result = await runtime.loadNewThreadModelCatalog()
                guard let self, self.appServerRuntime === runtime else { return }
                self.viewModel.finishNewThreadModelLoading(
                    result,
                    generation: requestGeneration
                )
            }
        }
        viewModel.onUninstallLegacyPlugin = { [weak self] candidate in
            guard let self, self.appServerRuntime === runtime else { return }
            self.legacyPluginRetirementTask?.cancel()
            self.legacyPluginRetirementTask = Task { [weak self] in
                let outcome = await runtime.uninstallLegacyPlugin(confirmed: candidate)
                guard let self, self.appServerRuntime === runtime else { return }
                self.viewModel.finishLegacyPluginRemoval(outcome)
            }
        }
        appServerRuntimeGeneration = generation
        appServerTask = Task { [weak self] in
            await runtime.run { [weak self] update in
                guard let self,
                      self.appServerRuntimeGeneration == generation
                else { return }
                self.viewModel.publish(
                    update.snapshot,
                    threadModelSelections: update.threadModelSelections,
                    hooks: update.hooks,
                    legacyPluginCandidate: update.legacyPluginCandidate,
                    legacyHookRetirementDiagnostic: update.legacyHookRetirementDiagnostic,
                    runtimeStatus: update.status,
                    at: update.observedAt
                )
                Task { [weak self] in
                    let proof = await runtime.sharedDesktopThreadProofStatus()
                    guard let self,
                          self.appServerRuntimeGeneration == generation else { return }
                    if self.viewModel.publishSharedDesktopThreadProofStatus(proof),
                       self.viewModel.sharedDesktopLabsEnabled {
                        self.viewModel.requestSharedDesktopDiagnosis()
                    }
                }
                Task { [weak self] in
                    let availability = await runtime.controlAvailability()
                    guard let self,
                          self.appServerRuntimeGeneration == generation else { return }
                    self.viewModel.setControlAvailability(availability)
                }
                self.panelController?.publishPassiveUpdate()
            }
        }
    }

}
