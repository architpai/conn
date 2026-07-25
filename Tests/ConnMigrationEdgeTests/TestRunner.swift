import Foundation

struct TestSuite {
    private(set) var assertions = 0
    private(set) var failures: [String] = []

    mutating func check(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        assertions += 1
        if !condition() { failures.append(message) }
    }

    mutating func checkEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ message: String
    ) {
        check(
            actual == expected,
            "\(message) (actual: \(actual), expected: \(expected))"
        )
    }

    mutating func recordUnexpected(_ error: Error) {
        assertions += 1
        failures.append("unexpected migration-edge error: \(error)")
    }
}

@main
private enum ConnMigrationEdgeTestRunner {
    static func main() {
        var suite = TestSuite()
        do {
            try Phase11LegacyHookRetirementTestCases.run(into: &suite)
        } catch {
            suite.recordUnexpected(error)
        }
        guard suite.failures.isEmpty else {
            fputs(
                "FAIL: \(suite.failures.count) of \(suite.assertions) assertions failed\n",
                stderr
            )
            suite.failures.forEach { fputs("- \($0)\n", stderr) }
            Foundation.exit(EXIT_FAILURE)
        }
        print("V0.2 COMPOSITION PARITY: \(suite.assertions) of 14 assertions")
        print("PASS: \(suite.assertions) assertions")
    }
}
