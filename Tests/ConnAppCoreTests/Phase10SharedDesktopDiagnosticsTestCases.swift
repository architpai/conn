import Foundation
import ConnAppCore
import ConnAppServerAdapter
import ConnDomain

enum Phase10SharedDesktopDiagnosticsTestCases {
    static func run(into suite: inout TestSuite) async {
        await mapsSetupArtifactProvenance(into: &suite)
        await mapsInstalledAppManagedSetup(into: &suite)
        await mapsSafePrivateAndSharedTopology(into: &suite)
        await qualifiesOnlyTheExactPhase5Tuple(into: &suite)
        await keepsRawHostFactsOutOfTheSummary(into: &suite)
        await respectsLabsOptOutAndNeverVerifiesFromHostFacts(into: &suite)
    }

    private static func mapsInstalledAppManagedSetup(into suite: inout TestSuite) async {
        let snapshot = await diagnose(
            isAppManagedSetupEnabled: true,
            launchConfiguration: .missing
        )
        suite.checkEqual(
            snapshot.evidence.setupArtifactState,
            .current,
            "an opted-in installed Conn app replaces the extra launch artifact"
        )
        suite.check(
            snapshot.evidence.confirmations.persistentSetup,
            "the persisted Conn preference plus named GUI flag qualifies app-managed setup"
        )
        suite.checkEqual(
            snapshot.evaluation.state,
            .awaitingDesktopThread,
            "app-managed setup reaches the same candidate proof boundary without a LaunchAgent"
        )
        suite.check(
            snapshot.socketTransportPrerequisitesPassed,
            "socket diagnosis passes from exact setup, flag, endpoint, and Desktop process selection"
        )
        let privateDesktop = await diagnose(
            isAppManagedSetupEnabled: true,
            launchConfiguration: .missing,
            processes: .value([
                .init(processID: 41, parentProcessID: 1, isDesktopExecutable: true, isPrivateAppServerChild: false),
                .init(processID: 42, parentProcessID: 41, isDesktopExecutable: false, isPrivateAppServerChild: true),
            ])
        )
        suite.check(
            !privateDesktop.socketTransportPrerequisitesPassed,
            "a direct Desktop stdio child fails the simplified socket diagnosis"
        )
    }

    private static func mapsSetupArtifactProvenance(into suite: inout TestSuite) async {
        let cases: [(
            SharedDesktopBoundedDataFact,
            SharedDesktopLaunchConfigurationInspection,
            SharedDesktopSetupArtifactState,
            SharedDesktopModeState
        )] = [
            (.value(currentLaunchPlist()), .connManaged, .current, .awaitingDesktopThread),
            (.value(legacyLaunchPlist()), .legacyConnManaged, .stale, .setupArtifactStale),
            (.missing, .missing, .absent, .unconfigured),
            (.value(foreignLaunchPlist()), .foreign, .failed, .setupFailed),
        ]

        for (fact, expectedInspection, expectedEvidence, expectedState) in cases {
            let snapshot = await diagnose(launchConfiguration: fact)
            suite.checkEqual(
                snapshot.host.launchConfiguration,
                expectedInspection,
                "host summary preserves only launch-configuration provenance"
            )
            suite.checkEqual(
                snapshot.evidence.setupArtifactState,
                expectedEvidence,
                "coordinator maps launch provenance into the exact setup evidence"
            )
            suite.checkEqual(
                snapshot.evaluation.state,
                expectedState,
                "setup provenance maps to its precise repair state"
            )
        }
    }

    private static func mapsSafePrivateAndSharedTopology(into suite: inout TestSuite) async {
        let shared = await diagnose()
        suite.checkEqual(shared.evidence.socketState, .safeExpected, "safe daemon maps to expected private socket")
        suite.checkEqual(shared.evidence.desktopAttachmentState, .sharedDaemon, "one Desktop without a private child maps to shared daemon")
        suite.check(!shared.host.hasPrivateDesktopAppServer, "shared topology reports no private Desktop App Server")

        let privateChild = await diagnose(processes: .value([
            .init(processID: 41, parentProcessID: 1, isDesktopExecutable: true, isPrivateAppServerChild: false),
            .init(processID: 42, parentProcessID: 41, isDesktopExecutable: false, isPrivateAppServerChild: true),
        ]))
        suite.checkEqual(privateChild.evidence.desktopAttachmentState, .ordinaryPrivateStdio, "exact private child maps to ordinary Desktop topology")
        suite.check(privateChild.host.hasPrivateDesktopAppServer, "private child is exposed only as a boolean")
        suite.checkEqual(privateChild.evaluation.state, .relaunchRequired, "ordinary Desktop requires an explicitly confirmed relaunch")

        let unsafe = await diagnose(daemon: .value(
            kind: .endpointRefused,
            cliVersion: "0.144.6",
            appServerVersion: "0.144.6"
        ))
        suite.checkEqual(unsafe.evidence.socketState, .unsafe, "refused endpoint maps to unsafe")
        suite.checkEqual(unsafe.evaluation.state, .unsafe, "unsafe endpoint remains the precise blocking state before sharing")

        let absentDesktop = await diagnose(processes: .value([]))
        suite.checkEqual(absentDesktop.evidence.desktopAttachmentState, .notRunning, "absent Desktop remains explicit")
        suite.checkEqual(absentDesktop.evaluation.state, .relaunchRequired, "absent Desktop still requires an explicitly confirmed launch")
    }

    private static func qualifiesOnlyTheExactPhase5Tuple(into suite: inout TestSuite) async {
        let phase5 = await diagnose()
        suite.checkEqual(phase5.evidence.versionQualification, .compatible, "exact Phase 5 Desktop and daemon tuple is transport-compatible")
        suite.checkEqual(phase5.evidence.versions?.desktopApplicationVersion, "26.715.31251", "Desktop application version participates in the exact identity")
        suite.checkEqual(phase5.evidence.versions?.desktopApplicationBuild, "5538", "Desktop application build participates in the exact identity")
        suite.checkEqual(phase5.evidence.versions?.desktopBundledCodexVersion, "0.145.0-alpha.18", "exact Desktop bundled version reaches runtime evidence")
        suite.check(phase5.evidence.rollbackQualification == nil, "Phase 5 does not qualify the new v1 setup contract rollback")
        suite.check(phase5.evidence.lifecycle == nil, "Phase 5 does not qualify the new v1 setup contract lifecycle")
        suite.checkEqual(phase5.evaluation.state, .awaitingDesktopThread, "compatible host facts still require a real Desktop thread")

        let phase5Verified = await diagnose(
            candidate: completeCandidate(),
            verificationConfirmed: true
        )
        suite.checkEqual(phase5Verified.evaluation.state, .observingCandidate, "historical transport compatibility cannot bypass v1 lifecycle and rollback proof")

        let phase5Daemon146 = await diagnose(daemon: .value(
            kind: .running,
            cliVersion: "0.144.6",
            appServerVersion: "0.144.6"
        ))
        suite.checkEqual(phase5Daemon146.evidence.versionQualification, .compatible, "historical Phase 5 transport evidence includes daemon App Server 0.144.6 selection")

        let mismatchedDaemonCLI = await diagnose(daemon: .value(
            kind: .running,
            cliVersion: "0.144.5",
            appServerVersion: "0.144.6"
        ))
        suite.checkEqual(mismatchedDaemonCLI.evidence.versionQualification, .unknown, "a mixed daemon CLI and App Server pair is never exact-version qualified")

        let currentCandidate = await diagnose(bundle: .value(bundlePlist(
            shortVersion: "26.715.31925",
            buildVersion: "6000"
        )))
        suite.checkEqual(currentCandidate.evidence.versionQualification, .unknown, "unqualified current Desktop candidate remains unknown")
        suite.checkEqual(currentCandidate.evaluation.state, .candidateUnqualified, "unknown compatibility remains an explicit non-verified candidate")
        suite.check(currentCandidate.evidence.rollbackQualification == nil, "the current Desktop tuple does not inherit Phase 5 rollback qualification")
        suite.check(currentCandidate.evidence.lifecycle == nil, "the current Desktop tuple does not inherit Phase 5 lifecycle evidence")

        let changedBundledCLI = await diagnose(bundledCLI: .value(
            terminationStatus: 0,
            output: Data("codex-cli 0.145.0-alpha.19\n".utf8)
        ))
        suite.checkEqual(changedBundledCLI.evidence.versionQualification, .unknown, "nearby bundled CLI versions do not inherit Phase 5 qualification")
        suite.checkEqual(changedBundledCLI.evaluation.state, .candidateUnqualified, "nearby tuple may gather evidence but cannot become verified")
        suite.check(changedBundledCLI.evidence.rollbackQualification == nil, "nearby bundled CLI does not inherit exact rollback evidence")
    }

    private static func keepsRawHostFactsOutOfTheSummary(into suite: inout TestSuite) async {
        let canary = "PRIVATE-HOST-CANARY"
        let snapshot = await diagnose(
            bundle: .value(bundlePlist(extra: ["RawConfiguration": canary])),
            guiEnvironment: .value(
                terminationStatus: 0,
                output: Data("\(canary)\n".utf8)
            ),
            launchConfiguration: .value(currentLaunchPlist(extra: ["RawConfiguration": canary])),
            processes: .value([
                .init(processID: 91_337, parentProcessID: 1, isDesktopExecutable: true, isPrivateAppServerChild: false),
            ])
        )

        suite.check(!snapshot.host.guiEnvironmentIsEnabled, "unexpected raw GUI value becomes only a disabled boolean")
        suite.checkEqual(snapshot.host.launchConfiguration, .malformed, "extra launch keys fail the exact setup contract without entering the summary")
        let rendered = String(describing: snapshot.host)
        suite.check(!rendered.contains(canary), "host summary omits raw bundle, launch, and environment values")
        suite.check(!rendered.contains("91337"), "host summary structurally omits process identifiers")
        suite.check(!rendered.localizedCaseInsensitiveContains("path"), "host summary structurally omits paths")
        suite.check(!rendered.localizedCaseInsensitiveContains("error"), "host summary structurally omits raw errors")
    }

    private static func respectsLabsOptOutAndNeverVerifiesFromHostFacts(into suite: inout TestSuite) async {
        let disabled = await diagnose(isLabsFeatureEnabled: false)
        suite.checkEqual(disabled.evaluation.state, .disabled, "Labs off remains disabled despite otherwise qualified host facts")
        suite.checkEqual(disabled.presentation.status, "Disabled", "Labs opt-out has explicit UI-ready copy")

        let factsOnly = await diagnose(verificationConfirmed: true)
        suite.check(factsOnly.evidence.candidate == nil, "host inspection never manufactures a Desktop thread candidate")
        suite.check(factsOnly.evaluation.state != .verified, "host facts and confirmation alone never become Verified")
        suite.checkEqual(factsOnly.evaluation.state, .awaitingDesktopThread, "host facts wait for explicit runtime-only thread evidence")
    }

    private static func diagnose(
        isLabsFeatureEnabled: Bool = true,
        isAppManagedSetupEnabled: Bool = false,
        bundle: SharedDesktopBoundedDataFact = .value(bundlePlist()),
        bundledCLI: SharedDesktopBoundedCommandFact = .value(
            terminationStatus: 0,
            output: Data("codex-cli 0.145.0-alpha.18\n".utf8)
        ),
        guiEnvironment: SharedDesktopBoundedCommandFact = .value(
            terminationStatus: 0,
            output: Data("1\n".utf8)
        ),
        launchConfiguration: SharedDesktopBoundedDataFact = .value(currentLaunchPlist()),
        processes: SharedDesktopProcessInventoryFact = .value([
            .init(processID: 41, parentProcessID: 1, isDesktopExecutable: true, isPrivateAppServerChild: false),
        ]),
        daemon: SharedDesktopDaemonFact = .value(
            kind: .running,
            cliVersion: "0.144.5",
            appServerVersion: "0.144.5"
        ),
        candidate: SharedDesktopThreadCandidateEvidence? = nil,
        lifecycle: SharedDesktopLifecycleEvidence? = nil,
        verificationConfirmed: Bool = false
    ) async -> SharedDesktopDiagnosticsSnapshot {
        let inspector = SharedDesktopHostInspector(dependencies: .init(
            bundleMetadata: { bundle },
            bundledCLI: { bundledCLI },
            guiEnvironment: { guiEnvironment },
            launchConfiguration: { launchConfiguration },
            processInventory: { processes },
            daemon: { daemon }
        ))
        return await SharedDesktopDiagnosticsCoordinator(inspector: inspector).diagnose(
            isLabsFeatureEnabled: isLabsFeatureEnabled,
            isAppManagedSetupEnabled: isAppManagedSetupEnabled,
            candidate: candidate,
            lifecycle: lifecycle,
            verificationConfirmed: verificationConfirmed
        )
    }

    private static func completeCandidate() -> SharedDesktopThreadCandidateEvidence {
        let threadID = AppServerThreadID(rawValue: "desktop-thread")
        return .init(
            threadID: threadID,
            userAttestedDesktopOrigin: true,
            authoritativeDiscoveryThreadIDs: [threadID],
            resumedThreadID: threadID,
            resumeStartedTurn: false,
            resumeTookOwnership: false,
            resumeSentConsequentialAction: false,
            newEventThreadID: threadID
        )
    }

    private static func bundlePlist(
        shortVersion: String = "26.715.31251",
        buildVersion: String = "5538",
        extra: [String: Any] = [:]
    ) -> Data {
        var value: [String: Any] = [
            "CFBundleIdentifier": SharedDesktopHostInspector.desktopBundleIdentifier,
            "CFBundleShortVersionString": shortVersion,
            "CFBundleVersion": buildVersion,
        ]
        for (key, item) in extra { value[key] = item }
        return plist(value)
    }

    private static func currentLaunchPlist(extra: [String: Any] = [:]) -> Data {
        var value: [String: Any] = [
            "Label": SharedDesktopHostInspector.launchAgentLabel,
            "ProgramArguments": [
                "/bin/launchctl",
                "setenv",
                SharedDesktopHostInspector.guiEnvironmentVariable,
                "1",
            ],
            "EnvironmentVariables": [
                "CONN_SHARED_DESKTOP_SETUP_CONTRACT": SharedDesktopHostInspector.setupContractMarker,
            ],
            "RunAtLoad": true,
            "ProcessType": "Background",
            "LimitLoadToSessionType": "Aqua",
        ]
        for (key, item) in extra { value[key] = item }
        return plist(value)
    }

    private static func legacyLaunchPlist() -> Data {
        plist([
            "Label": SharedDesktopHostInspector.launchAgentLabel,
            "ProgramArguments": [
                "/bin/sh",
                "-c",
                "/Users/test/.codex/packages/standalone/current/bin/codex app-server daemon start && /bin/launchctl setenv CODEX_APP_SERVER_USE_LOCAL_DAEMON 1",
            ],
        ])
    }

    private static func foreignLaunchPlist() -> Data {
        plist([
            "Label": "example.foreign",
            "ProgramArguments": [
                "/bin/launchctl",
                "setenv",
                SharedDesktopHostInspector.guiEnvironmentVariable,
                "1",
            ],
        ])
    }

    private static func plist(_ value: [String: Any]) -> Data {
        try! PropertyListSerialization.data(
            fromPropertyList: value,
            format: .xml,
            options: 0
        )
    }
}
