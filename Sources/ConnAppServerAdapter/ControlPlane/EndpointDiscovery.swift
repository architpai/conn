import Darwin
import Foundation

// Optional Level 3 adapter; never required for hook observation.

public struct EndpointDiscovery: Sendable {
    public static let controlDirectoryName = "app-server-control"
    public static let controlSocketName = "app-server-control.sock"

    private let currentUserID: uid_t

    private enum MetadataResult {
        case success(stat)
        case failure(Int32)
    }

    public init(currentUserID: uid_t = getuid()) {
        self.currentUserID = currentUserID
    }

    public func defaultCodexHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let configuredHome = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configuredHome.isEmpty
        {
            return URL(fileURLWithPath: configuredHome, isDirectory: true).standardizedFileURL
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .standardizedFileURL
    }

    public func expectedSocketURL(codexHome: URL) -> URL {
        codexHome
            .appendingPathComponent(Self.controlDirectoryName, isDirectory: true)
            .appendingPathComponent(Self.controlSocketName, isDirectory: false)
    }

    public func inspect(codexHome: URL) -> EndpointInspection {
        inspect(socketURL: expectedSocketURL(codexHome: codexHome))
    }

    public func inspect(socketURL: URL) -> EndpointInspection {
        let standardizedSocketURL = socketURL.standardizedFileURL
        let parentURL = standardizedSocketURL.deletingLastPathComponent()

        switch metadata(atPath: parentURL.path) {
        case let .success(parent):
            let parentType = parent.st_mode & mode_t(S_IFMT)
            let unsafeWriteBits = mode_t(S_IWGRP | S_IWOTH)
            guard parentType == mode_t(S_IFDIR),
                  parent.st_uid == currentUserID,
                  parent.st_mode & unsafeWriteBits == 0
            else {
                return EndpointInspection(
                    expectedSocketURL: standardizedSocketURL,
                    status: .unsafeParentDirectory,
                    detail: "Control directory must be a current-user-owned directory without group or world write access."
                )
            }
        case let .failure(errorNumber):
            if errorNumber == ENOENT {
                return EndpointInspection(
                    expectedSocketURL: standardizedSocketURL,
                    status: .missing,
                    detail: "The documented App Server control directory is absent."
                )
            }
            return EndpointInspection(
                expectedSocketURL: standardizedSocketURL,
                status: .inspectionFailed,
                detail: Self.errorDescription(operation: "inspect the control directory", errorNumber: errorNumber)
            )
        }

        switch metadata(atPath: standardizedSocketURL.path) {
        case let .success(socket):
            guard socket.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else {
                return EndpointInspection(
                    expectedSocketURL: standardizedSocketURL,
                    status: .notSocket,
                    detail: "The documented control endpoint exists but is not a Unix domain socket."
                )
            }
            guard socket.st_uid == currentUserID else {
                return EndpointInspection(
                    expectedSocketURL: standardizedSocketURL,
                    status: .wrongOwner,
                    detail: "The control socket is not owned by the current user."
                )
            }
            let permissionBits = socket.st_mode & mode_t(0o777)
            guard permissionBits == mode_t(0o600) else {
                return EndpointInspection(
                    expectedSocketURL: standardizedSocketURL,
                    status: .unsafeSocketPermissions,
                    detail: "The control socket must use exact current-user-only permissions (0600)."
                )
            }

            let endpoint = ControlEndpoint(socketURL: standardizedSocketURL, ownerUserID: socket.st_uid)
            return EndpointInspection(
                expectedSocketURL: standardizedSocketURL,
                status: .ready,
                detail: "Found the documented current-user App Server control socket.",
                endpoint: endpoint
            )
        case let .failure(errorNumber):
            if errorNumber == ENOENT {
                return EndpointInspection(
                    expectedSocketURL: standardizedSocketURL,
                    status: .missing,
                    detail: "The documented App Server control socket is absent."
                )
            }
            return EndpointInspection(
                expectedSocketURL: standardizedSocketURL,
                status: .inspectionFailed,
                detail: Self.errorDescription(operation: "inspect the control socket", errorNumber: errorNumber)
            )
        }
    }

    private func metadata(atPath path: String) -> MetadataResult {
        var value = stat()
        if lstat(path, &value) == 0 {
            return .success(value)
        }
        return .failure(errno)
    }

    private static func errorDescription(operation: String, errorNumber: Int32) -> String {
        let message = String(cString: strerror(errorNumber))
        return "Could not \(operation): \(message) (errno \(errorNumber))."
    }
}
