import SwiftUI
import ConnAppCore
import ConnCodexAdapter

@MainActor
final class CodexIntegrationSettingsModel: ObservableObject {
    static let enabledKey = "codex.integration.enabled.v1"

    @Published private(set) var enabled: Bool
    @Published private(set) var providerNotice: String?
    @Published var labsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(labsEnabled, forKey: Self.labsKey)
            refresh()
        }
    }
    @Published private(set) var isWorking = false
    @Published private(set) var diagnostics: SharedDesktopDiagnosticsSnapshot?
    @Published private(set) var setupResult: SharedDesktopSetupResult?
    @Published private(set) var lastDiagnosedAt: Date?
    @Published private(set) var legacyPluginCandidate:
        LegacySidequestPluginCandidate?
    @Published private(set) var legacyPluginResult: String?
    @Published private(set) var launchAtLoginStatus: ConnLaunchAtLoginStatus
    @Published private(set) var launchAtLoginIssue: String?
    @Published var showsSharedDesktopSetupConsent = false

    private static let labsKey = "sharedDesktopLabs.v1"
    private static let setupKey = "sharedDesktopAppManaged.v1"
    private let diagnosticsCoordinator = SharedDesktopDiagnosticsCoordinator()
    private let setupCoordinator = SharedDesktopSetupCoordinator()
    private let integration: CodexIntegration
    private let coordinator: ConnIntegrationCoordinator
    private let activationPreference: ConnIntegrationActivationPreference
    private let launchAtLogin: ConnLaunchAtLoginController
    private var task: Task<Void, Never>?

    init(
        integration: CodexIntegration,
        coordinator: ConnIntegrationCoordinator,
        defaults: UserDefaults = .standard,
        launchAtLogin: ConnLaunchAtLoginController = .init()
    ) {
        self.integration = integration
        self.coordinator = coordinator
        self.activationPreference = .init(
            defaults: defaults,
            key: Self.enabledKey
        )
        self.launchAtLogin = launchAtLogin
        launchAtLoginStatus = launchAtLogin.status
        enabled = activationPreference.resolve(defaultWhenAbsent: false)
        providerNotice = nil
        labsEnabled = defaults.bool(forKey: Self.labsKey)
    }

    var statusLabel: String {
        enabled ? "Enabled" : "Off"
    }

    func enable() {
        run { model in
            model.activationPreference.setEnabled(true)
            model.enabled = true
            await model.coordinator.setEnabled(
                CodexIntegrationIdentity.integrationID,
                true
            )
            model.providerNotice =
                "Codex supervision is enabled. Conn will not launch or stop Codex Sessions."
        }
    }

    func disable() {
        run { model in
            model.activationPreference.setEnabled(false)
            model.enabled = false
            await model.coordinator.setEnabled(
                CodexIntegrationIdentity.integrationID,
                false
            )
            model.providerNotice =
                "Codex supervision is disabled. Existing Codex work and Shared Desktop setup were left unchanged."
        }
    }

    var setupEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.setupKey)
    }

    func refresh() {
        run { model in
            await model.refreshInline()
        }
    }

    var launchAtLoginIsOn: Bool {
        ConnLaunchAtLoginPolicy.isOn(launchAtLoginStatus)
    }

    var launchAtLoginDetail: String {
        ConnLaunchAtLoginPolicy.detail(launchAtLoginStatus)
    }

    var canChangeLaunchAtLogin: Bool {
        ConnLaunchAtLoginPolicy.canChange(launchAtLoginStatus)
    }

    var sharedDesktopConsentMessage: String {
        if launchAtLoginStatus == .unavailable {
            return "This copy of Conn cannot register as a macOS login item. You can still set up Shared Desktop Labs without changing login behavior."
        }
        return "Launching Conn at login helps restore the managed App Server before you open ChatGPT/Codex Desktop. macOS does not guarantee ordering between separate login items."
    }

    func refreshLaunchAtLogin() {
        launchAtLoginStatus = launchAtLogin.status
        if launchAtLoginStatus == .enabled {
            launchAtLoginIssue = nil
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginIssue = nil
        switch launchAtLogin.setEnabled(enabled) {
        case let .success(status):
            launchAtLoginStatus = status
            if enabled, status == .requiresApproval {
                launchAtLoginIssue =
                    "macOS requires approval in System Settings before Conn can launch at login."
            } else if enabled, status != .enabled {
                launchAtLoginIssue =
                    "Conn could not confirm that launch at login is enabled."
            }
        case let .failure(error):
            launchAtLoginStatus = launchAtLogin.status
            launchAtLoginIssue = String(
                "Launch at login could not be changed: \(error.localizedDescription)"
                    .prefix(320)
            )
        }
    }

    func requestSetUp() {
        refreshLaunchAtLogin()
        if launchAtLoginStatus == .enabled {
            performSetUp()
        } else {
            showsSharedDesktopSetupConsent = true
        }
    }

    func confirmSetUp(enableLaunchAtLogin: Bool) {
        showsSharedDesktopSetupConsent = false
        if enableLaunchAtLogin {
            setLaunchAtLogin(true)
            guard ConnLaunchAtLoginPolicy.isConfirmedEnabled(
                launchAtLoginStatus
            ) else { return }
        }
        performSetUp()
    }

    func cancelSetUpConsent() {
        showsSharedDesktopSetupConsent = false
    }

    private func performSetUp() {
        run { model in
            let result = await model.setupCoordinator.setUp()
            guard !Task.isCancelled else { return }
            model.setupResult = result
            if result.outcome == .ready || result.outcome == .relaunchRequired {
                UserDefaults.standard.set(true, forKey: Self.setupKey)
            }
            await model.refreshInline()
        }
    }

    func turnOff() {
        run { model in
            let result = await model.setupCoordinator.turnOff()
            guard !Task.isCancelled else { return }
            model.setupResult = result
            if result.outcome == .disabled {
                UserDefaults.standard.set(false, forKey: Self.setupKey)
            }
            await model.refreshInline()
        }
    }

    func cancel() {
        task?.cancel()
    }

    func uninstallLegacyPlugin() {
        guard let candidate = legacyPluginCandidate else { return }
        run { model in
            let outcome = await model.integration.uninstallLegacyPlugin(
                confirmed: candidate
            )
            guard !Task.isCancelled else { return }
            model.legacyPluginResult = switch outcome {
            case .removed: "The retired Sidequest plugin was removed and verified."
            case .stillInstalled: "Codex still reports the retired plugin as installed."
            case .staleConfirmation: "The connection changed. Refresh before confirming again."
            case .alreadyAttempted: "Conn will not repeat this uninstall automatically."
            case .acknowledgementUncertain:
                "Codex may have accepted the uninstall; verify manually before retrying."
            case .unsupported: "This Codex version does not support verified removal."
            }
            if outcome == .removed || outcome == .alreadyAttempted {
                model.legacyPluginCandidate = nil
            }
            await model.refreshInline()
        }
    }

    private func run(
        _ operation: @escaping @MainActor (CodexIntegrationSettingsModel) async -> Void
    ) {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            isWorking = true
            defer { isWorking = false }
            await operation(self)
        }
    }

    private func refreshInline() async {
        let snapshot = await diagnosticsCoordinator.diagnose(
            isLabsFeatureEnabled: labsEnabled,
            isAppManagedSetupEnabled: setupEnabled
        )
        guard !Task.isCancelled else { return }
        let candidate = await integration.legacyPluginCandidate()
        guard !Task.isCancelled else { return }
        diagnostics = snapshot
        lastDiagnosedAt = Date()
        legacyPluginCandidate = candidate
    }
}

struct CodexIntegrationSettingsView: View {
    @ObservedObject var model: CodexIntegrationSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Conn startup")
                    .font(.system(size: 11, weight: .semibold))
                Toggle(
                    "Launch Conn at login",
                    isOn: Binding(
                        get: { model.launchAtLoginIsOn },
                        set: { model.setLaunchAtLogin($0) }
                    )
                )
                .disabled(!model.canChangeLaunchAtLogin)
                Text(model.launchAtLoginIssue ?? model.launchAtLoginDetail)
                    .font(.system(size: 9))
                    .foregroundStyle(
                        model.launchAtLoginIssue == nil
                            ? Color.secondary
                            : Color.orange
                    )
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Codex")
                        .font(.system(size: 13, weight: .bold))
                    Text("OpenAI Harness · built-in Integration")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isWorking {
                    ProgressView().controlSize(.small)
                }
            }

            Text(model.statusLabel)
                .font(.system(size: 9, weight: .medium))
            HStack {
                if model.enabled {
                    Button("Disable Codex") { model.disable() }
                } else {
                    Button("Enable Codex") { model.enable() }
                }
            }
            .disabled(model.isWorking)
            if let providerNotice = model.providerNotice {
                Text(providerNotice)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            if model.enabled {
                Toggle(
                    "Enable experimental Shared Desktop Labs",
                    isOn: $model.labsEnabled
                )

                if model.labsEnabled {
                    if let presentation = model.diagnostics?.presentation {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(presentation.status)
                                .font(.system(size: 11, weight: .semibold))
                            Text(presentation.detail)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text(model.diagnostics?.host.versionLabel ?? "")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                            if model.diagnostics?.evidence.versionQualification
                                != .compatible {
                                Text(
                                    "This Desktop build is outside the verified Shared Desktop tuple. Ordinary Codex supervision remains available."
                                )
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                            }
                            if let lastDiagnosedAt = model.lastDiagnosedAt {
                                Text(
                                    "Checked \(lastDiagnosedAt.formatted(date: .omitted, time: .standard))"
                                )
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    HStack {
                        Button(
                            model.lastDiagnosedAt == nil
                                ? "Diagnose"
                                : "Diagnose again"
                        ) {
                            model.refresh()
                        }
                        Button("Set up") { model.requestSetUp() }
                        Button("Turn off Shared Desktop") { model.turnOff() }
                    }
                    .disabled(model.isWorking)

                    if let result = model.setupResult {
                        Text(result.logs.last?.message ?? result.outcome.rawValue)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text(
                "Conn uses Codex App Server through the current-user managed daemon. Conn disconnecting never stops Codex work."
            )
            .font(.system(size: 10))
            .foregroundStyle(.secondary)

            if let candidate = model.legacyPluginCandidate {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Retired Sidequest plugin detected")
                        .font(.system(size: 11, weight: .semibold))
                    Text(
                        "\(candidate.pluginID) from \(candidate.marketplaceName)"
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    Button("Remove this exact plugin") {
                        model.uninstallLegacyPlugin()
                    }
                    .disabled(model.isWorking)
                    Text(
                        "This consequential action is bound to the displayed plugin and current Codex connection. Conn never retries it automatically."
                    )
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                }
            }

            if let legacyPluginResult = model.legacyPluginResult {
                Text(legacyPluginResult)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Text(
                "Harness attribution uses the installed OpenAI Codex/ChatGPT app icon, with “Codex” retained as its accessible Integration label."
            )
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
        .onAppear {
            model.refreshLaunchAtLogin()
        }
        .alert(
            "Prepare Shared Desktop Labs",
            isPresented: $model.showsSharedDesktopSetupConsent
        ) {
            Button("Set Up and Launch at Login") {
                model.confirmSetUp(enableLaunchAtLogin: true)
            }
            .disabled(!model.canChangeLaunchAtLogin)
            Button("Set Up Only") {
                model.confirmSetUp(enableLaunchAtLogin: false)
            }
            Button("Cancel", role: .cancel) {
                model.cancelSetUpConsent()
            }
        } message: {
            Text(model.sharedDesktopConsentMessage)
        }
    }
}
