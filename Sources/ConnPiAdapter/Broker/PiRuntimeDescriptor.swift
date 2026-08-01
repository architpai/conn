import Darwin
import Foundation

public struct PiBrokerRuntimeDescriptor:
    Codable, Equatable, Sendable, CustomStringConvertible
{
    public let protocolVersion: Int
    public let generation: UUID
    public let socketPath: String
    public let authenticationSecret: String
    public let issuedAt: Date
    public let expiresAt: Date

    public var description: String {
        "PiBrokerRuntimeDescriptor(protocolVersion: \(protocolVersion), "
            + "generation: \(generation), socketPath: \(socketPath), "
            + "authenticationSecret: <redacted>, issuedAt: \(issuedAt), "
            + "expiresAt: \(expiresAt))"
    }
}

public enum PiRuntimeDescriptorError: Error, Equatable, Sendable {
    case invalidDirectory
    case invalidSocketPath
    case invalidTimeToLive
    case unsafeExistingDescriptor
    case writeFailed
}

public struct PiRuntimeDescriptorStore: Sendable {
    public let directory: URL
    public let descriptorURL: URL
    private let currentUserID: uid_t

    public init(
        directory: URL,
        currentUserID: uid_t = getuid()
    ) {
        self.directory = directory.standardizedFileURL
        self.descriptorURL = directory
            .standardizedFileURL
            .appendingPathComponent("runtime.json")
        self.currentUserID = currentUserID
    }

    public func publish(
        socketURL: URL,
        now: Date = Date(),
        timeToLive: TimeInterval = 30
    ) throws(PiRuntimeDescriptorError) -> PiBrokerRuntimeDescriptor {
        guard directory.isFileURL, directory.path.hasPrefix("/") else {
            throw .invalidDirectory
        }
        guard socketURL.isFileURL, socketURL.path.hasPrefix("/"),
              socketURL.path.utf8.count <= 100 else {
            throw .invalidSocketPath
        }
        guard timeToLive > 0, timeToLive <= 300 else {
            throw .invalidTimeToLive
        }
        do {
            if runtimeFileKind(directory) == .absent {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            guard safeOwnedDirectory(directory, owner: currentUserID) else {
                throw PiRuntimeDescriptorError.invalidDirectory
            }
            if runtimeFileKind(descriptorURL) != .absent,
               !safeOwnedRegularFile(descriptorURL, owner: currentUserID) {
                throw PiRuntimeDescriptorError.unsafeExistingDescriptor
            }

            let issuedAt = Date(
                timeIntervalSince1970: floor(now.timeIntervalSince1970 * 1_000) / 1_000
            )
            let descriptor = PiBrokerRuntimeDescriptor(
                protocolVersion: PiBrokerProtocolBounds.currentVersion,
                generation: UUID(),
                socketPath: socketURL.standardizedFileURL.path,
                authenticationSecret: makeSecret(),
                issuedAt: issuedAt,
                expiresAt: issuedAt.addingTimeInterval(timeToLive)
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(descriptor)
            data.append(0x0A)
            let temporaryURL = directory.appendingPathComponent(
                ".runtime-\(descriptor.generation.uuidString).json"
            )
            try data.write(to: temporaryURL, options: .withoutOverwriting)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporaryURL.path
            )
            guard Darwin.rename(temporaryURL.path, descriptorURL.path) == 0 else {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw PiRuntimeDescriptorError.writeFailed
            }
            guard load(now: issuedAt) == descriptor else {
                try? FileManager.default.removeItem(at: descriptorURL)
                throw PiRuntimeDescriptorError.writeFailed
            }
            return descriptor
        } catch let error as PiRuntimeDescriptorError {
            throw error
        } catch {
            throw .writeFailed
        }
    }

    public func load(now: Date = Date()) -> PiBrokerRuntimeDescriptor? {
        guard safeOwnedRegularFile(descriptorURL, owner: currentUserID),
              let data = try? Data(contentsOf: descriptorURL),
              data.count <= PiBrokerProtocolBounds.maximumFrameBytes else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let descriptor = try? decoder.decode(
            PiBrokerRuntimeDescriptor.self,
            from: data
        ), descriptor.protocolVersion == PiBrokerProtocolBounds.currentVersion,
           descriptor.issuedAt <= now,
           descriptor.expiresAt > now,
           descriptor.expiresAt.timeIntervalSince(descriptor.issuedAt) <= 300,
           descriptor.socketPath.hasPrefix("/"),
           descriptor.socketPath.utf8.count <= 100,
           !descriptor.authenticationSecret.isEmpty,
           descriptor.authenticationSecret.utf8.count <= 512
        else {
            return nil
        }
        return descriptor
    }

    public func refresh(
        _ descriptor: PiBrokerRuntimeDescriptor,
        now: Date = Date(),
        timeToLive: TimeInterval = 30
    ) throws(PiRuntimeDescriptorError) -> PiBrokerRuntimeDescriptor {
        guard timeToLive > 0, timeToLive <= 300 else {
            throw .invalidTimeToLive
        }
        guard load(now: now) == descriptor else {
            throw .unsafeExistingDescriptor
        }
        let refreshedIssuedAt = Date(
            timeIntervalSince1970: floor(now.timeIntervalSince1970 * 1_000) / 1_000
        )
        let refreshed = PiBrokerRuntimeDescriptor(
            protocolVersion: descriptor.protocolVersion,
            generation: descriptor.generation,
            socketPath: descriptor.socketPath,
            authenticationSecret: descriptor.authenticationSecret,
            issuedAt: refreshedIssuedAt,
            expiresAt: refreshedIssuedAt.addingTimeInterval(timeToLive)
        )
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(refreshed)
            data.append(0x0A)
            let temporaryURL = directory.appendingPathComponent(
                ".runtime-refresh-\(descriptor.generation.uuidString).json"
            )
            try? FileManager.default.removeItem(at: temporaryURL)
            try data.write(to: temporaryURL, options: .withoutOverwriting)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporaryURL.path
            )
            guard Darwin.rename(temporaryURL.path, descriptorURL.path) == 0,
                  load(now: now) == refreshed else {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw PiRuntimeDescriptorError.writeFailed
            }
            return refreshed
        } catch let error as PiRuntimeDescriptorError {
            throw error
        } catch {
            throw .writeFailed
        }
    }

    public func invalidate() throws(PiRuntimeDescriptorError) {
        switch runtimeFileKind(descriptorURL) {
        case .absent:
            return
        case .regular:
            guard safeOwnedRegularFile(descriptorURL, owner: currentUserID) else {
                throw .unsafeExistingDescriptor
            }
            do {
                try FileManager.default.removeItem(at: descriptorURL)
            } catch {
                throw .writeFailed
            }
        case .directory, .other:
            throw .unsafeExistingDescriptor
        }
    }
}

private enum RuntimeFileKind {
    case absent
    case regular
    case directory
    case other
}

private func runtimeFileKind(_ url: URL) -> RuntimeFileKind {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
        return errno == ENOENT ? .absent : .other
    }
    switch metadata.st_mode & mode_t(S_IFMT) {
    case mode_t(S_IFREG): return .regular
    case mode_t(S_IFDIR): return .directory
    default: return .other
    }
}

private func safeOwnedDirectory(_ url: URL, owner: uid_t) -> Bool {
    var metadata = stat()
    return lstat(url.path, &metadata) == 0
        && metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        && metadata.st_uid == owner
        && metadata.st_mode & mode_t(S_IRWXG | S_IRWXO) == 0
}

private func safeOwnedRegularFile(_ url: URL, owner: uid_t) -> Bool {
    var metadata = stat()
    return lstat(url.path, &metadata) == 0
        && metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        && metadata.st_uid == owner
        && metadata.st_mode & mode_t(S_IRWXG | S_IRWXO) == 0
}

private func makeSecret() -> String {
    (UUID().uuidString + UUID().uuidString)
        .replacingOccurrences(of: "-", with: "")
        .lowercased()
}
