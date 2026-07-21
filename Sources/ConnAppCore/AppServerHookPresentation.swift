import Foundation
import ConnDomain

public struct AppServerConfiguredHookPresentation: Equatable, Sendable, Identifiable {
    public let id: String
    public let eventLabel: String
    public let handlerLabel: String
    public let sourceLabel: String
    public let stateLabel: String
    public let trustLabel: String
    public let pluginLabel: String?

    public init(_ hook: AppServerConfiguredHookSummary) {
        id = hook.id
        eventLabel = Self.words(hook.eventName.rawValue)
        handlerLabel = hook.handlerType.rawValue.capitalized
        sourceLabel = Self.words(hook.source.rawValue)
        stateLabel = hook.enabled ? "Enabled" : "Disabled"
        trustLabel = hook.trustStatus.rawValue.capitalized
        pluginLabel = hook.pluginID
    }

    private static func words(_ value: String) -> String {
        value.reduce(into: "") { result, character in
            if character.isUppercase, !result.isEmpty { result.append(" ") }
            result.append(character)
        }.capitalized
    }
}

public struct AppServerHookRunPresentation: Equatable, Sendable, Identifiable {
    public let id: String
    public let threadID: String
    public let turnID: String?
    public let title: String
    public let statusLabel: String
    public let startedAt: Date
    public let completedAt: Date?

    public init(_ run: AppServerHookRunSummary) {
        id = run.id
        threadID = run.threadID.rawValue
        turnID = run.turnID?.rawValue
        title = "\(run.eventName.rawValue) · \(run.handlerType.rawValue) · \(run.executionMode.rawValue)"
        statusLabel = run.status.rawValue.capitalized
        startedAt = run.startedAt
        completedAt = run.completedAt
    }
}

public struct AppServerHookVisibilityPresentation: Equatable, Sendable {
    public let isCurrent: Bool
    public let configuredHooks: [AppServerConfiguredHookPresentation]
    public let runsByThread: [String: [AppServerHookRunPresentation]]

    public init(_ snapshot: AppServerHookProjectionSnapshot) {
        isCurrent = snapshot.freshness == .current
        configuredHooks = snapshot.configuredHooks.map(AppServerConfiguredHookPresentation.init)
        runsByThread = Dictionary(uniqueKeysWithValues: snapshot.runsByThread.map { threadID, runs in
            (threadID.rawValue, runs.map(AppServerHookRunPresentation.init))
        })
    }
}
