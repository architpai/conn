import Darwin
import Foundation
import ConnAppCore

enum Phase11LegacyHookRetirementTestCases {
    static func run(into suite: inout TestSuite) throws {
        try removesOnlyFixedLegacyRootsAndIsIdempotent(into: &suite)
        try rejectsLegacyRootSymlinks(into: &suite)
        try rejectsNestedHazardsBeforeAnyRemoval(into: &suite)
        try rejectsUnexpectedLegacyRootTypes(into: &suite)
        try rejectsUnexpectedOwners(into: &suite)
    }

    private static func rejectsNestedHazardsBeforeAnyRemoval(
        into suite: inout TestSuite
    ) throws {
        let support = try temporarySupport("phase11-retire-nested-symlink")
        defer { try? FileManager.default.removeItem(at: support) }
        let bridge = support.appendingPathComponent("Sidequest/Bridge/v1", isDirectory: true)
        let domain = support.appendingPathComponent("Sidequest/Domain/v1", isDirectory: true)
        let outside = support.appendingPathComponent("outside.txt")
        try FileManager.default.createDirectory(at: bridge, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: domain, withIntermediateDirectories: true)
        try Data("bridge".utf8).write(to: bridge.appendingPathComponent("checkpoint.json"))
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: domain.appendingPathComponent("unsafe-link"),
            withDestinationURL: outside
        )
        let store = try LegacyHookRetirementStore(applicationSupportDirectory: support)
        do {
            _ = try store.retire()
            suite.check(false, "nested legacy symlink should be rejected")
        } catch let error as LegacyHookRetirementError {
            guard case .symbolicLinkNotAllowed = error else {
                suite.check(false, "nested legacy symlink returned \(error)")
                return
            }
            suite.check(FileManager.default.fileExists(atPath: bridge.path), "all roots survive failed preflight")
            suite.check(FileManager.default.fileExists(atPath: outside.path), "nested symlink destination is untouched")
        }
    }

    private static func removesOnlyFixedLegacyRootsAndIsIdempotent(
        into suite: inout TestSuite
    ) throws {
        let support = try temporarySupport("phase11-retire-success")
        defer { try? FileManager.default.removeItem(at: support) }
        let bridge = support.appendingPathComponent("Sidequest/Bridge/v1", isDirectory: true)
        let domain = support.appendingPathComponent("Sidequest/Domain/v1", isDirectory: true)
        let bridgeSibling = support.appendingPathComponent("Sidequest/Bridge/keep.txt")
        let appServer = support.appendingPathComponent("Conn/AppServerDomain/v1", isDirectory: true)
        try FileManager.default.createDirectory(at: bridge, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: domain, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appServer, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: bridgeSibling)
        try Data("cache".utf8).write(to: appServer.appendingPathComponent("checkpoint-a.json"))

        let store = try LegacyHookRetirementStore(applicationSupportDirectory: support)
        suite.checkEqual(
            try store.retire(),
            .completed(removedLegacyRoots: 2, legacyStateReappeared: false),
            "retirement removes both exact legacy hook roots"
        )
        suite.check(!FileManager.default.fileExists(atPath: bridge.path), "bridge v1 is removed")
        suite.check(!FileManager.default.fileExists(atPath: domain.path), "domain v1 is removed")
        suite.check(FileManager.default.fileExists(atPath: bridgeSibling.path), "legacy siblings are preserved")
        suite.check(FileManager.default.fileExists(atPath: appServer.path), "App Server cache is preserved")
        suite.check(FileManager.default.fileExists(atPath: store.markerURL.path), "one-shot marker is written")
        suite.checkEqual(
            try store.retire(),
            .alreadyCompleted,
            "retirement is idempotent after its private marker exists"
        )

        try FileManager.default.createDirectory(at: bridge, withIntermediateDirectories: true)
        suite.checkEqual(
            try store.retire(),
            .completed(removedLegacyRoots: 1, legacyStateReappeared: true),
            "reappearing legacy state is removed and reported after the one-shot marker"
        )
    }

    private static func rejectsLegacyRootSymlinks(into suite: inout TestSuite) throws {
        let support = try temporarySupport("phase11-retire-symlink")
        defer { try? FileManager.default.removeItem(at: support) }
        let outside = support.appendingPathComponent("outside", isDirectory: true)
        let bridgeParent = support.appendingPathComponent("Sidequest/Bridge", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bridgeParent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: bridgeParent.appendingPathComponent("v1"),
            withDestinationURL: outside
        )
        let store = try LegacyHookRetirementStore(applicationSupportDirectory: support)
        do {
            _ = try store.retire()
            suite.check(false, "legacy hook symlink should be rejected")
        } catch let error as LegacyHookRetirementError {
            guard case .symbolicLinkNotAllowed = error else {
                suite.check(false, "legacy hook symlink returned \(error)")
                return
            }
            suite.check(FileManager.default.fileExists(atPath: outside.path), "symlink destination is untouched")
            suite.check(!FileManager.default.fileExists(atPath: store.markerURL.path), "failed cleanup writes no marker")
        }
    }

    private static func rejectsUnexpectedLegacyRootTypes(into suite: inout TestSuite) throws {
        let support = try temporarySupport("phase11-retire-fifo")
        defer { try? FileManager.default.removeItem(at: support) }
        let bridgeParent = support.appendingPathComponent("Sidequest/Bridge", isDirectory: true)
        try FileManager.default.createDirectory(at: bridgeParent, withIntermediateDirectories: true)
        let fifo = bridgeParent.appendingPathComponent("v1")
        guard mkfifo(fifo.path, 0o600) == 0 else {
            throw LegacyHookRetirementError.fileSystem(operation: "mkfifo-test", code: errno)
        }
        let store = try LegacyHookRetirementStore(applicationSupportDirectory: support)
        do {
            _ = try store.retire()
            suite.check(false, "legacy hook FIFO should be rejected")
        } catch let error as LegacyHookRetirementError {
            guard case .unexpectedFileType = error else {
                suite.check(false, "legacy hook FIFO returned \(error)")
                return
            }
            suite.check(!FileManager.default.fileExists(atPath: store.markerURL.path), "FIFO cleanup failure writes no marker")
        }
    }

    private static func rejectsUnexpectedOwners(into suite: inout TestSuite) throws {
        let support = try temporarySupport("phase11-retire-owner")
        defer { try? FileManager.default.removeItem(at: support) }
        let wrongExpectedOwner = getuid() == uid_t.max ? getuid() - 1 : getuid() + 1
        let store = try LegacyHookRetirementStore(
            applicationSupportDirectory: support,
            expectedOwnerUID: wrongExpectedOwner
        )
        do {
            _ = try store.retire()
            suite.check(false, "unexpected Application Support owner should be rejected")
        } catch let error as LegacyHookRetirementError {
            guard case .unexpectedOwner = error else {
                suite.check(false, "unexpected owner returned \(error)")
                return
            }
            suite.check(!FileManager.default.fileExists(atPath: store.markerURL.path), "owner mismatch writes no marker")
        }
    }

    private static func temporarySupport(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
