import Foundation
import ConnAppServerAdapter

enum Phase10SharedDesktopHostInspectorTestCases {
    static func run(in suite: inout TestSuite) async {
        await classifiesHealthyClosedFacts(in: &suite)
        await rejectsBundleAndCLIFailures(in: &suite)
        await classifiesGUIEnvironmentWithoutReturningItsValue(in: &suite)
        await classifiesLaunchConfigurationProvenance(in: &suite)
        await classifiesExactDesktopChildTopology(in: &suite)
        await mapsDaemonFactsWithoutReturningDetails(in: &suite)
        await provesEncodedReportHasNoRawHostFacts(in: &suite)
    }

    private static func classifiesHealthyClosedFacts(in suite: inout TestSuite) async {
        let report = await inspect()
        suite.checkEqual(report.bundle.state, .available, "valid fixed Desktop metadata is available")
        suite.checkEqual(report.bundle.shortVersion, "26.715.40000", "Desktop short version is retained")
        suite.checkEqual(report.bundle.buildVersion, "6000", "Desktop build version is retained")
        suite.checkEqual(report.bundledCLI.state, .available, "bounded bundled CLI version is available")
        suite.checkEqual(report.bundledCLI.version, "0.144.6", "bundled CLI version is retained")
        suite.checkEqual(report.guiEnvironment, .enabled, "exact GUI flag value one is enabled")
        suite.checkEqual(report.launchConfiguration, .connManaged, "exact direct launch configuration is Conn-managed")
        suite.checkEqual(report.desktopTopology.desktop, .single, "one exact Desktop executable is reported")
        suite.checkEqual(report.desktopTopology.privateAppServerChild, .absent, "shared Desktop has no private App Server child")
        suite.checkEqual(report.daemon.state, .runningSafe, "validated running daemon is safe")
        suite.checkEqual(report.daemon.appServerVersion, "0.144.6", "daemon App Server version is retained")
    }

    private static func rejectsBundleAndCLIFailures(in suite: inout TestSuite) async {
        let missing = await inspect(
            bundle: .missing,
            cli: .missing
        )
        suite.checkEqual(missing.bundle.state, .missing, "missing Desktop bundle is explicit")
        suite.checkEqual(missing.bundledCLI.state, .missing, "missing bundled CLI is explicit")

        let untrusted = await inspect(
            bundle: .untrusted,
            cli: .untrusted
        )
        suite.checkEqual(untrusted.bundle.state, .untrusted, "untrusted bundle metadata is refused")
        suite.checkEqual(untrusted.bundledCLI.state, .untrusted, "untrusted bundled CLI is refused")

        let oversized = await inspect(
            bundle: .oversized,
            cli: .oversized
        )
        suite.checkEqual(oversized.bundle.state, .untrusted, "oversized bundle metadata cannot become trusted")
        suite.checkEqual(oversized.bundledCLI.state, .oversized, "oversized CLI output is explicit")

        let malformed = await inspect(
            bundle: .value(Data("not a plist".utf8)),
            cli: .value(terminationStatus: 0, output: Data("codex 0.144.6\n".utf8))
        )
        suite.checkEqual(malformed.bundle.state, .malformed, "malformed bundle metadata is explicit")
        suite.checkEqual(malformed.bundledCLI.state, .malformed, "malformed CLI version is explicit")
        suite.check(malformed.bundle.shortVersion == nil, "malformed bundle exposes no partial version")
        suite.check(malformed.bundledCLI.version == nil, "malformed CLI exposes no partial version")

        let oversizedPayload = Data(repeating: 0x31, count: 257)
        let defensiveBound = await inspect(
            cli: .value(terminationStatus: 0, output: oversizedPayload)
        )
        suite.checkEqual(defensiveBound.bundledCLI.state, .malformed, "injected over-bound CLI bytes still fail closed")
    }

    private static func classifiesGUIEnvironmentWithoutReturningItsValue(
        in suite: inout TestSuite
    ) async {
        let disabled = await inspect(gui: .value(terminationStatus: 0, output: Data("\n".utf8)))
        suite.checkEqual(disabled.guiEnvironment, .disabled, "empty GUI value is disabled")

        let unexpected = await inspect(gui: .value(terminationStatus: 0, output: Data("secret-value\n".utf8)))
        suite.checkEqual(unexpected.guiEnvironment, .unexpected, "non-one GUI value is classified without retention")

        let failed = await inspect(gui: .value(terminationStatus: 1, output: Data("1\n".utf8)))
        suite.checkEqual(failed.guiEnvironment, .unavailable, "failed GUI query cannot claim enabled")

        let oversized = await inspect(gui: .oversized)
        suite.checkEqual(oversized.guiEnvironment, .unavailable, "oversized GUI output fails closed")
    }

    private static func classifiesLaunchConfigurationProvenance(
        in suite: inout TestSuite
    ) async {
        let legacyArguments = [
            "/bin/sh",
            "-c",
            "/Users/test/.codex/packages/standalone/current/bin/codex app-server daemon start && /bin/launchctl setenv CODEX_APP_SERVER_USE_LOCAL_DAEMON 1",
        ]
        let legacy = await inspect(launch: .value(plist(
            label: SharedDesktopHostInspector.launchAgentLabel,
            arguments: legacyArguments
        )))
        suite.checkEqual(legacy.launchConfiguration, .legacyConnManaged, "known bounded Phase 5 launch configuration is recognized")

        let injected = await inspect(launch: .value(plist(
            label: SharedDesktopHostInspector.launchAgentLabel,
            arguments: ["/bin/sh", "-c", "/safe/codex app-server daemon start; touch /tmp/x && /bin/launchctl setenv CODEX_APP_SERVER_USE_LOCAL_DAEMON 1"]
        )))
        suite.checkEqual(injected.launchConfiguration, .malformed, "shell additions are never accepted as legacy Conn provenance")

        let current = await inspect(launch: .value(currentLaunchPlist()))
        suite.checkEqual(current.launchConfiguration, .connManaged, "only the exact current setup contract is current")

        let previous = await inspect(launch: .value(currentLaunchPlist(marker: "v1-2026-07-20")))
        suite.checkEqual(previous.launchConfiguration, .legacyConnManaged, "the previous exact setup contract remains safely migratable")

        let missingMarker = await inspect(launch: .value(plist(
            label: SharedDesktopHostInspector.launchAgentLabel,
            arguments: ["/bin/launchctl", "setenv", SharedDesktopHostInspector.guiEnvironmentVariable, "1"]
        )))
        suite.checkEqual(missingMarker.launchConfiguration, .malformed, "matching commands without the ownership contract are not claimed")

        let foreign = await inspect(launch: .value(plist(
            label: "example.foreign",
            arguments: ["/bin/launchctl", "setenv", "CODEX_APP_SERVER_USE_LOCAL_DAEMON", "1"]
        )))
        suite.checkEqual(foreign.launchConfiguration, .foreign, "foreign label is not claimed as Conn provenance")

        let malformed = await inspect(launch: .value(Data("bad plist".utf8)))
        suite.checkEqual(malformed.launchConfiguration, .malformed, "malformed launch configuration is explicit")
        suite.checkEqual((await inspect(launch: .missing)).launchConfiguration, .missing, "missing launch configuration is explicit")
        suite.checkEqual((await inspect(launch: .untrusted)).launchConfiguration, .untrusted, "untrusted launch configuration is refused")
        suite.checkEqual((await inspect(launch: .oversized)).launchConfiguration, .oversized, "oversized launch configuration is refused")
        suite.checkEqual((await inspect(launch: .unavailable)).launchConfiguration, .unavailable, "unreadable launch configuration is explicit")
    }

    private static func classifiesExactDesktopChildTopology(in suite: inout TestSuite) async {
        let none = await inspect(processes: .value([]))
        suite.checkEqual(none.desktopTopology.desktop, .notRunning, "no exact Desktop executable is not running")
        suite.checkEqual(none.desktopTopology.privateAppServerChild, .notApplicable, "child topology is not applicable without Desktop")

        let unrelatedChild = await inspect(processes: .value([
            .init(processID: 10, parentProcessID: 1, isDesktopExecutable: true, isPrivateAppServerChild: false),
            .init(processID: 11, parentProcessID: 99, isDesktopExecutable: false, isPrivateAppServerChild: true),
        ]))
        suite.checkEqual(unrelatedChild.desktopTopology.privateAppServerChild, .absent, "another parent's App Server child is not retargeted")

        let privateChild = await inspect(processes: .value([
            .init(processID: 10, parentProcessID: 1, isDesktopExecutable: true, isPrivateAppServerChild: false),
            .init(processID: 11, parentProcessID: 10, isDesktopExecutable: false, isPrivateAppServerChild: true),
        ]))
        suite.checkEqual(privateChild.desktopTopology.privateAppServerChild, .single, "exact direct private App Server child is detected")

        let multiple = await inspect(processes: .value([
            .init(processID: 10, parentProcessID: 1, isDesktopExecutable: true, isPrivateAppServerChild: false),
            .init(processID: 20, parentProcessID: 1, isDesktopExecutable: true, isPrivateAppServerChild: false),
            .init(processID: 11, parentProcessID: 10, isDesktopExecutable: false, isPrivateAppServerChild: true),
            .init(processID: 21, parentProcessID: 20, isDesktopExecutable: false, isPrivateAppServerChild: true),
        ]))
        suite.checkEqual(multiple.desktopTopology.desktop, .multiple, "multiple exact Desktop processes are ambiguous")
        suite.checkEqual(multiple.desktopTopology.privateAppServerChild, .multiple, "private child count remains closed metadata")

        let unavailable = await inspect(processes: .unavailable)
        suite.checkEqual(unavailable.desktopTopology.desktop, .unavailable, "process inspection failure is explicit")
        suite.checkEqual(unavailable.desktopTopology.privateAppServerChild, .unavailable, "failed inventory never claims child absence")
    }

    private static func currentLaunchPlist(
        marker: String = SharedDesktopHostInspector.setupContractMarker
    ) -> Data {
        plist(
            label: SharedDesktopHostInspector.launchAgentLabel,
            arguments: [
                "/bin/launchctl",
                "setenv",
                SharedDesktopHostInspector.guiEnvironmentVariable,
                "1",
            ],
            extra: [
                "EnvironmentVariables": [
                    "CONN_SHARED_DESKTOP_SETUP_CONTRACT": marker,
                ],
                "RunAtLoad": true,
                "ProcessType": "Background",
                "LimitLoadToSessionType": "Aqua",
            ]
        )
    }

    private static func mapsDaemonFactsWithoutReturningDetails(in suite: inout TestSuite) async {
        suite.check(
            sharedDesktopProcessInventoryIsSaturated(
                byteCount: Int32(8_192 * MemoryLayout<pid_t>.stride),
                capacity: 8_192
            ),
            "a capacity-filling PID inventory fails closed as truncated"
        )
        suite.check(
            !sharedDesktopProcessInventoryIsSaturated(
                byteCount: Int32(8_191 * MemoryLayout<pid_t>.stride),
                capacity: 8_192
            ),
            "a bounded PID inventory below capacity remains inspectable"
        )
        let mappings: [(ManagedDaemonStatus.Kind, SharedDesktopDaemonState)] = [
            (.running, .runningSafe),
            (.stopped, .stopped),
            (.incompatible, .incompatible),
            (.endpointRefused, .unsafeEndpoint),
            (.malformed, .malformed),
            (.unavailable, .unavailable),
        ]
        for (kind, expected) in mappings {
            let report = await inspect(daemon: .value(
                kind: kind,
                cliVersion: "0.144.6",
                appServerVersion: "0.144.6"
            ))
            suite.checkEqual(report.daemon.state, expected, "daemon kind \(kind.rawValue) maps to closed state")
        }
        suite.checkEqual((await inspect(daemon: .missing)).daemon.state, .missing, "missing supported CLI is distinct")
        suite.checkEqual((await inspect(daemon: .unavailable)).daemon.state, .unavailable, "unavailable daemon probe is explicit")

        let invalidVersion = await inspect(daemon: .value(
            kind: .running,
            cliVersion: String(repeating: "x", count: 65),
            appServerVersion: "0.144.6\nprivate"
        ))
        suite.check(invalidVersion.daemon.cliVersion == nil, "oversized daemon version is dropped")
        suite.check(invalidVersion.daemon.appServerVersion == nil, "control characters in daemon version are dropped")
    }

    private static func provesEncodedReportHasNoRawHostFacts(in suite: inout TestSuite) async {
        let secret = "privacy-canary-prompt-token"
        let bundle = plist(
            label: "unused",
            arguments: [],
            extra: [
                "CFBundleIdentifier": SharedDesktopHostInspector.desktopBundleIdentifier,
                "CFBundleShortVersionString": "26.715.40000",
                "CFBundleVersion": "6000",
                "RawConfiguration": secret,
            ]
        )
        let report = await inspect(
            bundle: .value(bundle),
            gui: .value(terminationStatus: 0, output: Data("\(secret)\n".utf8))
        )
        guard let data = try? JSONEncoder().encode(report),
              let json = String(data: data, encoding: .utf8) else {
            suite.fail("closed Shared Desktop report encodes")
            return
        }
        suite.check(!json.contains(secret), "raw configuration and GUI values are structurally absent")
        suite.check(!json.localizedCaseInsensitiveContains("path"), "report contains no filesystem path field")
        suite.check(!json.localizedCaseInsensitiveContains("processID"), "report contains no process identifier field")
        suite.check(!json.localizedCaseInsensitiveContains("detail"), "daemon diagnostic details are structurally absent")
    }

    private static func inspect(
        bundle: SharedDesktopBoundedDataFact = .value(validBundlePlist()),
        cli: SharedDesktopBoundedCommandFact = .value(
            terminationStatus: 0,
            output: Data("codex-cli 0.144.6\n".utf8)
        ),
        gui: SharedDesktopBoundedCommandFact = .value(
            terminationStatus: 0,
            output: Data("1\n".utf8)
        ),
        launch: SharedDesktopBoundedDataFact = .value(connManagedLaunchPlist()),
        processes: SharedDesktopProcessInventoryFact = .value([
            .init(
                processID: 10,
                parentProcessID: 1,
                isDesktopExecutable: true,
                isPrivateAppServerChild: false
            ),
        ]),
        daemon: SharedDesktopDaemonFact = .value(
            kind: .running,
            cliVersion: "0.144.6",
            appServerVersion: "0.144.6"
        )
    ) async -> SharedDesktopHostInspection {
        let inspector = SharedDesktopHostInspector(dependencies: .init(
            bundleMetadata: { bundle },
            bundledCLI: { cli },
            guiEnvironment: { gui },
            launchConfiguration: { launch },
            processInventory: { processes },
            daemon: { daemon }
        ))
        return await inspector.inspect()
    }

    private static func validBundlePlist() -> Data {
        plist(
            label: "unused",
            arguments: [],
            extra: [
                "CFBundleIdentifier": SharedDesktopHostInspector.desktopBundleIdentifier,
                "CFBundleShortVersionString": "26.715.40000",
                "CFBundleVersion": "6000",
            ]
        )
    }

    private static func connManagedLaunchPlist() -> Data {
        currentLaunchPlist()
    }

    private static func plist(
        label: String,
        arguments: [String],
        extra: [String: Any] = [:]
    ) -> Data {
        var value: [String: Any] = [
            "Label": label,
            "ProgramArguments": arguments,
        ]
        for (key, item) in extra { value[key] = item }
        return try! PropertyListSerialization.data(
            fromPropertyList: value,
            format: .xml,
            options: 0
        )
    }
}

private extension TestSuite {
    mutating func checkEqual<Value: Equatable>(
        _ actual: Value,
        _ expected: Value,
        _ message: String
    ) {
        check(actual == expected, message)
    }
}
