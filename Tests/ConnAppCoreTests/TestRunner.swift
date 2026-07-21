import Foundation

@main
private enum ConnAppCoreTestRunner {
    static func main() async {
        var suite = TestSuite()
        do {
            try await Phase3AppCoreTestCases.run(into: &suite)
            Phase4ShellPolicyTestCases.run(into: &suite)
            try await Phase7PersistenceMigrationTestCases.run(into: &suite)
            try await Phase8StructuredMonitoringTestCases.run(into: &suite)
            try await Phase8RuntimePolicyTestCases.run(into: &suite)
            Phase8ShellRegressionTestCases.run(into: &suite)
            try await Phase8PresentationPayloadTestCases.run(into: &suite)
            try await Phase85AdapterTestCases.run(into: &suite)
            await Phase85ProjectPresentationTestCases.run(into: &suite)
            try await Phase85RuntimeRecoveryTestCases.run(into: &suite)
            try await Phase87ProjectionPrivacyTestCases.run(into: &suite)
            await Phase87PresentationTestCases.run(into: &suite)
            Phase87ShellTestCases.run(into: &suite)
            try Phase88DurabilityTestCases.run(into: &suite)
            try await Phase9ThreadControlTestCases.run(into: &suite)
            try await Phase9ThreadControlRuntimeTestCases.run(into: &suite)
            await Phase92OutcomeReviewTestCases.run(into: &suite)
            try Phase10SharedDesktopModeTestCases.run(into: &suite)
            await Phase10SharedDesktopDiagnosticsTestCases.run(into: &suite)
            await Phase10SharedDesktopSetupTestCases.run(into: &suite)
            try await Phase10SharedDesktopRuntimeTestCases.run(into: &suite)
            try await Phase11HookVisibilityTestCases.run(into: &suite)
            try Phase11LegacyHookRetirementTestCases.run(into: &suite)
            await Phase11LegacyPluginRetirementTestCases.run(into: &suite)
            Phase115UIOverhaulTestCases.run(into: &suite)
            Phase115CompactShelfMotionTestCases.run(into: &suite)
            Phase115NotificationPolicyTestCases.run(into: &suite)
            await Phase115ThreadPickerPolicyTestCases.run(into: &suite)
        } catch {
            suite.recordUnexpected(error, context: "unexpected top-level app-core test error")
        }

        if suite.failures.isEmpty {
            print("PASS: \(suite.assertions) assertions")
            Foundation.exit(EXIT_SUCCESS)
        }
        fputs("FAIL: \(suite.failures.count) of \(suite.assertions) assertions failed\n", stderr)
        suite.failures.forEach { fputs("- \($0)\n", stderr) }
        Foundation.exit(EXIT_FAILURE)
    }
}
