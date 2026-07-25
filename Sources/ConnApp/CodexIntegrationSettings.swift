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

    private static let labsKey = "sharedDesktopLabs.v1"
    private static let setupKey = "sharedDesktopAppManaged.v1"
    private let diagnosticsCoordinator = SharedDesktopDiagnosticsCoordinator()
    private let setupCoordinator = SharedDesktopSetupCoordinator()
    private var task: Task<Void, Never>?

    init() {
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
                    }
                }
                HStack {
                    Button("Diagnose") { model.refresh() }
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

            Text(
                "Harness attribution uses the text badge “Codex” in this alpha. OpenAI’s mark remains reserved until the exact in-product placement clears the current brand terms."
            )
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
    }
}
