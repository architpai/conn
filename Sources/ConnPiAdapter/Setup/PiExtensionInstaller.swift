import CryptoKit
import Darwin
import Foundation

public enum PiExtensionResource {
    public static var bundledSourceURL: URL {
        let packagedURL = Bundle.main.resourceURL?
            .appendingPathComponent(
                "Conn_ConnPiAdapter.bundle",
                isDirectory: true
            )
            .appendingPathComponent("index.ts")
        if let packagedURL,
           FileManager.default.isReadableFile(atPath: packagedURL.path) {
            return packagedURL
        }
        guard let url = Bundle.module.url(
            forResource: "index",
            withExtension: "ts",
            subdirectory: "PiExtension"
        ) ?? Bundle.module.url(forResource: "index", withExtension: "ts") else {
            preconditionFailure("Conn's bundled Pi extension resource is missing")
        }
        return url
    }
}

public struct PiExtensionBehaviorConfiguration: Codable, Equatable, Sendable {
    public let questionsEnabled: Bool
    public let approvalsEnabled: Bool

    public init(
        questionsEnabled: Bool = false,
        approvalsEnabled: Bool = false
    ) {
        self.questionsEnabled = questionsEnabled
        self.approvalsEnabled = approvalsEnabled
    }
}

public enum PiExtensionInstallStatus: Equatable, Sendable {
    case absent
    case installed(
        version: String,
        configuration: PiExtensionBehaviorConfiguration
    )
    case foreign
}

public enum PiExtensionInstallOutcome: Equatable, Sendable {
    case installed
    case updated
}

public enum PiExtensionUninstallOutcome: Equatable, Sendable {
    case alreadyAbsent
    case movedToTrash
}

public enum PiExtensionInstallerError: Error, Equatable, Sendable {
    case invalidAgentDirectory
    case unsafeExtensionsDirectory
    case foreignTarget
    case resourceUnavailable
    case verificationFailed
    case transactionFailed
}

public struct PiExtensionInstaller: Sendable {
    public static let owner = "dev.conn.pi-extension"
    public static let extensionProtocolVersion = 1

    public let agentDirectory: URL
    public let sourceURL: URL
    public let releaseVersion: String
    public let trashDirectory: URL

    private var extensionsDirectory: URL {
        agentDirectory.appendingPathComponent("extensions", isDirectory: true)
    }

    private var targetDirectory: URL {
        extensionsDirectory.appendingPathComponent("conn", isDirectory: true)
    }

    public init(
        agentDirectory: URL,
        sourceURL: URL,
        releaseVersion: String,
        trashDirectory: URL
    ) {
        self.agentDirectory = agentDirectory.standardizedFileURL
        self.sourceURL = sourceURL.standardizedFileURL
        self.releaseVersion = releaseVersion
        self.trashDirectory = trashDirectory.standardizedFileURL
    }

    public static func userDefault(
        releaseVersion: String = "0.2.1"
    ) -> PiExtensionInstaller {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return .init(
            agentDirectory: home.appendingPathComponent(".pi/agent", isDirectory: true),
            sourceURL: PiExtensionResource.bundledSourceURL,
            releaseVersion: releaseVersion,
            trashDirectory: home.appendingPathComponent(".Trash", isDirectory: true)
        )
    }

    public func status() -> PiExtensionInstallStatus {
        guard isAbsoluteFileURL(agentDirectory),
              isRegularFile(sourceURL) else {
            return .foreign
        }
        switch fileKind(targetDirectory) {
        case .absent:
            return .absent
        case .directory:
            break
        case .other:
            return .foreign
        }
        let manifestURL = targetDirectory.appendingPathComponent(".conn-install.json")
        let configurationURL = targetDirectory.appendingPathComponent("behavior.json")
        let installedSourceURL = targetDirectory.appendingPathComponent("index.ts")
        guard isRegularFileWithoutSymlink(manifestURL),
              isRegularFileWithoutSymlink(configurationURL),
              isRegularFileWithoutSymlink(installedSourceURL),
              let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(OwnershipManifest.self, from: manifestData),
              manifest.owner == Self.owner,
              manifest.protocolVersion == Self.extensionProtocolVersion,
              let installedData = try? Data(contentsOf: installedSourceURL),
              manifest.contentSHA256 == sha256(installedData),
              let configurationData = try? Data(contentsOf: configurationURL),
              manifest.configurationSHA256 == sha256(configurationData),
              let configuration = try? JSONDecoder().decode(
                  PiExtensionBehaviorConfiguration.self,
                  from: configurationData
              )
        else {
            return .foreign
        }
        return .installed(
            version: manifest.releaseVersion,
            configuration: configuration
        )
    }

    public func install(
        configuration: PiExtensionBehaviorConfiguration
    ) throws(PiExtensionInstallerError) -> PiExtensionInstallOutcome {
        let priorStatus = status()
        guard priorStatus != .foreign else { throw .foreignTarget }
        try validateInstallAncestors()
        guard let sourceData = try? Data(contentsOf: sourceURL), !sourceData.isEmpty else {
            throw .resourceUnavailable
        }
        guard let configurationData = try? encodedJSON(configuration) else {
            throw .transactionFailed
        }
        let createsExtensionsDirectory = fileKind(extensionsDirectory) == .absent
        let preservesCreatedDirectoryOwnership =
            ownershipManifest()?.createdExtensionsDirectory ?? false

        do {
            if fileKind(extensionsDirectory) == .absent {
                try FileManager.default.createDirectory(
                    at: extensionsDirectory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            let transactionID = UUID()
            let staging = extensionsDirectory.appendingPathComponent(
                ".conn-install-\(transactionID.uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: staging,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            do {
                try write(
                    sourceData,
                    to: staging.appendingPathComponent("index.ts"),
                    permissions: 0o600
                )
                try write(
                    configurationData,
                    to: staging.appendingPathComponent("behavior.json"),
                    permissions: 0o600
                )
                try writeJSON(
                    OwnershipManifest(
                        owner: Self.owner,
                        protocolVersion: Self.extensionProtocolVersion,
                        releaseVersion: releaseVersion,
                        contentSHA256: sha256(sourceData),
                        configurationSHA256: sha256(configurationData),
                        transactionID: transactionID,
                        createdExtensionsDirectory:
                            createsExtensionsDirectory
                                || preservesCreatedDirectoryOwnership
                    ),
                    to: staging.appendingPathComponent(".conn-install.json")
                )
            } catch {
                try? FileManager.default.removeItem(at: staging)
                throw error
            }

            if priorStatus == .absent {
                try FileManager.default.moveItem(at: staging, to: targetDirectory)
            } else {
                let backup = extensionsDirectory.appendingPathComponent(
                    ".conn-previous-\(transactionID.uuidString)",
                    isDirectory: true
                )
                try FileManager.default.moveItem(at: targetDirectory, to: backup)
                do {
                    try FileManager.default.moveItem(at: staging, to: targetDirectory)
                    guard case .installed = status() else {
                        throw PiExtensionInstallerError.verificationFailed
                    }
                    try FileManager.default.removeItem(at: backup)
                } catch {
                    try? FileManager.default.removeItem(at: targetDirectory)
                    try? FileManager.default.moveItem(at: backup, to: targetDirectory)
                    try? FileManager.default.removeItem(at: staging)
                    throw error
                }
            }
            guard status() == .installed(
                version: releaseVersion,
                configuration: configuration
            ) else {
                throw PiExtensionInstallerError.verificationFailed
            }
            return priorStatus == .absent ? .installed : .updated
        } catch let error as PiExtensionInstallerError {
            throw error
        } catch {
            throw .transactionFailed
        }
    }

    public func uninstall() throws(PiExtensionInstallerError) -> PiExtensionUninstallOutcome {
        switch status() {
        case .absent:
            return .alreadyAbsent
        case .foreign:
            throw .foreignTarget
        case .installed:
            break
        }
        let removeExtensionsDirectory =
            ownershipManifest()?.createdExtensionsDirectory == true
        do {
            if fileKind(trashDirectory) == .absent {
                try FileManager.default.createDirectory(
                    at: trashDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            guard fileKind(trashDirectory) == .directory else {
                throw PiExtensionInstallerError.transactionFailed
            }
            let destination = trashDirectory.appendingPathComponent(
                "conn-pi-extension-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.moveItem(at: targetDirectory, to: destination)
            guard status() == .absent else {
                try? FileManager.default.moveItem(at: destination, to: targetDirectory)
                throw PiExtensionInstallerError.verificationFailed
            }
            if removeExtensionsDirectory,
               (try? FileManager.default.contentsOfDirectory(
                   at: extensionsDirectory,
                   includingPropertiesForKeys: nil
               ).isEmpty) == true {
                try? FileManager.default.removeItem(at: extensionsDirectory)
            }
            return .movedToTrash
        } catch let error as PiExtensionInstallerError {
            throw error
        } catch {
            throw .transactionFailed
        }
    }

    private func validateInstallAncestors() throws(PiExtensionInstallerError) {
        guard isAbsoluteFileURL(agentDirectory),
              fileKind(agentDirectory) == .directory,
              safeInstallerDirectory(agentDirectory) else {
            throw .invalidAgentDirectory
        }
        let kind = fileKind(extensionsDirectory)
        guard kind == .absent
                || (kind == .directory
                    && safeInstallerDirectory(extensionsDirectory)) else {
            throw .unsafeExtensionsDirectory
        }
    }

    private func ownershipManifest() -> OwnershipManifest? {
        let url = targetDirectory.appendingPathComponent(".conn-install.json")
        guard isRegularFileWithoutSymlink(url),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(
                  OwnershipManifest.self,
                  from: data
              ),
              manifest.owner == Self.owner else {
            return nil
        }
        return manifest
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try write(encodedJSON(value), to: url, permissions: 0o600)
    }

    private func encodedJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    private func write(_ data: Data, to url: URL, permissions: Int) throws {
        try data.write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }
}

private struct OwnershipManifest: Codable {
    let owner: String
    let protocolVersion: Int
    let releaseVersion: String
    let contentSHA256: String
    let configurationSHA256: String
    let transactionID: UUID
    let createdExtensionsDirectory: Bool
}

private enum PiFileKind {
    case absent
    case directory
    case other
}

private func fileKind(_ url: URL) -> PiFileKind {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
        return errno == ENOENT ? .absent : .other
    }
    return metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        ? .directory
        : .other
}

private func isRegularFileWithoutSymlink(_ url: URL) -> Bool {
    var metadata = stat()
    return lstat(url.path, &metadata) == 0
        && metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
}

private func safeInstallerDirectory(_ url: URL) -> Bool {
    var metadata = stat()
    return lstat(url.path, &metadata) == 0
        && metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        && metadata.st_uid == getuid()
        && metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
}

private func isRegularFile(_ url: URL) -> Bool {
    var metadata = stat()
    return stat(url.path, &metadata) == 0
        && metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
}

private func isAbsoluteFileURL(_ url: URL) -> Bool {
    url.isFileURL && url.path.hasPrefix("/")
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
