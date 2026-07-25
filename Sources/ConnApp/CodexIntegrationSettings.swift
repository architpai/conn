import SwiftUI
import ConnCodexAdapter

@MainActor
final class CodexIntegrationSettingsModel: ObservableObject {
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

    private static let labsKey = "sharedDesktopLabs.v1"
    private static let setupKey = "sharedDesktopAppManaged.v1"
    private let diagnosticsCoordinator = SharedDesktopDiagnosticsCoordinator()
    private let setupCoordinator = SharedDesktopSetupCoordinator()
    private let integration: CodexIntegration
    private var task: Task<Void, Never>?

    init(integration: CodexIntegration) {
        self.integration = integration
        labsEnabled = UserDefaults.standard.bool(forKey: Self.labsKey)
    }

    var setupEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.setupKey)
    }

    func refresh() {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            isWorking = true
            let snapshot = await diagnosticsCoordinator.diagnose(
                isLabsFeatureEnabled: labsEnabled,
                isAppManagedSetupEnabled: setupEnabled
            )
            guard !Task.isCancelled else { return }
            diagnostics = snapshot
            lastDiagnosedAt = Date()
            legacyPluginCandidate = await integration.legacyPluginCandidate()
            isWorking = false
        }
    }

    func setUp() {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            isWorking = true
            let result = await setupCoordinator.setUp()
            setupResult = result
            if result.outcome == .ready || result.outcome == .relaunchRequired {
                UserDefaults.standard.set(true, forKey: Self.setupKey)
            }
            isWorking = false
            refresh()
        }
    }

    func turnOff() {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            isWorking = true
            let result = await setupCoordinator.turnOff()
            setupResult = result
            if result.outcome == .disabled {
                UserDefaults.standard.set(false, forKey: Self.setupKey)
            }
            isWorking = false
            refresh()
        }
    }

    func cancel() {
        task?.cancel()
    }

    func uninstallLegacyPlugin() {
        guard let candidate = legacyPluginCandidate else { return }
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            isWorking = true
            let outcome = await integration.uninstallLegacyPlugin(
                confirmed: candidate
            )
            legacyPluginResult = switch outcome {
            case .removed: "The retired Sidequest plugin was removed and verified."
            case .stillInstalled: "Codex still reports the retired plugin as installed."
            case .staleConfirmation: "The connection changed. Refresh before confirming again."
            case .alreadyAttempted: "Conn will not repeat this uninstall automatically."
            case .acknowledgementUncertain:
                "Codex may have accepted the uninstall; verify manually before retrying."
            case .unsupported: "This Codex version does not support verified removal."
            }
            legacyPluginCandidate = nil
            isWorking = false
        }
    }
}

struct CodexIntegrationSettingsView: View {
    @ObservedObject var model: CodexIntegrationSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            Toggle("Enable experimental Shared Desktop Labs", isOn: $model.labsEnabled)

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
                    Button("Set up") { model.setUp() }
                    Button("Turn off") { model.turnOff() }
                }
                .disabled(model.isWorking)

                if let result = model.setupResult {
                    Text(result.logs.last?.message ?? result.outcome.rawValue)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
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
                "Harness attribution uses the text badge “Codex” in this alpha. OpenAI’s mark remains reserved until the exact in-product placement clears the current brand terms."
            )
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
    }
}
