import Foundation

struct TestSuite {
    private(set) var assertions = 0
    private(set) var failures: [String] = []

    mutating func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { failures.append(message) }
    }

    mutating func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        check(actual == expected, "\(message) (actual: \(actual), expected: \(expected))")
    }

    mutating func fail(_ message: String) {
        assertions += 1
        failures.append(message)
    }

    mutating func recordUnexpected(_ error: Error, context: String) {
        assertions += 1
        failures.append("\(context): \(error)")
    }
}

enum Phase3TestScaffolding {
    static func temporaryApplicationSupport(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "conn-codex-adapter-tests-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        return root
    }
}

@main
struct ConnCodexAdapterTestRunner {
    static func main() async {
        var suite = TestSuite()
        EndpointDiscoveryTestCases.run(in: &suite)
        await ProtocolTestCases.run(in: &suite)
        await TransportTestCases.run(in: &suite)
        await Phase6LifecycleTestCases.run(in: &suite)
        await Phase6ConnectionTestCases.run(in: &suite)
        await Phase7InboundEnvelopeTestCases.run(in: &suite)
        await Phase10SharedDesktopHostInspectorTestCases.run(in: &suite)
        do {
            try Phase10SharedDesktopModeTestCases.run(into: &suite)
            await Phase10SharedDesktopDiagnosticsTestCases.run(into: &suite)
            await Phase10SharedDesktopSetupTestCases.run(into: &suite)
            try await Phase10SharedDesktopRuntimeTestCases.run(into: &suite)
            try await Phase8StructuredMonitoringTestCases.run(into: &suite)
            try await Phase85AdapterTestCases.run(into: &suite)
            try await Phase85RuntimeRecoveryTestCases.run(into: &suite)
            try await Phase87ProjectionPrivacyTestCases.run(into: &suite)
            try await Phase9ThreadControlRuntimeTestCases.run(into: &suite)
            try await Phase11HookVisibilityTestCases.run(into: &suite)
            await Phase11LegacyPluginRetirementTestCases.run(into: &suite)
            let parityAssertions = suite.assertions
            suite.check(
                parityAssertions == 984,
                "Phase 1 CodexAdapter denominator remains exactly 984 assertions"
            )
            try await Phase3CodexIntegrationMappingTestCases.run(into: &suite)
            print("V0.2 CODEX PARITY: \(parityAssertions) of 984 assertions")
            print(
                "V0.2 CODEX PHASE3: "
                    + "\(suite.assertions - parityAssertions - 1) new assertions"
            )
        } catch {
            suite.recordUnexpected(error, context: "unexpected Codex adapter test error")
        }

        if suite.failures.isEmpty {
            print("PASS: \(suite.assertions) assertions")
            Foundation.exit(EXIT_SUCCESS)
        }

        fputs("FAIL: \(suite.failures.count) of \(suite.assertions) assertions failed\n", stderr)
        for failure in suite.failures {
            fputs("- \(failure)\n", stderr)
        }
        Foundation.exit(EXIT_FAILURE)
    }
}
