import Foundation
import ConnPiAdapter

enum PiExtensionInstallerTestCases {
    static func run(into suite: inout TestSuite) {
        do {
            try installsUpdatesAndRemovesOnlyOwnedContent(into: &suite)
            try preservesForeignAndTamperedTargets(into: &suite)
        } catch {
            suite.fail("Pi installer test setup failed: \(error)")
        }
    }

    private static func installsUpdatesAndRemovesOnlyOwnedContent(
        into suite: inout TestSuite
    ) throws {
        let root = try temporaryRoot("lifecycle")
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = root.appendingPathComponent("agent", isDirectory: true)
        let trash = root.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)

        let installer = PiExtensionInstaller(
            agentDirectory: agent,
            sourceURL: PiExtensionResource.bundledSourceURL,
            releaseVersion: "0.2.1",
            trashDirectory: trash
        )
        suite.check(installer.status() == .absent, "fresh Pi extension status is absent")
        let installOutcome = try installer.install(configuration: .init())
        suite.check(
            installOutcome == .installed,
            "fresh install reports installed"
        )
        guard case let .installed(version, configuration) = installer.status() else {
            suite.fail("installed extension must report its exact version and configuration")
            return
        }
        suite.check(version == "0.2.1", "ownership manifest records release version")
        suite.check(
            configuration == .init(),
            "optional Pi behavior defaults remain disabled"
        )

        let enabled = PiExtensionBehaviorConfiguration(
            questionsEnabled: true,
            approvalsEnabled: false
        )
        let updateOutcome = try installer.install(configuration: enabled)
        suite.check(
            updateOutcome == .updated,
            "owned reinstall atomically reports update"
        )
        suite.check(
            installer.status() == .installed(version: "0.2.1", configuration: enabled),
            "updated behavior configuration is verified"
        )
        let behaviorURL = agent.appendingPathComponent(
            "extensions/conn/behavior.json"
        )
        let ownedBehavior = try Data(contentsOf: behaviorURL)
        try Data(
            """
            {"questionsEnabled":false,"approvalsEnabled":true}
            """.utf8
        ).write(to: behaviorURL)
        suite.check(
            installer.status() == .foreign,
            "changed behavior configuration invalidates Conn ownership"
        )
        try ownedBehavior.write(to: behaviorURL)
        suite.check(
            installer.status() == .installed(
                version: "0.2.1",
                configuration: enabled
            ),
            "restoring the exact owned configuration restores verification"
        )
        let uninstallOutcome = try installer.uninstall()
        suite.check(
            uninstallOutcome == .movedToTrash,
            "uninstall uses a recoverable move"
        )
        suite.check(installer.status() == .absent, "uninstall verifies exact absence")
        suite.check(
            !FileManager.default.fileExists(
                atPath: agent.appendingPathComponent("extensions").path
            ),
            "uninstall removes the empty extensions parent that Conn created"
        )
        let trashEntries = try FileManager.default.contentsOfDirectory(
            at: trash,
            includingPropertiesForKeys: nil
        )
        suite.check(trashEntries.count == 1, "only the owned extension was moved to Trash")
    }

    private static func preservesForeignAndTamperedTargets(
        into suite: inout TestSuite
    ) throws {
        let root = try temporaryRoot("foreign")
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = root.appendingPathComponent("agent", isDirectory: true)
        let target = agent.appendingPathComponent("extensions/conn", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let foreign = target.appendingPathComponent("keep.txt")
        try Data("foreign".utf8).write(to: foreign)

        let installer = PiExtensionInstaller(
            agentDirectory: agent,
            sourceURL: PiExtensionResource.bundledSourceURL,
            releaseVersion: "0.2.1",
            trashDirectory: root.appendingPathComponent("trash", isDirectory: true)
        )
        suite.check(installer.status() == .foreign, "unmarked target is foreign")
        do {
            _ = try installer.install(configuration: .init())
            suite.fail("install must refuse a foreign target")
        } catch PiExtensionInstallerError.foreignTarget {
            suite.check(true, "foreign install target failed closed")
        }
        suite.check(
            FileManager.default.fileExists(atPath: foreign.path),
            "foreign target is preserved byte-for-byte"
        )
        do {
            _ = try installer.uninstall()
            suite.fail("uninstall must refuse a foreign target")
        } catch PiExtensionInstallerError.foreignTarget {
            suite.check(true, "foreign uninstall target failed closed")
        }
    }

    private static func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "conn-pi-installer-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        return root
    }
}
