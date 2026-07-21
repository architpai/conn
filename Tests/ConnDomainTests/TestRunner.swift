import Foundation

@main
private enum ConnDomainTestRunner {
    static func main() async {
        var suite = TestSuite()

        do {
            try await Phase7AppServerProjectionTestCases.run(into: &suite)
        } catch {
            suite.recordUnexpected(error, context: "unexpected top-level domain test error")
        }

        if suite.failures.isEmpty {
            print("PASS: \(suite.assertions) assertions")
            Foundation.exit(EXIT_SUCCESS)
        }

        fputs(
            "FAIL: \(suite.failures.count) of \(suite.assertions) assertions failed\n",
            stderr
        )
        suite.failures.forEach { failure in
            fputs("- \(failure)\n", stderr)
        }
        Foundation.exit(EXIT_FAILURE)
    }
}
