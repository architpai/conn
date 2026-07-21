import Foundation

// Optional Level 3 adapter; never required for hook observation.

public struct ControlEndpoint: Equatable, Sendable {
    public let socketURL: URL
    public let ownerUserID: uid_t

    package init(socketURL: URL, ownerUserID: uid_t) {
        self.socketURL = socketURL
        self.ownerUserID = ownerUserID
    }
}

public struct EndpointInspection: Equatable, Sendable {
    public enum Status: String, Equatable, Sendable {
        case ready
        case missing
        case unsafeParentDirectory
        case notSocket
        case wrongOwner
        case unsafeSocketPermissions
        case inspectionFailed
    }

    public let expectedSocketURL: URL
    public let status: Status
    public let detail: String
    public let endpoint: ControlEndpoint?

    public init(
        expectedSocketURL: URL,
        status: Status,
        detail: String,
        endpoint: ControlEndpoint? = nil
    ) {
        self.expectedSocketURL = expectedSocketURL
        self.status = status
        self.detail = detail
        self.endpoint = endpoint
    }
}
