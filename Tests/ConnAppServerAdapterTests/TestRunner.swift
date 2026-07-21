import Foundation

struct TestSuite {
    private(set) var assertions = 0
    private(set) var failures: [String] = []

    mutating func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { failures.append(message) }
    }

    mutating func fail(_ message: String) {
        assertions += 1
        failures.append(message)
    }
}

@main
struct ConnAppServerAdapterTestRunner {
    static func main() async {
        var suite = TestSuite()
        EndpointDiscoveryTestCases.run(in: &suite)
        await ProtocolTestCases.run(in: &suite)
        await TransportTestCases.run(in: &suite)
        await Phase6LifecycleTestCases.run(in: &suite)
        await Phase6ConnectionTestCases.run(in: &suite)
        await Phase7InboundEnvelopeTestCases.run(in: &suite)
        await Phase10SharedDesktopHostInspectorTestCases.run(in: &suite)

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
