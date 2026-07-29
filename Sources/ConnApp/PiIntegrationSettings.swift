import SwiftUI
import ConnAppCore
import ConnDomain
import ConnPiAdapter

@MainActor
final class PiIntegrationSettingsModel: ObservableObject {
    static let enabledKey = "pi.external.enabled.v1"
    static let questionsKey = "pi.external.questions.v1"
    static let approvalsKey = "pi.external.approvals.v1"

    @Published private(set) var installStatus: PiExtensionInstallStatus
    @Published private(set) var isWorking = false
    @Published private(set) var issue: String?
    @Published private(set) var notice: String?
    @Published private(set) var toolchainStatus = "Not yet qualified"
    @Published var showsEnableConsent = false
    @Published private(set) var questionsEnabled: Bool
    @Published private(set) var approvalsEnabled: Bool

    private let integration: PiExternalIntegration
    private let coordinator: ConnIntegrationCoordinator
    private let installer: PiExtensionInstaller
    private let discovery: PiToolchainDiscovery
    private var task: Task<Void, Never>?

    init(
        integration: PiExternalIntegration,
        coordinator: ConnIntegrationCoordinator,
        installer: PiExtensionInstaller = .userDefault(),
        discovery: PiToolchainDiscovery = .init()
    ) {
        self.integration = integration
        self.coordinator = coordinator
        self.installer = installer
        self.discovery = discovery
        self.installStatus = installer.status()
        self.questionsEnabled = UserDefaults.standard.bool(forKey: Self.questionsKey)
        self.approvalsEnabled = UserDefaults.standard.bool(forKey: Self.approvalsKey)
    }

    var enabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    var statusLabel: String {
        if enabled {
            return "Enabled — existing Pi TUIs may need /reload"
        }
        switch installStatus {
        case .absent: return "Not installed"
        case .installed: return "Installed but disabled"
        case .foreign: return "Conflict at ~/.pi/agent/extensions/conn"
        }
    }

    func requestEnable() {
        issue = nil
        notice = nil
        showsEnableConsent = true
    }

    func cancelEnable() {
        showsEnableConsent = false
    }

    func confirmEnable() {
        showsEnableConsent = false
        run { model in
            let inspection = await model.discovery.discover()
            guard case let .ready(toolchain) = inspection else {
                model.toolchainStatus = model.toolchainLabel(inspection)
                model.issue = model.toolchainRepairGuidance(inspection)
                return
            }
            model.toolchainStatus =
                "Pi \(toolchain.piVersion) · Node \(toolchain.nodeVersion)"
            do {
                _ = try model.installer.install(
                    configuration: model.behaviorConfiguration
                )
                UserDefaults.standard.set(true, forKey: Self.enabledKey)
                await model.integration.setEnabled(true)
                await model.coordinator.refresh(
                    PiExternalIntegrationIdentity.integrationID
                )
                model.installStatus = model.installer.status()
                model.notice =
                    "Pi monitoring is enabled. Run /reload once in already-open Pi TUIs."
            } catch {
                model.issue = model.userFacing(error)
                model.installStatus = model.installer.status()
            }
        }
    }

    func disable() {
        run { model in
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            await model.integration.setEnabled(false)
            await model.coordinator.refresh(
                PiExternalIntegrationIdentity.integrationID
            )
            model.installStatus = model.installer.status()
            model.notice =
                "Pi monitoring is disabled. External Pi TUIs were left running."
        }
    }

    func uninstall() {
        run { model in
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            await model.integration.setEnabled(false)
            await model.coordinator.refresh(
                PiExternalIntegrationIdentity.integrationID
            )
            do {
                _ = try model.installer.uninstall()
                model.notice = "Conn's Pi extension was moved to Trash."
            } catch {
                model.issue = model.userFacing(error)
            }
            model.installStatus = model.installer.status()
        }
    }

    func diagnose() {
        run { model in
            let inspection = await model.discovery.discover()
            model.toolchainStatus = model.toolchainLabel(inspection)
            if case .ready = inspection {
                model.notice = "Pi and Node passed Conn's bounded compatibility checks."
            } else {
                model.issue = model.toolchainRepairGuidance(inspection)
            }
        }
    }

    func updateExtension() {
        run { model in
            do {
                _ = try model.installer.install(
                    configuration: model.behaviorConfiguration
                )
                if model.enabled {
                    await model.integration.setOptionalFeatures(
                        model.brokerFeatures
                    )
                    await model.coordinator.refresh(
                        PiExternalIntegrationIdentity.integrationID
                    )
                }
                model.installStatus = model.installer.status()
                model.notice =
                    "Conn's Pi extension is current. Existing Pi TUIs need /reload."
            } catch {
                model.issue = model.userFacing(error)
                model.installStatus = model.installer.status()
            }
        }
    }

    func setQuestionsEnabled(_ value: Bool) {
        let priorValue = questionsEnabled
        questionsEnabled = value
        applyOptionalFeatures(
            changedFeature: .questions(priorValue: priorValue),
            notice: value
                ? "Conn questions are enabled. Existing Pi TUIs need /reload to add the tool."
                : "Conn questions are inert now. Existing Pi TUIs need /reload to remove the registered tool."
        )
    }

    func setApprovalsEnabled(_ value: Bool) {
        let priorValue = approvalsEnabled
        approvalsEnabled = value
        applyOptionalFeatures(
            changedFeature: .approvals(priorValue: priorValue),
            notice: value
                ? "Conn approval mediation is enabled for one-time approve or deny decisions."
                : "Conn approval mediation is disabled; Pi's original tool behavior is restored."
        )
    }

    func refresh() {
        installStatus = installer.status()
    }

    func cancel() {
        task?.cancel()
    }

    private func run(
        _ operation: @escaping @MainActor (PiIntegrationSettingsModel) async -> Void
    ) {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            isWorking = true
            issue = nil
            notice = nil
            defer { isWorking = false }
            await operation(self)
        }
    }

    private var behaviorConfiguration: PiExtensionBehaviorConfiguration {
        .init(
            questionsEnabled: questionsEnabled,
            approvalsEnabled: approvalsEnabled
        )
    }

    private var brokerFeatures: PiBrokerOptionalFeatures {
        .init(
            questionsEnabled: questionsEnabled,
            approvalsEnabled: approvalsEnabled
        )
    }

    private func applyOptionalFeatures(
        changedFeature: ChangedOptionalFeature,
        notice: String
    ) {
        guard enabled else { return }
        run { model in
            do {
                _ = try model.installer.install(
                    configuration: model.behaviorConfiguration
                )
                await model.integration.setOptionalFeatures(model.brokerFeatures)
                await model.coordinator.refresh(
                    PiExternalIntegrationIdentity.integrationID
                )
                UserDefaults.standard.set(
                    model.questionsEnabled,
                    forKey: Self.questionsKey
                )
                UserDefaults.standard.set(
                    model.approvalsEnabled,
                    forKey: Self.approvalsKey
                )
                model.installStatus = model.installer.status()
                model.notice = notice
            } catch {
                switch changedFeature {
                case let .questions(priorValue):
                    model.questionsEnabled = priorValue
                case let .approvals(priorValue):
                    model.approvalsEnabled = priorValue
                }
                model.issue = model.userFacing(error)
            }
        }
    }

    private func toolchainLabel(_ inspection: PiToolchainInspection) -> String {
        switch inspection {
        case let .ready(toolchain):
            "Pi \(toolchain.piVersion) · Node \(toolchain.nodeVersion)"
        case .missing:
            "Pi or Node not found"
        case .unsafe:
            "Unsafe Pi or Node installation"
        case let .unsupported(version):
            "Unsupported Pi \(version ?? "version")"
        case .diagnosticFailure:
            "Pi qualification failed"
        }
    }

    private func toolchainRepairGuidance(
        _ inspection: PiToolchainInspection
    ) -> String {
        switch inspection {
        case .ready:
            ""
        case .missing:
            "Conn could not find both Pi and Node. Install Pi 0.82.1, or repair the Node installation that provides the pi command, then retry."
        case let .unsafe(detail):
            "Conn preserved your setup because it could not safely execute it: \(detail)"
        case let .unsupported(version):
            "Conn v0.2.1 supports Pi 0.82.1; found \(version ?? "an unknown version"). Install the supported Pi version, then retry."
        case .diagnosticFailure:
            "Conn found Pi and Node but could not qualify them with a bounded version check. Verify that pi --version works in Terminal, then retry."
        }
    }

    private func userFacing(_ error: Error) -> String {
        switch error {
        case PiExtensionInstallerError.foreignTarget:
            "Conn found an unowned or changed Pi extension at ~/.pi/agent/extensions/conn and preserved it."
        case PiExtensionInstallerError.invalidAgentDirectory:
            "Pi's agent directory is unavailable. Launch Pi once, then retry."
        default:
            "Conn could not safely install its Pi extension: \(error.localizedDescription)"
        }
    }
}

private enum ChangedOptionalFeature {
    case questions(priorValue: Bool)
    case approvals(priorValue: Bool)
}

struct PiIntegrationSettingsView: View {
    @ObservedObject var model: PiIntegrationSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pi Agent")
                .font(.system(size: 11, weight: .semibold))
            Text(
                "Observe and control independently launched Pi TUIs through Pi's standard global extension."
            )
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            Text(model.statusLabel)
                .font(.system(size: 9, weight: .medium))
            Text(model.toolchainStatus)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            HStack {
                if model.enabled {
                    Button("Disable Pi") { model.disable() }
                } else {
                    Button("Enable Pi monitoring") { model.requestEnable() }
                }
                if model.installStatus != .absent {
                    Button("Update") { model.updateExtension() }
                    Button("Uninstall extension") { model.uninstall() }
                }
                Button("Diagnose") { model.diagnose() }
            }
            .disabled(model.isWorking || model.installStatus == .foreign)
            Group {
                Toggle(
                    "Enable Conn structured questions",
                    isOn: Binding(
                        get: { model.questionsEnabled },
                        set: { model.setQuestionsEnabled($0) }
                    )
                )
                Toggle(
                    "Enable Conn approval mediation",
                    isOn: Binding(
                        get: { model.approvalsEnabled },
                        set: { model.setApprovalsEnabled($0) }
                    )
                )
                .help(
                    "Conn policy intercepts write, edit, bash, and unknown tools for one-time approve or deny. It is not a sandbox."
                )
            }
            .disabled(!model.enabled || model.isWorking)
            if let notice = model.notice {
                Text(notice).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if let issue = model.issue {
                Text(issue).font(.system(size: 9)).foregroundStyle(.orange)
            }
        }
        .alert(
            "Enable Pi monitoring?",
            isPresented: $model.showsEnableConsent
        ) {
            Button("Cancel", role: .cancel) { model.cancelEnable() }
            Button("Install and Enable") { model.confirmEnable() }
        } message: {
            Text(
                "Conn will install a global TypeScript extension at ~/.pi/agent/extensions/conn. Extensions run with your permissions. Conn will not launch, restart, or stop Pi. Questions and approval mediation remain off. Existing Pi TUIs need one /reload."
            )
        }
    }
}

struct ConnIntegrationSettingsView: View {
    @ObservedObject var codex: CodexIntegrationSettingsModel
    @ObservedObject var pi: PiIntegrationSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CodexIntegrationSettingsView(model: codex)
            Divider()
            PiIntegrationSettingsView(model: pi)
        }
    }
}
