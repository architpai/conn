import Foundation
import ConnDomain

public enum SharedDesktopModeState: String, Codable, Equatable, Sendable {
    case disabled
    case unconfigured
    case setupArtifactStale
    case setupFailed
    case relaunchRequired
    case desktopNotSharing
    case incompatible
    case candidateUnqualified
    case unsafe
    case awaitingDesktopThread
    case observingCandidate
    case verified
    case rollbackRequired
    case rollbackVerified
}

public enum SharedDesktopEvaluationGoal: String, Equatable, Sendable {
    case sharing
    case rollback
}

public enum SharedDesktopSetupArtifactState: String, Codable, Equatable, Sendable {
    case absent
    case current
    case stale
    case failed
}

public enum SharedDesktopEnvironmentState: String, Codable, Equatable, Sendable {
    case absent
    case configured
    case unknown
}

public enum SharedDesktopSocketState: String, Codable, Equatable, Sendable {
    case safeExpected
    case missing
    case unsafe
    case unexpected
}

public enum SharedDesktopAttachmentState: String, Codable, Equatable, Sendable {
    case notRunning
    case ordinaryPrivateStdio
    case sharedDaemon
    case unknown
}

public enum SharedDesktopVersionQualification: String, Codable, Equatable, Sendable {
    case compatible
    case incompatible
    case unknown
}

/// Exact version identity is runtime evidence. It is deliberately not Codable;
/// durable compatibility telemetry records only the bounded qualification.
public struct SharedDesktopVersionIdentity: Equatable, Sendable {
    public let setupArtifactVersion: String
    public let desktopApplicationVersion: String
    public let desktopApplicationBuild: String
    public let codexCLIVersion: String
    public let daemonAppServerVersion: String
    public let desktopBundledCodexVersion: String

    public init(
        setupArtifactVersion: String,
        desktopApplicationVersion: String,
        desktopApplicationBuild: String,
        codexCLIVersion: String,
        daemonAppServerVersion: String,
        desktopBundledCodexVersion: String
    ) {
        self.setupArtifactVersion = setupArtifactVersion
        self.desktopApplicationVersion = desktopApplicationVersion
        self.desktopApplicationBuild = desktopApplicationBuild
        self.codexCLIVersion = codexCLIVersion
        self.daemonAppServerVersion = daemonAppServerVersion
        self.desktopBundledCodexVersion = desktopBundledCodexVersion
    }

    public var isComplete: Bool {
        Self.isBounded(setupArtifactVersion)
            && Self.isBounded(desktopApplicationVersion)
            && Self.isBounded(desktopApplicationBuild)
            && Self.isBounded(codexCLIVersion)
            && Self.isBounded(daemonAppServerVersion)
            && Self.isBounded(desktopBundledCodexVersion)
    }

    private static func isBounded(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
    }
}

/// Runtime-only lifecycle evidence for the two-client safety gate. These are
/// deliberately booleans: daemon process identities and observation details
/// must not enter telemetry or durable state.
public struct SharedDesktopLifecycleEvidence: Equatable, Sendable {
    public let observerDisconnected: Bool
    public let sameManagedDaemonSurvived: Bool
    public let desktopContinuedAfterObserverDisconnect: Bool

    public init(
        observerDisconnected: Bool,
        sameManagedDaemonSurvived: Bool,
        desktopContinuedAfterObserverDisconnect: Bool
    ) {
        self.observerDisconnected = observerDisconnected
        self.sameManagedDaemonSurvived = sameManagedDaemonSurvived
        self.desktopContinuedAfterObserverDisconnect = desktopContinuedAfterObserverDisconnect
    }

    public var isComplete: Bool {
        observerDisconnected
            && sameManagedDaemonSurvived
            && desktopContinuedAfterObserverDisconnect
    }
}

/// A runtime-only token for binding an asynchronous diagnosis to the Labs
/// generation that requested it. No inspected host value enters the token.
public struct SharedDesktopDiagnosisGeneration: Equatable, Sendable {
    fileprivate let rawValue: UInt64
    fileprivate let labsWasEnabled: Bool
}

/// Pure stale-result gate for asynchronous host diagnosis. Call `begin` for
/// each request and `invalidate` whenever Labs state changes independently of a
/// request; accept a result only when its token still matches.
public struct SharedDesktopDiagnosisGenerationGate: Equatable, Sendable {
    private var generation: UInt64
    private var labsIsEnabled: Bool

    public init(isLabsFeatureEnabled: Bool = false) {
        generation = 0
        labsIsEnabled = isLabsFeatureEnabled
    }

    public mutating func begin(
        isLabsFeatureEnabled: Bool
    ) -> SharedDesktopDiagnosisGeneration {
        advance()
        labsIsEnabled = isLabsFeatureEnabled
        return .init(rawValue: generation, labsWasEnabled: isLabsFeatureEnabled)
    }

    public mutating func invalidate(isLabsFeatureEnabled: Bool) {
        advance()
        labsIsEnabled = isLabsFeatureEnabled
    }

    public func accepts(_ token: SharedDesktopDiagnosisGeneration) -> Bool {
        labsIsEnabled
            && token.labsWasEnabled
            && token.rawValue == generation
    }

    private mutating func advance() {
        generation &+= 1
        if generation == 0 { generation = 1 }
    }
}

/// A verified label is valid only while its read-only host inspection is
/// fresh. Periodic reinspection renews the lease; expiry fails closed to the
/// ordinary managed-daemon presentation.
public struct SharedDesktopDiagnosticsFreshnessLease: Equatable, Sendable {
    public static let productionLifetime: TimeInterval = 15
    public let observedAt: Date
    public let lifetime: TimeInterval

    public init(
        observedAt: Date,
        lifetime: TimeInterval = productionLifetime
    ) {
        self.observedAt = observedAt
        self.lifetime = max(0, lifetime)
    }

    public func isFresh(at date: Date) -> Bool {
        date >= observedAt && date.timeIntervalSince(observedAt) < lifetime
    }
}

public struct SharedDesktopUserConfirmations: Equatable, Sendable {
    public let persistentSetup: Bool
    public let desktopRelaunch: Bool
    /// Confirms the user observed the candidate's new event in Desktop as the
    /// other subscribed client. Conn's own event observation is not enough.
    public let verification: Bool

    public init(
        persistentSetup: Bool = false,
        desktopRelaunch: Bool = false,
        verification: Bool = false
    ) {
        self.persistentSetup = persistentSetup
        self.desktopRelaunch = desktopRelaunch
        self.verification = verification
    }
}

/// Runtime-only candidate proof. No inferred source label grants Desktop
/// provenance: the user must attest one exact thread and every observation must
/// remain bound to that identity.
public struct SharedDesktopThreadCandidateEvidence: Equatable, Sendable {
    public let threadID: AppServerThreadID
    public let userAttestedDesktopOrigin: Bool
    public let authoritativeDiscoveryThreadIDs: Set<AppServerThreadID>
    public let resumedThreadID: AppServerThreadID?
    public let resumeStartedTurn: Bool
    public let resumeTookOwnership: Bool
    public let resumeSentConsequentialAction: Bool
    public let newEventThreadID: AppServerThreadID?

    public init(
        threadID: AppServerThreadID,
        userAttestedDesktopOrigin: Bool,
        authoritativeDiscoveryThreadIDs: Set<AppServerThreadID>,
        resumedThreadID: AppServerThreadID?,
        resumeStartedTurn: Bool,
        resumeTookOwnership: Bool,
        resumeSentConsequentialAction: Bool,
        newEventThreadID: AppServerThreadID?
    ) {
        self.threadID = threadID
        self.userAttestedDesktopOrigin = userAttestedDesktopOrigin
        self.authoritativeDiscoveryThreadIDs = authoritativeDiscoveryThreadIDs
        self.resumedThreadID = resumedThreadID
        self.resumeStartedTurn = resumeStartedTurn
        self.resumeTookOwnership = resumeTookOwnership
        self.resumeSentConsequentialAction = resumeSentConsequentialAction
        self.newEventThreadID = newEventThreadID
    }

    public var isCompleteReadOnlyProof: Bool {
        !threadID.rawValue.isEmpty
            && threadID.rawValue.utf8.count <= 512
            && userAttestedDesktopOrigin
            && authoritativeDiscoveryThreadIDs.contains(threadID)
            && resumedThreadID == threadID
            && !resumeStartedTurn
            && !resumeTookOwnership
            && !resumeSentConsequentialAction
            && newEventThreadID == threadID
    }
}

/// Evidence that rollback restored ordinary Desktop startup without taking
/// ownership of the managed daemon. It is valid only for one exact version set.
public struct SharedDesktopRollbackQualification: Equatable, Sendable {
    public let versions: SharedDesktopVersionIdentity
    public let setupStateRemoved: Bool
    public let environmentRemoved: Bool
    public let ordinaryDesktopRestored: Bool
    public let managedDaemonSurvived: Bool

    public init(
        versions: SharedDesktopVersionIdentity,
        setupStateRemoved: Bool,
        environmentRemoved: Bool,
        ordinaryDesktopRestored: Bool,
        managedDaemonSurvived: Bool
    ) {
        self.versions = versions
        self.setupStateRemoved = setupStateRemoved
        self.environmentRemoved = environmentRemoved
        self.ordinaryDesktopRestored = ordinaryDesktopRestored
        self.managedDaemonSurvived = managedDaemonSurvived
    }

    public func qualifies(exact expectedVersions: SharedDesktopVersionIdentity?) -> Bool {
        guard let expectedVersions,
              versions.isComplete,
              expectedVersions.isComplete,
              versions == expectedVersions else { return false }
        return setupStateRemoved
            && environmentRemoved
            && ordinaryDesktopRestored
            && managedDaemonSurvived
    }
}

public struct SharedDesktopModeEvidence: Equatable, Sendable {
    public let goal: SharedDesktopEvaluationGoal
    public let isLabsFeatureEnabled: Bool
    public let setupArtifactState: SharedDesktopSetupArtifactState
    public let environmentState: SharedDesktopEnvironmentState
    public let socketState: SharedDesktopSocketState
    public let desktopAttachmentState: SharedDesktopAttachmentState
    public let versionQualification: SharedDesktopVersionQualification
    public let versions: SharedDesktopVersionIdentity?
    public let confirmations: SharedDesktopUserConfirmations
    public let candidate: SharedDesktopThreadCandidateEvidence?
    public let lifecycle: SharedDesktopLifecycleEvidence?
    public let rollbackQualification: SharedDesktopRollbackQualification?

    public init(
        goal: SharedDesktopEvaluationGoal = .sharing,
        isLabsFeatureEnabled: Bool,
        setupArtifactState: SharedDesktopSetupArtifactState,
        environmentState: SharedDesktopEnvironmentState,
        socketState: SharedDesktopSocketState,
        desktopAttachmentState: SharedDesktopAttachmentState,
        versionQualification: SharedDesktopVersionQualification,
        versions: SharedDesktopVersionIdentity?,
        confirmations: SharedDesktopUserConfirmations = .init(),
        candidate: SharedDesktopThreadCandidateEvidence? = nil,
        lifecycle: SharedDesktopLifecycleEvidence? = nil,
        rollbackQualification: SharedDesktopRollbackQualification? = nil
    ) {
        self.goal = goal
        self.isLabsFeatureEnabled = isLabsFeatureEnabled
        self.setupArtifactState = setupArtifactState
        self.environmentState = environmentState
        self.socketState = socketState
        self.desktopAttachmentState = desktopAttachmentState
        self.versionQualification = versionQualification
        self.versions = versions
        self.confirmations = confirmations
        self.candidate = candidate
        self.lifecycle = lifecycle
        self.rollbackQualification = rollbackQualification
    }
}

public struct SharedDesktopModeEvaluation: Equatable, Sendable {
    public let state: SharedDesktopModeState
    public let hasAttestedCandidate: Bool
    public let authoritativeDiscoveryMatched: Bool
    public let readOnlyResumeMatched: Bool
    public let newEventMatched: Bool
    public let observerDisconnected: Bool
    public let sameManagedDaemonSurvived: Bool
    public let desktopContinuedAfterObserverDisconnect: Bool
    public let rollbackQualified: Bool

    public init(
        state: SharedDesktopModeState,
        hasAttestedCandidate: Bool,
        authoritativeDiscoveryMatched: Bool,
        readOnlyResumeMatched: Bool,
        newEventMatched: Bool,
        observerDisconnected: Bool,
        sameManagedDaemonSurvived: Bool,
        desktopContinuedAfterObserverDisconnect: Bool,
        rollbackQualified: Bool
    ) {
        self.state = state
        self.hasAttestedCandidate = hasAttestedCandidate
        self.authoritativeDiscoveryMatched = authoritativeDiscoveryMatched
        self.readOnlyResumeMatched = readOnlyResumeMatched
        self.newEventMatched = newEventMatched
        self.observerDisconnected = observerDisconnected
        self.sameManagedDaemonSurvived = sameManagedDaemonSurvived
        self.desktopContinuedAfterObserverDisconnect = desktopContinuedAfterObserverDisconnect
        self.rollbackQualified = rollbackQualified
    }
}

/// Constant, privacy-safe copy for the Labs diagnostics surface. It contains no
/// inspected host values; callers may render it without forwarding raw errors.
public struct SharedDesktopModePresentation: Equatable, Sendable {
    public let state: SharedDesktopModeState
    public let title: String
    public let status: String
    public let detail: String
    public let primaryRepair: String?

    public init(evaluation: SharedDesktopModeEvaluation) {
        state = evaluation.state
        switch evaluation.state {
        case .disabled:
            title = "Shared Desktop Mode"
            status = "Disabled"
            detail = "Experimental sharing is off. Managed Daemon Mode remains available."
            primaryRepair = "Enable in Labs"
        case .unconfigured:
            title = "Shared Desktop Mode"
            status = "Not configured"
            detail = "No current-user Shared Desktop setup is installed."
            primaryRepair = "Review setup"
        case .setupArtifactStale:
            title = "Shared Desktop Mode"
            status = "Setup update required"
            detail = "The installed setup does not match this Conn release."
            primaryRepair = "Review update and rollback"
        case .setupFailed:
            title = "Shared Desktop Mode"
            status = "Setup needs repair"
            detail = "Conn could not validate the current-user setup artifact."
            primaryRepair = "Open diagnostics"
        case .relaunchRequired:
            title = "Shared Desktop Mode"
            status = "Desktop relaunch required"
            detail = "Save active Desktop work, then explicitly confirm a relaunch."
            primaryRepair = "Review relaunch"
        case .desktopNotSharing:
            title = "Shared Desktop Mode"
            status = "Desktop not sharing"
            detail = "Desktop is not observed using the validated managed daemon."
            primaryRepair = "Run diagnostics"
        case .incompatible:
            title = "Shared Desktop Mode"
            status = "Incompatible"
            detail = "The observed setup and App Server versions are not qualified together."
            primaryRepair = "Review supported versions"
        case .candidateUnqualified:
            title = "Shared Desktop Mode"
            status = "Candidate version"
            detail = "This exact version tuple may collect proof, but cannot be called verified yet."
            primaryRepair = "Run candidate proof"
        case .unsafe:
            title = "Shared Desktop Mode"
            status = "Unsafe endpoint"
            detail = "The expected private current-user socket did not pass validation."
            primaryRepair = "Inspect endpoint"
        case .awaitingDesktopThread:
            title = "Shared Desktop Mode"
            status = "Awaiting Desktop thread"
            detail = "Create a throwaway thread in Desktop, then attest its exact identity."
            primaryRepair = "Choose Desktop thread"
        case .observingCandidate:
            title = "Shared Desktop Mode"
            status = "Verifying Desktop thread"
            detail = "Conn is waiting for exact-thread or observer-disconnect continued-work evidence."
            primaryRepair = "Verify again"
        case .verified:
            title = "Shared Desktop Mode"
            status = "Verified"
            detail = "Desktop and Conn are verified clients of the same managed daemon."
            primaryRepair = nil
        case .rollbackRequired:
            title = "Shared Desktop Mode"
            status = "Rollback proof required"
            detail = "Complete the documented rollback before sharing can be called verified."
            primaryRepair = "Review rollback"
        case .rollbackVerified:
            title = "Shared Desktop Mode"
            status = "Rollback verified"
            detail = "Ordinary Desktop startup is restored and the managed daemon remains available."
            primaryRepair = nil
        }
    }
}

public enum SharedDesktopModeEvaluator {
    public static func evaluate(_ evidence: SharedDesktopModeEvidence) -> SharedDesktopModeEvaluation {
        let candidate = evidence.candidate
        let hasAttestedCandidate = candidate?.userAttestedDesktopOrigin == true
        let discoveryMatched = candidate.map {
            $0.authoritativeDiscoveryThreadIDs.contains($0.threadID)
        } ?? false
        let readOnlyResumeMatched = candidate.map {
            $0.resumedThreadID == $0.threadID
                && !$0.resumeStartedTurn
                && !$0.resumeTookOwnership
                && !$0.resumeSentConsequentialAction
        } ?? false
        let newEventMatched = candidate.map { $0.newEventThreadID == $0.threadID } ?? false
        let observerDisconnected = evidence.lifecycle?.observerDisconnected == true
        let sameManagedDaemonSurvived = evidence.lifecycle?.sameManagedDaemonSurvived == true
        let desktopContinuedAfterObserverDisconnect = evidence.lifecycle?.desktopContinuedAfterObserverDisconnect == true
        let rollbackQualified = evidence.rollbackQualification?.qualifies(
            exact: evidence.versions
        ) == true

        let state: SharedDesktopModeState
        if !evidence.isLabsFeatureEnabled {
            state = .disabled
        } else if evidence.goal == .rollback {
            state = rollbackQualified
                && evidence.setupArtifactState == .absent
                && evidence.environmentState == .absent
                && evidence.desktopAttachmentState == .ordinaryPrivateStdio
                ? .rollbackVerified
                : .rollbackRequired
        } else {
            state = sharingState(
                evidence,
                rollbackQualified: rollbackQualified
            )
        }

        return .init(
            state: state,
            hasAttestedCandidate: hasAttestedCandidate,
            authoritativeDiscoveryMatched: discoveryMatched,
            readOnlyResumeMatched: readOnlyResumeMatched,
            newEventMatched: newEventMatched,
            observerDisconnected: observerDisconnected,
            sameManagedDaemonSurvived: sameManagedDaemonSurvived,
            desktopContinuedAfterObserverDisconnect: desktopContinuedAfterObserverDisconnect,
            rollbackQualified: rollbackQualified
        )
    }

    private static func sharingState(
        _ evidence: SharedDesktopModeEvidence,
        rollbackQualified: Bool
    ) -> SharedDesktopModeState {
        switch evidence.setupArtifactState {
        case .absent: return .unconfigured
        case .stale: return .setupArtifactStale
        case .failed: return .setupFailed
        case .current: break
        }
        guard evidence.versions?.isComplete == true else { return .incompatible }
        if evidence.versionQualification == .incompatible { return .incompatible }
        switch evidence.socketState {
        case .unsafe, .unexpected: return .unsafe
        case .missing: return .desktopNotSharing
        case .safeExpected: break
        }
        guard evidence.environmentState == .configured,
              evidence.confirmations.persistentSetup,
              evidence.confirmations.desktopRelaunch else { return .relaunchRequired }
        guard evidence.desktopAttachmentState == .sharedDaemon else {
            return .desktopNotSharing
        }
        if evidence.versionQualification == .unknown { return .candidateUnqualified }
        guard evidence.candidate?.userAttestedDesktopOrigin == true else {
            return .awaitingDesktopThread
        }
        guard evidence.confirmations.verification,
              evidence.candidate?.isCompleteReadOnlyProof == true else {
            return .observingCandidate
        }
        guard evidence.lifecycle?.isComplete == true else {
            return .observingCandidate
        }
        guard rollbackQualified else { return .rollbackRequired }
        return .verified
    }
}

/// Versioned, content-free compatibility telemetry. IDs, PIDs, paths, version
/// strings, configuration, content, and raw errors are structurally absent.
public struct SharedDesktopCompatibilityTelemetry: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let state: SharedDesktopModeState
    public let setupArtifactState: SharedDesktopSetupArtifactState
    public let socketState: SharedDesktopSocketState
    public let desktopAttachmentState: SharedDesktopAttachmentState
    public let versionQualification: SharedDesktopVersionQualification
    public let hasAttestedCandidate: Bool
    public let authoritativeDiscoveryMatched: Bool
    public let readOnlyResumeMatched: Bool
    public let newEventMatched: Bool
    public let observerDisconnected: Bool
    public let sameManagedDaemonSurvived: Bool
    public let desktopContinuedAfterObserverDisconnect: Bool
    public let rollbackQualified: Bool

    public init(evidence: SharedDesktopModeEvidence) {
        let evaluation = SharedDesktopModeEvaluator.evaluate(evidence)
        schemaVersion = Self.currentSchemaVersion
        state = evaluation.state
        setupArtifactState = evidence.setupArtifactState
        socketState = evidence.socketState
        desktopAttachmentState = evidence.desktopAttachmentState
        versionQualification = evidence.versionQualification
        hasAttestedCandidate = evaluation.hasAttestedCandidate
        authoritativeDiscoveryMatched = evaluation.authoritativeDiscoveryMatched
        readOnlyResumeMatched = evaluation.readOnlyResumeMatched
        newEventMatched = evaluation.newEventMatched
        observerDisconnected = evaluation.observerDisconnected
        sameManagedDaemonSurvived = evaluation.sameManagedDaemonSurvived
        desktopContinuedAfterObserverDisconnect = evaluation.desktopContinuedAfterObserverDisconnect
        rollbackQualified = evaluation.rollbackQualified
    }
}
