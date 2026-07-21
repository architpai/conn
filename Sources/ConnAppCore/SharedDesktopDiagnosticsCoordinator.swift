import Foundation
import ConnAppServerAdapter

public struct SharedDesktopHostSummary: Equatable, Sendable {
    public let desktopVersion: String?
    public let desktopBuild: String?
    public let desktopBundledCodexVersion: String?
    public let daemonCLIVersion: String?
    public let daemonAppServerVersion: String?
    public let guiEnvironmentIsEnabled: Bool
    public let hasPrivateDesktopAppServer: Bool
    public let launchConfiguration: SharedDesktopLaunchConfigurationInspection
    public let daemonState: SharedDesktopDaemonState

    public init(
        desktopVersion: String?,
        desktopBuild: String?,
        desktopBundledCodexVersion: String?,
        daemonCLIVersion: String?,
        daemonAppServerVersion: String?,
        guiEnvironmentIsEnabled: Bool,
        hasPrivateDesktopAppServer: Bool,
        launchConfiguration: SharedDesktopLaunchConfigurationInspection,
        daemonState: SharedDesktopDaemonState
    ) {
        self.desktopVersion = desktopVersion
        self.desktopBuild = desktopBuild
        self.desktopBundledCodexVersion = desktopBundledCodexVersion
        self.daemonCLIVersion = daemonCLIVersion
        self.daemonAppServerVersion = daemonAppServerVersion
        self.guiEnvironmentIsEnabled = guiEnvironmentIsEnabled
        self.hasPrivateDesktopAppServer = hasPrivateDesktopAppServer
        self.launchConfiguration = launchConfiguration
        self.daemonState = daemonState
    }

    public var versionLabel: String {
        let desktop = [desktopVersion, desktopBuild.map { "build \($0)" }]
            .compactMap { $0 }
            .joined(separator: " · ")
        let codex = desktopBundledCodexVersion.map { "Desktop Codex \($0)" }
        let daemon = daemonAppServerVersion.map { "App Server \($0)" }
        let values = [desktop.isEmpty ? nil : "Desktop \(desktop)", codex, daemon]
            .compactMap { $0 }
        return values.isEmpty ? "Versions unavailable" : values.joined(separator: " · ")
    }

    public var setupLabel: String {
        switch launchConfiguration {
        case .missing: "Setup artifact absent"
        case .connManaged: "Setup contract v1 installed"
        case .legacyConnManaged: "Legacy setup needs migration"
        case .foreign: "Existing setup has different ownership"
        case .untrusted: "Setup artifact is unsafe"
        case .malformed: "Setup artifact is malformed"
        case .oversized: "Setup artifact exceeds the diagnostic bound"
        case .unavailable: "Setup artifact could not be inspected"
        }
    }

    public var attachmentLabel: String {
        if hasPrivateDesktopAppServer { return "Desktop uses its private App Server" }
        if guiEnvironmentIsEnabled && daemonState == .runningSafe {
            return "Desktop is a shared-daemon candidate"
        }
        return "Desktop sharing is not established"
    }
}

public struct SharedDesktopDiagnosticsSnapshot: Equatable, Sendable {
    public let evidence: SharedDesktopModeEvidence
    public let evaluation: SharedDesktopModeEvaluation
    public let presentation: SharedDesktopModePresentation
    public let host: SharedDesktopHostSummary

    public init(
        evidence: SharedDesktopModeEvidence,
        evaluation: SharedDesktopModeEvaluation,
        presentation: SharedDesktopModePresentation,
        host: SharedDesktopHostSummary
    ) {
        self.evidence = evidence
        self.evaluation = evaluation
        self.presentation = presentation
        self.host = host
    }

    /// Mechanical transport check only. This proves the named GUI flag, safe
    /// Unix socket, and Desktop process selection; it does not claim that a
    /// particular task originated in Desktop or qualify an unknown version.
    public var socketTransportPrerequisitesPassed: Bool {
        evidence.setupArtifactState == .current
            && evidence.environmentState == .configured
            && evidence.socketState == .safeExpected
            && evidence.desktopAttachmentState == .sharedDaemon
    }
}

/// Read-only orchestration for the Labs diagnostics surface. The app-managed
/// setup preference is supplied by Conn; this actor cannot write launch state
/// or signal another process.
public actor SharedDesktopDiagnosticsCoordinator {
    private let inspector: SharedDesktopHostInspector

    public init(inspector: SharedDesktopHostInspector = .init()) {
        self.inspector = inspector
    }

    public func diagnose(
        isLabsFeatureEnabled: Bool,
        isAppManagedSetupEnabled: Bool = false,
        candidate: SharedDesktopThreadCandidateEvidence? = nil,
        lifecycle: SharedDesktopLifecycleEvidence? = nil,
        verificationConfirmed: Bool = false,
        rollbackQualification: SharedDesktopRollbackQualification? = nil,
        goal: SharedDesktopEvaluationGoal = .sharing
    ) async -> SharedDesktopDiagnosticsSnapshot {
        let inspection = await inspector.inspect()
        let versions = Self.versionIdentity(from: inspection)
        let attachment = Self.attachmentState(from: inspection)
        let evidence = SharedDesktopModeEvidence(
            goal: goal,
            isLabsFeatureEnabled: isLabsFeatureEnabled,
            setupArtifactState: Self.setupArtifactState(
                inspection.launchConfiguration,
                isAppManagedSetupEnabled: isAppManagedSetupEnabled
            ),
            environmentState: Self.environmentState(inspection.guiEnvironment),
            socketState: Self.socketState(inspection.daemon.state),
            desktopAttachmentState: attachment,
            versionQualification: Self.versionQualification(
                inspection,
                versions: versions
            ),
            versions: versions,
            confirmations: .init(
                persistentSetup: (
                    isAppManagedSetupEnabled
                        || inspection.launchConfiguration == .connManaged
                ) && inspection.guiEnvironment == .enabled,
                desktopRelaunch: attachment == .sharedDaemon,
                verification: verificationConfirmed
            ),
            candidate: candidate,
            lifecycle: lifecycle,
            rollbackQualification: rollbackQualification
        )
        let evaluation = SharedDesktopModeEvaluator.evaluate(evidence)
        return .init(
            evidence: evidence,
            evaluation: evaluation,
            presentation: .init(evaluation: evaluation),
            host: .init(
                desktopVersion: inspection.bundle.shortVersion,
                desktopBuild: inspection.bundle.buildVersion,
                desktopBundledCodexVersion: inspection.bundledCLI.version,
                daemonCLIVersion: inspection.daemon.cliVersion,
                daemonAppServerVersion: inspection.daemon.appServerVersion,
                guiEnvironmentIsEnabled: inspection.guiEnvironment == .enabled,
                hasPrivateDesktopAppServer: inspection.desktopTopology.privateAppServerChild == .single
                    || inspection.desktopTopology.privateAppServerChild == .multiple,
                launchConfiguration: inspection.launchConfiguration,
                daemonState: inspection.daemon.state
            )
        )
    }

    /// Re-evaluates runtime-only exact-thread evidence against the most recent
    /// bounded host inspection without launching another diagnostic command.
    public func reevaluate(
        _ previous: SharedDesktopDiagnosticsSnapshot,
        candidate: SharedDesktopThreadCandidateEvidence?,
        verificationConfirmed: Bool,
        lifecycle: SharedDesktopLifecycleEvidence? = nil
    ) -> SharedDesktopDiagnosticsSnapshot {
        let previousEvidence = previous.evidence
        let evidence = SharedDesktopModeEvidence(
            goal: previousEvidence.goal,
            isLabsFeatureEnabled: previousEvidence.isLabsFeatureEnabled,
            setupArtifactState: previousEvidence.setupArtifactState,
            environmentState: previousEvidence.environmentState,
            socketState: previousEvidence.socketState,
            desktopAttachmentState: previousEvidence.desktopAttachmentState,
            versionQualification: previousEvidence.versionQualification,
            versions: previousEvidence.versions,
            confirmations: .init(
                persistentSetup: previousEvidence.confirmations.persistentSetup,
                desktopRelaunch: previousEvidence.confirmations.desktopRelaunch,
                verification: verificationConfirmed
            ),
            candidate: candidate,
            lifecycle: lifecycle ?? previousEvidence.lifecycle,
            rollbackQualification: previousEvidence.rollbackQualification
        )
        let evaluation = SharedDesktopModeEvaluator.evaluate(evidence)
        return .init(
            evidence: evidence,
            evaluation: evaluation,
            presentation: .init(evaluation: evaluation),
            host: previous.host
        )
    }

    private static func setupArtifactState(
        _ state: SharedDesktopLaunchConfigurationInspection,
        isAppManagedSetupEnabled: Bool
    ) -> SharedDesktopSetupArtifactState {
        switch state {
        case .missing: isAppManagedSetupEnabled ? .current : .absent
        case .connManaged: .current
        case .legacyConnManaged: isAppManagedSetupEnabled ? .current : .stale
        case .foreign, .untrusted, .malformed, .oversized, .unavailable: .failed
        }
    }

    private static func environmentState(
        _ state: SharedDesktopGUIEnvironmentInspection
    ) -> SharedDesktopEnvironmentState {
        switch state {
        case .enabled: .configured
        case .disabled: .absent
        case .unexpected, .unavailable: .unknown
        }
    }

    private static func socketState(
        _ state: SharedDesktopDaemonState
    ) -> SharedDesktopSocketState {
        switch state {
        case .runningSafe: .safeExpected
        case .stopped, .missing: .missing
        case .unsafeEndpoint: .unsafe
        case .incompatible, .malformed, .unavailable: .unexpected
        }
    }

    private static func attachmentState(
        from inspection: SharedDesktopHostInspection
    ) -> SharedDesktopAttachmentState {
        switch inspection.desktopTopology.desktop {
        case .notRunning:
            return .notRunning
        case .multiple, .unavailable:
            return .unknown
        case .single:
            switch inspection.desktopTopology.privateAppServerChild {
            case .single, .multiple:
                return .ordinaryPrivateStdio
            case .absent:
                return inspection.guiEnvironment == .enabled
                    && inspection.daemon.state == .runningSafe
                    ? .sharedDaemon
                    : .unknown
            case .notApplicable, .unavailable:
                return .unknown
            }
        }
    }

    private static func versionIdentity(
        from inspection: SharedDesktopHostInspection
    ) -> SharedDesktopVersionIdentity? {
        guard let desktopVersion = inspection.bundle.shortVersion,
              let desktopBuild = inspection.bundle.buildVersion,
              let daemonCLI = inspection.daemon.cliVersion,
              let daemonAppServer = inspection.daemon.appServerVersion,
              let desktopBundledCodex = inspection.bundledCLI.version else { return nil }
        return .init(
            setupArtifactVersion: "1",
            desktopApplicationVersion: desktopVersion,
            desktopApplicationBuild: desktopBuild,
            codexCLIVersion: daemonCLI,
            daemonAppServerVersion: daemonAppServer,
            desktopBundledCodexVersion: desktopBundledCodex
        )
    }

    /// Phase 5 established transport compatibility for this historical app
    /// tuple. It did not exercise the Phase 10 flag-only setup contract, so it
    /// receives no production lifecycle or rollback qualification here.
    private static func isPhase5TransportCompatibleTuple(
        _ versions: SharedDesktopVersionIdentity
    ) -> Bool {
        versions.setupArtifactVersion == "1"
            && versions.desktopApplicationVersion == "26.715.31251"
            && versions.desktopApplicationBuild == "5538"
            && versions.desktopBundledCodexVersion == "0.145.0-alpha.18"
            && ((versions.codexCLIVersion == "0.144.5"
                    && versions.daemonAppServerVersion == "0.144.5")
                || (versions.codexCLIVersion == "0.144.6"
                    && versions.daemonAppServerVersion == "0.144.6"))
    }

    private static func versionQualification(
        _ inspection: SharedDesktopHostInspection,
        versions: SharedDesktopVersionIdentity?
    ) -> SharedDesktopVersionQualification {
        guard let versions,
              versions.isComplete,
              inspection.bundle.state == .available,
              inspection.bundledCLI.state == .available,
              inspection.daemon.state == .runningSafe else {
            return .unknown
        }
        let phase5Tuple = isPhase5TransportCompatibleTuple(versions)
        return phase5Tuple ? .compatible : .unknown
    }
}
