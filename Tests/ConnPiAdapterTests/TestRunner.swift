import Foundation

@main
private enum ConnPiAdapterTestRunner {
    static func main() {
        var suite = TestSuite()
        PiAdapterSeamTestCases.run(into: &suite)
        PiBrokerHandshakeTestCases.run(into: &suite)

        if suite.failures.isEmpty {
            print("PASS: \(suite.assertions) assertions")
            Foundation.exit(EXIT_SUCCESS)
        }
        fputs(
            "FAIL: \(suite.failures.count) of \(suite.assertions) assertions failed\n",
            stderr
        )
        suite.failures.forEach { fputs("- \($0)\n", stderr) }
        Foundation.exit(EXIT_FAILURE)
    }
}
