import Foundation

@main
private enum ConnAppCoreTestRunner {
    private enum V02Owner: String, CaseIterable {
        case codexAdapter = "ConnCodexAdapter"
        case appCore = "ConnAppCore"
        case ui = "ConnUI"
    }

    static func main() async {
        var suite = TestSuite()
        var ownerAssertions = Dictionary(
            uniqueKeysWithValues: V02Owner.allCases.map { ($0, 0) }
        )

        await runCase("Phase3AppCore", owner: .appCore, into: &suite, totals: &ownerAssertions) {
            try await Phase3AppCoreTestCases.run(into: &$0)
        }
        await runCase("Phase4ShellPolicy", owner: .appCore, into: &suite, totals: &ownerAssertions) {
            Phase4ShellPolicyTestCases.run(into: &$0)
        }
        await runCase("Phase4NeutralAggregation", owner: .appCore, into: &suite, totals: &ownerAssertions) {
            try await Phase4NeutralAggregationTestCases.run(into: &$0)
        }
        await runCase("Phase88Durability", owner: .appCore, into: &suite, totals: &ownerAssertions) {
            try Phase88DurabilityTestCases.run(into: &$0)
        }

        if suite.failures.isEmpty {
            print("PASS: \(suite.assertions) assertions")
            for owner in V02Owner.allCases {
                print("V0.2 OWNER: \(owner.rawValue) \(ownerAssertions[owner, default: 0]) assertions")
            }
            Foundation.exit(EXIT_SUCCESS)
        }
        fputs("FAIL: \(suite.failures.count) of \(suite.assertions) assertions failed\n", stderr)
        suite.failures.forEach { fputs("- \($0)\n", stderr) }
        Foundation.exit(EXIT_FAILURE)
    }

    @MainActor
    private static func runCase(
        _ name: String,
        owner: V02Owner,
        into suite: inout TestSuite,
        totals: inout [V02Owner: Int],
        operation: (inout TestSuite) async throws -> Void
    ) async {
        var testCaseSuite = TestSuite()
        do {
            try await operation(&testCaseSuite)
        } catch {
            testCaseSuite.recordUnexpected(error, context: "unexpected \(name) test error")
        }
        suite.merge(testCaseSuite)
        totals[owner, default: 0] += testCaseSuite.assertions
        print(
            "V0.2 CASE: \(owner.rawValue) \(name) "
                + "\(testCaseSuite.assertions) assertions"
        )
    }
}
