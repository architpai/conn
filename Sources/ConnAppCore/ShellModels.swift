import CoreGraphics
import Darwin
import Foundation
import ConnDomain

private typealias ConnFlockFunction = @convention(c) (Int32, Int32) -> Int32

/// Swift imports `flock` as the name of the C lock-structure type, so resolve
/// the libc function explicitly instead of adding a conflicting `_silgen_name`
/// declaration that changes calling convention under release optimization.
private let connFlockFunction: ConnFlockFunction? = {
    let defaultSymbolScope = UnsafeMutableRawPointer(bitPattern: -2)
    guard let symbol = Darwin.dlsym(defaultSymbolScope, "flock") else { return nil }
    return unsafeBitCast(symbol, to: ConnFlockFunction.self)
}()

private func connFlock(_ descriptor: Int32, _ operation: Int32) -> Int32 {
    guard let connFlockFunction else {
        errno = ENOSYS
        return -1
    }
    return connFlockFunction(descriptor, operation)
}

// MARK: - Shell lifecycle

public enum ShellSurfaceState: String, Codable, Equatable, Sendable {
    case compact
    case expanded
}

public enum ShellCompactShelfMode: Equatable, Sendable {
    case activity
    case approval
}

public enum ShellMotionStyle: Equatable, Sendable {
    case unfurlSpring
    case fadeOnly
}

public struct ShellMotionPresentation: Equatable, Sendable {
    public let style: ShellMotionStyle
    public let geometryDuration: TimeInterval
    public let contentDelay: TimeInterval
}

public enum ShellMotionPolicy {
    public static let expandedContentRevealLinearProgress = 0.58
    public static let expandedContentFadeDuration: TimeInterval = 0.16

    public static func presentation(reduceMotion: Bool) -> ShellMotionPresentation {
        reduceMotion
            ? .init(style: .fadeOnly, geometryDuration: 0, contentDelay: 0)
            : .init(style: .unfurlSpring, geometryDuration: 0.52, contentDelay: 0.08)
    }

    /// A damped spring whose first destination crossing occurs late in the
    /// transition. This keeps the visible unfurl aligned with content reveal
    /// instead of presenting a full-size empty panel during a long settle.
    public static func springProgress(_ linearProgress: Double) -> Double {
        let progress = min(max(linearProgress, 0), 1)
        guard progress < 1 else { return 1 }
        return 1 - (1 - progress) * exp(-2.5 * progress) * cos(2 * progress)
    }

    /// Derives animation progress from monotonic elapsed time instead of a
    /// scheduled frame index. A delayed main-thread callback therefore skips
    /// stale frames and still reaches the destination on time.
    public static func linearProgress(
        elapsed: TimeInterval,
        duration: TimeInterval
    ) -> Double {
        guard duration.isFinite, duration > 0 else { return 1 }
        guard elapsed.isFinite else { return elapsed.sign == .minus ? 0 : 1 }
        return min(max(elapsed / duration, 0), 1)
    }

    public static func shouldRevealExpandedContent(
        linearProgress: Double,
        hasPendingAnimatedGeometryRefresh: Bool
    ) -> Bool {
        !hasPendingAnimatedGeometryRefresh
            && linearProgress >= expandedContentRevealLinearProgress
    }
}

public enum ShellExpandedContentPresentationPolicy {
    /// Expanded content stays unmounted while AppKit changes the panel frame so
    /// the transcript and composer are not laid out at every intermediate size.
    public static func presentsExpandedContent(
        surface: ShellSurfaceState,
        isRevealReady: Bool
    ) -> Bool {
        surface == .expanded && isRevealReady
    }
}

public struct ShellSurfaceGeometryTransitionGeneration: Equatable, Sendable {
    fileprivate let rawValue: UInt64
}

public struct ShellSurfaceGeometryTransitionGenerationGate: Equatable, Sendable {
    private var value: UInt64 = 0

    public init() {}

    public mutating func begin() -> ShellSurfaceGeometryTransitionGeneration {
        value &+= 1
        return .init(rawValue: value)
    }

    public mutating func invalidate() {
        value &+= 1
    }

    public func isCurrent(_ generation: ShellSurfaceGeometryTransitionGeneration) -> Bool {
        generation.rawValue == value
    }
}

/// Deterministic presentation math for the compact notification shelf. The
    /// view owns only the notification's appearance date; this policy keeps its
    /// waveform and countdown behavior deterministic for each batch lifetime.
public enum ShellCompactShelfMotionPolicy {
    public static let defaultActivityLifetime: TimeInterval = 5
    public static let waveformCycleDuration: TimeInterval = 0.72

    public static func countdownProgress(
        elapsed: TimeInterval,
        duration: TimeInterval = defaultActivityLifetime,
        reduceMotion: Bool
    ) -> Double {
        guard !reduceMotion, elapsed.isFinite else { return 1 }
        let boundedDuration = max(duration, 0.1)
        return 1 - min(max(elapsed / boundedDuration, 0), 1)
    }

    public static func waveformHeight(
        barIndex: Int,
        elapsed: TimeInterval,
        reduceMotion: Bool
    ) -> CGFloat {
        let boundedIndex = min(max(barIndex, 0), 4)
        guard !reduceMotion, elapsed.isFinite else {
            return [6, 10, 14, 10, 6][boundedIndex]
        }
        let normalizedTime = elapsed / waveformCycleDuration
        let phase = (normalizedTime * 2 * Double.pi) + (Double(boundedIndex) * 0.82)
        return CGFloat(6 + ((sin(phase) + 1) * 4))
    }
}

/// Runtime-only content that unfolds beneath the compact bar without creating
/// another lifecycle state.
public struct ShellCompactShelfPresentation: Equatable, Sendable, Identifiable {
    public let id: String
    public let mode: ShellCompactShelfMode
    public let verb: String
    public let detail: String
    public let requestID: AppServerScopedRequestID?
    public let threadID: AppServerThreadID
    public let turnID: AppServerTurnID?
    public let approvalChoices: [AppServerApprovalChoice]

    public init(
        id: String,
        mode: ShellCompactShelfMode,
        verb: String,
        detail: String,
        requestID: AppServerScopedRequestID? = nil,
        threadID: AppServerThreadID,
        turnID: AppServerTurnID? = nil,
        approvalChoices: [AppServerApprovalChoice] = []
    ) {
        self.id = id
        self.mode = mode
        self.verb = verb
        self.detail = detail
        self.requestID = requestID
        self.threadID = threadID
        self.turnID = turnID
        self.approvalChoices = approvalChoices
    }
}

public enum ShellCompactApprovalPolicy {
    public static let displayOrder: [AppServerApprovalChoice] = [
        .approve, .approveForSession, .deny,
    ]

    public static func visibleChoices(
        from availableChoices: [AppServerApprovalChoice]
    ) -> [AppServerApprovalChoice] {
        let available = Set(availableChoices)
        return displayOrder.filter(available.contains)
    }
}

public enum ShellAppearance: String, CaseIterable, Codable, Equatable, Sendable {
    case dark
    case light
}

public enum ShellSidebarMode: String, CaseIterable, Codable, Equatable, Sendable {
    case threads
    case projects
}

public enum ShellOrderPlacement: Equatable, Sendable {
    case before
    case after
}

public enum ShellOrderStepDirection: Equatable, Sendable {
    case up
    case down
}

public enum ShellBarToggleAction: Equatable, Sendable {
    case resumeAndExpand
    case expand
    case collapse
}

/// Keeps the mock-aligned two-state bar behavior independent from AppKit wiring.
public enum ShellBarTogglePolicy {
    public static func action(for lifecycle: ShellLifecycleState) -> ShellBarToggleAction {
        guard lifecycle.visibility == .visible else { return .resumeAndExpand }
        return lifecycle.surface == .compact ? .expand : .collapse
    }
}

public enum ShellEscapeRoute: Equatable, Sendable {
    case ignore
    case dismissSettings
    case stepDown
}

/// Routes one exact Escape event. There is deliberately no time-window state:
/// the AppKit monitor consumes the event it routes, so a later Escape remains a
/// separate user intent even when it immediately follows settings dismissal.
public enum ShellEscapeRoutingPolicy {
    public static func route(
        showsSettings: Bool,
        lifecycle: ShellLifecycleState
    ) -> ShellEscapeRoute {
        if showsSettings { return .dismissSettings }
        guard lifecycle.visibility == .visible, lifecycle.surface != .compact else {
            return .ignore
        }
        return .stepDown
    }
}

public enum ShellQuestionEscapeAction: Equatable, Sendable {
    case defocusQuestionInput
    case routePanelEscape
}

/// Gives an active question field first refusal on Escape before the shell's
/// two-state collapse policy handles the next distinct key event.
public enum ShellQuestionEscapePolicy {
    public static func action(isQuestionInputFocused: Bool) -> ShellQuestionEscapeAction {
        isQuestionInputFocused ? .defocusQuestionInput : .routePanelEscape
    }
}

/// A persisted, identifier-only order for shell rows. Until the first drag it
/// follows each authoritative latest-first baseline exactly. After a drag it
/// preserves retained manual relationships while merging newly discovered IDs
/// at their authoritative recency boundary.
public struct ShellManualOrder: Codable, Equatable, Sendable {
    public private(set) var orderedIDs: [String]
    public private(set) var hasManualOverride: Bool

    public init(orderedIDs: [String] = [], hasManualOverride: Bool = false) {
        self.orderedIDs = Self.unique(orderedIDs)
        self.hasManualOverride = hasManualOverride
    }

    @discardableResult
    public mutating func reconcile(latestFirstIDs: [String]) -> Bool {
        let latest = Self.unique(latestFirstIDs)
        // Empty publication is meaningful to rendering, but never sufficient
        // evidence to erase the user's durable ordering intent. Callers render
        // through the current inventory independently from this saved order.
        guard !latest.isEmpty else { return false }
        guard hasManualOverride else {
            guard latest != orderedIDs else { return false }
            orderedIDs = latest
            return true
        }

        let available = Set(latest)
        let retained = orderedIDs.filter(available.contains)
        let retainedSet = Set(retained)
        let newlyObserved = latest.filter { !retainedSet.contains($0) }
        guard !retained.isEmpty else {
            // A zero-overlap frame may be a truncated/malformed reconnect view.
            // Incorporate what is currently visible without deleting dormant
            // saved identifiers. A later overlapping authoritative frame can
            // prune identifiers it genuinely proves absent.
            let latestSet = Set(latest)
            let next = latest + orderedIDs.filter { !latestSet.contains($0) }
            guard next != orderedIDs else { return false }
            orderedIDs = next
            return true
        }

        let rank = Dictionary(uniqueKeysWithValues: latest.enumerated().map { ($1, $0) })
        let retainedRanks = retained.compactMap { rank[$0] }
        let minimumRetainedRank = retainedRanks.min() ?? 0
        let maximumRetainedRank = retainedRanks.max() ?? 0
        var prepended: [String] = []
        var appended: [String] = []
        var insertionsAfter: [String: [String]] = [:]

        for id in newlyObserved {
            guard let idRank = rank[id] else { continue }
            if idRank < minimumRetainedRank {
                prepended.append(id)
            } else if idRank > maximumRetainedRank {
                appended.append(id)
            } else if let predecessor = retained
                .filter({ (rank[$0] ?? Int.max) < idRank })
                .max(by: { (rank[$0] ?? Int.min) < (rank[$1] ?? Int.min) }) {
                insertionsAfter[predecessor, default: []].append(id)
            } else {
                prepended.append(id)
            }
        }

        var next = prepended
        for id in retained {
            next.append(id)
            next.append(contentsOf: insertionsAfter[id] ?? [])
        }
        next.append(contentsOf: appended)
        guard next != orderedIDs else { return false }
        orderedIDs = next
        return true
    }

    @discardableResult
    public mutating func move(_ id: String, before targetID: String) -> Bool {
        move(id, relativeTo: targetID, placement: .before)
    }

    @discardableResult
    public mutating func move(
        _ id: String,
        relativeTo targetID: String,
        placement: ShellOrderPlacement
    ) -> Bool {
        guard id != targetID,
              let sourceIndex = orderedIDs.firstIndex(of: id),
              orderedIDs.contains(targetID)
        else { return false }
        var next = orderedIDs
        next.remove(at: sourceIndex)
        guard let targetIndex = next.firstIndex(of: targetID) else { return false }
        let insertionIndex = placement == .after ? targetIndex + 1 : targetIndex
        next.insert(id, at: insertionIndex)
        guard next != orderedIDs else { return false }
        orderedIDs = next
        hasManualOverride = true
        return true
    }

    @discardableResult
    public mutating func move(
        _ id: String,
        direction: ShellOrderStepDirection
    ) -> Bool {
        guard let sourceIndex = orderedIDs.firstIndex(of: id) else { return false }
        let targetIndex: Int
        switch direction {
        case .up:
            guard sourceIndex > orderedIDs.startIndex else { return false }
            targetIndex = sourceIndex - 1
        case .down:
            guard sourceIndex < orderedIDs.index(before: orderedIDs.endIndex) else { return false }
            targetIndex = sourceIndex + 1
        }
        orderedIDs.swapAt(sourceIndex, targetIndex)
        hasManualOverride = true
        return true
    }

    /// Moves by one visible neighbor while preserving unrelated interleaved
    /// identifiers (for example threads belonging to other project groups).
    @discardableResult
    public mutating func move(
        _ id: String,
        direction: ShellOrderStepDirection,
        within visibleIDs: [String]
    ) -> Bool {
        let visible = Self.unique(visibleIDs).filter(orderedIDs.contains)
        guard let sourceIndex = visible.firstIndex(of: id) else { return false }
        let targetID: String
        let placement: ShellOrderPlacement
        switch direction {
        case .up:
            guard sourceIndex > visible.startIndex else { return false }
            targetID = visible[sourceIndex - 1]
            placement = .before
        case .down:
            guard sourceIndex < visible.index(before: visible.endIndex) else { return false }
            targetID = visible[sourceIndex + 1]
            placement = .after
        }
        return move(id, relativeTo: targetID, placement: placement)
    }

    /// Moves identifiers from a transient rendered order while retaining saved
    /// identifiers that are absent from the current degraded inventory. The
    /// candidate is committed only after a real move succeeds, so a boundary or
    /// malformed drag cannot rewrite preferences as a side effect.
    @discardableResult
    public mutating func move(
        _ id: String,
        relativeTo targetID: String,
        placement: ShellOrderPlacement,
        fromVisibleOrder visibleIDs: [String]
    ) -> Bool {
        var candidate = self
        guard candidate.seedForVisibleMove(visibleIDs),
              candidate.move(id, relativeTo: targetID, placement: placement)
        else { return false }
        self = candidate
        return true
    }

    /// Uses `neighborIDs` for scoped movement (for example one project) while
    /// seeding from the complete visible order so unrelated rendered rows do
    /// not jump when the degraded move becomes durable.
    @discardableResult
    public mutating func move(
        _ id: String,
        direction: ShellOrderStepDirection,
        within neighborIDs: [String],
        fromVisibleOrder visibleIDs: [String]
    ) -> Bool {
        var candidate = self
        guard candidate.seedForVisibleMove(visibleIDs),
              candidate.move(id, direction: direction, within: neighborIDs)
        else { return false }
        self = candidate
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case orderedIDs
        case hasManualOverride
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        orderedIDs = Self.unique(try container.decodeIfPresent([String].self, forKey: .orderedIDs) ?? [])
        hasManualOverride = try container.decodeIfPresent(Bool.self, forKey: .hasManualOverride) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(orderedIDs, forKey: .orderedIDs)
        try container.encode(hasManualOverride, forKey: .hasManualOverride)
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    @discardableResult
    private mutating func seedForVisibleMove(_ visibleIDs: [String]) -> Bool {
        let visible = Self.unique(visibleIDs)
        guard !visible.isEmpty else { return false }
        let visibleSet = Set(visible)
        orderedIDs = visible + orderedIDs.filter { !visibleSet.contains($0) }
        return true
    }
}

public enum ShellInventoryAuthority: Equatable, Sendable {
    /// A startup, reconnect, or truncated frame that cannot prove inventory
    /// membership. It may render cached rows but cannot rewrite preferences.
    case unavailable
    /// One complete inventory response, including a genuine empty inventory.
    case authoritative

    /// Resolves whether the rendered identifiers are safe to use for durable
    /// preference pruning. Connection authority alone is insufficient: a
    /// malformed row can be known to inventory membership without producing a
    /// presentation row, while an unidentified malformed row makes membership
    /// itself incomplete.
    public static func resolve(
        isConnectedInventory: Bool,
        isTruncated: Bool,
        malformedRowCount: Int,
        inventoryMembershipIsComplete: Bool,
        listedThreadCount: Int?,
        renderedThreadCount: Int
    ) -> ShellInventoryAuthority {
        guard isConnectedInventory,
              !isTruncated,
              malformedRowCount == 0,
              inventoryMembershipIsComplete,
              let listedThreadCount,
              listedThreadCount == renderedThreadCount
        else { return .unavailable }
        return .authoritative
    }
}

public struct ShellInventoryPreferenceChanges: Equatable, Sendable {
    public let threadOrderChanged: Bool
    public let projectOrderChanged: Bool
    public let collapsedProjectsChanged: Bool

    public init(
        threadOrderChanged: Bool = false,
        projectOrderChanged: Bool = false,
        collapsedProjectsChanged: Bool = false
    ) {
        self.threadOrderChanged = threadOrderChanged
        self.projectOrderChanged = projectOrderChanged
        self.collapsedProjectsChanged = collapsedProjectsChanged
    }
}

/// Keeps durable user ordering separate from transient inventory frames.
/// Authoritative emptiness is meaningful for what the UI renders, but is not
/// useful evidence that the user's ordering and disclosure intent should be
/// permanently erased.
public enum ShellInventoryPreferencePolicy {
    public static func visibleOrder(
        persisted: ShellManualOrder,
        latestFirstIDs: [String]
    ) -> [String] {
        let visibleIDs = Set(latestFirstIDs)
        guard !visibleIDs.isEmpty else { return [] }
        var transient = persisted
        _ = transient.reconcile(latestFirstIDs: latestFirstIDs)
        return transient.orderedIDs.filter(visibleIDs.contains)
    }

    @discardableResult
    public static func reconcile(
        threadOrder: inout ShellManualOrder,
        projectOrder: inout ShellManualOrder,
        collapsedProjectIDs: inout Set<String>,
        latestFirstThreadIDs: [String],
        latestFirstProjectIDs: [String],
        authority: ShellInventoryAuthority
    ) -> ShellInventoryPreferenceChanges {
        guard authority == .authoritative else { return .init() }

        // A complete empty inventory renders as empty via the presentation,
        // while its persisted preferences remain available after reconnect or
        // after a daemon briefly reports no loaded workspace metadata.
        guard !latestFirstThreadIDs.isEmpty || !latestFirstProjectIDs.isEmpty else {
            return .init()
        }

        let threadChanged = latestFirstThreadIDs.isEmpty
            ? false
            : threadOrder.reconcile(latestFirstIDs: latestFirstThreadIDs)
        let projectChanged = latestFirstProjectIDs.isEmpty
            ? false
            : projectOrder.reconcile(latestFirstIDs: latestFirstProjectIDs)

        var collapsedChanged = false
        if !latestFirstProjectIDs.isEmpty {
            let availableProjects = Set(latestFirstProjectIDs)
            let pruned = collapsedProjectIDs.intersection(availableProjects)
            if pruned != collapsedProjectIDs {
                collapsedProjectIDs = pruned
                collapsedChanged = true
            }
        }
        return .init(
            threadOrderChanged: threadChanged,
            projectOrderChanged: projectChanged,
            collapsedProjectsChanged: collapsedChanged
        )
    }
}

package enum ConnSingleInstanceLockError: Error, Equatable, Sendable {
    case applicationSupportUnavailable
    case unsafePath(String)
    case symbolicLinkNotAllowed(String)
    case unexpectedFileType(String)
    case unexpectedOwner(String)
    case insecurePermissions(String)
    case unlinkedLockFile(String)
    case fileSystem(operation: String, code: Int32)
}

extension ConnSingleInstanceLockError: LocalizedError {
    package var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            "Application Support is unavailable."
        case let .unsafePath(path):
            "The single-instance lock path is unsafe: \(path)"
        case let .symbolicLinkNotAllowed(path):
            "The single-instance lock path must not be a symbolic link: \(path)"
        case let .unexpectedFileType(path):
            "The single-instance lock has an unexpected file type: \(path)"
        case let .unexpectedOwner(path):
            "The single-instance lock is not owned by the current user: \(path)"
        case let .insecurePermissions(path):
            "The single-instance lock location is not private: \(path)"
        case let .unlinkedLockFile(path):
            "The single-instance lock is no longer linked at its stable path: \(path)"
        case let .fileSystem(operation, code):
            "The single-instance lock failed during \(operation) (error \(code))."
        }
    }
}

/// A process-lifetime lock rooted under the user's private Application
/// Support/Conn directory. The descriptor and stable pathname are validated
/// after locking so removing/replacing a temporary lock cannot create two
/// independent lock domains.
package final class ConnSingleInstanceClaim {
    package static let directoryName = "Conn"
    package static let fileName = "conn-ui.lock"

    private static let privateDirectoryMode: mode_t = 0o700
    private static let privateFileMode: mode_t = 0o600
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    package static func acquireUserDefault(
        fileManager: FileManager = .default,
        expectedOwnerUID: uid_t = getuid()
    ) throws -> ConnSingleInstanceClaim? {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ConnSingleInstanceLockError.applicationSupportUnavailable
        }
        return try acquire(
            applicationSupportDirectory: applicationSupport,
            expectedOwnerUID: expectedOwnerUID
        )
    }

    /// Returns nil only when another process already owns the validated lock.
    /// Location, open, and validation failures are thrown for user-visible
    /// startup reporting; callers must never continue without a claim.
    package static func acquire(
        applicationSupportDirectory: URL,
        expectedOwnerUID: uid_t = getuid()
    ) throws -> ConnSingleInstanceClaim? {
        let base = applicationSupportDirectory.standardizedFileURL
        guard base.isFileURL, base.path.hasPrefix("/") else {
            throw ConnSingleInstanceLockError.unsafePath(applicationSupportDirectory.path)
        }
        let directoryURL = base.appendingPathComponent(directoryName, isDirectory: true)
            .standardizedFileURL
        guard directoryURL.path.hasPrefix(base.path + "/") else {
            throw ConnSingleInstanceLockError.unsafePath(directoryURL.path)
        }
        let lockURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)

        let baseDescriptor = Darwin.open(
            base.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard baseDescriptor >= 0 else {
            throw openError(operation: "open-application-support", path: base.path)
        }
        defer { Darwin.close(baseDescriptor) }
        try validateDirectory(
            baseDescriptor,
            path: base.path,
            expectedOwnerUID: expectedOwnerUID,
            requirePrivatePermissions: false
        )

        if mkdirat(baseDescriptor, directoryName, privateDirectoryMode) != 0,
           errno != EEXIST {
            throw ConnSingleInstanceLockError.fileSystem(
                operation: "create-conn-directory",
                code: errno
            )
        }
        let directoryDescriptor = openat(
            baseDescriptor,
            directoryName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw openError(operation: "open-conn-directory", path: directoryURL.path)
        }
        defer { Darwin.close(directoryDescriptor) }
        try validateDirectory(
            directoryDescriptor,
            path: directoryURL.path,
            expectedOwnerUID: expectedOwnerUID,
            requirePrivatePermissions: true
        )

        let descriptor = openat(
            directoryDescriptor,
            fileName,
            O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
            privateFileMode
        )
        guard descriptor >= 0 else {
            throw openError(operation: "open-instance-lock", path: lockURL.path)
        }
        var ownsLock = false
        do {
            try validateLockFile(
                descriptor,
                directoryDescriptor: directoryDescriptor,
                path: lockURL.path,
                expectedOwnerUID: expectedOwnerUID
            )
            guard connFlock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                if code == EWOULDBLOCK || code == EAGAIN {
                    Darwin.close(descriptor)
                    return nil
                }
                throw ConnSingleInstanceLockError.fileSystem(
                    operation: "lock-instance-file",
                    code: code
                )
            }
            ownsLock = true
            try validateLockFile(
                descriptor,
                directoryDescriptor: directoryDescriptor,
                path: lockURL.path,
                expectedOwnerUID: expectedOwnerUID
            )
            return ConnSingleInstanceClaim(descriptor: descriptor)
        } catch {
            if ownsLock { _ = connFlock(descriptor, LOCK_UN) }
            Darwin.close(descriptor)
            throw error
        }
    }

    deinit {
        _ = connFlock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    private static func openError(
        operation: String,
        path: String
    ) -> ConnSingleInstanceLockError {
        if errno == ELOOP {
            return .symbolicLinkNotAllowed(path)
        }
        return .fileSystem(operation: operation, code: errno)
    }

    private static func validateDirectory(
        _ descriptor: Int32,
        path: String,
        expectedOwnerUID: uid_t,
        requirePrivatePermissions: Bool
    ) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw ConnSingleInstanceLockError.fileSystem(
                operation: "inspect-instance-directory",
                code: errno
            )
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            throw ConnSingleInstanceLockError.unexpectedFileType(path)
        }
        guard metadata.st_uid == expectedOwnerUID else {
            throw ConnSingleInstanceLockError.unexpectedOwner(path)
        }
        if requirePrivatePermissions,
           metadata.st_mode & mode_t(S_IRWXG | S_IRWXO) != 0 {
            throw ConnSingleInstanceLockError.insecurePermissions(path)
        }
    }

    private static func validateLockFile(
        _ descriptor: Int32,
        directoryDescriptor: Int32,
        path: String,
        expectedOwnerUID: uid_t
    ) throws {
        var descriptorMetadata = stat()
        guard fstat(descriptor, &descriptorMetadata) == 0 else {
            throw ConnSingleInstanceLockError.fileSystem(
                operation: "inspect-instance-lock",
                code: errno
            )
        }
        guard descriptorMetadata.st_mode & S_IFMT == S_IFREG else {
            throw ConnSingleInstanceLockError.unexpectedFileType(path)
        }
        guard descriptorMetadata.st_uid == expectedOwnerUID else {
            throw ConnSingleInstanceLockError.unexpectedOwner(path)
        }
        guard descriptorMetadata.st_mode & mode_t(S_IRWXG | S_IRWXO) == 0 else {
            throw ConnSingleInstanceLockError.insecurePermissions(path)
        }
        guard descriptorMetadata.st_nlink == 1 else {
            throw ConnSingleInstanceLockError.unlinkedLockFile(path)
        }

        var pathMetadata = stat()
        guard fstatat(
            directoryDescriptor,
            fileName,
            &pathMetadata,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            throw ConnSingleInstanceLockError.unlinkedLockFile(path)
        }
        guard pathMetadata.st_mode & S_IFMT == S_IFREG else {
            throw ConnSingleInstanceLockError.unexpectedFileType(path)
        }
        guard descriptorMetadata.st_dev == pathMetadata.st_dev,
              descriptorMetadata.st_ino == pathMetadata.st_ino,
              pathMetadata.st_nlink == 1 else {
            throw ConnSingleInstanceLockError.unlinkedLockFile(path)
        }
    }
}

/// Phase 8.7 reserves the final control layout without claiming that Conn can
/// yet mutate a Codex thread. Phase 9 replaces this policy with capability-
/// gated actions; no App Server method belongs in this presentation policy.
public struct ShellPhase9AffordancePolicy: Equatable, Sendable {
    public static let laterReleaseDetail = "Thread actions arrive in a later Conn release."

    public let isComposerEnabled: Bool
    public let isSendEnabled: Bool
    public let isStopEnabled: Bool
    public let areApprovalResponsesEnabled: Bool
    public let areQuestionResponsesEnabled: Bool
    public let detail: String

    public init(
        isComposerEnabled: Bool = false,
        isSendEnabled: Bool = false,
        isStopEnabled: Bool = false,
        areApprovalResponsesEnabled: Bool = false,
        areQuestionResponsesEnabled: Bool = false,
        detail: String = Self.laterReleaseDetail
    ) {
        self.isComposerEnabled = isComposerEnabled
        self.isSendEnabled = isSendEnabled
        self.isStopEnabled = isStopEnabled
        self.areApprovalResponsesEnabled = areApprovalResponsesEnabled
        self.areQuestionResponsesEnabled = areQuestionResponsesEnabled
        self.detail = detail
    }
}

/// Presentation-level monitoring intent. This state must never gate durable
/// inbox ingestion or acknowledgement; Pause only suppresses shell updates.
public enum ShellMonitoringState: String, Codable, Equatable, Sendable {
    case monitoring
    case paused
}

public enum ShellVisibilityState: String, Codable, Equatable, Sendable {
    case visible
    case hidden
}

public enum ShellApplicationLifecycleState: String, Codable, Equatable, Sendable {
    case active
    case sessionInactive
    case screenAsleep
    case terminating
}

public enum ShellSystemAvailabilityEvent: Equatable, Sendable {
    case userSessionActive(Bool)
    case screensAwake(Bool)
}

/// Tracks independent system suppressors so a screen-wake notification cannot
/// reveal Conn while the user session is still inactive or locked.
public struct ShellSystemAvailability: Codable, Equatable, Sendable {
    public private(set) var isUserSessionActive: Bool
    public private(set) var areScreensAwake: Bool

    public init(isUserSessionActive: Bool = true, areScreensAwake: Bool = true) {
        self.isUserSessionActive = isUserSessionActive
        self.areScreensAwake = areScreensAwake
    }

    public var lifecycleState: ShellApplicationLifecycleState {
        if !isUserSessionActive { return .sessionInactive }
        if !areScreensAwake { return .screenAsleep }
        return .active
    }

    public mutating func apply(_ event: ShellSystemAvailabilityEvent) {
        switch event {
        case let .userSessionActive(active):
            isUserSessionActive = active
        case let .screensAwake(awake):
            areScreensAwake = awake
        }
    }
}

/// User intent and passive observations are deliberately distinct. Passive
/// observations are accepted by the reducer but never open, reveal, or unpause
/// the shell.
public enum ShellLifecycleEvent: Equatable, Sendable {
    case userExpand
    case userCollapse
    case userToggleExpansion
    case outsideClick
    case escape
    case pauseMonitoring
    case resumeMonitoring
    case hide
    case show
    case pauseAndHide
    case resumeAndShow
    case applicationLifecycleChanged(ShellApplicationLifecycleState)
    case passiveUpdate
}

public struct ShellLifecycleState: Codable, Equatable, Sendable {
    public private(set) var surface: ShellSurfaceState
    public private(set) var monitoring: ShellMonitoringState
    public private(set) var visibility: ShellVisibilityState
    public private(set) var applicationLifecycle: ShellApplicationLifecycleState
    public private(set) var isUserHidden: Bool

    public init(
        surface: ShellSurfaceState = .compact,
        monitoring: ShellMonitoringState = .monitoring,
        visibility: ShellVisibilityState = .visible,
        applicationLifecycle: ShellApplicationLifecycleState = .active,
        isUserHidden: Bool? = nil
    ) {
        let userHidden = isUserHidden ?? (visibility == .hidden)
        let shouldSuppress = userHidden || applicationLifecycle != .active
        self.surface = userHidden ? .compact : surface
        self.monitoring = monitoring
        self.visibility = shouldSuppress ? .hidden : .visible
        self.applicationLifecycle = applicationLifecycle
        self.isUserHidden = userHidden
    }

    public var isInteractive: Bool {
        visibility == .visible && surface == .expanded
    }

    @discardableResult
    public mutating func apply(_ event: ShellLifecycleEvent) -> Bool {
        let previous = self

        switch event {
        case .userExpand:
            guard visibility == .visible else { break }
            surface = .expanded
        case .userCollapse:
            surface = .compact
        case .outsideClick:
            surface = .compact
        case .escape:
            surface = .compact
        case .userToggleExpansion:
            guard visibility == .visible else { break }
            surface = surface == .expanded ? .compact : .expanded
        case .pauseMonitoring:
            monitoring = .paused
        case .resumeMonitoring:
            monitoring = .monitoring
        case .hide:
            surface = .compact
            isUserHidden = true
            refreshVisibility()
        case .show:
            surface = .compact
            isUserHidden = false
            refreshVisibility()
        case .pauseAndHide:
            monitoring = .paused
            surface = .compact
            isUserHidden = true
            refreshVisibility()
        case .resumeAndShow:
            monitoring = .monitoring
            surface = .compact
            isUserHidden = false
            refreshVisibility()
        case let .applicationLifecycleChanged(lifecycle):
            applicationLifecycle = lifecycle
            refreshVisibility()
        case .passiveUpdate:
            break
        }

        return self != previous
    }

    public func applying(_ event: ShellLifecycleEvent) -> Self {
        var copy = self
        copy.apply(event)
        return copy
    }

    private mutating func refreshVisibility() {
        visibility = !isUserHidden && applicationLifecycle == .active ? .visible : .hidden
    }
}

// MARK: - Stable session selection

/// Keeps selection attached to a session identifier instead of an array index.
/// A passive refresh may reorder rows freely. If the selected row disappears
/// during direct interaction, fallback is deferred until interaction ends.
public struct ShellSelectionState: Equatable, Sendable {
    public private(set) var selectedSessionID: String?
    public private(set) var isUserInteracting: Bool

    private var deferredAvailableSessionIDs: [String]?

    public init(selectedSessionID: String? = nil, isUserInteracting: Bool = false) {
        self.selectedSessionID = selectedSessionID
        self.isUserInteracting = isUserInteracting
        self.deferredAvailableSessionIDs = nil
    }

    public mutating func beginUserInteraction() {
        isUserInteracting = true
    }

    @discardableResult
    public mutating func selectSession(
        _ sessionID: String?,
        availableSessionIDs: [String]
    ) -> Bool {
        let available = Self.uniqueIDs(availableSessionIDs)
        guard sessionID == nil || available.contains(sessionID!) else { return false }

        selectedSessionID = sessionID
        deferredAvailableSessionIDs = available
        return true
    }

    /// Reconciles a domain refresh without allowing row reordering to change a
    /// valid selection. Returns true only when selection actually changes.
    @discardableResult
    public mutating func applyPassiveUpdate(availableSessionIDs: [String]) -> Bool {
        let available = Self.uniqueIDs(availableSessionIDs)
        let previousSelection = selectedSessionID

        if let selectedSessionID, available.contains(selectedSessionID) {
            deferredAvailableSessionIDs = nil
            return false
        }

        if isUserInteracting {
            deferredAvailableSessionIDs = available
            return false
        }

        selectedSessionID = available.first
        deferredAvailableSessionIDs = nil
        return selectedSessionID != previousSelection
    }

    /// Ends direct interaction and applies the latest deferred fallback, if a
    /// selected row disappeared while the user was interacting.
    @discardableResult
    public mutating func endUserInteraction() -> Bool {
        let previousSelection = selectedSessionID
        isUserInteracting = false

        if let available = deferredAvailableSessionIDs {
            if selectedSessionID == nil || !available.contains(selectedSessionID!) {
                selectedSessionID = available.first
            }
        }

        deferredAvailableSessionIDs = nil
        return selectedSessionID != previousSelection
    }

    private static func uniqueIDs(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        return ids.filter { seen.insert($0).inserted }
    }
}

// MARK: - Asynchronous shell action authority

/// Opaque authority for one user-started shell action. Callers can retain and
/// compare tokens, but only `ShellActionGate` can mint them.
public struct ShellActionToken: Hashable, Sendable {
    fileprivate let generation: UUID

    fileprivate init(generation: UUID) {
        self.generation = generation
    }
}

public enum ShellActionCompletionResult: Equatable, Sendable {
    case completed
    case ignored
}

/// Prevents an asynchronous completion from mutating a replacement action.
/// Starting a new action invalidates the previous token immediately.
public struct ShellActionGate: Sendable {
    private var currentToken: ShellActionToken?

    public init() {}

    public var hasCurrentAction: Bool { currentToken != nil }

    @discardableResult
    public mutating func begin() -> ShellActionToken {
        let token = ShellActionToken(generation: UUID())
        currentToken = token
        return token
    }

    public func isCurrent(_ token: ShellActionToken) -> Bool {
        currentToken == token
    }

    /// Consumes only the exact current token. A stale callback is observable as
    /// `ignored` and leaves the replacement action untouched.
    @discardableResult
    public mutating func complete(
        _ token: ShellActionToken
    ) -> ShellActionCompletionResult {
        guard currentToken == token else { return .ignored }
        currentToken = nil
        return .completed
    }

    public mutating func invalidate() {
        currentToken = nil
    }
}

public enum ShellActionTerminalOutcome: Equatable, Sendable {
    case success
    case failure
    case cancelled
    case rejected
}

public enum ShellActionPresentationEffect: Equatable, Sendable {
    case ignored
    case finished
    case finishedAndCollapse
}

/// Pure action state used by the native view model. Context is descriptive;
/// completion authority always comes from the opaque token, so two actions for
/// the same thread still cannot complete one another.
public struct ShellActionState: Sendable {
    private var gate = ShellActionGate()
    public private(set) var contextID: String?
    public private(set) var isPerforming = false

    public init() {}

    @discardableResult
    public mutating func begin(
        contextID: String?,
        isPerforming: Bool
    ) -> ShellActionToken {
        let token = gate.begin()
        self.contextID = contextID
        self.isPerforming = isPerforming
        return token
    }

    public func isCurrent(_ token: ShellActionToken) -> Bool {
        gate.isCurrent(token)
    }

    @discardableResult
    public mutating func finish(
        _ token: ShellActionToken,
        outcome: ShellActionTerminalOutcome,
        collapseOnSuccess: Bool = false
    ) -> ShellActionPresentationEffect {
        guard gate.complete(token) == .completed else { return .ignored }
        contextID = nil
        isPerforming = false
        if outcome == .success, collapseOnSuccess {
            return .finishedAndCollapse
        }
        return .finished
    }

    public mutating func invalidate() {
        gate.invalidate()
        contextID = nil
        isPerforming = false
    }
}

// MARK: - Display selection and persistence

public struct ShellDisplayID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

public struct ShellEdgeInsets: Equatable, Sendable {
    public var top: CGFloat
    public var left: CGFloat
    public var bottom: CGFloat
    public var right: CGFloat

    public init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
        self.top = max(0, top.isFinite ? top : 0)
        self.left = max(0, left.isFinite ? left : 0)
        self.bottom = max(0, bottom.isFinite ? bottom : 0)
        self.right = max(0, right.isFinite ? right : 0)
    }
}

/// AppKit adapters populate this from NSScreen. The persistent identifier should
/// be based on the CoreGraphics display UUID, not the runtime display number.
public struct ShellDisplayDescriptor: Equatable, Sendable, Identifiable {
    public let id: ShellDisplayID
    public let persistentIdentifier: String
    public let localizedName: String
    public let frame: CGRect
    public let visibleFrame: CGRect
    public let safeAreaInsets: ShellEdgeInsets
    public let isBuiltIn: Bool

    public init(
        id: ShellDisplayID,
        persistentIdentifier: String,
        localizedName: String,
        frame: CGRect,
        visibleFrame: CGRect,
        safeAreaInsets: ShellEdgeInsets,
        isBuiltIn: Bool
    ) {
        self.id = id
        self.persistentIdentifier = persistentIdentifier
        self.localizedName = localizedName
        self.frame = frame.standardized
        self.visibleFrame = visibleFrame.standardized
        self.safeAreaInsets = safeAreaInsets
        self.isBuiltIn = isBuiltIn
    }

    /// Safe-area top inset alone is not treated as proof of a camera housing on
    /// an external display.
    public var hasPhysicalNotch: Bool {
        isBuiltIn && safeAreaInsets.top > 0
    }
}

public struct PersistedDisplayBookmark: Codable, Equatable, Sendable {
    public let persistentIdentifier: String
    public let lastKnownName: String

    public init(persistentIdentifier: String, lastKnownName: String) {
        self.persistentIdentifier = persistentIdentifier
        self.lastKnownName = lastKnownName
    }

    public init(display: ShellDisplayDescriptor) {
        self.init(
            persistentIdentifier: display.persistentIdentifier,
            lastKnownName: display.localizedName
        )
    }
}

public enum PersistedDisplaySelection: Codable, Equatable, Sendable {
    case automatic
    case specific(PersistedDisplayBookmark)
}

public enum DisplayResolutionSource: String, Codable, Equatable, Sendable {
    case persistedIdentifier
    case builtInFallback
    case mainDisplayFallback
    case firstAvailableFallback
    case unavailable
}

public struct SelectedDisplayResolution: Equatable, Sendable {
    public let display: ShellDisplayDescriptor?
    public let source: DisplayResolutionSource

    public init(display: ShellDisplayDescriptor?, source: DisplayResolutionSource) {
        self.display = display
        self.source = source
    }

    public var usedFallback: Bool {
        switch source {
        case .builtInFallback, .mainDisplayFallback, .firstAvailableFallback:
            true
        case .persistedIdentifier, .unavailable:
            false
        }
    }
}

public enum SelectedDisplayResolver {
    public static func resolve(
        _ selection: PersistedDisplaySelection,
        among displays: [ShellDisplayDescriptor],
        mainDisplayID: ShellDisplayID?
    ) -> SelectedDisplayResolution {
        guard !displays.isEmpty else {
            return .init(display: nil, source: .unavailable)
        }

        if case let .specific(bookmark) = selection {
            if let exact = displays.first(where: {
                !$0.persistentIdentifier.isEmpty
                    && $0.persistentIdentifier == bookmark.persistentIdentifier
            }) {
                return .init(display: exact, source: .persistedIdentifier)
            }
        }

        let deterministicDisplays = displays.sorted { lhs, rhs in
            if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
            if lhs.frame.minY != rhs.frame.minY { return lhs.frame.minY < rhs.frame.minY }
            return lhs.id.rawValue < rhs.id.rawValue
        }
        if let builtIn = deterministicDisplays.first(where: \.isBuiltIn) {
            return .init(display: builtIn, source: .builtInFallback)
        }

        if let mainDisplayID, let main = displays.first(where: { $0.id == mainDisplayID }) {
            return .init(display: main, source: .mainDisplayFallback)
        }

        let deterministicFirst = deterministicDisplays.first
        return .init(display: deterministicFirst, source: .firstAvailableFallback)
    }
}

// MARK: - Top-center geometry

public struct ShellTextScale: Equatable, Sendable {
    public let value: CGFloat

    public init(_ value: CGFloat) {
        let finiteValue = value.isFinite ? value : 1
        self.value = min(max(finiteValue, 1), 2)
    }
}

public enum ShellPanelPlacement: String, Codable, Equatable, Sendable {
    case physicalNotch
    case externalCapsule
}

public enum ShellGraphiteChromePolicy {
    public static let compactCornerRadius: CGFloat = 1_000
    public static let compactShelfCornerRadius: CGFloat = 17
    public static let expandedCornerRadius: CGFloat = 24
    public static let connMarkOrbitDuration: TimeInterval = 3.2

    public static func cornerRadius(
        for surface: ShellSurfaceState,
        showsCompactShelf: Bool = false
    ) -> CGFloat {
        if surface == .compact {
            return showsCompactShelf ? compactShelfCornerRadius : compactCornerRadius
        }
        return expandedCornerRadius
    }

    public static func connMarkOrbitDegrees(
        elapsed: TimeInterval,
        reduceMotion: Bool
    ) -> Double {
        guard !reduceMotion, elapsed.isFinite else { return 0 }
        let normalized = elapsed.truncatingRemainder(dividingBy: connMarkOrbitDuration)
            / connMarkOrbitDuration
        return normalized * 360
    }
}

public enum SharedDesktopLabsLayoutPolicy {
    public static let preferredViewportHeight: CGFloat = 560
    public static let minimumViewportHeight: CGFloat = 360
    public static let screenClearance: CGFloat = 72

    public static func viewportHeight(availableHeight: CGFloat) -> CGFloat {
        min(
            preferredViewportHeight,
            max(minimumViewportHeight, availableHeight - screenClearance)
        )
    }
}

public enum ShellTranscriptActivityPolicy {
    public static let maximumVisibleEntryCount = 40

    public static func segmentID(
        turnID: String?,
        precedingBoundaryID: String?
    ) -> String {
        func component(_ value: String?) -> String {
            guard let value else { return "n" }
            return "s\(value.utf8.count):\(value)"
        }
        return "\(component(turnID))|\(component(precedingBoundaryID))"
    }

    public static func shouldAutoExpand(
        isLatestActivity: Bool,
        hasFollowingUserFacingText: Bool,
        visualState: AppServerThreadVisualState
    ) -> Bool {
        guard isLatestActivity, !hasFollowingUserFacingText else { return false }
        switch visualState {
        case .running, .waitingForApproval, .needsInput: return true
        case .unreviewedOutcome, .failed, .idle, .notLoaded, .unknown: return false
        }
    }

    public static func expansionState(
        stored: Bool?,
        autoExpand: Bool
    ) -> Bool {
        stored ?? autoExpand
    }

    public static func expansionUpdate(
        stored: Bool?,
        requested: Bool
    ) -> Bool? {
        stored == requested ? nil : requested
    }

    public static func autoScrollKey(
        threadID: String,
        tailID: String?,
        tailRevision: String?
    ) -> String? {
        guard let tailID, let tailRevision else { return nil }
        return [threadID, tailID, tailRevision]
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
    }

    public static func shouldAutoScroll(
        previousKey: String?,
        nextKey: String?
    ) -> Bool {
        nextKey != nil && nextKey != previousKey
    }
}

public struct ShellPanelGeometryConfiguration: Equatable, Sendable {
    public var compactSize: CGSize
    public var compactShelfHeight: CGFloat
    public var expandedWidth: CGFloat
    public var maximumExpandedWidth: CGFloat
    public var maximumExpandedHeight: CGFloat
    public var expandedChromeHeight: CGFloat
    public var expandedBodyVerticalPadding: CGFloat
    public var expandedEmptyBodyHeight: CGFloat
    public var expandedDetailBodyMinimumHeight: CGFloat
    public var integrationRepairHeight: CGFloat
    public var rowHeight: CGFloat
    public var horizontalMargin: CGFloat
    public var externalTopGap: CGFloat
    public var physicalNotchMinimumWidth: CGFloat
    public var maximumVisibleRows: Int

    public init(
        compactSize: CGSize = .init(width: 264, height: 38),
        compactShelfHeight: CGFloat = 36,
        expandedWidth: CGFloat = 600,
        maximumExpandedWidth: CGFloat = 640,
        maximumExpandedHeight: CGFloat = 520,
        expandedChromeHeight: CGFloat = 116,
        expandedBodyVerticalPadding: CGFloat = 24,
        expandedEmptyBodyHeight: CGFloat = 132,
        expandedDetailBodyMinimumHeight: CGFloat = 300,
        integrationRepairHeight: CGFloat = 76,
        rowHeight: CGFloat = 57,
        horizontalMargin: CGFloat = 12,
        externalTopGap: CGFloat = 8,
        physicalNotchMinimumWidth: CGFloat = 220,
        maximumVisibleRows: Int = 5
    ) {
        self.compactSize = .init(
            width: max(1, compactSize.width),
            height: max(1, compactSize.height)
        )
        self.compactShelfHeight = max(1, compactShelfHeight)
        self.expandedWidth = max(1, expandedWidth)
        self.maximumExpandedWidth = max(1, maximumExpandedWidth)
        self.maximumExpandedHeight = max(1, maximumExpandedHeight)
        self.expandedChromeHeight = max(1, expandedChromeHeight)
        self.expandedBodyVerticalPadding = max(0, expandedBodyVerticalPadding)
        self.expandedEmptyBodyHeight = max(1, expandedEmptyBodyHeight)
        self.expandedDetailBodyMinimumHeight = max(1, expandedDetailBodyMinimumHeight)
        self.integrationRepairHeight = max(0, integrationRepairHeight)
        self.rowHeight = max(1, rowHeight)
        self.horizontalMargin = max(0, horizontalMargin)
        self.externalTopGap = max(0, externalTopGap)
        self.physicalNotchMinimumWidth = max(1, physicalNotchMinimumWidth)
        self.maximumVisibleRows = max(1, maximumVisibleRows)
    }
}

public struct ShellPanelGeometry: Equatable, Sendable {
    public let frame: CGRect
    public let placement: ShellPanelPlacement
    public let textScale: ShellTextScale
    public let visibleRowCount: Int

    public init(
        frame: CGRect,
        placement: ShellPanelPlacement,
        textScale: ShellTextScale,
        visibleRowCount: Int
    ) {
        self.frame = frame
        self.placement = placement
        self.textScale = textScale
        self.visibleRowCount = visibleRowCount
    }
}

public struct ShellPanelGeometryPolicy: Equatable, Sendable {
    public var configuration: ShellPanelGeometryConfiguration

    public init(configuration: ShellPanelGeometryConfiguration = .init()) {
        self.configuration = configuration
    }

    public func geometry(
        for display: ShellDisplayDescriptor,
        surface: ShellSurfaceState,
        rowCount: Int,
        showsIntegrationRepair: Bool = false,
        showsSessionDetail: Bool = false,
        showsCompactShelf: Bool = false,
        compactShelfHeight: CGFloat? = nil,
        textScale: ShellTextScale = .init(1)
    ) -> ShellPanelGeometry {
        let displayFrame = display.frame.standardized
        let visibleFrame = display.visibleFrame.standardized.intersection(displayFrame)
        let usableVisibleFrame = visibleFrame.isNull || visibleFrame.isEmpty ? displayFrame : visibleFrame
        let placement: ShellPanelPlacement = display.hasPhysicalNotch
            ? .physicalNotch
            : .externalCapsule
        let scale = textScale.value
        let visibleRows: Int
        switch surface {
        case .compact:
            visibleRows = 0
        case .expanded:
            visibleRows = min(max(0, rowCount), configuration.maximumVisibleRows)
        }

        let desiredWidth: CGFloat
        let desiredHeight: CGFloat
        switch surface {
        case .compact:
            desiredWidth = max(
                configuration.compactSize.width * scale,
                placement == .physicalNotch ? configuration.physicalNotchMinimumWidth : 0
            )
            let barHeight = max(
                configuration.compactSize.height * scale,
                placement == .physicalNotch ? display.safeAreaInsets.top : 0
            )
            desiredHeight = barHeight
                + (showsCompactShelf
                    ? (compactShelfHeight ?? configuration.compactShelfHeight) * scale
                    : 0)
        case .expanded:
            desiredWidth = configuration.expandedWidth * scale
            let rowDrivenBodyHeight = visibleRows == 0
                ? configuration.expandedEmptyBodyHeight
                : configuration.expandedBodyVerticalPadding
                    + CGFloat(visibleRows) * configuration.rowHeight
            let bodyHeight = showsSessionDetail
                ? max(rowDrivenBodyHeight, configuration.expandedDetailBodyMinimumHeight)
                : rowDrivenBodyHeight
            let repairHeight = showsIntegrationRepair
                ? configuration.integrationRepairHeight
                : 0
            desiredHeight = (
                configuration.expandedChromeHeight
                    + bodyHeight
                    + repairHeight
            ) * scale
        }

        let horizontalMargin = min(configuration.horizontalMargin, displayFrame.width / 2)
        let maximumWidth = max(1, displayFrame.width - horizontalMargin * 2)
        let policyMaximumWidth = surface == .expanded
            ? configuration.maximumExpandedWidth
            : maximumWidth
        let width = min(maximumWidth, policyMaximumWidth, max(1, desiredWidth))
        let x = min(
            max(displayFrame.midX - width / 2, displayFrame.minX + horizontalMargin),
            displayFrame.maxX - horizontalMargin - width
        )

        let topAnchor: CGFloat
        let bottomLimit: CGFloat
        switch placement {
        case .physicalNotch:
            topAnchor = displayFrame.maxY
            bottomLimit = max(displayFrame.minY, usableVisibleFrame.minY)
        case .externalCapsule:
            topAnchor = min(displayFrame.maxY, usableVisibleFrame.maxY) - configuration.externalTopGap
            bottomLimit = max(displayFrame.minY, usableVisibleFrame.minY)
        }

        let maximumHeight = max(1, topAnchor - bottomLimit)
        let policyMaximumHeight = surface == .expanded
            ? configuration.maximumExpandedHeight
            : maximumHeight
        let height = min(maximumHeight, policyMaximumHeight, max(1, desiredHeight))
        let frame = CGRect(x: x, y: topAnchor - height, width: width, height: height)

        return .init(
            frame: frame,
            placement: placement,
            textScale: textScale,
            visibleRowCount: visibleRows
        )
    }
}

/// Keeps the compact status cluster inside the usable wing beside a physical
/// camera notch. Presentation supplies pills in urgency order; the compact
/// notch layout retains the three highest-priority states and renders the most
/// urgent one at the outside edge, away from the camera housing.
public enum ShellStatusPillLayoutPolicy {
    public static let physicalNotchCompactLimit = 3

    public static func orderedVisiblePills<Element>(
        _ pills: [Element],
        surface: ShellSurfaceState,
        placement: ShellPanelPlacement
    ) -> [Element] {
        guard surface == .compact, placement == .physicalNotch else {
            return pills
        }
        return Array(pills.prefix(physicalNotchCompactLimit).reversed())
    }
}

// MARK: - Five-row expanded layout

public enum ShellRowPriority: Int, Codable, Comparable, Sendable {
    case attention = 0
    case integrationRepair = 1
    case outcome = 2
    case running = 3
    case noRecentSignals = 4
    case recent = 5

    public static func < (lhs: ShellRowPriority, rhs: ShellRowPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var isPinned: Bool {
        self == .attention || self == .integrationRepair
    }
}

public struct ShellSessionRow: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let priority: ShellRowPriority

    public init(id: String, priority: ShellRowPriority) {
        self.id = id
        self.priority = priority
    }
}

/// Separates pinned attention/repair rows from the ordinary scrolling section.
/// `initialViewportRows` is a deterministic five-row (by default) first paint;
/// consumers must render only the viewport projections at once, while the full
/// arrays remain ordered sources for scrolling and accessibility.
public struct ExpandedShellRowLayout: Equatable, Sendable {
    public let pinnedRows: [ShellSessionRow]
    public let scrollingRows: [ShellSessionRow]
    public let initialViewportRows: [ShellSessionRow]
    public let viewportPinnedRows: [ShellSessionRow]
    public let viewportScrollingRows: [ShellSessionRow]
    public let overflowRows: [ShellSessionRow]
    public let maximumVisibleRows: Int

    public init(rows: [ShellSessionRow], maximumVisibleRows: Int = 5) {
        let capacity = max(1, maximumVisibleRows)
        let sorted = rows.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.priority != rhs.element.priority {
                    return lhs.element.priority < rhs.element.priority
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)

        let pinnedRows = sorted.filter { $0.priority.isPinned }
        let scrollingRows = sorted.filter { !$0.priority.isPinned }
        let initialViewportRows = Array(sorted.prefix(capacity))

        self.pinnedRows = pinnedRows
        self.scrollingRows = scrollingRows
        self.initialViewportRows = initialViewportRows
        self.viewportPinnedRows = initialViewportRows.filter { $0.priority.isPinned }
        self.viewportScrollingRows = initialViewportRows.filter { !$0.priority.isPinned }
        self.overflowRows = Array(sorted.dropFirst(capacity))
        self.maximumVisibleRows = capacity
    }

    public var requiresScrolling: Bool {
        pinnedRows.count + scrollingRows.count > maximumVisibleRows
    }

    /// Uses one scroll region when pinned rows consume the viewport and any
    /// additional row would otherwise be placed in a zero-height section.
    public var requiresUnifiedScrolling: Bool {
        pinnedRows.count >= maximumVisibleRows && requiresScrolling
    }

    public var hiddenRowCount: Int {
        max(0, pinnedRows.count + scrollingRows.count - maximumVisibleRows)
    }
}

// MARK: - Focus policy

public struct ShellApplicationPID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: Int32

    public init?(rawValue: Int32) {
        guard rawValue > 0 else { return nil }
        self.rawValue = rawValue
    }
}

public enum ShellCollapseReason: String, Codable, Equatable, Sendable {
    case userToggle
    case escape
    case outsideClick
    case openCodex
    case pauseOrHide
    case displayReconfiguration
}

public enum ShellCollapseRoutingPolicy {
    public static func lifecycleEvent(for reason: ShellCollapseReason) -> ShellLifecycleEvent {
        reason == .outsideClick ? .outsideClick : .userCollapse
    }
}

public enum ShellFocusEvent: Equatable, Sendable {
    case passiveUpdate
    case passiveAttention
    case displayChanged
    case userExpand(frontmostApplicationPID: ShellApplicationPID?)
    case userCollapse(
        reason: ShellCollapseReason,
        frontmostApplicationPID: ShellApplicationPID?
    )
    case displayReconfiguration(frontmostApplicationPID: ShellApplicationPID?)
}

public enum ShellFocusDecision: Equatable, Sendable {
    case none
    case activateConn
    case restoreApplication(ShellApplicationPID)
}

/// Pure focus bookkeeping. AppKit performs the returned decision; the policy
/// itself cannot activate applications or make windows key.
public struct ShellFocusState: Equatable, Sendable {
    public private(set) var priorApplicationPID: ShellApplicationPID?

    public init(priorApplicationPID: ShellApplicationPID? = nil) {
        self.priorApplicationPID = priorApplicationPID
    }

    @discardableResult
    public mutating func apply(
        _ event: ShellFocusEvent,
        connApplicationPID: ShellApplicationPID?
    ) -> ShellFocusDecision {
        switch event {
        case .passiveUpdate, .passiveAttention, .displayChanged:
            return .none

        case let .userExpand(frontmostApplicationPID):
            if priorApplicationPID == nil,
               let frontmostApplicationPID,
               frontmostApplicationPID != connApplicationPID {
                priorApplicationPID = frontmostApplicationPID
            }
            return .activateConn

        case let .userCollapse(reason, frontmostApplicationPID):
            return collapseDecision(
                reason: reason,
                frontmostApplicationPID: frontmostApplicationPID,
                connApplicationPID: connApplicationPID
            )

        case let .displayReconfiguration(frontmostApplicationPID):
            return collapseDecision(
                reason: .displayReconfiguration,
                frontmostApplicationPID: frontmostApplicationPID,
                connApplicationPID: connApplicationPID
            )
        }
    }

    private mutating func collapseDecision(
        reason: ShellCollapseReason,
        frontmostApplicationPID: ShellApplicationPID?,
        connApplicationPID: ShellApplicationPID?
    ) -> ShellFocusDecision {
        let prior = priorApplicationPID
        priorApplicationPID = nil

        // An outside click already transfers focus to the clicked app. An
        // Open Codex handoff deliberately transfers focus to Codex. Neither
        // path may race that target by restoring an older application. Every
        // other restoration also requires proof that Conn still owns
        // focus; otherwise an intervening user app choice wins.
        guard reason != .outsideClick,
              reason != .openCodex,
              let prior,
              let connApplicationPID,
              frontmostApplicationPID == connApplicationPID
        else {
            return .none
        }
        return .restoreApplication(prior)
    }
}
