import Darwin
import Foundation
import ConnAppCore

enum Phase88DurabilityTestCases {
    static func run(into suite: inout TestSuite) throws {
        preferencesSurviveEmptyAndTransientInventories(into: &suite)
        malformedMembershipCannotPrunePreferences(into: &suite)
        directManualOrderRejectsDestructiveFrames(into: &suite)
        degradedVisibleRowsRemainReorderable(into: &suite)
        try stablePrivateSingleInstanceLock(into: &suite)
        try rejectsSplitLockDomains(into: &suite)
    }

    private static func directManualOrderRejectsDestructiveFrames(
        into suite: inout TestSuite
    ) {
        var baseline = ShellManualOrder(
            orderedIDs: ["saved-b", "saved-a"],
            hasManualOverride: false
        )
        suite.check(
            !baseline.reconcile(latestFirstIDs: []),
            "direct empty reconciliation cannot erase an untouched saved baseline"
        )
        suite.checkEqual(
            baseline.orderedIDs,
            ["saved-b", "saved-a"],
            "empty reconciliation leaves baseline identifiers durable"
        )

        var manual = ShellManualOrder(
            orderedIDs: ["dormant-b", "dormant-a"],
            hasManualOverride: true
        )
        suite.check(
            manual.reconcile(latestFirstIDs: ["visible-new", "visible-old"]),
            "zero-overlap reconciliation incorporates visible identifiers"
        )
        suite.checkEqual(
            manual.orderedIDs,
            ["visible-new", "visible-old", "dormant-b", "dormant-a"],
            "zero-overlap reconciliation never wipes dormant manual preferences"
        )
    }

    private static func degradedVisibleRowsRemainReorderable(
        into suite: inout TestSuite
    ) {
        var threads = ShellManualOrder(
            orderedIDs: ["dormant-thread-b", "dormant-thread-a"],
            hasManualOverride: true
        )
        let visibleThreads = ["visible-thread-new", "visible-thread-old"]
        suite.checkEqual(
            ShellInventoryPreferencePolicy.visibleOrder(
                persisted: threads,
                latestFirstIDs: visibleThreads
            ),
            visibleThreads,
            "a zero-overlap degraded inventory renders its transient thread rows"
        )
        suite.check(
            threads.move(
                "visible-thread-old",
                relativeTo: "visible-thread-new",
                placement: .before,
                fromVisibleOrder: visibleThreads
            ),
            "a thread rendered only by degraded inventory can still be dragged"
        )
        suite.checkEqual(
            threads.orderedIDs,
            [
                "visible-thread-old",
                "visible-thread-new",
                "dormant-thread-b",
                "dormant-thread-a",
            ],
            "degraded thread drag persists the visible relationship without pruning dormant rows"
        )

        var projects = ShellManualOrder(
            orderedIDs: ["dormant-project"],
            hasManualOverride: true
        )
        let visibleProjects = ["visible-project-a", "visible-project-b"]
        suite.check(
            projects.move(
                "visible-project-a",
                direction: .down,
                within: visibleProjects,
                fromVisibleOrder: visibleProjects
            ),
            "a project rendered only by degraded inventory supports accessible step movement"
        )
        suite.checkEqual(
            projects.orderedIDs,
            ["visible-project-b", "visible-project-a", "dormant-project"],
            "degraded project movement preserves dormant persisted projects"
        )

        var interleavedThreads = ShellManualOrder(
            orderedIDs: ["project-a-1", "dormant-thread"],
            hasManualOverride: true
        )
        let fullVisibleOrder = ["project-a-1", "project-b-1", "project-a-2"]
        suite.check(
            interleavedThreads.move(
                "project-a-1",
                direction: .down,
                within: ["project-a-1", "project-a-2"],
                fromVisibleOrder: fullVisibleOrder
            ),
            "grouped movement uses visible project neighbors under degraded authority"
        )
        suite.checkEqual(
            interleavedThreads.orderedIDs,
            ["project-b-1", "project-a-2", "project-a-1", "dormant-thread"],
            "grouped degraded movement preserves unrelated visible and dormant identifiers"
        )
    }

    private static func malformedMembershipCannotPrunePreferences(
        into suite: inout TestSuite
    ) {
        var threadOrder = ShellManualOrder(
            orderedIDs: ["malformed-thread", "valid-thread"],
            hasManualOverride: true
        )
        var projectOrder = ShellManualOrder(
            orderedIDs: ["malformed-project", "valid-project"],
            hasManualOverride: true
        )
        var collapsedProjects: Set<String> = ["malformed-project"]
        let knownMalformedAuthority = ShellInventoryAuthority.resolve(
            isConnectedInventory: true,
            isTruncated: false,
            malformedRowCount: 1,
            inventoryMembershipIsComplete: true,
            listedThreadCount: 2,
            renderedThreadCount: 1
        )
        suite.checkEqual(
            knownMalformedAuthority,
            .unavailable,
            "a connected inventory missing a known malformed presentation row cannot prune preferences"
        )
        let changes = ShellInventoryPreferencePolicy.reconcile(
            threadOrder: &threadOrder,
            projectOrder: &projectOrder,
            collapsedProjectIDs: &collapsedProjects,
            latestFirstThreadIDs: ["valid-thread"],
            latestFirstProjectIDs: ["valid-project"],
            authority: knownMalformedAuthority
        )
        suite.checkEqual(changes, .init(), "malformed connected inventory produces no durable changes")
        suite.checkEqual(
            threadOrder.orderedIDs,
            ["malformed-thread", "valid-thread"],
            "known malformed membership remains in saved thread order"
        )
        suite.checkEqual(
            projectOrder.orderedIDs,
            ["malformed-project", "valid-project"],
            "a project hidden by malformed metadata remains in saved project order"
        )
        suite.checkEqual(
            collapsedProjects,
            ["malformed-project"],
            "a collapsed project hidden by malformed metadata remains saved"
        )

        suite.checkEqual(
            ShellInventoryAuthority.resolve(
                isConnectedInventory: true,
                isTruncated: false,
                malformedRowCount: 1,
                inventoryMembershipIsComplete: false,
                listedThreadCount: 1,
                renderedThreadCount: 1
            ),
            .unavailable,
            "unidentified malformed membership suppresses persistence even when visible counts match"
        )
        suite.checkEqual(
            ShellInventoryAuthority.resolve(
                isConnectedInventory: true,
                isTruncated: false,
                malformedRowCount: 0,
                inventoryMembershipIsComplete: true,
                listedThreadCount: 1,
                renderedThreadCount: 1
            ),
            .authoritative,
            "a complete clean connected inventory remains safe for persistence"
        )
    }

    private static func preferencesSurviveEmptyAndTransientInventories(
        into suite: inout TestSuite
    ) {
        var threadOrder = ShellManualOrder(
            orderedIDs: ["thread-b", "thread-a"],
            hasManualOverride: true
        )
        var projectOrder = ShellManualOrder(
            orderedIDs: ["project-b", "project-a"],
            hasManualOverride: true
        )
        var collapsedProjects: Set<String> = ["project-a"]

        let emptyChanges = ShellInventoryPreferencePolicy.reconcile(
            threadOrder: &threadOrder,
            projectOrder: &projectOrder,
            collapsedProjectIDs: &collapsedProjects,
            latestFirstThreadIDs: [],
            latestFirstProjectIDs: [],
            authority: .authoritative
        )
        suite.checkEqual(
            emptyChanges,
            .init(),
            "authoritative empty inventory does not persist destructive preference changes"
        )
        suite.checkEqual(
            threadOrder.orderedIDs,
            ["thread-b", "thread-a"],
            "empty inventory preserves manual thread order"
        )
        suite.checkEqual(
            projectOrder.orderedIDs,
            ["project-b", "project-a"],
            "empty inventory preserves manual project order"
        )
        suite.checkEqual(collapsedProjects, ["project-a"], "empty inventory preserves collapsed projects")
        suite.checkEqual(
            ShellInventoryPreferencePolicy.visibleOrder(
                persisted: threadOrder,
                latestFirstIDs: []
            ),
            [],
            "authoritative empty inventory still renders an empty thread list"
        )

        let transientChanges = ShellInventoryPreferencePolicy.reconcile(
            threadOrder: &threadOrder,
            projectOrder: &projectOrder,
            collapsedProjectIDs: &collapsedProjects,
            latestFirstThreadIDs: ["thread-new", "thread-a", "thread-b"],
            latestFirstProjectIDs: ["project-a", "project-b"],
            authority: .unavailable
        )
        suite.checkEqual(
            transientChanges,
            .init(),
            "non-authoritative inventory cannot rewrite preferences"
        )
        suite.checkEqual(
            threadOrder.orderedIDs,
            ["thread-b", "thread-a"],
            "transient rows leave durable thread order untouched"
        )
        suite.checkEqual(
            ShellInventoryPreferencePolicy.visibleOrder(
                persisted: threadOrder,
                latestFirstIDs: ["thread-new", "thread-a", "thread-b"]
            ),
            ["thread-new", "thread-b", "thread-a"],
            "transient rows remain visible around the saved manual order"
        )

        let repopulatedChanges = ShellInventoryPreferencePolicy.reconcile(
            threadOrder: &threadOrder,
            projectOrder: &projectOrder,
            collapsedProjectIDs: &collapsedProjects,
            latestFirstThreadIDs: ["thread-new", "thread-a", "thread-b"],
            latestFirstProjectIDs: ["project-a", "project-b"],
            authority: .authoritative
        )
        suite.check(
            repopulatedChanges.threadOrderChanged,
            "repopulated authority safely incorporates a new thread"
        )
        suite.check(
            !repopulatedChanges.collapsedProjectsChanged,
            "repopulated authority retains an available collapsed project"
        )
        suite.checkEqual(
            threadOrder.orderedIDs,
            ["thread-new", "thread-b", "thread-a"],
            "manual thread relationships survive empty then repopulation"
        )
        suite.checkEqual(
            projectOrder.orderedIDs,
            ["project-b", "project-a"],
            "manual project relationships survive empty then repopulation"
        )
        suite.checkEqual(
            collapsedProjects,
            ["project-a"],
            "collapsed preference survives empty then repopulation"
        )
    }

    private static func stablePrivateSingleInstanceLock(
        into suite: inout TestSuite
    ) throws {
        let support = try temporaryPrivateDirectory(named: "conn-instance-lock")
        defer { try? FileManager.default.removeItem(at: support) }

        var first: ConnSingleInstanceClaim? = try ConnSingleInstanceClaim.acquire(
            applicationSupportDirectory: support
        )
        suite.check(first != nil, "first launch acquires the stable Application Support lock")
        let second = try ConnSingleInstanceClaim.acquire(applicationSupportDirectory: support)
        suite.check(second == nil, "a concurrent launch cannot acquire the same stable lock")

        let connDirectory = support.appendingPathComponent("Conn", isDirectory: true)
        let lockFile = connDirectory.appendingPathComponent("conn-ui.lock")
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: connDirectory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: lockFile.path)
        suite.checkEqual(
            (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o700,
            "single-instance directory is current-user-only"
        )
        suite.checkEqual(
            (fileAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600,
            "single-instance file is current-user-only"
        )

        first = nil
        let afterRelease = try ConnSingleInstanceClaim.acquire(applicationSupportDirectory: support)
        suite.check(afterRelease != nil, "a clean shutdown releases the stable lock")
        _ = afterRelease
    }

    private static func rejectsSplitLockDomains(
        into suite: inout TestSuite
    ) throws {
        let support = try temporaryPrivateDirectory(named: "conn-instance-hardlink")
        defer { try? FileManager.default.removeItem(at: support) }
        let connDirectory = support.appendingPathComponent("Conn", isDirectory: true)
        try FileManager.default.createDirectory(
            at: connDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let lockFile = connDirectory.appendingPathComponent("conn-ui.lock")
        let secondLink = connDirectory.appendingPathComponent("replacement-domain")
        guard FileManager.default.createFile(
            atPath: lockFile.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw ConnSingleInstanceLockError.fileSystem(
                operation: "test-create-lock-file",
                code: errno
            )
        }
        guard link(lockFile.path, secondLink.path) == 0 else {
            throw ConnSingleInstanceLockError.fileSystem(
                operation: "test-create-hard-link",
                code: errno
            )
        }

        do {
            _ = try ConnSingleInstanceClaim.acquire(applicationSupportDirectory: support)
            suite.check(false, "a multiply linked lock file cannot create a split lock domain")
        } catch let error as ConnSingleInstanceLockError {
            suite.checkEqual(
                error,
                .unlinkedLockFile(lockFile.path),
                "stable lock validation rejects replaceable or multiply linked files"
            )
            suite.check(
                !(error.localizedDescription).isEmpty,
                "lock validation errors provide user-visible startup detail"
            )
        }
    }

    private static func temporaryPrivateDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }
}
