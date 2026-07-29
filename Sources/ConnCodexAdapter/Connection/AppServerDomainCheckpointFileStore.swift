import Darwin
import Foundation
import ConnDomain

public enum AppServerDomainCheckpointFileStoreError: Error, Equatable, Sendable {
    case invalidLimit
    case unsafePath(String)
    case symbolicLinkNotAllowed(String)
    case unexpectedFileType(String)
    case unexpectedOwner(String)
    case insecurePermissions(String)
    case invalidCheckpoint
    case checkpointTooLarge(maximumBytes: Int)
    case generationOverflow
    case fileSystem(operation: String, code: Int32)
}

/// A bounded, current-user-only two-slot store for the App Server projection
/// cache. Its distinct root and checkpoint discriminator deliberately prevent
/// legacy hook checkpoints from being restored as App Server state.
public struct AppServerDomainCheckpointFileStore: Sendable {
    private enum Slot: String, CaseIterable, Sendable {
        case a = "checkpoint-a.json"
        case b = "checkpoint-b.json"

        var alternate: Slot { self == .a ? .b : .a }
    }

    private struct Wrapper: Codable, Sendable {
        static let currentFormatVersion = 1

        let formatVersion: Int
        let generation: UInt64
        let checkpoint: AppServerProjectionCheckpoint
    }

    private struct Candidate: Sendable {
        let slot: Slot
        let wrapper: Wrapper
    }

    private static let privateDirectoryMode: mode_t = 0o700
    private static let privateFileMode: mode_t = 0o600
    private static let lockFileName = "checkpoint.lock"
    private static let rootComponents = ["Conn", "AppServerDomain", "v1"]

    public let applicationSupportDirectory: URL
    public let rootDirectory: URL
    public let maximumCheckpointBytes: Int
    public let expectedOwnerUID: uid_t
    public let projectionConfiguration: AppServerProjectionConfiguration

    public init(
        applicationSupportDirectory: URL,
        maximumCheckpointBytes: Int = 1 * 1_024 * 1_024,
        expectedOwnerUID: uid_t = getuid(),
        projectionConfiguration: AppServerProjectionConfiguration = .init()
    ) throws {
        guard maximumCheckpointBytes > 0 else {
            throw AppServerDomainCheckpointFileStoreError.invalidLimit
        }

        let base = applicationSupportDirectory.standardizedFileURL
        guard base.isFileURL, base.path.hasPrefix("/") else {
            throw AppServerDomainCheckpointFileStoreError.unsafePath(
                applicationSupportDirectory.path
            )
        }
        let root = Self.rootComponents.reduce(base) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }.standardizedFileURL
        guard root.path.hasPrefix(base.path + "/") else {
            throw AppServerDomainCheckpointFileStoreError.unsafePath(root.path)
        }

        self.applicationSupportDirectory = base
        self.rootDirectory = root
        self.maximumCheckpointBytes = maximumCheckpointBytes
        self.expectedOwnerUID = expectedOwnerUID
        self.projectionConfiguration = projectionConfiguration

        let descriptor = try openRoot(createAndRepair: true)
        do {
            try prepareLockFile(rootDescriptor: descriptor)
        } catch {
            close(descriptor)
            throw error
        }
        guard close(descriptor) == 0 else {
            throw AppServerDomainCheckpointFileStoreError.fileSystem(
                operation: "close-app-server-domain-directory",
                code: errno
            )
        }
    }

    public static func userDefault(
        maximumCheckpointBytes: Int = 1 * 1_024 * 1_024,
        fileManager: FileManager = .default,
        expectedOwnerUID: uid_t = getuid(),
        projectionConfiguration: AppServerProjectionConfiguration = .init()
    ) throws -> AppServerDomainCheckpointFileStore {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw AppServerDomainCheckpointFileStoreError.unsafePath(
                "Application Support is unavailable"
            )
        }
        return try AppServerDomainCheckpointFileStore(
            applicationSupportDirectory: applicationSupport,
            maximumCheckpointBytes: maximumCheckpointBytes,
            expectedOwnerUID: expectedOwnerUID,
            projectionConfiguration: projectionConfiguration
        )
    }

    /// Moves the disposable cache out of the active path. If quarantine cannot
    /// be created, removing this exact cache root is safe because App Server is
    /// authoritative and no preferences or conversation content live here.
    @discardableResult
    public static func quarantineUserDefaultCache(
        fileManager: FileManager = .default
    ) -> Bool {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return false }
        let root = rootComponents.reduce(applicationSupport.standardizedFileURL) {
            $0.appendingPathComponent($1, isDirectory: true)
        }
        guard fileManager.fileExists(atPath: root.path) else { return true }
        let quarantine = root.deletingLastPathComponent().appendingPathComponent(
            "v1-quarantine-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.moveItem(at: root, to: quarantine)
            return true
        } catch {
            do {
                try fileManager.removeItem(at: root)
                return true
            } catch {
                return false
            }
        }
    }

    /// Loads the checkpoint from the highest valid generation. Malformed,
    /// oversized, legacy, and unsupported slots are ignored independently so
    /// the other crash-consistent slot can still be recovered.
    public func load() throws -> AppServerProjectionCheckpoint? {
        try loadCandidate()?.wrapper.checkpoint
    }

    /// Reports the generation associated with `load()` without exposing the
    /// private on-disk wrapper format.
    public func loadGeneration() throws -> UInt64? {
        try loadCandidate()?.wrapper.generation
    }

    /// Atomically commits a new generation and returns its generation number.
    @discardableResult
    public func save(_ checkpoint: AppServerProjectionCheckpoint) throws -> UInt64 {
        guard isValid(checkpoint) else {
            throw AppServerDomainCheckpointFileStoreError.invalidCheckpoint
        }

        let descriptor = try openRoot(createAndRepair: false)
        defer { close(descriptor) }

        return try withExclusiveLock(rootDescriptor: descriptor) {
            let current = try validCandidates(rootDescriptor: descriptor)
                .max(by: candidateComesBefore)
            guard current?.wrapper.generation != UInt64.max else {
                throw AppServerDomainCheckpointFileStoreError.generationOverflow
            }

            let generation = (current?.wrapper.generation ?? 0) + 1
            let destination = current?.slot.alternate ?? .a
            var wrapper = Wrapper(
                formatVersion: Wrapper.currentFormatVersion,
                generation: generation,
                checkpoint: checkpoint
            )
            var data = try Self.encoder().encode(wrapper)
            while data.count > maximumCheckpointBytes {
                guard let trimmed = byteTrimmed(wrapper.checkpoint) else {
                    throw AppServerDomainCheckpointFileStoreError.checkpointTooLarge(
                        maximumBytes: maximumCheckpointBytes
                    )
                }
                wrapper = Wrapper(
                    formatVersion: Wrapper.currentFormatVersion,
                    generation: generation,
                    checkpoint: trimmed
                )
                data = try Self.encoder().encode(wrapper)
            }

            try writeAtomically(
                data,
                destination: destination,
                rootDescriptor: descriptor
            )
            return generation
        }
    }

    /// Removes the oldest durable detail first while retaining recent thread
    /// rows. Durable items contain metadata only, but count-bounded state can
    /// still exceed the byte envelope at the configured caps.
    private func byteTrimmed(
        _ checkpoint: AppServerProjectionCheckpoint
    ) -> AppServerProjectionCheckpoint? {
        var threads = checkpoint.threads
        if let threadIndex = threads.indices.reversed().first(where: {
            !threads[$0].turns.isEmpty
        }) {
            let thread = threads[threadIndex]
            threads[threadIndex] = AppServerCachedThread(
                id: thread.id,
                sessionID: thread.sessionID,
                title: thread.title,
                workingDirectoryName: thread.workingDirectoryName,
                workingDirectoryPath: thread.workingDirectoryPath,
                projectRootPath: thread.projectRootPath,
                source: thread.source,
                parentThreadID: thread.parentThreadID,
                forkedFromThreadID: thread.forkedFromThreadID,
                status: thread.status,
                createdAt: thread.createdAt,
                updatedAt: thread.updatedAt,
                lastObservedAt: thread.lastObservedAt,
                turns: Array(thread.turns.dropLast())
            )
        } else if !threads.isEmpty {
            threads.removeLast()
        } else {
            return nil
        }
        return AppServerProjectionCheckpoint(
            checkpointKind: checkpoint.checkpointKind,
            schemaVersion: checkpoint.schemaVersion,
            savedAt: checkpoint.savedAt,
            connectionSource: checkpoint.connectionSource,
            threads: threads
        )
    }

    private func loadCandidate() throws -> Candidate? {
        let descriptor = try openRoot(createAndRepair: false)
        defer { close(descriptor) }
        return try withExclusiveLock(rootDescriptor: descriptor) {
            try validCandidates(rootDescriptor: descriptor)
                .max(by: candidateComesBefore)
        }
    }

    private func prepareLockFile(rootDescriptor: Int32) throws {
        let descriptor = openat(
            rootDescriptor,
            Self.lockFileName,
            O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
            Self.privateFileMode
        )
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw AppServerDomainCheckpointFileStoreError.symbolicLinkNotAllowed(
                    rootDirectory.appendingPathComponent(Self.lockFileName).path
                )
            }
            throw AppServerDomainCheckpointFileStoreError.fileSystem(
                operation: "open-app-server-checkpoint-lock",
                code: errno
            )
        }
        defer { close(descriptor) }

        try validateLockFile(
            descriptor,
            displayPath: rootDirectory.appendingPathComponent(Self.lockFileName).path,
            requirePrivatePermissions: false
        )
        guard fchmod(descriptor, Self.privateFileMode) == 0 else {
            throw AppServerDomainCheckpointFileStoreError.fileSystem(
                operation: "chmod-app-server-checkpoint-lock",
                code: errno
            )
        }
        guard fsync(descriptor) == 0 else {
            throw AppServerDomainCheckpointFileStoreError.fileSystem(
                operation: "fsync-app-server-checkpoint-lock",
                code: errno
            )
        }
        guard fsync(rootDescriptor) == 0 else {
            throw AppServerDomainCheckpointFileStoreError.fileSystem(
                operation: "fsync-app-server-domain-directory",
                code: errno
            )
        }
    }

    private func withExclusiveLock<T>(
        rootDescriptor: Int32,
        _ body: () throws -> T
    ) throws -> T {
        let descriptor = openat(
            rootDescriptor,
            Self.lockFileName,
            O_RDWR | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw AppServerDomainCheckpointFileStoreError.symbolicLinkNotAllowed(
                    rootDirectory.appendingPathComponent(Self.lockFileName).path
                )
            }
            throw AppServerDomainCheckpointFileStoreError.fileSystem(
                operation: "open-app-server-checkpoint-lock",
                code: errno
            )
        }
        defer { close(descriptor) }

        try validateLockFile(
            descriptor,
            displayPath: rootDirectory.appendingPathComponent(Self.lockFileName).path,
            requirePrivatePermissions: true
        )
        while flock(descriptor, LOCK_EX) != 0 {
            let code = errno
            if code == EINTR { continue }
            throw AppServerDomainCheckpointFileStoreError.fileSystem(
                operation: "lock-app-server-checkpoint-store",
                code: code
            )
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func validCandidates(rootDescriptor: Int32) throws -> [Candidate] {
        var candidates: [Candidate] = []
        for slot in Slot.allCases {
            guard let data = try readSlot(slot, rootDescriptor: rootDescriptor) else {
                continue
            }
            guard let wrapper = try? Self.decoder().decode(Wrapper.self, from: data),
                  wrapper.formatVersion == Wrapper.currentFormatVersion,
                  wrapper.generation > 0,
                  isValid(wrapper.checkpoint)
            else {
                continue
            }
            candidates.append(Candidate(slot: slot, wrapper: wrapper))
        }
        return candidates
    }

    private func isValid(_ checkpoint: AppServerProjectionCheckpoint) -> Bool {
        guard checkpoint.checkpointKind == .appServerProjection,
              checkpoint.schemaVersion == AppServerProjectionCheckpoint.currentSchemaVersion,
              checkpoint.savedAt.timeIntervalSince1970.isFinite,
              checkpoint.threads.count <= projectionConfiguration.maximumThreads,
              Set(checkpoint.threads.map(\.id)).count == checkpoint.threads.count
        else { return false }

        return checkpoint.threads.allSatisfy { thread in
            isValid(thread.id.rawValue)
                && (thread.sessionID.map { isValid($0.rawValue) } ?? true)
                && (thread.parentThreadID.map { isValid($0.rawValue) } ?? true)
                && (thread.forkedFromThreadID.map { isValid($0.rawValue) } ?? true)
                && isValid(thread.title)
                && isValid(thread.workingDirectoryName)
                && (thread.createdAt?.timeIntervalSince1970.isFinite ?? true)
                && thread.updatedAt.timeIntervalSince1970.isFinite
                && thread.lastObservedAt.timeIntervalSince1970.isFinite
                && thread.turns.count <= projectionConfiguration.maximumTurnsPerThread
                && Set(thread.turns.map(\.id)).count == thread.turns.count
                && thread.turns.allSatisfy { turn in
                    isValid(turn.id.rawValue)
                        && (turn.startedAt?.timeIntervalSince1970.isFinite ?? true)
                        && (turn.completedAt?.timeIntervalSince1970.isFinite ?? true)
                        && turn.items.count <= projectionConfiguration.maximumItemsPerTurn
                        && Set(turn.items.map(\.id)).count == turn.items.count
                        && turn.items.allSatisfy { item in
                            isValid(item.id.rawValue)
                                && (item.startedAt?.timeIntervalSince1970.isFinite ?? true)
                                && (item.completedAt?.timeIntervalSince1970.isFinite ?? true)
                        }
                }
        }
    }

    private func isValid(_ value: String?) -> Bool {
        guard let value else { return true }
        return isValid(value)
    }

    private func isValid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= projectionConfiguration.maximumStringBytes
    }

    private func candidateComesBefore(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.wrapper.generation != rhs.wrapper.generation {
            return lhs.wrapper.generation < rhs.wrapper.generation
        }
        return lhs.slot.rawValue < rhs.slot.rawValue
    }

    private func readSlot(_ slot: Slot, rootDescriptor: Int32) throws -> Data? {
        let descriptor = openat(
            rootDescriptor,
            slot.rawValue,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP {
                throw AppServerDomainCheckpointFileStoreError.symbolicLinkNotAllowed(
                    rootDirectory.appendingPathComponent(slot.rawValue).path
                )
            }
            throw AppServerDomainCheckpointFileStoreError.fileSystem(
                operation: "open-app-server-checkpoint",
                code: errno
            )
        }
        defer { close(descriptor) }

        let displayPath = rootDirectory.appendingPathComponent(slot.rawValue).path
        let size = try validatePrivateFile(descriptor, displayPath: displayPath)
        guard size <= maximumCheckpointBytes else {
            return nil
        }

        var bytes = [UInt8](repeating: 0, count: size)
        var offset = 0
        while offset < size {
            let count = bytes.withUnsafeMutableBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                return Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    size - offset
                )
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw AppServerDomainCheckpointFileStoreError.fileSystem(
                    operation: "read-app-server-checkpoint",
                    code: errno
                )
            }
            if count == 0 { break }
            offset += count
        }
        guard offset == size else { return nil }
        return Data(bytes)
    }

    private func writeAtomically(
        _ data: Data,
        destination: Slot,
        rootDescriptor: Int32
    ) throws {
        let temporaryName = ".\(destination.rawValue).tmp"
        try removeStaleTemporary(
            named: temporaryName,
            rootDescriptor: rootDescriptor
        )
        let descriptor = openat(
            rootDescriptor,
            temporaryName,
            O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC,
            Self.privateFileMode
        )
        guard descriptor >= 0 else {
            throw AppServerDomainCheckpointFileStoreError.fileSystem(
                operation: "create-app-server-checkpoint-temp",
                code: errno
            )
        }

        var shouldCloseDescriptor = true
        var shouldRemoveTemporary = true
        defer {
            if shouldCloseDescriptor { close(descriptor) }
            if shouldRemoveTemporary {
                _ = unlinkat(rootDescriptor, temporaryName, 0)
            }
        }

        guard fchmod(descriptor, Self.privateFileMode) == 0 else {
            throw AppServerDomainCheckpointFileStoreError.fileSystem(
                operation: "chmod-app-server-checkpoint-temp",
                code: errno
            )
        }
        try writeAll(data, descriptor: descriptor)
        guard fsync(descriptor) == 0 else {
            throw AppServerDomainCheckpointFileStoreError.fileSystem(
                operation: "fsync-app-server-checkpoint-temp",
                code: errno
            )
        }
        guard close(descriptor) == 0 else {
            throw AppServerDomainCheckpointFileStoreError.fileSystem(
                operation: "close-app-server-checkpoint-temp",
                code: errno
            )
        }
        shouldCloseDescriptor = false

        guard renameat(
            rootDescriptor,
            temporaryName,
            rootDescriptor,
            destination.rawValue
        ) == 0 else {
            throw AppServerDomainCheckpointFileStoreError.fileSystem(
                operation: "rename-app-server-checkpoint",
                code: errno
            )
        }
        shouldRemoveTemporary = false
        // The new slot is already published and its contents were fsynced. A
        // directory-sync error cannot be reported as an ordinary save failure:
        // callers would roll back memory while the new generation remains
        // observable. Treat publication as committed at this point.
        _ = fsync(rootDescriptor)
    }

    private func removeStaleTemporary(
        named name: String,
        rootDescriptor: Int32
    ) throws {
        let descriptor = openat(
            rootDescriptor,
            name,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return }
            if errno == ELOOP {
                throw AppServerDomainCheckpointFileStoreError.symbolicLinkNotAllowed(
                    rootDirectory.appendingPathComponent(name).path
                )
            }
            throw AppServerDomainCheckpointFileStoreError.fileSystem(
                operation: "open-stale-app-server-checkpoint-temp",
                code: errno
            )
        }
        defer { close(descriptor) }

        _ = try validatePrivateFile(
            descriptor,
            displayPath: rootDirectory.appendingPathComponent(name).path
        )
        guard unlinkat(rootDescriptor, name, 0) == 0 else {
            throw AppServerDomainCheckpointFileStoreError.fileSystem(
                operation: "unlink-stale-app-server-checkpoint-temp",
                code: errno
            )
        }
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
        var failure: AppServerDomainCheckpointFileStoreError?
        data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count < 0 {
                    if errno == EINTR { continue }
                    failure = .fileSystem(
                        operation: "write-app-server-checkpoint",
                        code: errno
                    )
                    return
                }
                if count == 0 {
                    failure = .fileSystem(
                        operation: "write-app-server-checkpoint",
                        code: EIO
                    )
                    return
                }
                remaining -= count
                pointer = pointer.advanced(by: count)
            }
        }
        if let failure { throw failure }
    }

    private func openRoot(createAndRepair: Bool) throws -> Int32 {
        var current = open(
            applicationSupportDirectory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard current >= 0 else {
            if errno == ELOOP {
                throw AppServerDomainCheckpointFileStoreError.symbolicLinkNotAllowed(
                    applicationSupportDirectory.path
                )
            }
            throw AppServerDomainCheckpointFileStoreError.fileSystem(
                operation: "open-application-support",
                code: errno
            )
        }

        do {
            try validateDirectory(
                current,
                displayPath: applicationSupportDirectory.path,
                requirePrivatePermissions: false
            )
            var displayPath = applicationSupportDirectory.path
            for component in Self.rootComponents {
                displayPath += "/" + component
                if createAndRepair,
                   mkdirat(current, component, Self.privateDirectoryMode) != 0,
                   errno != EEXIST {
                    throw AppServerDomainCheckpointFileStoreError.fileSystem(
                        operation: "mkdir-app-server-domain-directory",
                        code: errno
                    )
                }

                let child = openat(
                    current,
                    component,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard child >= 0 else {
                    if errno == ELOOP {
                        throw AppServerDomainCheckpointFileStoreError
                            .symbolicLinkNotAllowed(displayPath)
                    }
                    throw AppServerDomainCheckpointFileStoreError.fileSystem(
                        operation: "open-app-server-domain-directory",
                        code: errno
                    )
                }
                do {
                    try validateDirectory(
                        child,
                        displayPath: displayPath,
                        requirePrivatePermissions: !createAndRepair
                    )
                    if createAndRepair {
                        guard fchmod(child, Self.privateDirectoryMode) == 0 else {
                            throw AppServerDomainCheckpointFileStoreError.fileSystem(
                                operation: "chmod-app-server-domain-directory",
                                code: errno
                            )
                        }
                    }
                } catch {
                    close(child)
                    throw error
                }
                close(current)
                current = child
            }
            return current
        } catch {
            close(current)
            throw error
        }
    }

    private func validateDirectory(
        _ descriptor: Int32,
        displayPath: String,
        requirePrivatePermissions: Bool
    ) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw AppServerDomainCheckpointFileStoreError.fileSystem(
                operation: "fstat-app-server-domain-directory",
                code: errno
            )
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw AppServerDomainCheckpointFileStoreError.unexpectedFileType(displayPath)
        }
        guard info.st_uid == expectedOwnerUID else {
            throw AppServerDomainCheckpointFileStoreError.unexpectedOwner(displayPath)
        }
        if requirePrivatePermissions,
           (info.st_mode & 0o777) != Self.privateDirectoryMode {
            throw AppServerDomainCheckpointFileStoreError.insecurePermissions(displayPath)
        }
    }

    private func validateLockFile(
        _ descriptor: Int32,
        displayPath: String,
        requirePrivatePermissions: Bool
    ) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw AppServerDomainCheckpointFileStoreError.fileSystem(
                operation: "fstat-app-server-checkpoint-lock",
                code: errno
            )
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
            throw AppServerDomainCheckpointFileStoreError.unexpectedFileType(displayPath)
        }
        guard info.st_uid == expectedOwnerUID else {
            throw AppServerDomainCheckpointFileStoreError.unexpectedOwner(displayPath)
        }
        if requirePrivatePermissions,
           (info.st_mode & 0o777) != Self.privateFileMode {
            throw AppServerDomainCheckpointFileStoreError.insecurePermissions(displayPath)
        }
    }

    private func validatePrivateFile(_ descriptor: Int32, displayPath: String) throws -> Int {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw AppServerDomainCheckpointFileStoreError.fileSystem(
                operation: "fstat-app-server-checkpoint",
                code: errno
            )
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
            throw AppServerDomainCheckpointFileStoreError.unexpectedFileType(displayPath)
        }
        guard info.st_uid == expectedOwnerUID else {
            throw AppServerDomainCheckpointFileStoreError.unexpectedOwner(displayPath)
        }
        guard (info.st_mode & 0o777) == Self.privateFileMode else {
            throw AppServerDomainCheckpointFileStoreError.insecurePermissions(displayPath)
        }
        guard info.st_size >= 0, info.st_size <= Int64(Int.max) else {
            throw AppServerDomainCheckpointFileStoreError.checkpointTooLarge(
                maximumBytes: maximumCheckpointBytes
            )
        }
        return Int(info.st_size)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
