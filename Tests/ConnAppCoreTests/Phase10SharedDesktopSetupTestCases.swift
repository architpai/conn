import Foundation
import ConnAppCore
import ConnAppServerAdapter

enum Phase10SharedDesktopSetupTestCases {
    static func run(into suite: inout TestSuite) async {
        await alreadyConfiguredIsIdempotent(into: &suite)
        await missingSetupInstallsPersistentLaunchAgent(into: &suite)
        await unsafeExistingSetupFailsClosed(into: &suite)
        await unexpectedEnvironmentFailsClosed(into: &suite)
        await privateDesktopRequestsRelaunch(into: &suite)
        await postCheckFailureRollsBackFlag(into: &suite)
        await failedPersistentInstallRollsBackPossibleEffects(into: &suite)
        await failedRollbackRemainsActionable(into: &suite)
        await cancellationAfterEnableRunsCleanup(into: &suite)
        await interruptedEnableRunsCleanup(into: &suite)
        await disableClearsOnlyTheNamedEnvironment(into: &suite)
        await disableRejectsUnknownEnvironment(into: &suite)
        await disableRejectsForeignLaunchConfiguration(into: &suite)
        await launchAgentManagerInstallsAndRemovesExactContract(into: &suite)
        await launchAgentManagerRefusesUnexpectedExistingFile(into: &suite)
        boundedLogs(into: &suite)
    }

    private static func alreadyConfiguredIsIdempotent(into suite: inout TestSuite) async {
        let recorder = Recorder()
        let coordinator = SharedDesktopSetupCoordinator(dependencies: .init(
            inspect: { await recorder.nextInspection() },
            ensureDaemon: { await recorder.recordDaemon(); return .running },
            installLaunchConfiguration: { launch in await recorder.recordInstall(launch); return true },
            enableGUIEnvironment: { await recorder.recordEnvironment(); return true },
            disableGUIEnvironment: { true }
        ))
        await recorder.setInspections([inspection(), inspection()])
        let result = await coordinator.setUp()
        suite.checkEqual(result.outcome, .ready, "an exact installed setup with shared process selection is ready")
        suite.checkEqual(await recorder.installs, 1, "an idempotent retry refreshes the persistent launch preference")
        suite.checkEqual(await recorder.environmentUpdates, 1, "an idempotent retry renews the named GUI flag")
        suite.check(result.logs.allSatisfy { !$0.message.contains("/") }, "setup logs contain no host paths")
    }

    private static func missingSetupInstallsPersistentLaunchAgent(into suite: inout TestSuite) async {
        let recorder = Recorder()
        await recorder.setInspections([
            inspection(launch: .missing, gui: .disabled),
            inspection(launch: .connManaged),
        ])
        let coordinator = SharedDesktopSetupCoordinator(dependencies: .init(
            inspect: { await recorder.nextInspection() },
            ensureDaemon: { .running },
            installLaunchConfiguration: { launch in await recorder.recordInstall(launch); return true },
            enableGUIEnvironment: { await recorder.recordEnvironment(); return true },
            disableGUIEnvironment: { true }
        ))
        let result = await coordinator.setUp()
        suite.checkEqual(result.outcome, .relaunchRequired, "first-time setup requires Codex Desktop to inherit the flag on relaunch")
        suite.checkEqual(await recorder.installs, 1, "one click installs one launch preference")
        suite.checkEqual(await recorder.lastInstalledState, .missing, "installation is guarded by the inspected prior state")
        suite.checkEqual(await recorder.environmentUpdates, 1, "one click also enables the current login session")
    }

    private static func unsafeExistingSetupFailsClosed(into suite: inout TestSuite) async {
        let recorder = Recorder()
        await recorder.setInspections([inspection(launch: .foreign)])
        let coordinator = SharedDesktopSetupCoordinator(dependencies: .init(
            inspect: { await recorder.nextInspection() },
            ensureDaemon: { await recorder.recordDaemon(); return .running },
            installLaunchConfiguration: { launch in await recorder.recordInstall(launch); return true },
            enableGUIEnvironment: { await recorder.recordEnvironment(); return true },
            disableGUIEnvironment: { true }
        ))
        let result = await coordinator.setUp()
        suite.checkEqual(result.outcome, .blocked, "a foreign launch artifact blocks setup")
        suite.checkEqual(await recorder.daemonChecks, 0, "blocked setup performs no daemon action")
        suite.checkEqual(await recorder.environmentUpdates, 0, "blocked setup does not alter launch state")
        suite.checkEqual(await recorder.installs, 0, "blocked setup does not install persistence")
    }

    private static func unexpectedEnvironmentFailsClosed(into suite: inout TestSuite) async {
        let recorder = Recorder()
        await recorder.setInspections([inspection(gui: .unexpected)])
        let coordinator = SharedDesktopSetupCoordinator(dependencies: .init(
            inspect: { await recorder.nextInspection() },
            ensureDaemon: { await recorder.recordDaemon(); return .running },
            enableGUIEnvironment: { await recorder.recordEnvironment(); return true },
            disableGUIEnvironment: { true }
        ))
        let result = await coordinator.setUp()
        suite.checkEqual(result.outcome, .blocked, "an unexpected existing GUI value fails closed")
        suite.checkEqual(await recorder.daemonChecks, 0, "unexpected launch state blocks before daemon setup")
        suite.checkEqual(await recorder.environmentUpdates, 0, "unexpected launch state is never overwritten")
    }

    private static func privateDesktopRequestsRelaunch(into suite: inout TestSuite) async {
        let recorder = Recorder()
        let privateDesktop = inspection(privateChild: .single)
        await recorder.setInspections([privateDesktop, privateDesktop])
        let coordinator = SharedDesktopSetupCoordinator(dependencies: .init(
            inspect: { await recorder.nextInspection() },
            ensureDaemon: { .running },
            enableGUIEnvironment: { true },
            disableGUIEnvironment: { true }
        ))
        let result = await coordinator.setUp()
        suite.checkEqual(result.outcome, .relaunchRequired, "a live private Desktop child gets an honest relaunch result")
    }

    private static func disableClearsOnlyTheNamedEnvironment(into suite: inout TestSuite) async {
        let recorder = Recorder()
        await recorder.setInspections([
            inspection(gui: .enabled),
            inspection(launch: .missing, gui: .disabled),
        ])
        let coordinator = SharedDesktopSetupCoordinator(dependencies: .init(
            inspect: { await recorder.nextInspection() },
            ensureDaemon: { await recorder.recordDaemon(); return .running },
            removeLaunchConfiguration: { await recorder.recordRemoval(); return true },
            enableGUIEnvironment: { await recorder.recordEnvironment(); return true },
            disableGUIEnvironment: { await recorder.recordDisable(); return true }
        ))
        let result = await coordinator.turnOff()
        suite.checkEqual(result.outcome, .disabled, "disable confirms the named environment flag is absent")
        suite.checkEqual(await recorder.disables, 1, "disable performs exactly one named environment update")
        suite.checkEqual(await recorder.removals, 1, "disable removes the recognized persistent preference")
        suite.checkEqual(await recorder.daemonChecks, 0, "disable never stops or probes daemon ownership")
    }

    private static func postCheckFailureRollsBackFlag(into suite: inout TestSuite) async {
        let recorder = Recorder()
        await recorder.setInspections([
            inspection(launch: .missing, gui: .disabled),
            inspection(gui: .unavailable),
        ])
        let coordinator = SharedDesktopSetupCoordinator(dependencies: .init(
            inspect: { await recorder.nextInspection() },
            ensureDaemon: { .running },
            removeLaunchConfiguration: { await recorder.recordRemoval(); return true },
            enableGUIEnvironment: { await recorder.recordEnvironment(); return true },
            disableGUIEnvironment: { await recorder.recordDisable(); return true }
        ))
        let result = await coordinator.setUp()
        suite.checkEqual(result.outcome, .failed, "a failed post-check cannot report setup success")
        suite.checkEqual(await recorder.disables, 1, "post-check failure rolls the named flag back")
        suite.checkEqual(await recorder.removals, 1, "post-check failure removes newly installed persistence")
    }

    private static func failedPersistentInstallRollsBackPossibleEffects(
        into suite: inout TestSuite
    ) async {
        let recorder = Recorder()
        await recorder.setInspections([inspection(launch: .missing, gui: .disabled)])
        let coordinator = SharedDesktopSetupCoordinator(dependencies: .init(
            inspect: { await recorder.nextInspection() },
            ensureDaemon: { .running },
            installLaunchConfiguration: { _ in false },
            removeLaunchConfiguration: { await recorder.recordRemoval(); return true },
            enableGUIEnvironment: { await recorder.recordEnvironment(); return true },
            disableGUIEnvironment: { await recorder.recordDisable(); return true }
        ))
        let result = await coordinator.setUp()
        suite.checkEqual(result.outcome, .failed, "a failed persistent install cannot report setup success")
        suite.checkEqual(await recorder.removals, 1, "a partial install is removed defensively")
        suite.checkEqual(await recorder.disables, 1, "a possibly loaded job cannot leave the session flag enabled")
        suite.checkEqual(await recorder.environmentUpdates, 0, "explicit session enable does not run after install failure")
    }

    private static func disableRejectsUnknownEnvironment(into suite: inout TestSuite) async {
        let recorder = Recorder()
        await recorder.setInspections([inspection(gui: .unavailable)])
        let coordinator = SharedDesktopSetupCoordinator(dependencies: .init(
            inspect: { await recorder.nextInspection() },
            ensureDaemon: { .running },
            enableGUIEnvironment: { true },
            disableGUIEnvironment: { await recorder.recordDisable(); return true }
        ))
        let result = await coordinator.turnOff()
        suite.checkEqual(result.outcome, .blocked, "turn off fails closed on unavailable prior state")
        suite.checkEqual(await recorder.disables, 0, "turn off never clears an unrecognized environment value")
    }

    private static func disableRejectsForeignLaunchConfiguration(into suite: inout TestSuite) async {
        let recorder = Recorder()
        await recorder.setInspections([inspection(launch: .foreign)])
        let coordinator = SharedDesktopSetupCoordinator(dependencies: .init(
            inspect: { await recorder.nextInspection() },
            ensureDaemon: { .running },
            removeLaunchConfiguration: { await recorder.recordRemoval(); return true },
            enableGUIEnvironment: { true },
            disableGUIEnvironment: { await recorder.recordDisable(); return true }
        ))
        let result = await coordinator.turnOff()
        suite.checkEqual(result.outcome, .blocked, "turn off refuses a foreign launch configuration")
        suite.checkEqual(await recorder.removals, 0, "turn off never removes foreign persistence")
        suite.checkEqual(await recorder.disables, 0, "turn off does not mutate the session after a provenance failure")
    }

    private static func failedRollbackRemainsActionable(into suite: inout TestSuite) async {
        let recorder = Recorder()
        await recorder.setInspections([
            inspection(launch: .missing, gui: .disabled),
            inspection(gui: .unavailable),
        ])
        let coordinator = SharedDesktopSetupCoordinator(dependencies: .init(
            inspect: { await recorder.nextInspection() },
            ensureDaemon: { .running },
            removeLaunchConfiguration: { await recorder.recordRemoval(); return false },
            enableGUIEnvironment: { true },
            disableGUIEnvironment: { false }
        ))
        let result = await coordinator.setUp()
        suite.checkEqual(
            result.outcome,
            .partial,
            "an unverified flag that could not be rolled back remains explicitly actionable"
        )
        suite.checkEqual(await recorder.removals, 1, "failed persistence rollback keeps the result actionable")
    }

    private static func cancellationAfterEnableRunsCleanup(into suite: inout TestSuite) async {
        let recorder = Recorder()
        await recorder.setInspections([inspection(launch: .missing, gui: .disabled)])
        let coordinator = SharedDesktopSetupCoordinator(dependencies: .init(
            inspect: { await recorder.nextInspection() },
            ensureDaemon: { .running },
            removeLaunchConfiguration: { await recorder.recordRemoval(); return true },
            enableGUIEnvironment: {
                withUnsafeCurrentTask { $0?.cancel() }
                return true
            },
            disableGUIEnvironment: { await recorder.recordDisable(); return true }
        ))
        let result = await Task { await coordinator.setUp() }.value
        suite.checkEqual(result.outcome, .failed, "cancelled setup reports the compensated failure")
        suite.checkEqual(await recorder.disables, 1, "cancelled setup runs uncancelled flag cleanup")
        suite.checkEqual(await recorder.removals, 1, "cancelled setup removes newly installed persistence")
    }

    private static func interruptedEnableRunsCleanup(into suite: inout TestSuite) async {
        let recorder = Recorder()
        await recorder.setInspections([inspection(launch: .missing, gui: .disabled)])
        let coordinator = SharedDesktopSetupCoordinator(dependencies: .init(
            inspect: { await recorder.nextInspection() },
            ensureDaemon: { .running },
            removeLaunchConfiguration: { await recorder.recordRemoval(); return true },
            enableGUIEnvironment: {
                withUnsafeCurrentTask { $0?.cancel() }
                return false
            },
            disableGUIEnvironment: { await recorder.recordDisable(); return true }
        ))
        let result = await Task { await coordinator.setUp() }.value
        suite.checkEqual(result.outcome, .failed, "interrupted enable reports a compensated failure")
        suite.checkEqual(await recorder.disables, 1, "interrupted enable runs uncancelled cleanup")
        suite.checkEqual(await recorder.removals, 1, "interrupted enable removes newly installed persistence")
    }

    private static func launchAgentManagerInstallsAndRemovesExactContract(
        into suite: inout TestSuite
    ) async {
        let root: URL
        do {
            root = try Phase3TestScaffolding.temporaryApplicationSupport("launch-agent")
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("Library", isDirectory: true),
                withIntermediateDirectories: false
            )
        } catch {
            suite.recordUnexpected(error, context: "create launch-agent fixture")
            return
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let launchctl = LaunchctlRecorder()
        let manager = SharedDesktopLaunchAgentManager(
            homeDirectory: root,
            launchctlRunner: { arguments in await launchctl.run(arguments) }
        )

        let installed = await manager.install(replacing: .missing)
        suite.check(installed, "missing setup installs the exact launch agent")
        do {
            let data = try Data(contentsOf: manager.launchAgentURL)
            suite.checkEqual(
                SharedDesktopHostInspector.inspectLaunchConfigurationData(data),
                .connManaged,
                "installed plist matches the current exact contract"
            )
            let attributes = try FileManager.default.attributesOfItem(atPath: manager.launchAgentURL.path)
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue
            suite.checkEqual(mode, 0o600, "installed launch agent is private to the current user")
        } catch {
            suite.recordUnexpected(error, context: "inspect installed launch agent")
        }
        suite.checkEqual(await launchctl.commandCount, 2, "installation reloads only the named launch agent")
        let removed = await manager.remove()
        suite.check(removed, "recognized launch agent can be turned off")
        suite.check(!FileManager.default.fileExists(atPath: manager.launchAgentURL.path), "turn off deletes the recognized plist")
    }

    private static func launchAgentManagerRefusesUnexpectedExistingFile(
        into suite: inout TestSuite
    ) async {
        let root: URL
        do {
            root = try Phase3TestScaffolding.temporaryApplicationSupport("launch-agent-foreign")
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("Library/LaunchAgents", isDirectory: true),
                withIntermediateDirectories: true
            )
        } catch {
            suite.recordUnexpected(error, context: "create foreign launch-agent fixture")
            return
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let launchctl = LaunchctlRecorder()
        let manager = SharedDesktopLaunchAgentManager(
            homeDirectory: root,
            launchctlRunner: { arguments in await launchctl.run(arguments) }
        )
        do {
            try Data("foreign".utf8).write(to: manager.launchAgentURL)
        } catch {
            suite.recordUnexpected(error, context: "write foreign launch-agent fixture")
            return
        }

        let installed = await manager.install(replacing: .missing)
        suite.check(!installed, "unexpected existing files are never overwritten")
        suite.checkEqual(await launchctl.commandCount, 0, "rejected files trigger no launchctl action")
        let removed = await manager.remove()
        suite.check(!removed, "unexpected existing files are never deleted")
        suite.checkEqual(await launchctl.commandCount, 0, "foreign files trigger no launchctl action during turn off")
        suite.check(FileManager.default.fileExists(atPath: manager.launchAgentURL.path), "foreign file remains untouched")
    }

    private static func boundedLogs(into suite: inout TestSuite) {
        let logs = (0..<20).map {
            SharedDesktopSetupLogEntry(id: $0, state: .passed, message: "Stage \($0)")
        }
        suite.checkEqual(
            SharedDesktopSetupResult(outcome: .ready, logs: logs).logs.count,
            12,
            "setup activity is bounded"
        )
    }

    private static func inspection(
        launch: SharedDesktopLaunchConfigurationInspection = .connManaged,
        gui: SharedDesktopGUIEnvironmentInspection = .enabled,
        privateChild: SharedDesktopPrivateAppServerChildState = .absent
    ) -> SharedDesktopHostInspection {
        .init(
            bundle: .init(state: .available, shortVersion: "26.715.50000", buildVersion: "6000"),
            bundledCLI: .init(state: .available, version: "0.145.0-alpha.18"),
            guiEnvironment: gui,
            launchConfiguration: launch,
            desktopTopology: .init(desktop: .single, privateAppServerChild: privateChild),
            daemon: .init(state: .runningSafe, cliVersion: "0.144.6", appServerVersion: "0.144.6")
        )
    }
}

private actor Recorder {
    private var inspections: [SharedDesktopHostInspection] = []
    private(set) var environmentUpdates = 0
    private(set) var daemonChecks = 0
    private(set) var disables = 0
    private(set) var installs = 0
    private(set) var removals = 0
    private(set) var lastInstalledState: SharedDesktopLaunchConfigurationInspection?

    func setInspections(_ value: [SharedDesktopHostInspection]) {
        inspections = value
    }

    func nextInspection() -> SharedDesktopHostInspection {
        if inspections.count > 1 { return inspections.removeFirst() }
        return inspections[0]
    }

    func recordEnvironment() { environmentUpdates += 1 }
    func recordDaemon() { daemonChecks += 1 }
    func recordDisable() { disables += 1 }
    func recordInstall(_ state: SharedDesktopLaunchConfigurationInspection) {
        installs += 1
        lastInstalledState = state
    }
    func recordRemoval() { removals += 1 }
}

private actor LaunchctlRecorder {
    private var commands: [[String]] = []
    var commandCount: Int { commands.count }

    func run(_ arguments: [String]) -> Bool {
        commands.append(arguments)
        return true
    }
}
