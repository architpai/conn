import Darwin
import Foundation
import ConnAppServerAdapter

package struct SharedDesktopLaunchAgentManager: Sendable {
    package typealias LaunchctlRunner = @Sendable ([String]) async -> Bool

    private static let fileName = "com.conn.experimental-shared-desktop.plist"
    private static let maximumConfigurationBytes = 16 * 1_024
    private static let privateFileMode = mode_t(S_IRUSR | S_IWUSR)
    private static let privateDirectoryMode = mode_t(S_IRWXU)

    private let homeDirectory: URL
    private let ownerUID: uid_t
    private let launchctlRunner: LaunchctlRunner

    package init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        ownerUID: uid_t = getuid(),
        launchctlRunner: @escaping LaunchctlRunner = Self.liveLaunchctlRunner
    ) {
        self.homeDirectory = homeDirectory
        self.ownerUID = ownerUID
        self.launchctlRunner = launchctlRunner
    }

    package var launchAgentURL: URL {
        homeDirectory
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(Self.fileName)
    }

    package func install(
        replacing expected: SharedDesktopLaunchConfigurationInspection
    ) async -> Bool {
        guard expected == .missing || expected == .connManaged || expected == .legacyConnManaged,
              let data = Self.configurationData()
        else { return false }

        do {
            let directory = try openLaunchAgentsDirectory(createIfMissing: true)
            defer { close(directory) }
            let current = try readConfiguration(directory: directory)
            switch (expected, current?.inspection) {
            case (.missing, nil), (.connManaged, .connManaged),
                 (.legacyConnManaged, .legacyConnManaged):
                break
            default:
                return false
            }
            try writeAtomically(data, directory: directory, replacing: current)
        } catch {
            return false
        }

        let domain = "gui/\(ownerUID)"
        _ = await launchctlRunner([
            "bootout", "\(domain)/\(SharedDesktopHostInspector.launchAgentLabel)",
        ])
        return await launchctlRunner(["bootstrap", domain, launchAgentURL.path])
    }

    package func remove() async -> Bool {
        do {
            guard let directory = try openLaunchAgentsDirectoryIfPresent() else { return true }
            defer { close(directory) }
            guard let current = try readConfiguration(directory: directory) else { return true }
            guard current.inspection == .connManaged || current.inspection == .legacyConnManaged else {
                return false
            }
            let domain = "gui/\(ownerUID)"
            _ = await launchctlRunner([
                "bootout", "\(domain)/\(SharedDesktopHostInspector.launchAgentLabel)",
            ])
            var pathMetadata = stat()
            guard fstatat(directory, Self.fileName, &pathMetadata, AT_SYMLINK_NOFOLLOW) == 0,
                  pathMetadata.st_dev == current.device,
                  pathMetadata.st_ino == current.inode,
                  pathMetadata.st_nlink == 1
            else { return false }
            guard unlinkat(directory, Self.fileName, 0) == 0 else { return false }
            _ = fsync(directory)
            return true
        } catch {
            return false
        }
    }
}

private extension SharedDesktopLaunchAgentManager {
    struct Configuration {
        let inspection: SharedDesktopLaunchConfigurationInspection
        let device: dev_t
        let inode: ino_t
    }

    enum FileError: Error {
        case notFound
        case invalidDirectory
        case invalidFile
        case oversized
        case fileSystem
    }

    static func configurationData() -> Data? {
        let dictionary: [String: Any] = [
            "Label": SharedDesktopHostInspector.launchAgentLabel,
            "ProgramArguments": [
                "/bin/launchctl",
                "setenv",
                SharedDesktopHostInspector.guiEnvironmentVariable,
                "1",
            ],
            "EnvironmentVariables": [
                "CONN_SHARED_DESKTOP_SETUP_CONTRACT": SharedDesktopHostInspector.setupContractMarker,
            ],
            "RunAtLoad": true,
            "ProcessType": "Background",
            "LimitLoadToSessionType": "Aqua",
        ]
        return try? PropertyListSerialization.data(
            fromPropertyList: dictionary,
            format: .xml,
            options: 0
        )
    }

    static func liveLaunchctlRunner(_ arguments: [String]) async -> Bool {
        do {
            let result = try await BoundedProcessRunner(outputLimit: 1_024).run(
                executableURL: URL(fileURLWithPath: "/bin/launchctl"),
                arguments: arguments,
                timeout: .seconds(3)
            )
            return result.terminationStatus == 0
        } catch {
            return false
        }
    }

    func openLaunchAgentsDirectory(createIfMissing: Bool) throws -> Int32 {
        let home = open(homeDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard home >= 0 else { throw FileError.fileSystem }
        defer { close(home) }
        try validateDirectory(home)

        let library = openat(home, "Library", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard library >= 0 else { throw FileError.fileSystem }
        defer { close(library) }
        try validateDirectory(library)

        var launchAgents = openat(
            library,
            "LaunchAgents",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        if launchAgents < 0, errno == ENOENT, createIfMissing {
            guard mkdirat(library, "LaunchAgents", Self.privateDirectoryMode) == 0 || errno == EEXIST else {
                throw FileError.fileSystem
            }
            launchAgents = openat(
                library,
                "LaunchAgents",
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard launchAgents >= 0 else {
            if errno == ENOENT { throw FileError.notFound }
            throw FileError.fileSystem
        }
        do {
            try validateDirectory(launchAgents)
        } catch {
            close(launchAgents)
            throw error
        }
        return launchAgents
    }

    func openLaunchAgentsDirectoryIfPresent() throws -> Int32? {
        do {
            return try openLaunchAgentsDirectory(createIfMissing: false)
        } catch FileError.notFound {
            return nil
        }
    }

    func validateDirectory(_ descriptor: Int32) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              metadata.st_uid == ownerUID,
              metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
        else { throw FileError.invalidDirectory }
    }

    func readConfiguration(directory: Int32) throws -> Configuration? {
        let descriptor = openat(
            directory,
            Self.fileName,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw FileError.invalidFile
        }
        defer { close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_uid == ownerUID,
              metadata.st_nlink == 1,
              metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
        else { throw FileError.invalidFile }
        guard metadata.st_size >= 0,
              metadata.st_size <= Self.maximumConfigurationBytes
        else { throw FileError.oversized }

        var data = Data(count: Int(metadata.st_size))
        let dataCount = data.count
        var offset = 0
        while offset < dataCount {
            let count = data.withUnsafeMutableBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return 0 }
                return Darwin.read(descriptor, base.advanced(by: offset), dataCount - offset)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw FileError.fileSystem
            }
            if count == 0 { break }
            offset += count
        }
        guard offset == dataCount else { throw FileError.invalidFile }

        var pathMetadata = stat()
        guard fstatat(directory, Self.fileName, &pathMetadata, AT_SYMLINK_NOFOLLOW) == 0,
              pathMetadata.st_dev == metadata.st_dev,
              pathMetadata.st_ino == metadata.st_ino,
              pathMetadata.st_nlink == 1
        else { throw FileError.invalidFile }
        return .init(
            inspection: SharedDesktopHostInspector.inspectLaunchConfigurationData(data),
            device: metadata.st_dev,
            inode: metadata.st_ino
        )
    }

    func writeAtomically(
        _ data: Data,
        directory: Int32,
        replacing current: Configuration?
    ) throws {
        let temporaryName = ".\(Self.fileName).\(UUID().uuidString).tmp"
        let descriptor = openat(
            directory,
            temporaryName,
            O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC,
            Self.privateFileMode
        )
        guard descriptor >= 0 else { throw FileError.fileSystem }
        var shouldClose = true
        var shouldRemove = true
        defer {
            if shouldClose { close(descriptor) }
            if shouldRemove { _ = unlinkat(directory, temporaryName, 0) }
        }

        guard fchmod(descriptor, Self.privateFileMode) == 0 else { throw FileError.fileSystem }
        var offset = 0
        try data.withUnsafeBytes { bytes in
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw FileError.fileSystem
                }
                offset += count
            }
        }
        guard fsync(descriptor) == 0, close(descriptor) == 0 else {
            throw FileError.fileSystem
        }
        shouldClose = false
        var destinationMetadata = stat()
        let destinationStatus = fstatat(
            directory,
            Self.fileName,
            &destinationMetadata,
            AT_SYMLINK_NOFOLLOW
        )
        if let current {
            guard destinationStatus == 0,
                  destinationMetadata.st_dev == current.device,
                  destinationMetadata.st_ino == current.inode,
                  destinationMetadata.st_nlink == 1
            else { throw FileError.invalidFile }
        } else {
            guard destinationStatus != 0, errno == ENOENT else {
                throw FileError.invalidFile
            }
        }
        guard renameat(directory, temporaryName, directory, Self.fileName) == 0 else {
            throw FileError.fileSystem
        }
        shouldRemove = false
        _ = fsync(directory)
    }
}
