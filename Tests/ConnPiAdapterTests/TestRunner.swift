import Foundation
import ConnPiAdapter

@main
private enum ConnPiAdapterTestRunner {
    static func main() async {
        if CommandLine.arguments.contains("--live-probe") {
            await PiProductionLiveProbe.run()
            return
        }
        if CommandLine.arguments.contains("--toolchain-probe") {
            print(await PiToolchainDiscovery().discover())
            return
        }
        var suite = TestSuite()
        PiAdapterSeamTestCases.run(into: &suite)
        PiBrokerHandshakeTestCases.run(into: &suite)
        PiExtensionInstallerTestCases.run(into: &suite)
        PiRuntimeDescriptorTestCases.run(into: &suite)
        await PiToolchainDiscoveryTestCases.run(into: &suite)
        await PiLocalBrokerTestCases.run(into: &suite)
        await PiExternalIntegrationTestCases.run(into: &suite)

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
