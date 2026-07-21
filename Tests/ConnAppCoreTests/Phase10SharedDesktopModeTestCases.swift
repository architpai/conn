import Foundation
import ConnAppCore
import ConnDomain

enum Phase10SharedDesktopModeTestCases {
    static func run(into suite: inout TestSuite) throws {
        preciseSetupAndRepairStates(into: &suite)
        refusesInferredOrIncompleteDesktopOrigin(into: &suite)
        requiresTheFullVerificationConjunction(into: &suite)
        requiresObserverDisconnectAndContinuedWork(into: &suite)
        bindsRollbackToExactVersions(into: &suite)
        rejectsStaleDiagnosisGenerations(into: &suite)
        providesPrivacySafePresentation(into: &suite)
        try keepsTelemetryContentFree(into: &suite)
    }

    private static func preciseSetupAndRepairStates(into suite: inout TestSuite) {
        suite.checkEqual(evaluate(base(isLabsFeatureEnabled: false)).state, .disabled, "Labs opt-out is disabled")
        suite.checkEqual(evaluate(base(setupArtifactState: .absent)).state, .unconfigured, "missing setup is unconfigured")
        suite.checkEqual(evaluate(base(setupArtifactState: .stale)).state, .setupArtifactStale, "stale setup is precise")
        suite.checkEqual(evaluate(base(setupArtifactState: .failed)).state, .setupFailed, "failed setup is precise")
        suite.checkEqual(evaluate(base(versionQualification: .incompatible)).state, .incompatible, "version mismatch is incompatible")
        suite.checkEqual(evaluate(base(versionQualification: .unknown)).state, .candidateUnqualified, "unknown version compatibility permits evidence gathering but never verification")
        suite.checkEqual(evaluate(base(versions: nil)).state, .incompatible, "missing exact versions fail closed")
        suite.checkEqual(evaluate(base(socketState: .unsafe)).state, .unsafe, "unsafe socket fails closed")
        suite.checkEqual(evaluate(base(socketState: .unexpected)).state, .unsafe, "unexpected socket fails closed")
        suite.checkEqual(evaluate(base(confirmations: .init())).state, .relaunchRequired, "missing confirmations require relaunch setup")
        suite.checkEqual(evaluate(base(desktopAttachmentState: .ordinaryPrivateStdio)).state, .desktopNotSharing, "ordinary Desktop child is not sharing")
        suite.checkEqual(evaluate(base(candidate: nil)).state, .awaitingDesktopThread, "sharing host still requires Desktop thread")

        let deterministic = base(candidate: candidate(), rollbackQualification: rollback())
        suite.checkEqual(evaluate(deterministic), evaluate(deterministic), "repeated evaluation is deterministic and idempotent")
    }

    private static func refusesInferredOrIncompleteDesktopOrigin(into suite: inout TestSuite) {
        let inferred = candidate(userAttested: false)
        suite.checkEqual(evaluate(base(candidate: inferred)).state, .awaitingDesktopThread, "source-like observations cannot replace user attestation")

        let wrongDiscovery = candidate(discoveredIDs: [.init(rawValue: "some-other-thread")])
        suite.checkEqual(evaluate(base(candidate: wrongDiscovery)).state, .observingCandidate, "authoritative discovery must contain the exact candidate")

        let wrongResume = candidate(resumedID: .init(rawValue: "some-other-thread"))
        suite.checkEqual(evaluate(base(candidate: wrongResume)).state, .observingCandidate, "resume must bind to the exact candidate")

        let owningResume = candidate(resumeTookOwnership: true)
        suite.checkEqual(evaluate(base(candidate: owningResume)).state, .observingCandidate, "ownership-taking resume is refused")

        let consequentialResume = candidate(resumeSentConsequentialAction: true)
        suite.checkEqual(evaluate(base(candidate: consequentialResume)).state, .observingCandidate, "resume proof cannot send a consequential action")

        let wrongEvent = candidate(newEventThreadID: .init(rawValue: "some-other-thread"))
        suite.checkEqual(evaluate(base(candidate: wrongEvent)).state, .observingCandidate, "new event must bind to the exact candidate")
    }

    private static func requiresTheFullVerificationConjunction(into suite: inout TestSuite) {
        let completeCandidate = candidate()
        let withoutUserConfirmation = base(
            confirmations: .init(persistentSetup: true, desktopRelaunch: true),
            candidate: completeCandidate,
            rollbackQualification: rollback()
        )
        suite.checkEqual(evaluate(withoutUserConfirmation).state, .observingCandidate, "verification requires explicit user confirmation")

        let withoutRollback = base(candidate: completeCandidate)
        suite.checkEqual(evaluate(withoutRollback).state, .rollbackRequired, "complete sharing proof still requires qualified rollback")

        let verified = base(candidate: completeCandidate, rollbackQualification: rollback())
        let result = evaluate(verified)
        suite.checkEqual(result.state, .verified, "full exact evidence becomes verified")
        suite.check(result.hasAttestedCandidate, "verified evidence includes attestation")
        suite.check(result.authoritativeDiscoveryMatched, "verified evidence includes authoritative discovery")
        suite.check(result.readOnlyResumeMatched, "verified evidence includes read-only resume")
        suite.check(result.newEventMatched, "verified evidence includes an exact-thread event")
        suite.check(result.rollbackQualified, "verified evidence includes exact-version rollback")
    }

    private static func bindsRollbackToExactVersions(into suite: inout TestSuite) {
        let changedVersions = SharedDesktopVersionIdentity(
            setupArtifactVersion: "2",
            desktopApplicationVersion: "26.715.31251",
            desktopApplicationBuild: "5538",
            codexCLIVersion: "0.144.6",
            daemonAppServerVersion: "0.144.6",
            desktopBundledCodexVersion: "0.145.0-alpha.19"
        )
        let staleRollback = SharedDesktopRollbackQualification(
            versions: versions(),
            setupStateRemoved: true,
            environmentRemoved: true,
            ordinaryDesktopRestored: true,
            managedDaemonSurvived: true
        )
        let sharing = base(
            versions: changedVersions,
            candidate: candidate(),
            rollbackQualification: staleRollback
        )
        suite.checkEqual(evaluate(sharing).state, .rollbackRequired, "version changes invalidate old rollback proof")

        let rollbackPending = base(goal: .rollback, setupArtifactState: .current, rollbackQualification: rollback())
        suite.checkEqual(evaluate(rollbackPending).state, .rollbackRequired, "rollback stays required while setup remains")

        let rollbackComplete = base(
            goal: .rollback,
            setupArtifactState: .absent,
            environmentState: .absent,
            desktopAttachmentState: .ordinaryPrivateStdio,
            rollbackQualification: rollback()
        )
        suite.checkEqual(evaluate(rollbackComplete).state, .rollbackVerified, "ordinary Desktop plus removed setup verifies rollback")

        let daemonStopped = SharedDesktopRollbackQualification(
            versions: versions(),
            setupStateRemoved: true,
            environmentRemoved: true,
            ordinaryDesktopRestored: true,
            managedDaemonSurvived: false
        )
        suite.checkEqual(
            evaluate(base(
                goal: .rollback,
                setupArtifactState: .absent,
                environmentState: .absent,
                desktopAttachmentState: .ordinaryPrivateStdio,
                rollbackQualification: daemonStopped
            )).state,
            .rollbackRequired,
            "rollback cannot claim success after stopping the managed daemon"
        )
    }

    private static func requiresObserverDisconnectAndContinuedWork(into suite: inout TestSuite) {
        let incompleteCases: [(SharedDesktopLifecycleEvidence?, String)] = [
            (nil, "missing lifecycle evidence"),
            (.init(
                observerDisconnected: false,
                sameManagedDaemonSurvived: true,
                desktopContinuedAfterObserverDisconnect: true
            ), "observer remained connected"),
            (.init(
                observerDisconnected: true,
                sameManagedDaemonSurvived: false,
                desktopContinuedAfterObserverDisconnect: true
            ), "daemon identity did not survive"),
            (.init(
                observerDisconnected: true,
                sameManagedDaemonSurvived: true,
                desktopContinuedAfterObserverDisconnect: false
            ), "Desktop did not continue work"),
        ]
        for (lifecycle, reason) in incompleteCases {
            let result = evaluate(base(
                candidate: candidate(),
                lifecycle: lifecycle,
                rollbackQualification: rollback()
            ))
            suite.checkEqual(result.state, .observingCandidate, "\(reason) blocks verification")
        }

        let complete = evaluate(base(
            candidate: candidate(),
            lifecycle: lifecycle(),
            rollbackQualification: rollback()
        ))
        suite.checkEqual(complete.state, .verified, "observer disconnect plus same-daemon continued Desktop work completes the lifecycle gate")
        suite.check(complete.observerDisconnected, "evaluation exposes content-free observer-disconnect evidence")
        suite.check(complete.sameManagedDaemonSurvived, "evaluation exposes content-free same-daemon survival evidence")
        suite.check(complete.desktopContinuedAfterObserverDisconnect, "evaluation exposes content-free Desktop continued-work evidence")
    }

    private static func rejectsStaleDiagnosisGenerations(into suite: inout TestSuite) {
        var gate = SharedDesktopDiagnosisGenerationGate()
        let disabledRequest = gate.begin(isLabsFeatureEnabled: false)
        suite.check(!gate.accepts(disabledRequest), "a diagnosis requested while Labs is disabled is never accepted")

        let firstEnabledRequest = gate.begin(isLabsFeatureEnabled: true)
        suite.check(gate.accepts(firstEnabledRequest), "the current Labs-enabled diagnosis generation is accepted")
        let newerEnabledRequest = gate.begin(isLabsFeatureEnabled: true)
        suite.check(!gate.accepts(firstEnabledRequest), "a later diagnosis invalidates an older async result")
        suite.check(gate.accepts(newerEnabledRequest), "the newest enabled diagnosis remains current")

        gate.invalidate(isLabsFeatureEnabled: false)
        suite.check(!gate.accepts(newerEnabledRequest), "disabling Labs rejects an in-flight enabled diagnosis")
        gate.invalidate(isLabsFeatureEnabled: true)
        suite.check(!gate.accepts(newerEnabledRequest), "re-enabling Labs does not revive a stale diagnosis result")

        let observed = Date(timeIntervalSince1970: 1_000)
        let lease = SharedDesktopDiagnosticsFreshnessLease(observedAt: observed, lifetime: 15)
        suite.check(lease.isFresh(at: observed.addingTimeInterval(14.999)), "diagnostic lease remains fresh before its bound")
        suite.check(!lease.isFresh(at: observed.addingTimeInterval(15)), "diagnostic lease fails closed at expiry")
        suite.check(!lease.isFresh(at: observed.addingTimeInterval(-1)), "diagnostic lease rejects time before observation")
    }

    private static func keepsTelemetryContentFree(into suite: inout TestSuite) throws {
        let canary = "PRIVATE-CONTENT-CANARY"
        let canaryID = AppServerThreadID(rawValue: "thread-\(canary)")
        let privateVersions = SharedDesktopVersionIdentity(
            setupArtifactVersion: "setup-\(canary)",
            desktopApplicationVersion: "app-\(canary)",
            desktopApplicationBuild: "build-\(canary)",
            codexCLIVersion: "cli-\(canary)",
            daemonAppServerVersion: "daemon-\(canary)",
            desktopBundledCodexVersion: "desktop-\(canary)"
        )
        let privateCandidate = SharedDesktopThreadCandidateEvidence(
            threadID: canaryID,
            userAttestedDesktopOrigin: true,
            authoritativeDiscoveryThreadIDs: [canaryID],
            resumedThreadID: canaryID,
            resumeStartedTurn: false,
            resumeTookOwnership: false,
            resumeSentConsequentialAction: false,
            newEventThreadID: canaryID
        )
        let privateRollback = SharedDesktopRollbackQualification(
            versions: privateVersions,
            setupStateRemoved: true,
            environmentRemoved: true,
            ordinaryDesktopRestored: true,
            managedDaemonSurvived: true
        )
        let evidence = base(
            versions: privateVersions,
            candidate: privateCandidate,
            rollbackQualification: privateRollback
        )
        let telemetry = SharedDesktopCompatibilityTelemetry(evidence: evidence)
        let encoded = try JSONEncoder().encode(telemetry)
        let json = String(decoding: encoded, as: UTF8.self)
        suite.check(!json.contains(canary), "telemetry structurally omits ID, path, content, config, and raw version canaries")
        suite.check(
            !json.contains("threadID")
                && !json.contains("pid")
                && !json.contains("path")
                && !json.contains("environment")
                && !json.contains("config"),
            "telemetry has no identity, path, environment, or configuration fields"
        )
        suite.checkEqual(telemetry.schemaVersion, 1, "telemetry schema is explicitly versioned")
        suite.checkEqual(try JSONDecoder().decode(SharedDesktopCompatibilityTelemetry.self, from: encoded), telemetry, "content-free telemetry round trips")
    }

    private static func providesPrivacySafePresentation(into suite: inout TestSuite) {
        let verified = SharedDesktopModePresentation(evaluation: evaluate(base(
            candidate: candidate(),
            rollbackQualification: rollback()
        )))
        suite.checkEqual(verified.status, "Verified", "presentation exposes concise verified status")
        suite.check(verified.primaryRepair == nil, "verified presentation has no repair action")

        let relaunch = SharedDesktopModePresentation(evaluation: evaluate(base(confirmations: .init())))
        suite.checkEqual(relaunch.status, "Desktop relaunch required", "presentation distinguishes relaunch confirmation")
        suite.check(relaunch.detail.contains("explicitly confirm"), "relaunch copy makes confirmation explicit")
        suite.check(relaunch.primaryRepair != nil, "repairable state exposes one primary repair")
    }

    private static func evaluate(_ evidence: SharedDesktopModeEvidence) -> SharedDesktopModeEvaluation {
        SharedDesktopModeEvaluator.evaluate(evidence)
    }

    private static func base(
        goal: SharedDesktopEvaluationGoal = .sharing,
        isLabsFeatureEnabled: Bool = true,
        setupArtifactState: SharedDesktopSetupArtifactState = .current,
        environmentState: SharedDesktopEnvironmentState = .configured,
        socketState: SharedDesktopSocketState = .safeExpected,
        desktopAttachmentState: SharedDesktopAttachmentState = .sharedDaemon,
        versionQualification: SharedDesktopVersionQualification = .compatible,
        versions: SharedDesktopVersionIdentity? = versions(),
        confirmations: SharedDesktopUserConfirmations = .init(
            persistentSetup: true,
            desktopRelaunch: true,
            verification: true
        ),
        candidate: SharedDesktopThreadCandidateEvidence? = nil,
        lifecycle: SharedDesktopLifecycleEvidence? = lifecycle(),
        rollbackQualification: SharedDesktopRollbackQualification? = nil
    ) -> SharedDesktopModeEvidence {
        .init(
            goal: goal,
            isLabsFeatureEnabled: isLabsFeatureEnabled,
            setupArtifactState: setupArtifactState,
            environmentState: environmentState,
            socketState: socketState,
            desktopAttachmentState: desktopAttachmentState,
            versionQualification: versionQualification,
            versions: versions,
            confirmations: confirmations,
            candidate: candidate,
            lifecycle: lifecycle,
            rollbackQualification: rollbackQualification
        )
    }

    private static func versions() -> SharedDesktopVersionIdentity {
        .init(
            setupArtifactVersion: "1",
            desktopApplicationVersion: "26.715.31251",
            desktopApplicationBuild: "5538",
            codexCLIVersion: "0.144.6",
            daemonAppServerVersion: "0.144.6",
            desktopBundledCodexVersion: "0.145.0-alpha.18"
        )
    }

    private static func lifecycle() -> SharedDesktopLifecycleEvidence {
        .init(
            observerDisconnected: true,
            sameManagedDaemonSurvived: true,
            desktopContinuedAfterObserverDisconnect: true
        )
    }

    private static func candidate(
        userAttested: Bool = true,
        discoveredIDs: Set<AppServerThreadID>? = nil,
        resumedID: AppServerThreadID? = .init(rawValue: "desktop-thread"),
        resumeTookOwnership: Bool = false,
        resumeSentConsequentialAction: Bool = false,
        newEventThreadID: AppServerThreadID? = .init(rawValue: "desktop-thread")
    ) -> SharedDesktopThreadCandidateEvidence {
        let threadID = AppServerThreadID(rawValue: "desktop-thread")
        return .init(
            threadID: threadID,
            userAttestedDesktopOrigin: userAttested,
            authoritativeDiscoveryThreadIDs: discoveredIDs ?? [threadID],
            resumedThreadID: resumedID,
            resumeStartedTurn: false,
            resumeTookOwnership: resumeTookOwnership,
            resumeSentConsequentialAction: resumeSentConsequentialAction,
            newEventThreadID: newEventThreadID
        )
    }

    private static func rollback() -> SharedDesktopRollbackQualification {
        .init(
            versions: versions(),
            setupStateRemoved: true,
            environmentRemoved: true,
            ordinaryDesktopRestored: true,
            managedDaemonSurvived: true
        )
    }
}
