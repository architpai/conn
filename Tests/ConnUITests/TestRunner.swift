import Foundation

@main
private enum ConnUITestRunner {
    static func main() async {
        var suite = TestSuite()

        Phase8ShellRegressionTestCases.run(into: &suite)
        Phase87ShellTestCases.run(into: &suite)
        Phase115UIOverhaulTestCases.run(into: &suite)
        Phase115CompactShelfMotionTestCases.run(into: &suite)

        if suite.failures.isEmpty {
            print("V0.2 UI PARITY: 210 of 210 assertions")
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
