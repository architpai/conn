import Foundation
import ConnPiAdapter

enum PiToolchainDiscoveryTestCases {
    static func run(into suite: inout TestSuite) async {
        do {
            try await qualifiesResolvedEntryAndRejectsUnsupportedPi(into: &suite)
        } catch {
            suite.fail("Pi toolchain discovery test setup failed: \(error)")
        }
    }

    private static func qualifiesResolvedEntryAndRejectsUnsupportedPi(
        into suite: inout TestSuite
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "conn-pi-discovery-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        let node = root.appendingPathComponent("node")
        let entry = root.appendingPathComponent("cli.js")
        let launcher = root.appendingPathComponent("pi")
        try Data(
            """
            #!/bin/sh
            if [ "$1" = "--version" ]; then
              echo v24.16.0
            else
              echo "${CONN_TEST_PI_VERSION:-0.82.1}"
            fi
            """.utf8
        ).write(to: node)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: node.path
        )
        try Data("// test entry\n".utf8).write(to: entry)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: entry.path
        )
        try FileManager.default.createSymbolicLink(
            at: launcher,
            withDestinationURL: entry
        )

        let discovery = PiToolchainDiscovery(
            homeDirectory: root,
            shellURL: nil,
            timeout: .seconds(1)
        )
        let inspection = await discovery.inspect(
            nodeURL: node,
            piLauncherURL: launcher
        )
        guard case let .ready(toolchain) = inspection else {
            suite.fail("qualified Pi fixture should be ready, got \(inspection)")
            return
        }
        suite.check(
            toolchain.piEntryURL == entry,
            "discovery resolves the Pi launcher to its package entry"
        )
        suite.check(
            toolchain.piVersion == "0.82.1",
            "discovery qualifies only the pinned Pi version"
        )

        let unsupportedNode = root.appendingPathComponent("unsupported-node")
        try Data(
            """
            #!/bin/sh
            if [ "$1" = "--version" ]; then
              echo v24.16.0
            else
              echo 0.83.0
            fi
            """.utf8
        ).write(to: unsupportedNode)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: unsupportedNode.path
        )
        let unsupportedInspection = await discovery.inspect(
            nodeURL: unsupportedNode,
            piLauncherURL: launcher
        )
        suite.check(
            unsupportedInspection == .unsupported(reportedVersion: "0.83.0"),
            "unsupported Pi versions fail qualification explicitly"
        )
    }
}
