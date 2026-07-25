import Foundation

/// App Server releases whose generated stable and experimental schemas have
/// been reviewed for this connection layer.
public enum SupportedAppServerVersion: String, CaseIterable, Codable, Sendable {
    case v0_144_5 = "0.144.5"
    case v0_144_6 = "0.144.6"

    public init(validating version: String) throws {
        guard let value = Self(rawValue: version) else {
            throw ConnAppServerConnectionError.unsupportedVersion(version)
        }
        self = value
    }
}

/// Named experimental features are the only path that enables experimental
/// API initialization. Each feature has a stable fallback at the product layer.
public enum AppServerExperimentalFeature: String, CaseIterable, Codable, Sendable {
    case collaborationModeList = "collaborationMode/list"
    case threadSearch = "thread/search"
}

public enum AppServerCapabilityMode: Equatable, Sendable {
    case stable
    case experimental(Set<AppServerExperimentalFeature>)

    public var enablesExperimentalAPI: Bool {
        switch self {
        case .stable: false
        case let .experimental(features): !features.isEmpty
        }
    }
}

/// Version-pinned, fail-closed method policy. This is deliberately narrower
/// than accepting arbitrary strings from a schema: Conn exposes only methods
/// it has integration semantics for and never treats initialize as discovery.
public struct AppServerCompatibilityPolicy: Sendable {
    public let version: SupportedAppServerVersion
    public let mode: AppServerCapabilityMode

    public init(
        version: SupportedAppServerVersion,
        mode: AppServerCapabilityMode = .stable
    ) {
        self.version = version
        self.mode = mode
    }

    public func supports(method: String) -> Bool {
        if Self.stableClientMethods(for: version).contains(method) { return true }
        guard case let .experimental(features) = mode else { return false }
        return features.contains { $0.rawValue == method }
    }

    /// Server requests have response schemas rather than client request
    /// methods. Keep their response authority in a separate exact-version
    /// policy so observing a future request never implies Conn may answer it.
    public func supportsServerResponse(method: String) -> Bool {
        Self.stableServerResponseMethods(for: version).contains(method)
    }

    public func requireSupport(for method: String) throws {
        guard supports(method: method) else {
            throw ConnAppServerConnectionError.unsupportedMethod(
                method: method,
                version: version.rawValue,
                experimentalAPIEnabled: mode.enablesExperimentalAPI
            )
        }
    }

    public func requireServerResponseSupport(for method: String) throws {
        guard supportsServerResponse(method: method) else {
            throw ConnAppServerConnectionError.unsupportedMethod(
                method: method,
                version: version.rawValue,
                // Server-response authority is a distinct reviewed policy;
                // enabling experimental client requests never widens it.
                experimentalAPIEnabled: false
            )
        }
    }

    // Reviewed Conn client request surface. Keep the switch explicit even
    // while the two pinned releases match: a schema change in either release
    // must be reviewed rather than widening every supported version at once.
    private static func stableClientMethods(
        for version: SupportedAppServerVersion
    ) -> Set<String> {
        switch version {
        case .v0_144_5: stableReadMethods.union(stableControlMethods0_144_5)
        case .v0_144_6: stableReadMethods.union(stableControlMethods0_144_6)
        }
    }

    private static func stableServerResponseMethods(
        for version: SupportedAppServerVersion
    ) -> Set<String> {
        switch version {
        case .v0_144_5: stableServerResponseMethods0_144_5
        case .v0_144_6: stableServerResponseMethods0_144_6
        }
    }

    private static let stableReadMethods: Set<String> = [
        "account/rateLimits/read",
        "account/read",
        "account/usage/read",
        "app/list",
        "config/read",
        "hooks/list",
        "model/list",
        "plugin/list",
        "thread/list",
        "thread/loaded/list",
        "thread/read",
        "thread/resume",
        "thread/unsubscribe",
    ]

    private static let stableControlMethods0_144_5: Set<String> = [
        "plugin/uninstall",
        "thread/start",
        "turn/interrupt",
        "turn/start",
        "turn/steer",
    ]

    private static let stableControlMethods0_144_6: Set<String> = [
        "plugin/uninstall",
        "thread/start",
        "turn/interrupt",
        "turn/start",
        "turn/steer",
    ]

    private static let stableServerResponseMethods0_144_5: Set<String> = [
        "item/commandExecution/requestApproval",
        "item/fileChange/requestApproval",
        "item/permissions/requestApproval",
        "item/tool/requestUserInput",
    ]

    private static let stableServerResponseMethods0_144_6: Set<String> = [
        "item/commandExecution/requestApproval",
        "item/fileChange/requestApproval",
        "item/permissions/requestApproval",
        "item/tool/requestUserInput",
    ]
}
