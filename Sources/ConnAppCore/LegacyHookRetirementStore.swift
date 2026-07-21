import Darwin
import Foundation

public enum LegacyHookRetirementError: Error, Equatable, Sendable {
    case unsafePath(String)
    case symbolicLinkNotAllowed(String)
    case unexpectedFileType(String)
    case unexpectedOwner(String)
    case insecurePermissions(String)
    case retirementBoundExceeded
    case fileSystem(operation: String, code: Int32)
}

public enum LegacyHookRetirementResult: Equatable, Sendable {
    case alreadyCompleted
    case completed(removedLegacyRoots: Int, legacyStateReappeared: Bool)
}

/// One-shot retirement for the two obsolete hook checkpoint roots.
///
/// The paths are fixed deliberately. This type never scans Application Support,
/// never imports legacy data, and never touches Conn/AppServerDomain.
public struct LegacyHookRetirementStore: Sendable {
    private static let legacyRoots = [
        ["Sidequest", "Bridge", "v1"],
        ["Sidequest", "Domain", "v1"],
    ]
    private static let markerComponents = ["Conn", "LegacyHookRetirement", "v1"]
    private static let markerFileName = "completed"
    private static let privateDirectoryMode: mode_t = 0o700
    private static let privateFileMode: mode_t = 0o600
    private static let maximumRetiredEntries = 4_096
    private static let maximumRetiredBytes: Int64 = 64 * 1_024 * 1_024

    public let applicationSupportDirectory: URL
    public let expectedOwnerUID: uid_t

    public init(
        applicationSupportDirectory: URL,
        expectedOwnerUID: uid_t = getuid()
    ) throws {
        let base = applicationSupportDirectory.standardizedFileURL
        guard base.isFileURL, base.path.hasPrefix("/") else {
            throw LegacyHookRetirementError.unsafePath(applicationSupportDirectory.path)
        }
        self.applicationSupportDirectory = base
        self.expectedOwnerUID = expectedOwnerUID
    }

    public static func userDefault(
        fileManager: FileManager = .default,
        expectedOwnerUID: uid_t = getuid()
    ) throws -> LegacyHookRetirementStore {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw LegacyHookRetirementError.unsafePath(
                "Application Support is unavailable"
            )
        }
        return try LegacyHookRetirementStore(
            applicationSupportDirectory: applicationSupport,
            expectedOwnerUID: expectedOwnerUID
        )
    }

    @discardableResult
    public func retire(fileManager: FileManager = .default) throws -> LegacyHookRetirementResult {
        try validateExistingDirectory(applicationSupportDirectory)
        let marker = markerURL
        let markerAlreadyExisted = try validateMarkerIfPresent(marker)
        let legacyRootExists = Self.legacyRoots.contains { components in
            let target = components.reduce(applicationSupportDirectory) {
                $0.appendingPathComponent($1, isDirectory: true)
            }
            return pathExistsWithoutFollowing(target)
        }
        if markerAlreadyExisted, !legacyRootExists {
            return .alreadyCompleted
        }

        var targets: [URL] = []
        for components in Self.legacyRoots {
            let target = components.reduce(applicationSupportDirectory) {
                $0.appendingPathComponent($1, isDirectory: true)
            }
            guard try validateFixedDirectoryChainIfPresent(components) else { continue }
            try validateRetirementTree(target, fileManager: fileManager)
            targets.append(target)
        }

        var removed = 0
        for target in targets {
            do {
                try fileManager.removeItem(at: target)
                removed += 1
            } catch let error as CocoaError {
                throw LegacyHookRetirementError.fileSystem(
                    operation: "remove-legacy-hook-root",
                    code: Int32(error.errorCode)
                )
            }
        }

        if !markerAlreadyExisted {
            try createMarker(fileManager: fileManager)
        }
        return .completed(
            removedLegacyRoots: removed,
            legacyStateReappeared: markerAlreadyExisted
        )
    }

    private func validateRetirementTree(_ root: URL, fileManager: FileManager) throws {
        var enumerationErrorCode: Int32?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, error in
                enumerationErrorCode = Int32((error as NSError).code)
                return false
            }
        ) else {
            throw LegacyHookRetirementError.fileSystem(
                operation: "enumerate-legacy-hook-root",
                code: errno
            )
        }
        var entryCount = 0
        var totalBytes: Int64 = 0
        while let value = enumerator.nextObject() as? URL {
            entryCount += 1
            guard entryCount <= Self.maximumRetiredEntries else {
                throw LegacyHookRetirementError.retirementBoundExceeded
            }
            var info = stat()
            guard lstat(value.path, &info) == 0 else {
                throw LegacyHookRetirementError.fileSystem(
                    operation: "lstat-legacy-hook-entry",
                    code: errno
                )
            }
            let type = info.st_mode & S_IFMT
            guard type != S_IFLNK else {
                throw LegacyHookRetirementError.symbolicLinkNotAllowed(value.path)
            }
            guard type == S_IFDIR || type == S_IFREG else {
                throw LegacyHookRetirementError.unexpectedFileType(value.path)
            }
            guard info.st_uid == expectedOwnerUID else {
                throw LegacyHookRetirementError.unexpectedOwner(value.path)
            }
            if type == S_IFREG {
                guard info.st_size >= 0,
                      totalBytes <= Self.maximumRetiredBytes - info.st_size else {
                    throw LegacyHookRetirementError.retirementBoundExceeded
                }
                totalBytes += info.st_size
            }
        }
        if let enumerationErrorCode {
            throw LegacyHookRetirementError.fileSystem(
                operation: "enumerate-legacy-hook-entry",
                code: enumerationErrorCode
            )
        }
    }

    public var markerURL: URL {
        Self.markerComponents.reduce(applicationSupportDirectory) {
            $0.appendingPathComponent($1, isDirectory: true)
        }.appendingPathComponent(Self.markerFileName, isDirectory: false)
    }

    private func validateFixedDirectoryChainIfPresent(_ components: [String]) throws -> Bool {
        var candidate = applicationSupportDirectory
        for component in components {
            candidate.appendPathComponent(component, isDirectory: true)
            guard pathExistsWithoutFollowing(candidate) else {
                return false
            }
            try validateExistingDirectory(candidate)
        }
        return true
    }

    private func createMarker(fileManager: FileManager) throws {
        var directory = applicationSupportDirectory
        for component in Self.markerComponents {
            directory.appendPathComponent(component, isDirectory: true)
            if pathExistsWithoutFollowing(directory) {
                try validateExistingDirectory(directory)
            } else {
                do {
                    try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
                    guard chmod(directory.path, Self.privateDirectoryMode) == 0 else {
                        throw LegacyHookRetirementError.fileSystem(
                            operation: "chmod-retirement-directory",
                            code: errno
                        )
                    }
                } catch let error as LegacyHookRetirementError {
                    throw error
                } catch let error as CocoaError {
                    throw LegacyHookRetirementError.fileSystem(
                        operation: "create-retirement-directory",
                        code: Int32(error.errorCode)
                    )
                }
                try validateExistingDirectory(directory, requirePrivatePermissions: true)
            }
        }

        let marker = markerURL
        let descriptor = open(
            marker.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            Self.privateFileMode
        )
        if descriptor < 0 {
            if errno == EEXIST, try validateMarkerIfPresent(marker) { return }
            throw LegacyHookRetirementError.fileSystem(
                operation: "create-retirement-marker",
                code: errno
            )
        }
        let bytes = Array("legacy hook checkpoints discarded\n".utf8)
        let written = bytes.withUnsafeBytes { buffer in
            Darwin.write(descriptor, buffer.baseAddress, buffer.count)
        }
        let savedErrno = errno
        let closeResult = close(descriptor)
        guard written == bytes.count else {
            throw LegacyHookRetirementError.fileSystem(
                operation: "write-retirement-marker",
                code: savedErrno
            )
        }
        guard closeResult == 0 else {
            throw LegacyHookRetirementError.fileSystem(
                operation: "close-retirement-marker",
                code: errno
            )
        }
    }

    private func validateMarkerIfPresent(_ url: URL) throws -> Bool {
        guard pathExistsWithoutFollowing(url) else { return false }
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw LegacyHookRetirementError.fileSystem(
                operation: "lstat-retirement-marker",
                code: errno
            )
        }
        guard (info.st_mode & S_IFMT) != S_IFLNK else {
            throw LegacyHookRetirementError.symbolicLinkNotAllowed(url.path)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
            throw LegacyHookRetirementError.unexpectedFileType(url.path)
        }
        guard info.st_uid == expectedOwnerUID else {
            throw LegacyHookRetirementError.unexpectedOwner(url.path)
        }
        guard (info.st_mode & 0o777) == Self.privateFileMode else {
            throw LegacyHookRetirementError.insecurePermissions(url.path)
        }
        return true
    }

    private func validateExistingDirectory(
        _ url: URL,
        requirePrivatePermissions: Bool = false
    ) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw LegacyHookRetirementError.fileSystem(
                operation: "lstat-retirement-directory",
                code: errno
            )
        }
        guard (info.st_mode & S_IFMT) != S_IFLNK else {
            throw LegacyHookRetirementError.symbolicLinkNotAllowed(url.path)
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw LegacyHookRetirementError.unexpectedFileType(url.path)
        }
        guard info.st_uid == expectedOwnerUID else {
            throw LegacyHookRetirementError.unexpectedOwner(url.path)
        }
        if requirePrivatePermissions,
           (info.st_mode & 0o777) != Self.privateDirectoryMode {
            throw LegacyHookRetirementError.insecurePermissions(url.path)
        }
    }

    private func pathExistsWithoutFollowing(_ url: URL) -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        return errno != ENOENT
    }
}
