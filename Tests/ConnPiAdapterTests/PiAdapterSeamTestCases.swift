import ConnDomain
import ConnPiAdapter

enum PiAdapterSeamTestCases {
    static func run(into suite: inout TestSuite) {
        suite.check(
            PiExternalIntegrationIdentity.harnessID == HarnessID(rawValue: "pi"),
            "external Pi uses the stable Pi Harness identity"
        )
        suite.check(
            PiExternalIntegrationIdentity.integrationID
                == IntegrationID(rawValue: "pi.external"),
            "external Pi uses its stable Integration identity"
        )
        suite.check(
            PiExternalIntegrationIdentity.descriptor.displayName == "Pi",
            "the neutral descriptor exposes only the product label"
        )
    }
}
