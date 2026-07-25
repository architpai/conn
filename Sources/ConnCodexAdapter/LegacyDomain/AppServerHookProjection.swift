import Foundation

public enum AppServerHookEventName: String, Codable, Hashable, Sendable {
    case preToolUse, permissionRequest, postToolUse, preCompact, postCompact
    case sessionStart, userPromptSubmit, subagentStart, subagentStop, stop
}

public enum AppServerHookHandlerType: String, Codable, Hashable, Sendable {
    case command, prompt, agent
}

public enum AppServerHookSource: String, Codable, Hashable, Sendable {
    case system, user, project, mdm, sessionFlags, plugin, cloudRequirements
    case cloudManagedConfig, legacyManagedConfigFile, legacyManagedConfigMdm, unknown
}

public enum AppServerHookTrustStatus: String, Codable, Hashable, Sendable {
    case managed, untrusted, trusted, modified
}

public enum AppServerHookExecutionMode: String, Codable, Hashable, Sendable {
    case sync, async
}

public enum AppServerHookScope: String, Codable, Hashable, Sendable {
    case thread, turn
}

public enum AppServerHookRunStatus: String, Codable, Hashable, Sendable {
    case running, completed, failed, blocked, stopped
}

/// A configured-hook summary deliberately excludes command, cwd, matcher,
/// sourcePath, hash, warning, error, and status-message content.
public struct AppServerConfiguredHookSummary: Equatable, Hashable, Sendable, Identifiable {
    public let eventName: AppServerHookEventName
    public let handlerType: AppServerHookHandlerType
    public let source: AppServerHookSource
    public let enabled: Bool
    public let trustStatus: AppServerHookTrustStatus
    public let pluginID: String?

    public var id: String {
        [eventName.rawValue, handlerType.rawValue, source.rawValue,
         enabled ? "enabled" : "disabled", trustStatus.rawValue, pluginID ?? ""]
            .joined(separator: ":")
    }

    public init(
        eventName: AppServerHookEventName,
        handlerType: AppServerHookHandlerType,
        source: AppServerHookSource,
        enabled: Bool,
        trustStatus: AppServerHookTrustStatus,
        pluginID: String?
    ) {
        self.eventName = eventName
        self.handlerType = handlerType
        self.source = source
        self.enabled = enabled
        self.trustStatus = trustStatus
        self.pluginID = pluginID
    }
}

/// Runtime-only lifecycle evidence. Output entries, paths, and status messages
/// never cross the adapter boundary.
public struct AppServerHookRunSummary: Equatable, Sendable, Identifiable {
    public let id: String
    public let threadID: AppServerThreadID
    public let turnID: AppServerTurnID?
    public let eventName: AppServerHookEventName
    public let executionMode: AppServerHookExecutionMode
    public let handlerType: AppServerHookHandlerType
    public let scope: AppServerHookScope
    public let status: AppServerHookRunStatus
    public let startedAt: Date
    public let completedAt: Date?

    public init(
        id: String,
        threadID: AppServerThreadID,
        turnID: AppServerTurnID?,
        eventName: AppServerHookEventName,
        executionMode: AppServerHookExecutionMode,
        handlerType: AppServerHookHandlerType,
        scope: AppServerHookScope,
        status: AppServerHookRunStatus,
        startedAt: Date,
        completedAt: Date?
    ) {
        self.id = id
        self.threadID = threadID
        self.turnID = turnID
        self.eventName = eventName
        self.executionMode = executionMode
        self.handlerType = handlerType
        self.scope = scope
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

public enum AppServerHookProjectionFreshness: String, Equatable, Sendable {
    case current, stale
}

public struct AppServerHookProjectionSnapshot: Equatable, Sendable {
    public let connection: AppServerConnectionIdentity?
    public let freshness: AppServerHookProjectionFreshness
    public let configuredHooks: [AppServerConfiguredHookSummary]
    public let runsByThread: [AppServerThreadID: [AppServerHookRunSummary]]

    public init(
        connection: AppServerConnectionIdentity?,
        freshness: AppServerHookProjectionFreshness,
        configuredHooks: [AppServerConfiguredHookSummary],
        runsByThread: [AppServerThreadID: [AppServerHookRunSummary]]
    ) {
        self.connection = connection
        self.freshness = freshness
        self.configuredHooks = configuredHooks
        self.runsByThread = runsByThread
    }
}

public enum AppServerHookProjectionApplyResult: Equatable, Sendable {
    case applied, duplicate, rejectedStaleConnection, rejectedOutOfOrder, rejectedBound
}

/// A runtime-only reducer intentionally separate from thread lifecycle state.
/// Applying hook facts cannot change thread/turn status, Outcomes, or requests.
public actor AppServerHookProjectionStore {
    public static let maximumConfiguredHooks = 256
    public static let maximumThreads = 256
    public static let maximumRunsPerThread = 64

    private var connection: AppServerConnectionIdentity?
    private var freshness: AppServerHookProjectionFreshness = .stale
    private var configured: [String: AppServerConfiguredHookSummary] = [:]
    private var configuredSequence: UInt64?
    private var runs: [AppServerThreadID: [String: (AppServerHookRunSummary, UInt64)]] = [:]

    public init() {}

    @discardableResult
    public func activate(_ identity: AppServerConnectionIdentity) -> AppServerHookProjectionApplyResult {
        if connection == identity, freshness == .current { return .duplicate }
        connection = identity
        freshness = .stale
        configured.removeAll(keepingCapacity: true)
        configuredSequence = nil
        runs.removeAll(keepingCapacity: true)
        return .applied
    }

    @discardableResult
    public func loseConnection(_ identity: AppServerConnectionIdentity) -> AppServerHookProjectionApplyResult {
        guard connection == identity else { return .rejectedStaleConnection }
        connection = nil
        freshness = .stale
        return .applied
    }

    @discardableResult
    public func replaceConfiguredHooks(
        _ values: [AppServerConfiguredHookSummary],
        cursor: AppServerObservationCursor
    ) -> AppServerHookProjectionApplyResult {
        guard connection == cursor.connection else { return .rejectedStaleConnection }
        if let previous = configuredSequence {
            if cursor.sequence < previous { return .rejectedOutOfOrder }
            if cursor.sequence == previous { return .duplicate }
        }
        let unique = Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard unique.count <= Self.maximumConfiguredHooks else { return .rejectedBound }
        configured = unique
        configuredSequence = cursor.sequence
        freshness = .current
        return .applied
    }

    @discardableResult
    public func markConfigurationStale(
        _ identity: AppServerConnectionIdentity
    ) -> AppServerHookProjectionApplyResult {
        guard connection == identity else { return .rejectedStaleConnection }
        if freshness == .stale { return .duplicate }
        freshness = .stale
        return .applied
    }

    @discardableResult
    public func applyRun(
        _ value: AppServerHookRunSummary,
        cursor: AppServerObservationCursor
    ) -> AppServerHookProjectionApplyResult {
        guard connection == cursor.connection else { return .rejectedStaleConnection }
        if runs[value.threadID] == nil, runs.count >= Self.maximumThreads,
           let oldestThread = runs.min(by: { left, right in
               let leftSequence = left.value.values.map { $0.1 }.max() ?? 0
               let rightSequence = right.value.values.map { $0.1 }.max() ?? 0
               if leftSequence != rightSequence { return leftSequence < rightSequence }
               return left.key.rawValue < right.key.rawValue
           })?.key {
            runs.removeValue(forKey: oldestThread)
        }
        var threadRuns = runs[value.threadID] ?? [:]
        if let previous = threadRuns[value.id] {
            if cursor.sequence < previous.1 { return .rejectedOutOfOrder }
            if cursor.sequence == previous.1 { return .duplicate }
        }
        if threadRuns[value.id] == nil,
           threadRuns.count >= Self.maximumRunsPerThread,
           let oldestRunID = threadRuns.min(by: { left, right in
               if left.value.1 != right.value.1 { return left.value.1 < right.value.1 }
               return left.key < right.key
           })?.key {
            threadRuns.removeValue(forKey: oldestRunID)
        }
        threadRuns[value.id] = (value, cursor.sequence)
        runs[value.threadID] = threadRuns
        return .applied
    }

    public func snapshot() -> AppServerHookProjectionSnapshot {
        .init(
            connection: connection,
            freshness: freshness,
            configuredHooks: configured.values.sorted { $0.id < $1.id },
            runsByThread: runs.mapValues { values in
                values.values.map(\.0).sorted {
                    if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
                    return $0.id < $1.id
                }
            }
        )
    }
}
