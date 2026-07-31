import Foundation
import ConnCodexAdapter

enum CodexHarnessAssetTestCases {
    static func run(into suite: inout TestSuite) {
        suite.check(
            CodexHarnessAsset.officialSourceURL.absoluteString
                == "https://cdn.openai.com/brand/openai-logos.zip",
            "Codex harness badge records OpenAI's official logo package"
        )
        let badgeURL = CodexHarnessAsset.bundledBadgeURL
        suite.check(
            badgeURL.lastPathComponent == "OpenAIBlossom.svg",
            "Codex harness badge is bundled as an SVG resource"
        )
        suite.check(
            (try? badgeURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )).map {
                $0.isRegularFile == true && $0.isSymbolicLink != true
            } == true,
            "OpenAI Blossom is a regular bundled resource"
        )
    }
}
