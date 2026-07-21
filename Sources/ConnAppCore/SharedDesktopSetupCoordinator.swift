import Foundation
import ConnAppServerAdapter

public enum SharedDesktopSetupOutcome: String, Equatable, Sendable {
    case ready
    case relaunchRequired
    case disabled
    case partial
    case blocked
    case failed
}

public struct SharedDesktopSetupLogEntry: Equatable, Sendable, Identifiable {
    public enum State: String, Equatable, Sendable {
        case running
        case passed
        case needsAction
        case failed
    }

    public let id: Int
    public let state: State
    public let message: String

    public init(id: Int, state: State, message: String) {
        self.id = id
        self.state = state
        self.message = message
    }
}

public struct SharedDesktopSetupResult: Equatable, Sendable {
    public let outcome: SharedDesktopSetupOutcome
    public let logs: [SharedDesktopSetupLogEntry]

    public init(outcome: SharedDesktopSetupOutcome, logs: [SharedDesktopSetupLogEntry]) {
        self.outcome = outcome
        self.logs = Array(logs.suffix(12))
    }
}

package struct SharedDesktopSetupDependencies: Sendable {
    package let inspect: @Sendable () async -> SharedDesktopHostInspection
    package let ensureDaemon: @Sendable () async -> ManagedDaemonStatus.Kind
    package let installLaunchConfiguration: @Sendable (SharedDesktopLaunchConfigurationInspection) async -> Bool
    package let removeLaunchConfiguration: @Sendable () async -> Bool
    package let enableGUIEnvironment: @Sendable () async -> Bool
    package let disableGUIEnvironment: @Sendable () async -> Bool

    package init(
        inspect: @escaping @Sendable () async -> SharedDesktopHostInspection,
        ensureDaemon: @escaping @Sendable () async -> ManagedDaemonStatus.Kind,
        installLaunchConfiguration: @escaping @Sendable (SharedDesktopLaunchConfigurationInspection) async -> Bool = { _ in true },
        removeLaunchConfiguration: @escaping @Sendable () async -> Bool = { true },
        enableGUIEnvironment: @escaping @Sendable () async -> Bool,
        disableGUIEnvironment: @escaping @Sendable () async -> Bool
    ) {
        self.inspect = inspect
        self.ensureDaemon = ensureDaemon
        self.installLaunchConfiguration = installLaunchConfiguration
        self.removeLaunchConfiguration = removeLaunchConfiguration
        self.enableGUIEnvironment = enableGUIEnvironment
        self.disableGUIEnvironment = disableGUIEnvironment
    }
}

/// Installs only Conn's exact current-user Shared Desktop launch contract.
/// It can start a confirmed-stopped Codex-managed daemon, but has no stop,
/// restart, Desktop signalling, private IPC, or remote-control operation.
public actor SharedDesktopSetupCoordinator {
    private let dependencies: SharedDesktopSetupDependencies

    public init() {
        dependencies = .live()
    }

    package init(dependencies: SharedDesktopSetupDependencies) {
        self.dependencies = dependencies
    }

    public func setUp() async -> SharedDesktopSetupResult {
        var log = Log()
        log.append(.running, "Inspecting the current-user setup")
        let before = await dependencies.inspect()
        guard !Task.isCancelled else { return log.result(.failed, "Setup was cancelled") }

        switch before.launchConfiguration {
        case .foreign, .untrusted, .malformed, .oversized, .unavailable:
            return log.result(
                .blocked,
                "Setup stopped because an existing launch configuration needs manual review"
            )
        case .missing, .legacyConnManaged, .connManaged:
            log.append(.passed, "No conflicting launch configuration was found")
        }
        guard before.guiEnvironment == .enabled || before.guiEnvironment == .disabled else {
            return log.result(
                .blocked,
                "Setup stopped because the existing launch environment could not be identified safely"
            )
        }

        log.append(.running, "Checking the Codex-managed socket daemon")
        let daemon = await dependencies.ensureDaemon()
        guard daemon == .running else {
            return log.result(.failed, "The managed daemon did not expose a safe supported socket")
        }
        log.append(.passed, "The managed daemon socket is ready")

        guard !Task.isCancelled else { return log.result(.failed, "Setup was cancelled") }
        log.append(.running, "Installing Conn's login-persistent launch preference")
        guard await dependencies.installLaunchConfiguration(before.launchConfiguration) else {
            let rolledBack = await rollback(
                originalLaunchConfiguration: before.launchConfiguration,
                clearEnvironment: before.guiEnvironment == .disabled
            )
            return log.result(
                rolledBack ? .failed : .partial,
                rolledBack
                    ? "The persistent launch preference could not be installed"
                    : "The persistent launch preference failed and may need manual review"
            )
        }
        log.append(.passed, "The login-persistent launch preference is installed")

        if Task.isCancelled {
            let rolledBack = await rollback(
                originalLaunchConfiguration: before.launchConfiguration,
                clearEnvironment: before.guiEnvironment == .disabled
            )
            return log.result(
                rolledBack ? .failed : .partial,
                rolledBack
                    ? "Setup was cancelled and the persistent preference was rolled back"
                    : "Setup was cancelled but the persistent preference may remain"
            )
        }

        log.append(.running, "Enabling shared-daemon selection for this login session")
        guard await dependencies.enableGUIEnvironment() else {
            let rolledBack = await rollback(
                originalLaunchConfiguration: before.launchConfiguration,
                clearEnvironment: before.guiEnvironment == .disabled
            )
            return log.result(
                rolledBack ? .failed : .partial,
                rolledBack
                    ? "The launch update failed and setup changes were rolled back"
                    : "The launch update failed and setup may need manual review"
            )
        }
        log.append(.passed, "Shared-daemon selection is enabled")

        if Task.isCancelled {
            let rolledBack = await rollback(
                originalLaunchConfiguration: before.launchConfiguration,
                clearEnvironment: before.guiEnvironment == .disabled
            )
            return log.result(
                rolledBack ? .failed : .partial,
                rolledBack
                    ? "Setup was cancelled and its changes were rolled back"
                    : "Setup was cancelled but some setup changes may remain"
            )
        }

        let after = await dependencies.inspect()
        guard after.launchConfiguration == .connManaged,
              after.guiEnvironment == .enabled,
              after.daemon.state == .runningSafe else {
            let rolledBack = await rollback(
                originalLaunchConfiguration: before.launchConfiguration,
                clearEnvironment: before.guiEnvironment == .disabled
            )
            return log.result(
                rolledBack ? .failed : .partial,
                rolledBack
                    ? "The post-setup check failed and setup changes were rolled back"
                    : "The post-setup check failed; run Turn off before relaunching Codex"
            )
        }
        if before.guiEnvironment == .disabled,
           before.desktopTopology.desktop == .single {
            return log.result(
                .relaunchRequired,
                "Setup passed; fully quit and reopen Codex Desktop once to inherit the shared-daemon flag"
            )
        }
        if after.desktopTopology.desktop == .single,
           after.desktopTopology.privateAppServerChild == .absent {
            return log.result(.ready, "Process selection and the Unix socket check passed")
        }
        return log.result(.relaunchRequired, "Setup passed; relaunch Codex Desktop once to use the shared socket")
    }

    public func turnOff() async -> SharedDesktopSetupResult {
        var log = Log()
        log.append(.running, "Inspecting Conn's persistent launch preference")
        let before = await dependencies.inspect()
        switch before.launchConfiguration {
        case .foreign, .untrusted, .malformed, .oversized, .unavailable:
            return log.result(
                .blocked,
                "Turn off stopped because an existing launch configuration needs manual review"
            )
        case .missing, .legacyConnManaged, .connManaged:
            break
        }
        guard before.guiEnvironment == .enabled || before.guiEnvironment == .disabled else {
            return log.result(
                .blocked,
                "Turn off stopped because the existing launch environment could not be identified safely"
            )
        }
        if before.launchConfiguration == .connManaged || before.launchConfiguration == .legacyConnManaged {
            log.append(.running, "Removing Conn's login-persistent launch preference")
            guard await dependencies.removeLaunchConfiguration() else {
                return log.result(.failed, "Conn's persistent launch preference could not be removed")
            }
            log.append(.passed, "The login-persistent launch preference was removed")
        }
        if before.guiEnvironment == .enabled {
            log.append(.running, "Disabling Conn's shared-daemon launch preference")
            guard await dependencies.disableGUIEnvironment() else {
                return log.result(.failed, "The current-login launch environment could not be cleared")
            }
        }
        guard !Task.isCancelled else { return log.result(.failed, "Disable was cancelled") }
        let after = await dependencies.inspect()
        guard after.launchConfiguration == .missing,
              after.guiEnvironment == .disabled else {
            return log.result(.failed, "The post-disable diagnosis still found Conn's persistent setup")
        }
        return log.result(.disabled, "Shared-daemon selection is off; the managed daemon was left untouched")
    }
}

private extension SharedDesktopSetupCoordinator {
    func rollback(
        originalLaunchConfiguration: SharedDesktopLaunchConfigurationInspection,
        clearEnvironment: Bool
    ) async -> Bool {
        let disableGUIEnvironment = dependencies.disableGUIEnvironment
        let removeLaunchConfiguration = dependencies.removeLaunchConfiguration
        return await Task.detached {
            let environmentRolledBack = clearEnvironment
                ? await disableGUIEnvironment()
                : true
            let launchConfigurationRolledBack = switch originalLaunchConfiguration {
            case .missing, .legacyConnManaged:
                await removeLaunchConfiguration()
            case .connManaged:
                true
            case .foreign, .untrusted, .malformed, .oversized, .unavailable:
                false
            }
            return environmentRolledBack && launchConfigurationRolledBack
        }.value
    }

    struct Log {
        private var entries: [SharedDesktopSetupLogEntry] = []

        mutating func append(_ state: SharedDesktopSetupLogEntry.State, _ message: String) {
            entries.append(.init(id: entries.count, state: state, message: message))
        }

        mutating func result(
            _ outcome: SharedDesktopSetupOutcome,
            _ finalMessage: String
        ) -> SharedDesktopSetupResult {
            let state: SharedDesktopSetupLogEntry.State = switch outcome {
            case .ready, .disabled: .passed
            case .relaunchRequired, .partial, .blocked: .needsAction
            case .failed: .failed
            }
            append(state, finalMessage)
            return .init(outcome: outcome, logs: entries)
        }
    }
}

private extension SharedDesktopSetupDependencies {
    static func live() -> Self {
        let inspector = SharedDesktopHostInspector()
        let launchAgentManager = SharedDesktopLaunchAgentManager()
        return .init(
            inspect: { await inspector.inspect() },
            ensureDaemon: {
                let codexHome = EndpointDiscovery().defaultCodexHome()
                guard case let .ready(executable) = await CodexExecutableDiscovery().discover(
                    codexHome: codexHome
                ) else { return .unavailable }
                do {
                    return try await ManagedDaemonLifecycle(
                        executable: executable,
                        codexHome: codexHome
                    ).ensureRunning().status.kind
                } catch {
                    return .unavailable
                }
            },
            installLaunchConfiguration: { existing in
                await launchAgentManager.install(replacing: existing)
            },
            removeLaunchConfiguration: {
                await launchAgentManager.remove()
            },
            enableGUIEnvironment: {
                await updateLaunchEnvironment(enabled: true)
            },
            disableGUIEnvironment: {
                await updateLaunchEnvironment(enabled: false)
            }
        )
    }

    static func updateLaunchEnvironment(enabled: Bool) async -> Bool {
        let runner = BoundedProcessRunner(outputLimit: 1_024)
        do {
            try Task.checkCancellation()
            let setenv = try await runner.run(
                executableURL: URL(fileURLWithPath: "/bin/launchctl"),
                arguments: enabled
                    ? ["setenv", SharedDesktopHostInspector.guiEnvironmentVariable, "1"]
                    : ["unsetenv", SharedDesktopHostInspector.guiEnvironmentVariable],
                timeout: .seconds(2)
            )
            return setenv.terminationStatus == 0
        } catch {
            return false
        }
    }
}
