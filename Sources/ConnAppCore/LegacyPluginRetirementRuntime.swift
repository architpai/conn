import Foundation
import ConnAppServerAdapter
import ConnDomain

public struct LegacySidequestPluginCandidate: Equatable, Sendable {
    public let connection: AppServerConnectionIdentity
    public let pluginID: String
    public let marketplaceName: String

    public init(
        connection: AppServerConnectionIdentity,
        pluginID: String,
        marketplaceName: String
    ) {
        self.connection = connection
        self.pluginID = pluginID
        self.marketplaceName = marketplaceName
    }
}

public enum LegacySidequestPluginScanOutcome: Equatable, Sendable {
    case absent
    case candidate(LegacySidequestPluginCandidate)
    case ambiguous
    case connectionInvalidated
    case unsupported
    case invalidResponse
    case unavailable
}

public enum LegacySidequestPluginUninstallOutcome: Equatable, Sendable {
    case removed
    case stillInstalled
    case staleConfirmation
    case alreadyAttempted
    case acknowledgementUncertain
    case unsupported
}

/// Runtime-only migration control for the exact legacy Sidequest plugin.
///
/// Discovery is read-only. Uninstall is user-triggered, bound to the captured
/// server-returned plugin and connection identities, and is never retried after
/// a send because timeout cannot prove whether App Server accepted the action.
public actor LegacyPluginRetirementRuntime {
    private struct Session: Sendable {
        let connection: any AppServerThreadControlConnection
        let wireIdentity: ConnAppServerConnectionIdentity
        let domainConnection: AppServerConnectionIdentity
        let version: SupportedAppServerVersion
    }

    private struct Attempt: Hashable, Sendable {
        let wireIdentity: ConnAppServerConnectionIdentity
        let pluginID: String
    }

    private static let legacyPluginID = "sidequest"
    private static let localMarketplace = "sidequest-local"
    private static let releaseMarketplacePrefix = "sidequest-release-"
    private static let maximumMarketplaces = 64
    private static let maximumPluginsPerMarketplace = 256
    private static let maximumIdentityBytes = 512

    private var session: Session?
    private var candidate: LegacySidequestPluginCandidate?
    private var attempts: Set<Attempt> = []

    public init() {}

    package func attach(
        connection: any AppServerThreadControlConnection,
        wireIdentity: ConnAppServerConnectionIdentity,
        domainConnection: AppServerConnectionIdentity,
        version: SupportedAppServerVersion
    ) {
        session = .init(
            connection: connection,
            wireIdentity: wireIdentity,
            domainConnection: domainConnection,
            version: version
        )
        candidate = nil
    }

    package func detach(ifWireIdentityMatches identity: ConnAppServerConnectionIdentity) {
        guard session?.wireIdentity == identity else { return }
        session = nil
        candidate = nil
    }

    public func currentCandidate() -> LegacySidequestPluginCandidate? { candidate }

    public func scan(
        workingDirectories: [String] = []
    ) async -> LegacySidequestPluginScanOutcome {
        candidate = nil
        guard let captured = session else { return .connectionInvalidated }
        let uniqueWorkingDirectories = Set(workingDirectories)
        guard !workingDirectories.isEmpty,
              workingDirectories.count <= 32,
              uniqueWorkingDirectories.count == workingDirectories.count,
              workingDirectories.allSatisfy({ $0.hasPrefix("/") && $0.utf8.count <= 4_096 })
        else { return .invalidResponse }
        let policy = AppServerCompatibilityPolicy(version: captured.version)
        guard policy.supports(method: "plugin/list") else { return .unsupported }
        do {
            let response = try await captured.connection.requestEnvelope(
                method: "plugin/list",
                params: .object([
                    "cwds": .array(workingDirectories.map(JSONValue.string)),
                    "marketplaceKinds": .array([
                        .string("local"),
                        .string("vertical"),
                        .string("workspace-directory"),
                        .string("shared-with-me"),
                        .string("created-by-me-remote"),
                    ]),
                ]),
                timeout: .seconds(10)
            )
            guard isCurrent(captured), response.connection == captured.wireIdentity else {
                return .connectionInvalidated
            }
            guard let decoded = decodeCandidates(
                response.result,
                connection: captured.domainConnection
            ) else { return .invalidResponse }
            if decoded.hasUnrecognizedInstalledMatch { return .ambiguous }
            switch decoded.candidates.count {
            case 0:
                return .absent
            case 1:
                candidate = decoded.candidates[0]
                return .candidate(decoded.candidates[0])
            default:
                return .ambiguous
            }
        } catch {
            return isCurrent(captured) ? .unavailable : .connectionInvalidated
        }
    }

    public func uninstall(
        confirmed candidate: LegacySidequestPluginCandidate,
        verificationWorkingDirectories: [String]
    ) async -> LegacySidequestPluginUninstallOutcome {
        guard let captured = session,
              candidate == self.candidate,
              candidate.connection == captured.domainConnection else {
            return .staleConfirmation
        }
        let policy = AppServerCompatibilityPolicy(version: captured.version)
        guard policy.supports(method: "plugin/uninstall") else { return .unsupported }
        let attempt = Attempt(
            wireIdentity: captured.wireIdentity,
            pluginID: candidate.pluginID
        )
        guard attempts.insert(attempt).inserted else { return .alreadyAttempted }
        guard isCurrent(captured),
              await captured.connection.controlIdentity() == captured.wireIdentity else {
            return .staleConfirmation
        }

        do {
            let response = try await captured.connection.requestEnvelope(
                method: "plugin/uninstall",
                params: .object(["pluginId": .string(candidate.pluginID)]),
                timeout: .seconds(10)
            )
            guard response.connection == captured.wireIdentity, isCurrent(captured) else {
                return .acknowledgementUncertain
            }
        } catch {
            return .acknowledgementUncertain
        }

        switch await scan(workingDirectories: verificationWorkingDirectories) {
        case .absent:
            guard let hooksAreGone = await verifyLegacyHooksAreGone(
                pluginID: candidate.pluginID,
                workingDirectories: verificationWorkingDirectories,
                session: captured
            ) else { return .acknowledgementUncertain }
            return hooksAreGone ? .removed : .stillInstalled
        case .candidate, .ambiguous:
            return .stillInstalled
        case .connectionInvalidated, .invalidResponse, .unavailable:
            return .acknowledgementUncertain
        case .unsupported:
            return .unsupported
        }
    }

    private func verifyLegacyHooksAreGone(
        pluginID: String,
        workingDirectories: [String],
        session captured: Session
    ) async -> Bool? {
        guard !workingDirectories.isEmpty,
              workingDirectories.count <= 32,
              workingDirectories.allSatisfy({
                  $0.hasPrefix("/") && $0.utf8.count <= 4_096
              }) else { return nil }
        do {
            let response = try await captured.connection.requestEnvelope(
                method: "hooks/list",
                params: .object([
                    "cwds": .array(workingDirectories.map(JSONValue.string)),
                ]),
                timeout: .seconds(10)
            )
            guard response.connection == captured.wireIdentity,
                  isCurrent(captured),
                  let rows = response.result.objectValue?["data"]?.arrayValue,
                  rows.count == workingDirectories.count else { return nil }
            let expectedDirectories = Set(workingDirectories)
            var returnedDirectories: Set<String> = []
            for encodedRow in rows {
                guard let row = encodedRow.objectValue,
                      let cwd = row["cwd"]?.stringValue,
                      expectedDirectories.contains(cwd),
                      returnedDirectories.insert(cwd).inserted,
                      let errors = row["errors"]?.arrayValue, errors.isEmpty,
                      let warnings = row["warnings"]?.arrayValue, warnings.isEmpty
                else { return nil }
            }
            guard returnedDirectories == expectedDirectories,
                  let observation = try? AppServerObservationAdapter().configuredHooks(
                      response: response
                  ) else { return nil }
            return !observation.hooks.contains { $0.pluginID == pluginID }
        } catch {
            return nil
        }
    }

    private func isCurrent(_ captured: Session) -> Bool {
        session?.wireIdentity == captured.wireIdentity
            && session?.domainConnection == captured.domainConnection
    }

    private func decodeCandidates(
        _ result: JSONValue,
        connection: AppServerConnectionIdentity
    ) -> (
        candidates: [LegacySidequestPluginCandidate],
        hasUnrecognizedInstalledMatch: Bool
    )? {
        guard let object = result.objectValue,
              let marketplaces = object["marketplaces"]?.arrayValue,
              marketplaces.count <= Self.maximumMarketplaces else { return nil }
        if let encodedErrors = object["marketplaceLoadErrors"] {
            guard let errors = encodedErrors.arrayValue, errors.isEmpty else { return nil }
        }
        var matches: [LegacySidequestPluginCandidate] = []
        var hasUnrecognizedInstalledMatch = false
        for encodedMarketplace in marketplaces {
            guard let marketplace = encodedMarketplace.objectValue,
                  let name = marketplace["name"]?.stringValue,
                  !name.isEmpty,
                  name.utf8.count <= Self.maximumIdentityBytes,
                  let plugins = marketplace["plugins"]?.arrayValue,
                  plugins.count <= Self.maximumPluginsPerMarketplace else { return nil }
            let isLegacyMarketplace = name == Self.localMarketplace
                || name.hasPrefix(Self.releaseMarketplacePrefix)
            for encodedPlugin in plugins {
                guard let plugin = encodedPlugin.objectValue,
                      let id = plugin["id"]?.stringValue,
                      id.utf8.count <= Self.maximumIdentityBytes,
                      let installed = plugin["installed"]?.boolValue else { return nil }
                guard installed, id == Self.legacyPluginID else { continue }
                if isLegacyMarketplace {
                    matches.append(.init(
                        connection: connection,
                        pluginID: id,
                        marketplaceName: name
                    ))
                } else {
                    hasUnrecognizedInstalledMatch = true
                }
            }
        }
        return (matches, hasUnrecognizedInstalledMatch)
    }
}
