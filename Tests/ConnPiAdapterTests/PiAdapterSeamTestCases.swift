import Foundation
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
        suite.check(
            PiHarnessAsset.officialSourceURL.absoluteString
                == "https://pi.dev/favicon.svg",
            "Pi harness badge records its official source"
        )
        let badgeURL = PiHarnessAsset.bundledBadgeURL
        suite.check(
            badgeURL.lastPathComponent == "PiHarnessBadge.svg",
            "Pi harness badge is bundled as an SVG resource"
        )
        suite.check(
            (try? badgeURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )).map {
                $0.isRegularFile == true && $0.isSymbolicLink != true
            } == true,
            "Pi harness badge is a regular bundled resource"
        )
    }
}
