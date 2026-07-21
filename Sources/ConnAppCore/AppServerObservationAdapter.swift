import Foundation
import ConnAppServerAdapter
import ConnDomain

public enum AppServerObservationAdapterError: Error, Equatable, Sendable {
    case malformed(context: String, field: String)
}

public struct AppServerThreadListPage: Equatable, Sendable {
    public let snapshot: AppServerSnapshotInput
    public let nextCursor: String?
    public let inventoryThreadIDs: Set<AppServerThreadID>
    public let malformedRowCount: Int
    public let inventoryMembershipIsComplete: Bool

    public init(
        snapshot: AppServerSnapshotInput,
        nextCursor: String?,
        inventoryThreadIDs: Set<AppServerThreadID>? = nil,
        malformedRowCount: Int = 0,
        inventoryMembershipIsComplete: Bool = true
    ) {
        self.snapshot = snapshot
        self.nextCursor = nextCursor
        self.inventoryThreadIDs = inventoryThreadIDs ?? Set(snapshot.threads.map(\.id))
        self.malformedRowCount = max(0, malformedRowCount)
        self.inventoryMembershipIsComplete = inventoryMembershipIsComplete
    }

    public var isTruncated: Bool { nextCursor != nil }
}

public struct AppServerConfiguredHooksObservation: Equatable, Sendable {
    public let cursor: AppServerObservationCursor
    public let hooks: [AppServerConfiguredHookSummary]

    public init(cursor: AppServerObservationCursor, hooks: [AppServerConfiguredHookSummary]) {
        self.cursor = cursor
        self.hooks = hooks
    }
}

public struct AppServerHookRunObservation: Equatable, Sendable {
    public let cursor: AppServerObservationCursor
    public let run: AppServerHookRunSummary

    public init(cursor: AppServerObservationCursor, run: AppServerHookRunSummary) {
        self.cursor = cursor
        self.run = run
    }
}

/// A bounded, shared cache for the filesystem-only part of Git projection.
/// Adapter values copied into concurrent qualification tasks retain this one
/// lock-protected cache instead of walking the same ancestor chain per row.
package final class AppServerGitProjectionCache: @unchecked Sendable {
    private struct Entry: Sendable {
        let repositoryRoot: String?
        let expiresAt: Date
    }

    private let maximumEntries: Int
    private let timeToLive: TimeInterval
    private let fileExists: @Sendable (String) -> Bool
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var recency: [String] = []

    package init(
        maximumEntries: Int = 1_024,
        timeToLive: TimeInterval = 300,
        fileExists: @escaping @Sendable (String) -> Bool = {
            FileManager.default.fileExists(atPath: $0)
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.maximumEntries = max(1, maximumEntries)
        self.timeToLive = max(0, timeToLive)
        self.fileExists = fileExists
        self.now = now
    }

    package func repositoryRoot(for workingDirectoryPath: String) -> String? {
        let key = URL(fileURLWithPath: workingDirectoryPath).standardizedFileURL.path
        let observedAt = now()
        lock.lock()
        if let entry = entries[key], entry.expiresAt >= observedAt {
            touchLocked(key)
            lock.unlock()
            return entry.repositoryRoot
        }
        entries.removeValue(forKey: key)
        recency.removeAll { $0 == key }
        lock.unlock()

        var candidate = URL(fileURLWithPath: key).standardizedFileURL
        let resolvedRoot: String?
        while true {
            if fileExists(candidate.appendingPathComponent(".git").path) {
                resolvedRoot = candidate.path
                break
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                resolvedRoot = nil
                break
            }
            candidate = parent
        }

        lock.lock()
        entries[key] = Entry(
            repositoryRoot: resolvedRoot,
            expiresAt: observedAt.addingTimeInterval(timeToLive)
        )
        touchLocked(key)
        while entries.count > maximumEntries, let evicted = recency.first {
            recency.removeFirst()
            entries.removeValue(forKey: evicted)
        }
        lock.unlock()
        return resolvedRoot
    }

    package func invalidateAll() {
        lock.lock()
        entries.removeAll(keepingCapacity: true)
        recency.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    private func touchLocked(_ key: String) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}

package struct AppServerLoadedThreadPage: Equatable, Sendable {
    package let threadIDs: [AppServerThreadID]
    package let nextCursor: String?

    package init(threadIDs: [AppServerThreadID], nextCursor: String?) {
        self.threadIDs = threadIDs
        self.nextCursor = nextCursor
    }
}

/// Reduces App Server wire values to bounded typed facts accepted by
/// `ConnDomain`. Only explicitly supported presentation fields cross this
/// seam. Raw reasoning, command output, patch diffs, tool arguments/results,
/// and arbitrary unknown fields are discarded.
public struct AppServerObservationAdapter: Sendable {
    private static let maximumMetadataBytes = 512
    private static let maximumMalformedRowsReported = 10_000
    public static let maximumRequestTextUTF8Bytes = 4 * 1_024
    public static let maximumRequestTextLineCount = 40
    public static let maximumStructuredQuestions = 8
    public static let maximumQuestionOptions = 16
    public static let maximumPermissionEntries = 64
    public static let maximumPermissionPaths = 64
    private let presentationLimits: AppServerItemPresentationLimits
    private let maximumTurnsPerThread: Int
    private let maximumItemsPerTurn: Int
    private let gitProjectionCache: AppServerGitProjectionCache

    public init(
        presentationLimits: AppServerItemPresentationLimits = .standard,
        maximumTurnsPerThread: Int = 20,
        maximumItemsPerTurn: Int = 100
    ) {
        self.presentationLimits = presentationLimits
        self.maximumTurnsPerThread = max(1, maximumTurnsPerThread)
        self.maximumItemsPerTurn = max(1, maximumItemsPerTurn)
        self.gitProjectionCache = AppServerGitProjectionCache()
    }

    package init(
        presentationLimits: AppServerItemPresentationLimits = .standard,
        maximumTurnsPerThread: Int = 20,
        maximumItemsPerTurn: Int = 100,
        gitProjectionCache: AppServerGitProjectionCache
    ) {
        self.presentationLimits = presentationLimits
        self.maximumTurnsPerThread = max(1, maximumTurnsPerThread)
        self.maximumItemsPerTurn = max(1, maximumItemsPerTurn)
        self.gitProjectionCache = gitProjectionCache
    }

    public func connectionIdentity(
        from identity: ConnAppServerConnectionIdentity
    ) -> AppServerConnectionIdentity {
        .init(instanceID: identity.instanceID, generation: identity.generation)
    }

    public func observationCursor(
        from envelope: ConnAppServerInboundEnvelope
    ) -> AppServerObservationCursor {
        .init(
            connection: connectionIdentity(from: envelope.connection),
            sequence: envelope.sequence
        )
    }

    public func projectionInput(
        from envelope: ConnAppServerInboundEnvelope,
        observedAt: Date
    ) throws -> AppServerProjectionInput? {
        let cursor = observationCursor(from: envelope)
        switch envelope.message {
        case let .notification(notification):
            return try projectionInput(
                from: notification,
                cursor: cursor,
                observedAt: observedAt
            )
        case let .request(request):
            return try projectionInput(
                from: request,
                cursor: cursor,
                observedAt: observedAt
            )
        }
    }

    public func connectionActivated(
        identity: AppServerConnectionIdentity,
        source: AppServerConnectionSource,
        serverVersion: SupportedAppServerVersion,
        mode: AppServerCapabilityMode = .stable
    ) -> AppServerProjectionInput {
        let policy = AppServerCompatibilityPolicy(version: serverVersion, mode: mode)
        var features: Set<AppServerFeature> = [.monitor]
        if policy.supports(method: "thread/start") { features.insert(.createThread) }
        if policy.supports(method: "turn/start") { features.insert(.followUp) }
        if policy.supports(method: "turn/steer") { features.insert(.steer) }
        if policy.supports(method: "turn/interrupt") { features.insert(.stopTurn) }
        let approvalMethods = [
            "item/commandExecution/requestApproval",
            "item/fileChange/requestApproval",
            "item/permissions/requestApproval",
        ]
        if approvalMethods.allSatisfy({ policy.supportsServerResponse(method: $0) }) {
            features.insert(.resolveApproval)
        }
        if policy.supportsServerResponse(method: "item/tool/requestUserInput") {
            features.insert(.answer)
        }
        return .connectionActivated(
            identity: identity,
            source: source,
            featureSupport: AppServerFeatureSupport(features: features)
        )
    }

    /// Decodes one complete, unpaginated `thread/list` result as the global
    /// hydration snapshot. Its cursor is taken from the correlated response so
    /// notifications received before and after it can be reduced truthfully.
    public func threadListSnapshot(
        response: ConnAppServerResponseEnvelope,
        observedAt: Date
    ) throws -> AppServerProjectionInput {
        let page = try threadListPage(response: response, observedAt: observedAt)
        guard !page.isTruncated else {
            throw AppServerObservationAdapterError.malformed(
                context: "thread/list result",
                field: "nextCursor"
            )
        }
        guard page.inventoryMembershipIsComplete else {
            throw AppServerObservationAdapterError.malformed(
                context: "thread/list result",
                field: "data.id"
            )
        }
        return .snapshot(.init(
            cursor: page.snapshot.cursor,
            observedAt: page.snapshot.observedAt,
            threads: page.snapshot.threads,
            threadFreshness: page.snapshot.threadFreshness,
            contentAuthority: page.snapshot.contentAuthority,
            inventoryAuthority: .authoritative,
            authoritativeThreadIDs: page.inventoryThreadIDs
        ))
    }

    /// Decodes one inventory page without widening it into global snapshot
    /// authority. Runtime callers continue through `nextCursor` until nil,
    /// including when this page's `data` array is empty, and may hydrate rows
    /// incrementally while assembling the authoritative inventory.
    public func threadListPage(
        response: ConnAppServerResponseEnvelope,
        observedAt: Date
    ) throws -> AppServerThreadListPage {
        let context = "thread/list result"
        let object = try requiredObject(response.result, context: context)
        let nextCursor: String?
        switch object["nextCursor"] {
        case nil, .some(.null), .some(.string("")):
            nextCursor = nil
        case let .some(.string(value)):
            nextCursor = value
        default:
            throw AppServerObservationAdapterError.malformed(
                context: context,
                field: "nextCursor"
            )
        }
        guard case let .array(values) = try requiredValue(object, "data", context: context) else {
            throw AppServerObservationAdapterError.malformed(context: context, field: "data")
        }
        var threads: [AppServerThreadInput] = []
        var inventoryThreadIDs = Set<AppServerThreadID>()
        var malformedRowCount = 0
        var inventoryMembershipIsComplete = true
        for value in values {
            do {
                let thread = try decodeThread(value, turnsAreAuthoritative: false)
                if inventoryThreadIDs.insert(thread.id).inserted {
                    threads.append(thread)
                }
            } catch {
                malformedRowCount = min(
                    Self.maximumMalformedRowsReported,
                    malformedRowCount + 1
                )
                if case let .object(row) = value,
                   let knownID = try? threadID(row, context: "Thread", field: "id") {
                    inventoryThreadIDs.insert(knownID)
                } else {
                    inventoryMembershipIsComplete = false
                }
            }
        }
        return AppServerThreadListPage(
            snapshot: .init(
                cursor: responseCursor(response),
                observedAt: observedAt,
                threads: threads
            ),
            nextCursor: nextCursor,
            inventoryThreadIDs: inventoryThreadIDs,
            malformedRowCount: malformedRowCount,
            inventoryMembershipIsComplete: inventoryMembershipIsComplete
        )
    }

    /// Decodes one schema-faithful `thread/loaded/list` page without loading
    /// thread history. The server's order is retained, with repeated IDs
    /// collapsed to their first occurrence so one usable page stays usable.
    package func threadLoadedListPage(
        response: ConnAppServerResponseEnvelope
    ) throws -> AppServerLoadedThreadPage {
        let context = "thread/loaded/list result"
        let object = try requiredObject(response.result, context: context)
        let nextCursor: String?
        switch object["nextCursor"] {
        case nil, .some(.null):
            nextCursor = nil
        case let .some(.string(value)):
            nextCursor = value.isEmpty ? nil : value
        default:
            throw AppServerObservationAdapterError.malformed(
                context: context,
                field: "nextCursor"
            )
        }

        guard case let .array(values) = try requiredValue(object, "data", context: context) else {
            throw AppServerObservationAdapterError.malformed(context: context, field: "data")
        }

        var seen = Set<AppServerThreadID>()
        var threadIDs: [AppServerThreadID] = []
        threadIDs.reserveCapacity(values.count)
        for value in values {
            guard case let .string(rawID) = value, !rawID.isEmpty else {
                throw AppServerObservationAdapterError.malformed(context: context, field: "data")
            }
            let threadID = AppServerThreadID(rawValue: rawID)
            if seen.insert(threadID).inserted { threadIDs.append(threadID) }
        }

        return AppServerLoadedThreadPage(
            threadIDs: threadIDs,
            nextCursor: nextCursor
        )
    }

    /// Decodes the metadata/status portion shared by `thread/read` and
    /// `thread/resume` without traversing their `turns` payload. The expected
    /// ID binds the correlated response to the qualification request.
    package func threadStatusDelta(
        response: ConnAppServerResponseEnvelope,
        expectedThreadID: AppServerThreadID,
        observedAt: Date
    ) throws -> AppServerProjectionInput {
        let context = "thread status result"
        let object = try requiredObject(response.result, context: context)
        let thread = try decodeThread(
            requiredValue(object, "thread", context: context),
            decodeTurns: false
        )
        guard thread.id == expectedThreadID else {
            throw AppServerObservationAdapterError.malformed(
                context: context,
                field: "thread.id"
            )
        }
        return .delta(.init(
            cursor: responseCursor(response),
            observedAt: observedAt,
            delta: .threadUpsert(thread)
        ))
    }

    /// A `thread/read(includeTurns: true)` response is authoritative only for
    /// that thread. Model it as a cursor-bearing upsert rather than a global
    /// snapshot so independently timed reads cannot delete or reorder peers.
    public func threadReadDelta(
        response: ConnAppServerResponseEnvelope,
        observedAt: Date
    ) throws -> AppServerProjectionInput {
        let context = "thread/read result"
        let object = try requiredObject(response.result, context: context)
        let thread = try decodeThread(
            requiredValue(object, "thread", context: context),
            turnsAreAuthoritative: true
        )
        return .delta(.init(
            cursor: responseCursor(response),
            observedAt: observedAt,
            delta: .threadUpsert(thread)
        ))
    }

    /// Decodes `hooks/list` into safe configuration summaries. Commands,
    /// working directories, source paths, hashes, matchers, warnings, errors,
    /// and status messages are intentionally never copied into the result.
    public func configuredHooks(
        response: ConnAppServerResponseEnvelope
    ) throws -> AppServerConfiguredHooksObservation {
        let context = "hooks/list result"
        let object = try requiredObject(response.result, context: context)
        guard case let .array(entries) = try requiredValue(object, "data", context: context) else {
            throw AppServerObservationAdapterError.malformed(context: context, field: "data")
        }
        var summaries: [AppServerConfiguredHookSummary] = []
        guard entries.count <= 32 else {
            throw AppServerObservationAdapterError.malformed(context: context, field: "data")
        }
        for entryValue in entries {
            let entry = try requiredObject(entryValue, context: context)
            _ = try requiredString(entry, "cwd", context: context)
            let errors = try requiredArray(entry, "errors", context: context)
            guard errors.count <= 256 else {
                throw AppServerObservationAdapterError.malformed(context: context, field: "errors")
            }
            for errorValue in errors {
                let error = try requiredObject(errorValue, context: context)
                _ = try requiredString(error, "message", context: context)
                _ = try requiredString(error, "path", context: context)
            }
            let warnings = try requiredArray(entry, "warnings", context: context)
            guard warnings.count <= 256 else {
                throw AppServerObservationAdapterError.malformed(context: context, field: "warnings")
            }
            for warning in warnings {
                guard case .string = warning else {
                    throw AppServerObservationAdapterError.malformed(context: context, field: "warnings")
                }
            }
            guard case let .array(hooks) = try requiredValue(entry, "hooks", context: context) else {
                throw AppServerObservationAdapterError.malformed(context: context, field: "hooks")
            }
            guard hooks.count <= AppServerHookProjectionStore.maximumConfiguredHooks else {
                throw AppServerObservationAdapterError.malformed(context: context, field: "hooks")
            }
            for hookValue in hooks {
                let hook = try requiredObject(hookValue, context: context)
                try validateOptionalNullableString(hook, "command", context: context)
                _ = try requiredString(hook, "currentHash", context: context)
                _ = try requiredInteger(hook, "displayOrder", context: context)
                _ = try requiredBool(hook, "isManaged", context: context)
                _ = try requiredString(hook, "key", context: context)
                try validateOptionalNullableString(hook, "matcher", context: context)
                try validateOptionalNullableString(hook, "pluginId", context: context)
                _ = try requiredString(hook, "sourcePath", context: context)
                try validateOptionalNullableString(hook, "statusMessage", context: context)
                guard try requiredInteger(hook, "timeoutSec", context: context) >= 0 else {
                    throw AppServerObservationAdapterError.malformed(context: context, field: "timeoutSec")
                }
                let event = try enumValue(
                    AppServerHookEventName.self, hook, "eventName", context: context
                )
                let handler = try enumValue(
                    AppServerHookHandlerType.self, hook, "handlerType", context: context
                )
                let source = try enumValue(
                    AppServerHookSource.self, hook, "source", context: context
                )
                let trust = try enumValue(
                    AppServerHookTrustStatus.self, hook, "trustStatus", context: context
                )
                let rawPluginID = optionalString(hook["pluginId"])
                let pluginID = rawPluginID.map { Self.boundedMetadata($0, maximumBytes: 128) }
                summaries.append(.init(
                    eventName: event,
                    handlerType: handler,
                    source: source,
                    enabled: try requiredBool(hook, "enabled", context: context),
                    trustStatus: trust,
                    pluginID: pluginID
                ))
                guard summaries.count <= AppServerHookProjectionStore.maximumConfiguredHooks else {
                    throw AppServerObservationAdapterError.malformed(
                        context: context, field: "data.hooks"
                    )
                }
            }
        }
        return .init(cursor: responseCursor(response), hooks: summaries)
    }

    /// Decodes only the bounded lifecycle identity/status fields from
    /// `hook/started` and `hook/completed` notifications.
    public func hookRun(
        from envelope: ConnAppServerInboundEnvelope
    ) throws -> AppServerHookRunObservation? {
        guard case let .notification(notification) = envelope.message,
              notification.method == "hook/started" || notification.method == "hook/completed"
        else { return nil }
        let context = notification.method
        guard let params = notification.params else {
            throw AppServerObservationAdapterError.malformed(context: context, field: "params")
        }
        let object = try requiredObject(params, context: context)
        let runObject = try requiredObject(
            requiredValue(object, "run", context: context), context: context
        )
        let rawID = try requiredString(runObject, "id", context: context)
        guard !rawID.isEmpty, rawID.utf8.count <= 512 else {
            throw AppServerObservationAdapterError.malformed(context: context, field: "run.id")
        }
        let completedAt = try optionalMillisecondsDate(
            runObject["completedAt"], context: context, field: "run.completedAt"
        )
        _ = try requiredInteger(runObject, "displayOrder", context: context)
        let entries = try requiredArray(runObject, "entries", context: context)
        guard entries.count <= 256 else {
            throw AppServerObservationAdapterError.malformed(context: context, field: "entries")
        }
        let allowedEntryKinds: Set<String> = ["warning", "stop", "feedback", "context", "error"]
        for entryValue in entries {
            let entry = try requiredObject(entryValue, context: context)
            let kind = try requiredString(entry, "kind", context: context)
            guard allowedEntryKinds.contains(kind) else {
                throw AppServerObservationAdapterError.malformed(context: context, field: "entries.kind")
            }
            _ = try requiredString(entry, "text", context: context)
        }
        _ = try requiredString(runObject, "sourcePath", context: context)
        let run = AppServerHookRunSummary(
            id: rawID,
            threadID: try threadID(object, context: context),
            turnID: try optionalTurnID(object["turnId"], context: context),
            eventName: try enumValue(
                AppServerHookEventName.self, runObject, "eventName", context: context
            ),
            executionMode: try enumValue(
                AppServerHookExecutionMode.self, runObject, "executionMode", context: context
            ),
            handlerType: try enumValue(
                AppServerHookHandlerType.self, runObject, "handlerType", context: context
            ),
            scope: try enumValue(
                AppServerHookScope.self, runObject, "scope", context: context
            ),
            status: try enumValue(
                AppServerHookRunStatus.self, runObject, "status", context: context
            ),
            startedAt: try millisecondsDate(runObject, "startedAt", context: context),
            completedAt: completedAt
        )
        return .init(cursor: observationCursor(from: envelope), run: run)
    }

    private func responseCursor(
        _ response: ConnAppServerResponseEnvelope
    ) -> AppServerObservationCursor {
        .init(
            connection: connectionIdentity(from: response.connection),
            sequence: response.sequence
        )
    }

    /// Returns nil for methods outside the Phase 7 projection contract.
    /// A known method with malformed required correlation fails locally.
    public func projectionInput(
        from notification: JSONRPCNotification,
        cursor: AppServerObservationCursor,
        observedAt: Date
    ) throws -> AppServerProjectionInput? {
        let context = notification.method
        guard Self.knownNotificationMethods.contains(notification.method) else {
            return nil
        }
        guard let params = notification.params else {
            throw AppServerObservationAdapterError.malformed(context: context, field: "params")
        }
        let object = try requiredObject(params, context: context)
        let delta: AppServerProjectionDelta

        switch notification.method {
        case "thread/started":
            delta = .threadUpsert(try decodeThread(requiredValue(object, "thread", context: context)))

        case "thread/status/changed":
            delta = .threadStatus(
                threadID: try threadID(object, context: context),
                status: try decodeThreadStatus(requiredValue(object, "status", context: context))
            )

        case "thread/archived", "thread/deleted":
            delta = .threadRemoved(try threadID(object, context: context))

        case "thread/closed":
            // App Server emits `thread/closed` when an unloaded persisted
            // thread's in-memory session ends; it is not archive or deletion.
            // Keep the successfully qualified row and reflect that it is no
            // longer loaded so multi-thread history does not collapse to the
            // last live session.
            delta = .threadStatus(
                threadID: try threadID(object, context: context),
                status: .notLoaded
            )

        case "turn/started", "turn/completed":
            // The projection store derives the sole authoritative Outcome from
            // terminal Turn.status; emitting a second fact would invent a
            // second receive cursor for one notification.
            delta = .turnUpsert(
                threadID: try threadID(object, context: context),
                turn: try decodeTurn(requiredValue(object, "turn", context: context))
            )

        case "item/started":
            delta = .itemUpsert(
                threadID: try threadID(object, context: context),
                turnID: try turnID(object, context: context),
                item: try decodeItem(
                    requiredValue(object, "item", context: context),
                    lifecycleStatus: .started,
                    startedAt: try millisecondsDate(object, "startedAtMs", context: context),
                    completedAt: nil
                )
            )

        case "item/completed":
            delta = .itemUpsert(
                threadID: try threadID(object, context: context),
                turnID: try turnID(object, context: context),
                item: try decodeItem(
                    requiredValue(object, "item", context: context),
                    lifecycleStatus: .completed,
                    startedAt: nil,
                    completedAt: try millisecondsDate(object, "completedAtMs", context: context)
                )
            )

        case "item/agentMessage/delta":
            delta = .itemPresentationDelta(
                threadID: try threadID(object, context: context),
                turnID: try turnID(object, context: context),
                itemID: try itemID(object, context: context),
                delta: .agentText(boundedText(
                    try requiredString(object, "delta", context: context),
                    maximumBytes: presentationLimits.maximumTextUTF8Bytes,
                    maximumLines: presentationLimits.maximumTextLineCount
                ))
            )

        case "item/reasoning/summaryPartAdded":
            delta = .itemPresentationDelta(
                threadID: try threadID(object, context: context),
                turnID: try turnID(object, context: context),
                itemID: try itemID(object, context: context),
                delta: .reasoningSummaryPartAdded(
                    index: try decodeSummaryIndex(object, context: context)
                )
            )

        case "item/reasoning/summaryTextDelta":
            delta = .itemPresentationDelta(
                threadID: try threadID(object, context: context),
                turnID: try turnID(object, context: context),
                itemID: try itemID(object, context: context),
                delta: .reasoningSummaryText(
                    index: try decodeSummaryIndex(object, context: context),
                    text: boundedText(
                        try requiredString(object, "delta", context: context),
                        maximumBytes: presentationLimits.maximumTextUTF8Bytes,
                        maximumLines: presentationLimits.maximumTextLineCount
                    )
                )
            )

        case "thread/tokenUsage/updated":
            delta = .threadTokenUsage(
                threadID: try threadID(object, context: context),
                turnID: try turnID(object, context: context),
                usage: try decodeTokenUsage(
                    requiredValue(object, "tokenUsage", context: context),
                    context: context
                )
            )

        case "turn/plan/updated":
            switch object["explanation"] {
            case nil, .some(.null), .some(.string):
                break
            default:
                throw AppServerObservationAdapterError.malformed(
                    context: context,
                    field: "explanation"
                )
            }
            let planValue = try requiredValue(object, "plan", context: context)
            guard case let .array(values) = planValue else {
                throw AppServerObservationAdapterError.malformed(
                    context: context,
                    field: "plan"
                )
            }
            let steps = try values.prefix(presentationLimits.maximumPlanSteps).map { value in
                let step = try requiredObject(value, context: context)
                return AppServerTurnPlanStep(
                    step: boundedText(
                        try requiredString(step, "step", context: context),
                        maximumBytes: presentationLimits.maximumPlanStepUTF8Bytes,
                        maximumLines: 1
                    ),
                    status: AppServerTurnPlanStepStatus(
                        rawValue: try requiredString(step, "status", context: context)
                    ) ?? .unknown
                )
            }
            delta = .turnPlanUpdated(
                threadID: try threadID(object, context: context),
                turnID: try turnID(object, context: context),
                plan: .init(steps: steps, updatedAt: observedAt)
            )

        case "serverRequest/resolved":
            delta = .requestResolved(
                threadID: try threadID(object, context: context),
                requestID: try requestID(
                    requiredValue(object, "requestId", context: context),
                    context: context
                )
            )

        default:
            return nil
        }

        return .delta(.init(cursor: cursor, observedAt: observedAt, delta: delta))
    }

    /// Decodes approval and structured-question server requests without
    /// retaining the operation, question text, choices, secret semantics, or
    /// any arbitrary payload. Unknown requests remain owned by the connection
    /// layer and do not become product attention state.
    public func projectionInput(
        from request: JSONRPCRequest,
        cursor: AppServerObservationCursor,
        observedAt: Date
    ) throws -> AppServerProjectionInput? {
        let kind: AppServerRequestKind
        let requiresUpstreamStartTime: Bool
        switch request.method {
        case "item/commandExecution/requestApproval":
            kind = .commandApproval
            requiresUpstreamStartTime = true
        case "item/fileChange/requestApproval":
            kind = .fileChangeApproval
            requiresUpstreamStartTime = true
        case "item/permissions/requestApproval":
            kind = .permissionsApproval
            requiresUpstreamStartTime = true
        case "item/tool/requestUserInput":
            kind = .structuredQuestion
            requiresUpstreamStartTime = false
        case "mcpServer/elicitation/request":
            kind = .mcpElicitation
            requiresUpstreamStartTime = false
        default:
            return nil
        }

        let context = request.method
        guard let params = request.params else {
            throw AppServerObservationAdapterError.malformed(context: context, field: "params")
        }
        let object = try requiredObject(params, context: context)
        let facts: AppServerRequestFacts
        if kind == .structuredQuestion {
            if let questionFacts = try structuredQuestionFacts(object, context: context) {
                facts = .structuredQuestions(questionFacts)
            } else {
                facts = .unsupported
            }
        } else if kind == .mcpElicitation {
            try validateMCPElicitation(object, context: context)
            facts = .unsupported
        } else if kind == .permissionsApproval {
            let workingDirectory = try requiredString(object, "cwd", context: context)
            if workingDirectory.utf8.count <= Self.maximumRequestTextUTF8Bytes,
               let permissions = try requestedPermissionProfile(
                    requiredValue(object, "permissions", context: context),
                    context: context
               ) {
                facts = .permissionsApproval(.init(
                    workingDirectory: workingDirectory,
                    reason: try boundedOptionalRequestText(
                        object["reason"], field: "reason", context: context
                    ),
                    requestedPermissions: permissions
                ))
            } else {
                facts = .unsupported
            }
        } else if kind == .commandApproval {
            facts = .commandApproval(.init(
                command: try boundedOptionalRequestText(
                    object["command"], field: "command", context: context
                ),
                workingDirectory: try boundedOptionalRequestText(
                    object["cwd"], field: "cwd", context: context, maximumLines: 1
                ),
                reason: try boundedOptionalRequestText(
                    object["reason"], field: "reason", context: context
                )
            ))
        } else if kind == .fileChangeApproval {
            facts = .fileChangeApproval(.init(
                reason: try boundedOptionalRequestText(
                    object["reason"], field: "reason", context: context
                ),
                grantRoot: try boundedOptionalRequestText(
                    object["grantRoot"], field: "grantRoot", context: context, maximumLines: 1
                )
            ))
        } else {
            facts = .unsupported
        }

        let startedAt = requiresUpstreamStartTime
            ? try millisecondsDate(object, "startedAtMs", context: context)
            : observedAt // requestUserInput has no upstream timestamp in the stable schema.
        let mappedTurnID: AppServerTurnID? = if kind == .mcpElicitation {
            try optionalTurnID(object["turnId"], context: context)
        } else {
            try turnID(object, context: context)
        }
        let input = AppServerRequestInput(
            requestID: mapRequestID(request.id),
            threadID: try threadID(object, context: context),
            turnID: mappedTurnID,
            itemID: kind == .mcpElicitation ? nil : try itemID(object, context: context),
            kind: kind,
            facts: facts,
            startedAt: startedAt
        )
        return .delta(.init(cursor: cursor, observedAt: observedAt, delta: .requestOpened(input)))
    }

    private func structuredQuestionFacts(
        _ object: [String: JSONValue],
        context: String
    ) throws -> AppServerStructuredQuestionFacts? {
        guard case let .array(rawQuestions) = try requiredValue(
            object, "questions", context: context
        ) else {
            throw AppServerObservationAdapterError.malformed(context: context, field: "questions")
        }
        guard !rawQuestions.isEmpty,
              rawQuestions.count <= Self.maximumStructuredQuestions else { return nil }

        var seenIDs: Set<String> = []
        var questions: [AppServerStructuredQuestion] = []
        for rawQuestion in rawQuestions {
            let question = try requiredObject(rawQuestion, context: context)
            let id = try requiredString(question, "id", context: context)
            let header = try requiredString(question, "header", context: context)
            let prompt = try requiredString(question, "question", context: context)
            guard !id.isEmpty,
                  id.utf8.count <= Self.maximumMetadataBytes,
                  seenIDs.insert(id).inserted else { return nil }

            let options: [AppServerQuestionOption]?
            switch question["options"] {
            case nil, .some(.null):
                options = nil
            case let .some(.array(rawOptions)):
                guard rawOptions.count <= Self.maximumQuestionOptions else { return nil }
                var decoded: [AppServerQuestionOption] = []
                for rawOption in rawOptions {
                    let option = try requiredObject(rawOption, context: context)
                    let label = try requiredString(option, "label", context: context)
                    guard !label.isEmpty,
                          label.utf8.count <= Self.maximumRequestTextUTF8Bytes else {
                        return nil
                    }
                    decoded.append(.init(
                        label: label,
                        detail: boundedRequestText(
                            try requiredString(option, "description", context: context)
                        )
                    ))
                }
                options = decoded
            case .some:
                throw AppServerObservationAdapterError.malformed(context: context, field: "options")
            }

            questions.append(.init(
                id: id,
                header: boundedRequestText(header, maximumLines: 1),
                prompt: boundedRequestText(prompt),
                options: options,
                permitsOther: try optionalBool(
                    question["isOther"], field: "isOther", context: context
                ) ?? false,
                isSecret: try optionalBool(
                    question["isSecret"], field: "isSecret", context: context
                ) ?? false
            ))
        }

        let autoResolutionMilliseconds: UInt64?
        switch object["autoResolutionMs"] {
        case nil, .some(.null):
            autoResolutionMilliseconds = nil
        case let .some(.integer(value)) where value >= 0:
            autoResolutionMilliseconds = UInt64(value)
        case .some:
            throw AppServerObservationAdapterError.malformed(
                context: context,
                field: "autoResolutionMs"
            )
        }
        return .init(
            questions: questions,
            autoResolutionMilliseconds: autoResolutionMilliseconds
        )
    }

    private func requestedPermissionProfile(
        _ value: JSONValue,
        context: String
    ) throws -> AppServerRequestedPermissionProfile? {
        let object = try requiredObject(value, context: context)
        let fileSystem: AppServerRequestedFileSystemPermissions?
        switch object["fileSystem"] {
        case nil, .some(.null):
            fileSystem = nil
        case let .some(value):
            guard let decoded = try requestedFileSystemPermissions(value, context: context) else {
                return nil
            }
            fileSystem = decoded
        }

        let network: AppServerRequestedNetworkPermissions?
        switch object["network"] {
        case nil, .some(.null):
            network = nil
        case let .some(value):
            let networkObject = try requiredObject(value, context: context)
            network = .init(enabled: try optionalBool(
                networkObject["enabled"], field: "permissions.network.enabled", context: context
            ))
        }
        return .init(fileSystem: fileSystem, network: network)
    }

    private func requestedFileSystemPermissions(
        _ value: JSONValue,
        context: String
    ) throws -> AppServerRequestedFileSystemPermissions? {
        let object = try requiredObject(value, context: context)
        let entries: [AppServerFileSystemPermissionEntry]?
        switch object["entries"] {
        case nil, .some(.null):
            entries = nil
        case let .some(.array(rawEntries)):
            guard rawEntries.count <= Self.maximumPermissionEntries else { return nil }
            var decoded: [AppServerFileSystemPermissionEntry] = []
            for rawEntry in rawEntries {
                let entry = try requiredObject(rawEntry, context: context)
                guard let access = AppServerFileSystemAccess(rawValue: try requiredString(
                    entry, "access", context: context
                )) else {
                    throw AppServerObservationAdapterError.malformed(
                        context: context,
                        field: "permissions.fileSystem.entries.access"
                    )
                }
                guard let path = try fileSystemPath(
                    requiredValue(entry, "path", context: context),
                    context: context
                ) else { return nil }
                decoded.append(.init(access: access, path: path))
            }
            entries = decoded
        case .some:
            throw AppServerObservationAdapterError.malformed(
                context: context,
                field: "permissions.fileSystem.entries"
            )
        }

        let readPathsResult = try permissionPathArray(
            object["read"], field: "permissions.fileSystem.read", context: context
        )
        let writePathsResult = try permissionPathArray(
            object["write"], field: "permissions.fileSystem.write", context: context
        )
        guard case let .value(readPaths) = readPathsResult,
              case let .value(writePaths) = writePathsResult else { return nil }

        let depth: UInt?
        switch object["globScanMaxDepth"] {
        case nil, .some(.null): depth = nil
        case let .some(.integer(value)) where value > 0: depth = UInt(value)
        case .some:
            throw AppServerObservationAdapterError.malformed(
                context: context,
                field: "permissions.fileSystem.globScanMaxDepth"
            )
        }
        return .init(
            entries: entries,
            globScanMaximumDepth: depth,
            readPaths: readPaths,
            writePaths: writePaths
        )
    }

    private enum PermissionPathArrayResult {
        case value([String]?)
        case unsupported
    }

    private func permissionPathArray(
        _ value: JSONValue?,
        field: String,
        context: String
    ) throws -> PermissionPathArrayResult {
        switch value {
        case nil, .some(.null): return .value(nil)
        case let .some(.array(values)):
            guard values.count <= Self.maximumPermissionPaths else {
                return .unsupported
            }
            var paths: [String] = []
            for value in values {
                guard case let .string(path) = value else {
                    throw AppServerObservationAdapterError.malformed(context: context, field: field)
                }
                guard path.utf8.count <= Self.maximumRequestTextUTF8Bytes else {
                    return .unsupported
                }
                paths.append(path)
            }
            return .value(paths)
        case .some:
            throw AppServerObservationAdapterError.malformed(context: context, field: field)
        }
    }

    private func fileSystemPath(
        _ value: JSONValue,
        context: String
    ) throws -> AppServerFileSystemPath? {
        let object = try requiredObject(value, context: context)
        switch try requiredString(object, "type", context: context) {
        case "path":
            let path = try requiredString(object, "path", context: context)
            return path.utf8.count <= Self.maximumRequestTextUTF8Bytes ? .path(path) : nil
        case "glob_pattern":
            let pattern = try requiredString(object, "pattern", context: context)
            return pattern.utf8.count <= Self.maximumRequestTextUTF8Bytes
                ? .globPattern(pattern)
                : nil
        case "special":
            let special = try requiredObject(
                requiredValue(object, "value", context: context),
                context: context
            )
            switch try requiredString(special, "kind", context: context) {
            case "root": return .special(.root)
            case "minimal": return .special(.minimal)
            case "project_roots":
                guard case let .value(subpath) = try exactOptionalRequestText(
                    special["subpath"], field: "subpath", context: context, maximumLines: 1
                ) else { return nil }
                return .special(.projectRoots(subpath: subpath))
            case "tmpdir": return .special(.temporaryDirectory)
            case "slash_tmp": return .special(.slashTemporaryDirectory)
            case "unknown":
                let path = try requiredString(special, "path", context: context)
                guard path.utf8.count <= Self.maximumRequestTextUTF8Bytes else { return nil }
                guard case let .value(subpath) = try exactOptionalRequestText(
                    special["subpath"], field: "subpath", context: context, maximumLines: 1
                ) else { return nil }
                return .special(.unknown(path: path, subpath: subpath))
            default:
                return nil
            }
        default:
            throw AppServerObservationAdapterError.malformed(
                context: context,
                field: "permissions.fileSystem.entries.path.type"
            )
        }
    }

    private enum ExactOptionalRequestTextResult {
        case value(String?)
        case unsupported
    }

    private func exactOptionalRequestText(
        _ value: JSONValue?,
        field: String,
        context: String,
        maximumLines: Int
    ) throws -> ExactOptionalRequestTextResult {
        switch value {
        case nil, .some(.null):
            return .value(nil)
        case let .some(.string(value)):
            guard value.utf8.count <= Self.maximumRequestTextUTF8Bytes,
                  lineCount(value) <= maximumLines else {
                return .unsupported
            }
            return .value(value)
        case .some:
            throw AppServerObservationAdapterError.malformed(context: context, field: field)
        }
    }

    private func boundedOptionalRequestText(
        _ value: JSONValue?,
        field: String,
        context: String,
        maximumLines: Int = maximumRequestTextLineCount
    ) throws -> String? {
        switch value {
        case nil, .some(.null): return nil
        case let .some(.string(value)):
            return boundedRequestText(value, maximumLines: maximumLines)
        case .some:
            throw AppServerObservationAdapterError.malformed(context: context, field: field)
        }
    }

    private func optionalBool(
        _ value: JSONValue?,
        field: String,
        context: String
    ) throws -> Bool? {
        switch value {
        case nil, .some(.null): return nil
        case let .some(.bool(value)): return value
        case .some:
            throw AppServerObservationAdapterError.malformed(context: context, field: field)
        }
    }

    private func boundedRequestText(
        _ value: String,
        maximumLines: Int = maximumRequestTextLineCount
    ) -> String {
        boundedText(
            value,
            maximumBytes: Self.maximumRequestTextUTF8Bytes,
            maximumLines: maximumLines
        )
    }

    private func decodeThread(
        _ value: JSONValue,
        turnsAreAuthoritative: Bool = false,
        decodeTurns: Bool = true
    ) throws -> AppServerThreadInput {
        let context = "Thread"
        let object = try requiredObject(value, context: context)
        let id = try threadID(object, context: context, field: "id")

        // Validate stable required identity even where the current domain
        // projection does not yet expose every field.
        let sessionRawValue = try requiredString(object, "sessionId", context: context)
        guard !sessionRawValue.isEmpty else {
            throw AppServerObservationAdapterError.malformed(context: context, field: "sessionId")
        }
        let sessionID = AppServerSessionID(rawValue: sessionRawValue)
        _ = try requiredString(object, "cliVersion", context: context)
        _ = try requiredString(object, "modelProvider", context: context)
        _ = try requiredString(object, "preview", context: context)
        _ = try requiredBool(object, "ephemeral", context: context)

        let cwd = try requiredString(object, "cwd", context: context)
        let git = try gitProjection(
            workingDirectoryPath: cwd,
            gitInfo: object["gitInfo"],
            context: context
        )
        let turnValues: [JSONValue]
        if decodeTurns {
            let turnsValue = try requiredValue(object, "turns", context: context)
            guard case let .array(values) = turnsValue else {
                throw AppServerObservationAdapterError.malformed(context: context, field: "turns")
            }
            turnValues = values
        } else {
            turnValues = []
        }

        return AppServerThreadInput(
            id: id,
            sessionID: sessionID,
            title: optionalString(object["name"]).map(Self.boundedTitle),
            workingDirectoryName: Self.workingDirectoryName(cwd),
            workingDirectoryPath: cwd,
            projectRootPath: git.projectRootPath,
            gitBranch: git.branch,
            source: try decodeThreadSource(try requiredValue(object, "source", context: context)),
            parentThreadID: optionalString(object["parentThreadId"]).map(AppServerThreadID.init(rawValue:)),
            forkedFromThreadID: optionalString(object["forkedFromId"]).map(AppServerThreadID.init(rawValue:)),
            status: try decodeThreadStatus(try requiredValue(object, "status", context: context)),
            createdAt: try secondsDate(object, "createdAt", context: context),
            updatedAt: try secondsDate(object, "updatedAt", context: context),
            turnsAreAuthoritative: decodeTurns && turnsAreAuthoritative,
            // App Server returns turns oldest-first. Keep the newest bounded
            // suffix so an otherwise valid long thread still reaches the
            // projection instead of being rejected wholesale by its limits.
            turns: try turnValues.suffix(maximumTurnsPerThread).map(decodeTurn)
        )
    }

    private func decodeTurn(_ value: JSONValue) throws -> AppServerTurnInput {
        let context = "Turn"
        let object = try requiredObject(value, context: context)
        let itemsValue = try requiredValue(object, "items", context: context)
        guard case let .array(itemValues) = itemsValue else {
            throw AppServerObservationAdapterError.malformed(context: context, field: "items")
        }

        let itemsView: AppServerTurnItemsView
        switch object["itemsView"] {
        case nil, .some(.null): itemsView = .full
        case .some(.string("notLoaded")): itemsView = .notLoaded
        case .some(.string("summary")): itemsView = .summary
        case .some(.string("full")): itemsView = .full
        case .some(.string): itemsView = .notLoaded
        default:
            throw AppServerObservationAdapterError.malformed(
                context: context,
                field: "itemsView"
            )
        }

        return AppServerTurnInput(
            id: try turnID(object, context: context, field: "id"),
            status: try decodeTurnStatus(requiredString(object, "status", context: context)),
            startedAt: try optionalSecondsDate(object["startedAt"], context: context, field: "startedAt"),
            completedAt: try optionalSecondsDate(object["completedAt"], context: context, field: "completedAt"),
            itemsView: itemsView,
            // Items are likewise chronological. The bounded suffix preserves
            // the newest inspectable activity and remains deterministic.
            items: try itemValues.suffix(maximumItemsPerTurn).map { try decodeItem($0) }
        )
    }

    private func decodeItem(
        _ value: JSONValue,
        lifecycleStatus: AppServerItemStatus? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) throws -> AppServerItemInput {
        let context = "ThreadItem"
        let object = try requiredObject(value, context: context)
        let type = try requiredString(object, "type", context: context)
        let kind = decodeItemKind(type)
        try validateKnownItem(object, kind: kind, context: context)
        let embeddedStatus = decodeItemStatus(optionalString(object["status"]))
        let status: AppServerItemStatus
        if lifecycleStatus == .completed, embeddedStatus == .failed {
            status = .failed
        } else if let lifecycleStatus {
            status = lifecycleStatus
        } else if itemKindHasNoStatus(kind) {
            // Stable ThreadItem history has no status member for these kinds.
            // Their presence in a read/resume response is a complete fact, not
            // an indeterminate lifecycle transition.
            status = .completed
        } else {
            status = embeddedStatus
        }

        return AppServerItemInput(
            id: try itemID(object, context: context, field: "id"),
            kind: kind,
            status: status,
            startedAt: startedAt,
            completedAt: completedAt,
            presentation: try decodePresentation(object, kind: kind, context: context)
        )
    }

    private func decodePresentation(
        _ object: [String: JSONValue],
        kind: AppServerItemKind,
        context: String
    ) throws -> AppServerItemPresentationPayload? {
        let limits = presentationLimits
        switch kind {
        case .userMessage:
            return try decodeUserMessageText(object, context: context)

        case .agentMessage:
            let text = boundedText(
                try requiredString(object, "text", context: context),
                maximumBytes: limits.maximumTextUTF8Bytes,
                maximumLines: limits.maximumTextLineCount
            )
            switch object["phase"] {
            case .some(.string("final_answer")):
                return .agentFinalText(text)
            case nil, .some(.null), .some(.string("commentary")), .some(.string):
                // Phase is optional and providers do not emit it consistently.
                // Preserve the legacy message behavior unless finality is explicit.
                return .agentText(text)
            default:
                throw AppServerObservationAdapterError.malformed(
                    context: context,
                    field: "phase"
                )
            }

        case .plan:
            return .planText(boundedText(
                try requiredString(object, "text", context: context),
                maximumBytes: limits.maximumTextUTF8Bytes,
                maximumLines: limits.maximumTextLineCount
            ))

        case .reasoning:
            guard let summary = object["summary"] else { return nil }
            guard case let .array(values) = summary else {
                throw AppServerObservationAdapterError.malformed(
                    context: context,
                    field: "summary"
                )
            }
            var remainingBytes = limits.maximumTextUTF8Bytes
            var remainingLines = limits.maximumTextLineCount
            var parts: [String] = []
            for value in values.prefix(limits.maximumReasoningSummaryParts) {
                guard case let .string(rawPart) = value else {
                    throw AppServerObservationAdapterError.malformed(
                        context: context,
                        field: "summary"
                    )
                }
                guard remainingBytes > 0, remainingLines > 0 else { break }
                let part = boundedText(
                    rawPart,
                    maximumBytes: remainingBytes,
                    maximumLines: remainingLines
                )
                parts.append(part)
                remainingBytes -= part.utf8.count
                remainingLines -= lineCount(part)
            }
            return parts.isEmpty ? nil : .reasoningSummary(parts)

        case .commandExecution:
            return .command(boundedText(
                try requiredString(object, "command", context: context),
                maximumBytes: limits.maximumTextUTF8Bytes,
                maximumLines: limits.maximumTextLineCount
            ))

        case .fileChange:
            guard case let .array(values) = try requiredValue(
                object,
                "changes",
                context: context
            ) else {
                throw AppServerObservationAdapterError.malformed(
                    context: context,
                    field: "changes"
                )
            }
            var changes: [AppServerFileChangePresentation] = []
            for value in values.prefix(limits.maximumFileChanges) {
                let change = try requiredObject(value, context: context)
                let rawPath = try requiredString(change, "path", context: context)
                guard !rawPath.isEmpty else { continue }
                let kindObject = try requiredObject(
                    requiredValue(change, "kind", context: context),
                    context: context
                )
                let rawKind = try requiredString(kindObject, "type", context: context)
                let counts = diffLineCounts(
                    try requiredString(change, "diff", context: context)
                )
                changes.append(.init(
                    path: boundedText(
                        rawPath,
                        maximumBytes: limits.maximumPathUTF8Bytes,
                        maximumLines: 1
                    ),
                    kind: AppServerFileChangeKind(rawValue: rawKind) ?? .unknown,
                    additions: counts.additions,
                    deletions: counts.deletions
                ))
            }
            return changes.isEmpty ? nil : .fileChanges(changes)

        case .mcpToolCall:
            let name = boundedName(try requiredString(object, "tool", context: context))
            guard !name.isEmpty else { return nil }
            let server = boundedName(try requiredString(object, "server", context: context))
            return .tool(
                name: name,
                server: server.isEmpty ? nil : server
            )

        case .dynamicToolCall, .collabAgentToolCall:
            let name = boundedName(try requiredString(object, "tool", context: context))
            guard !name.isEmpty else { return nil }
            return .tool(
                name: name,
                server: nil
            )

        case .hookPrompt, .subagentActivity, .webSearch, .imageView,
             .sleep, .imageGeneration, .enteredReviewMode, .exitedReviewMode,
             .contextCompaction, .unknown:
            return nil
        }
    }

    private func decodeUserMessageText(
        _ object: [String: JSONValue],
        context: String
    ) throws -> AppServerItemPresentationPayload? {
        guard case let .array(values) = try requiredValue(object, "content", context: context) else {
            throw AppServerObservationAdapterError.malformed(context: context, field: "content")
        }
        var textParts: [String] = []
        for value in values {
            let input = try requiredObject(value, context: context)
            switch try requiredString(input, "type", context: context) {
            case "text":
                let text = try requiredString(input, "text", context: context)
                if let elements = input["text_elements"], case .array = elements {
                    // UI-defined spans are validated structurally but not retained.
                } else if input["text_elements"] != nil {
                    throw AppServerObservationAdapterError.malformed(
                        context: context,
                        field: "text_elements"
                    )
                }
                textParts.append(text)
            case "image":
                _ = try requiredString(input, "url", context: context)
                if let detail = input["detail"] {
                    switch detail {
                    case .null:
                        break
                    case let .string(value) where ["auto", "low", "high", "original"].contains(value):
                        break
                    default:
                        throw AppServerObservationAdapterError.malformed(
                            context: context,
                            field: "content.detail"
                        )
                    }
                }
            case "localImage":
                _ = try requiredString(input, "path", context: context)
                if let detail = input["detail"] {
                    switch detail {
                    case .null:
                        break
                    case let .string(value) where ["auto", "low", "high", "original"].contains(value):
                        break
                    default:
                        throw AppServerObservationAdapterError.malformed(
                            context: context,
                            field: "content.detail"
                        )
                    }
                }
            case "skill", "mention":
                _ = try requiredString(input, "name", context: context)
                _ = try requiredString(input, "path", context: context)
            default:
                throw AppServerObservationAdapterError.malformed(
                    context: context,
                    field: "content.type"
                )
            }
        }
        guard !textParts.isEmpty else { return nil }
        return .userText(boundedText(
            textParts.joined(separator: "\n"),
            maximumBytes: presentationLimits.maximumTextUTF8Bytes,
            maximumLines: presentationLimits.maximumTextLineCount
        ))
    }

    private func decodeTokenUsage(
        _ value: JSONValue,
        context: String
    ) throws -> AppServerTokenUsage {
        let tokenUsage = try requiredObject(value, context: context)
        let last = try decodeTokenUsageBreakdown(
            requiredValue(tokenUsage, "last", context: context),
            context: context,
            field: "tokenUsage.last"
        )
        _ = try decodeTokenUsageBreakdown(
            requiredValue(tokenUsage, "total", context: context),
            context: context,
            field: "tokenUsage.total"
        )
        let contextWindow: Int64?
        switch tokenUsage["modelContextWindow"] {
        case nil, .some(.null):
            contextWindow = nil
        case let .some(.integer(value)) where value > 0:
            contextWindow = value
        default:
            throw AppServerObservationAdapterError.malformed(
                context: context,
                field: "tokenUsage.modelContextWindow"
            )
        }
        // `total` is lifetime-cumulative usage for the thread and can exceed a
        // model's context window after several turns. The context ring is a
        // current-window gauge, so it must use the latest turn breakdown.
        return .init(usedTokens: last, contextWindow: contextWindow)
    }

    private func decodeSummaryIndex(
        _ object: [String: JSONValue],
        context: String
    ) throws -> Int {
        guard case let .integer(index) = try requiredValue(
            object,
            "summaryIndex",
            context: context
        ), index >= 0,
           index < Int64(min(
               presentationLimits.maximumReasoningSummaryParts,
               presentationLimits.maximumTextLineCount
           )) else {
            throw AppServerObservationAdapterError.malformed(
                context: context,
                field: "summaryIndex"
            )
        }
        return Int(index)
    }

    /// Derives presentation-only line totals without retaining patch text.
    /// Counts saturate so a pathological diff cannot overflow an integer or
    /// produce an unbounded accessibility label.
    private func diffLineCounts(_ diff: String) -> (additions: Int, deletions: Int) {
        let maximumCount = 999_999
        var additions = 0
        var deletions = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let isFileHeader = line.hasPrefix("+++ ")
                || line.hasPrefix("+++\t")
                || line.hasPrefix("--- ")
                || line.hasPrefix("---\t")
            if isFileHeader { continue }
            if line.first == "+", additions < maximumCount {
                additions += 1
            } else if line.first == "-", deletions < maximumCount {
                deletions += 1
            }
            if additions == maximumCount, deletions == maximumCount { break }
        }
        return (additions, deletions)
    }

    private func decodeTokenUsageBreakdown(
        _ value: JSONValue,
        context: String,
        field: String
    ) throws -> Int64 {
        let breakdown = try requiredObject(value, context: context)
        var totalTokens: Int64?
        for name in [
            "cachedInputTokens",
            "inputTokens",
            "outputTokens",
            "reasoningOutputTokens",
            "totalTokens",
        ] {
            guard let rawValue = breakdown[name],
                  case let .integer(number) = rawValue,
                  number >= 0 else {
                throw AppServerObservationAdapterError.malformed(
                    context: context,
                    field: "\(field).\(name)"
                )
            }
            if name == "totalTokens" { totalTokens = number }
        }
        return totalTokens!
    }

    private func boundedName(_ value: String) -> String {
        boundedText(
            value,
            maximumBytes: presentationLimits.maximumNameUTF8Bytes,
            maximumLines: 1
        )
    }

    private func boundedText(
        _ value: String,
        maximumBytes: Int,
        maximumLines: Int
    ) -> String {
        var characters: [Character] = []
        characters.reserveCapacity(min(value.count, maximumBytes))
        var byteCount = 0
        var lines = 1

        for character in value {
            let lineBreaks = lineBreakCount(String(character))
            guard lines + lineBreaks <= maximumLines else { break }
            let bytes = String(character).utf8.count
            guard byteCount + bytes <= maximumBytes else { break }
            characters.append(character)
            byteCount += bytes
            lines += lineBreaks
        }
        return String(characters)
    }

    private func lineCount(_ value: String) -> Int {
        1 + lineBreakCount(value)
    }

    private func lineBreakCount(_ value: String) -> Int {
        var count = 0
        var previousWasCarriageReturn = false
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x0A:
                if !previousWasCarriageReturn { count += 1 }
                previousWasCarriageReturn = false
            case 0x0D:
                count += 1
                previousWasCarriageReturn = true
            case 0x85, 0x2028, 0x2029:
                count += 1
                previousWasCarriageReturn = false
            default:
                previousWasCarriageReturn = false
            }
        }
        return count
    }

    private func decodeThreadStatus(_ value: JSONValue) throws -> AppServerThreadStatus {
        let context = "ThreadStatus"
        let object = try requiredObject(value, context: context)
        switch try requiredString(object, "type", context: context) {
        case "notLoaded": return .notLoaded
        case "idle": return .idle
        case "systemError": return .systemError
        case "active":
            guard case let .array(values) = try requiredValue(object, "activeFlags", context: context) else {
                throw AppServerObservationAdapterError.malformed(context: context, field: "activeFlags")
            }
            var flags: Set<AppServerThreadActiveFlag> = []
            for value in values {
                guard case let .string(raw) = value else {
                    throw AppServerObservationAdapterError.malformed(
                        context: context,
                        field: "activeFlags"
                    )
                }
                if let flag = AppServerThreadActiveFlag(rawValue: raw) { flags.insert(flag) }
            }
            return .active(flags)
        default:
            return .unknown
        }
    }

    private func decodeTurnStatus(_ rawValue: String) -> AppServerTurnStatus {
        AppServerTurnStatus(rawValue: rawValue) ?? .unknown
    }

    private func decodeItemStatus(_ rawValue: String?) -> AppServerItemStatus {
        switch rawValue {
        case "inProgress": .started
        case "completed": .completed
        case "failed", "declined": .failed
        default: .unknown
        }
    }

    private func decodeItemKind(_ rawValue: String) -> AppServerItemKind {
        // The stable schema spells this discriminator with a capital `A`.
        // Keep the explicit mapping even if the domain raw value changes so
        // wire compatibility cannot regress to the old Swift-case spelling.
        if rawValue == "subAgentActivity" { return .subagentActivity }
        return AppServerItemKind(rawValue: rawValue) ?? .unknown
    }

    private func itemKindHasNoStatus(_ kind: AppServerItemKind) -> Bool {
        switch kind {
        case .userMessage, .hookPrompt, .agentMessage, .plan, .reasoning,
             .subagentActivity, .webSearch, .imageView, .sleep,
             .enteredReviewMode, .exitedReviewMode, .contextCompaction:
            return true
        case .commandExecution, .fileChange, .mcpToolCall, .dynamicToolCall,
             .collabAgentToolCall, .imageGeneration, .unknown:
            return false
        }
    }

    private func decodeThreadSource(_ value: JSONValue) throws -> AppServerThreadSource {
        switch value {
        case let .string(raw):
            switch raw {
            case "appServer": return .appServer
            case "cli": return .cli
            case "vscode": return .vscode
            case "exec": return .exec
            default: return .unknown
            }
        case let .object(object):
            // Stable SessionSource uses a `subAgent` tagged object. A custom
            // source remains generic; transport provenance never implies
            // Desktop.
            if object["subAgent"] != nil { return .subagent }
            if object["custom"] != nil { return .custom }
            return .unknown
        default:
            throw AppServerObservationAdapterError.malformed(context: "Thread", field: "source")
        }
    }

    private static func workingDirectoryName(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? nil : boundedTitle(name)
    }

    private func gitProjection(
        workingDirectoryPath: String,
        gitInfo: JSONValue?,
        context: String
    ) throws -> (projectRootPath: String?, branch: String?) {
        guard let gitInfo else { return (nil, nil) }
        if case .null = gitInfo { return (nil, nil) }
        let object = try requiredObject(gitInfo, context: context)

        // Validate the stable GitInfo shape while retaining only a bounded
        // branch. Origin URLs may contain credentials and never cross the seam.
        for field in ["branch", "originUrl", "sha"] {
            guard let value = object[field] else { continue }
            switch value {
            case .null, .string:
                continue
            default:
                throw AppServerObservationAdapterError.malformed(
                    context: context,
                    field: "gitInfo.\(field)"
                )
            }
        }
        let branch = optionalString(object["branch"]).map(Self.boundedTitle)

        return (gitProjectionCache.repositoryRoot(for: workingDirectoryPath), branch)
    }

    private static func boundedTitle(_ value: String) -> String {
        guard value.utf8.count > maximumMetadataBytes else { return value }
        var result = ""
        var byteCount = 0
        for character in value {
            let fragment = String(character)
            let fragmentBytes = fragment.utf8.count
            guard byteCount + fragmentBytes <= maximumMetadataBytes else { break }
            result.append(character)
            byteCount += fragmentBytes
        }
        return result
    }

    private static func boundedMetadata(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var result = ""
        for character in value {
            let candidate = result + String(character)
            guard candidate.utf8.count <= maximumBytes else { break }
            result = candidate
        }
        return result
    }

    private static let knownNotificationMethods: Set<String> = [
        "thread/started",
        "thread/status/changed",
        "thread/archived",
        "thread/deleted",
        "thread/closed",
        "turn/started",
        "turn/completed",
        "item/started",
        "item/completed",
        "item/agentMessage/delta",
        "item/reasoning/summaryPartAdded",
        "item/reasoning/summaryTextDelta",
        "thread/tokenUsage/updated",
        "turn/plan/updated",
        "serverRequest/resolved",
    ]
}

private func requiredObject(
    _ value: JSONValue,
    context: String
) throws -> [String: JSONValue] {
    guard case let .object(object) = value else {
        throw AppServerObservationAdapterError.malformed(context: context, field: "object")
    }
    return object
}

private func requiredValue(
    _ object: [String: JSONValue],
    _ field: String,
    context: String
) throws -> JSONValue {
    guard let value = object[field] else {
        throw AppServerObservationAdapterError.malformed(context: context, field: field)
    }
    return value
}

private func requiredString(
    _ object: [String: JSONValue],
    _ field: String,
    context: String
) throws -> String {
    guard case let .string(value) = try requiredValue(object, field, context: context) else {
        throw AppServerObservationAdapterError.malformed(context: context, field: field)
    }
    return value
}

private func requiredBool(
    _ object: [String: JSONValue],
    _ field: String,
    context: String
) throws -> Bool {
    guard case let .bool(value) = try requiredValue(object, field, context: context) else {
        throw AppServerObservationAdapterError.malformed(context: context, field: field)
    }
    return value
}

private func requiredInteger(
    _ object: [String: JSONValue],
    _ field: String,
    context: String
) throws -> Int64 {
    guard case let .integer(value) = try requiredValue(object, field, context: context) else {
        throw AppServerObservationAdapterError.malformed(context: context, field: field)
    }
    return value
}

private func requiredArray(
    _ object: [String: JSONValue],
    _ field: String,
    context: String
) throws -> [JSONValue] {
    guard case let .array(value) = try requiredValue(object, field, context: context) else {
        throw AppServerObservationAdapterError.malformed(context: context, field: field)
    }
    return value
}

private func validateOptionalNullableString(
    _ object: [String: JSONValue],
    _ field: String,
    context: String
) throws {
    guard let value = object[field] else { return }
    guard case .null = value else {
        guard case .string = value else {
            throw AppServerObservationAdapterError.malformed(context: context, field: field)
        }
        return
    }
}

private func enumValue<Value: RawRepresentable>(
    _ type: Value.Type,
    _ object: [String: JSONValue],
    _ field: String,
    context: String
) throws -> Value where Value.RawValue == String {
    let rawValue = try requiredString(object, field, context: context)
    guard let value = Value(rawValue: rawValue) else {
        throw AppServerObservationAdapterError.malformed(context: context, field: field)
    }
    return value
}

private func optionalString(_ value: JSONValue?) -> String? {
    guard case let .string(value) = value, !value.isEmpty else { return nil }
    return value
}

private func threadID(
    _ object: [String: JSONValue],
    context: String,
    field: String = "threadId"
) throws -> AppServerThreadID {
    let rawValue = try requiredString(object, field, context: context)
    guard !rawValue.isEmpty else {
        throw AppServerObservationAdapterError.malformed(context: context, field: field)
    }
    return .init(rawValue: rawValue)
}

private func turnID(
    _ object: [String: JSONValue],
    context: String,
    field: String = "turnId"
) throws -> AppServerTurnID {
    let rawValue = try requiredString(object, field, context: context)
    guard !rawValue.isEmpty else {
        throw AppServerObservationAdapterError.malformed(context: context, field: field)
    }
    return .init(rawValue: rawValue)
}

private func itemID(
    _ object: [String: JSONValue],
    context: String,
    field: String = "itemId"
) throws -> AppServerItemID {
    let rawValue = try requiredString(object, field, context: context)
    guard !rawValue.isEmpty else {
        throw AppServerObservationAdapterError.malformed(context: context, field: field)
    }
    return .init(rawValue: rawValue)
}

private func validateStructuredQuestions(
    _ object: [String: JSONValue],
    context: String
) throws {
    guard case let .array(questions) = try requiredValue(object, "questions", context: context) else {
        throw AppServerObservationAdapterError.malformed(context: context, field: "questions")
    }
    for question in questions {
        let value = try requiredObject(question, context: context)
        _ = try requiredString(value, "header", context: context)
        _ = try requiredString(value, "id", context: context)
        _ = try requiredString(value, "question", context: context)
        if let options = value["options"], case .null = options {
            continue
        } else if let options = value["options"] {
            guard case let .array(values) = options else {
                throw AppServerObservationAdapterError.malformed(context: context, field: "options")
            }
            for option in values {
                let optionObject = try requiredObject(option, context: context)
                _ = try requiredString(optionObject, "label", context: context)
                _ = try requiredString(optionObject, "description", context: context)
            }
        }
    }
}

private func validateKnownItem(
    _ object: [String: JSONValue],
    kind: AppServerItemKind,
    context: String
) throws {
    switch kind {
    case .userMessage:
        try requireArray(object, "content", context: context)
    case .hookPrompt:
        try requireArray(object, "fragments", context: context)
    case .agentMessage:
        _ = try requiredString(object, "text", context: context)
    case .plan:
        _ = try requiredString(object, "text", context: context)
    case .reasoning, .contextCompaction, .unknown:
        break
    case .commandExecution:
        _ = try requiredString(object, "command", context: context)
        try requireArray(object, "commandActions", context: context)
        _ = try requiredString(object, "cwd", context: context)
        _ = try requiredString(object, "status", context: context)
    case .fileChange:
        try requireArray(object, "changes", context: context)
        _ = try requiredString(object, "status", context: context)
    case .mcpToolCall:
        _ = try requiredValue(object, "arguments", context: context)
        _ = try requiredString(object, "server", context: context)
        _ = try requiredString(object, "status", context: context)
        _ = try requiredString(object, "tool", context: context)
    case .dynamicToolCall:
        _ = try requiredValue(object, "arguments", context: context)
        _ = try requiredString(object, "status", context: context)
        _ = try requiredString(object, "tool", context: context)
    case .collabAgentToolCall:
        _ = try requiredObject(
            requiredValue(object, "agentsStates", context: context),
            context: context
        )
        try requireArray(object, "receiverThreadIds", context: context)
        _ = try requiredString(object, "senderThreadId", context: context)
        _ = try requiredString(object, "status", context: context)
        _ = try requiredString(object, "tool", context: context)
    case .subagentActivity:
        _ = try requiredString(object, "agentPath", context: context)
        _ = try requiredString(object, "agentThreadId", context: context)
        _ = try requiredString(object, "kind", context: context)
    case .webSearch:
        _ = try requiredString(object, "query", context: context)
    case .imageView:
        _ = try requiredString(object, "path", context: context)
    case .sleep:
        guard case .integer = try requiredValue(object, "durationMs", context: context) else {
            throw AppServerObservationAdapterError.malformed(context: context, field: "durationMs")
        }
    case .imageGeneration:
        _ = try requiredString(object, "result", context: context)
        _ = try requiredString(object, "status", context: context)
    case .enteredReviewMode, .exitedReviewMode:
        _ = try requiredString(object, "review", context: context)
    }
}

private func requireArray(
    _ object: [String: JSONValue],
    _ field: String,
    context: String
) throws {
    guard case .array = try requiredValue(object, field, context: context) else {
        throw AppServerObservationAdapterError.malformed(context: context, field: field)
    }
}

private func validateMCPElicitation(
    _ object: [String: JSONValue],
    context: String
) throws {
    _ = try requiredString(object, "serverName", context: context)
    _ = try requiredString(object, "message", context: context)
    switch try requiredString(object, "mode", context: context) {
    case "form", "openai/form":
        _ = try requiredValue(object, "requestedSchema", context: context)
    case "url":
        _ = try requiredString(object, "elicitationId", context: context)
        _ = try requiredString(object, "url", context: context)
    default:
        throw AppServerObservationAdapterError.malformed(context: context, field: "mode")
    }
}

private func optionalTurnID(
    _ value: JSONValue?,
    context: String
) throws -> AppServerTurnID? {
    guard let value else { return nil }
    if case .null = value { return nil }
    guard case let .string(rawValue) = value, !rawValue.isEmpty else {
        throw AppServerObservationAdapterError.malformed(context: context, field: "turnId")
    }
    return .init(rawValue: rawValue)
}

private func requestID(_ value: JSONValue, context: String) throws -> AppServerRequestID {
    switch value {
    case let .integer(value): return .integer(value)
    case let .string(value): return .string(value)
    default: throw AppServerObservationAdapterError.malformed(context: context, field: "requestId")
    }
}

private func mapRequestID(_ value: ConnAppServerAdapter.RequestID) -> AppServerRequestID {
    switch value {
    case let .integer(value): .integer(value)
    case let .string(value): .string(value)
    }
}

private func secondsDate(
    _ object: [String: JSONValue],
    _ field: String,
    context: String
) throws -> Date {
    guard case let .integer(value) = try requiredValue(object, field, context: context) else {
        throw AppServerObservationAdapterError.malformed(context: context, field: field)
    }
    return Date(timeIntervalSince1970: TimeInterval(value))
}

private func optionalSecondsDate(
    _ value: JSONValue?,
    context: String,
    field: String
) throws -> Date? {
    guard let value else { return nil }
    if case .null = value { return nil }
    guard case let .integer(seconds) = value else {
        throw AppServerObservationAdapterError.malformed(context: context, field: field)
    }
    return Date(timeIntervalSince1970: TimeInterval(seconds))
}

private func millisecondsDate(
    _ object: [String: JSONValue],
    _ field: String,
    context: String
) throws -> Date {
    guard case let .integer(value) = try requiredValue(object, field, context: context) else {
        throw AppServerObservationAdapterError.malformed(context: context, field: field)
    }
    return Date(timeIntervalSince1970: TimeInterval(value) / 1_000)
}

private func optionalMillisecondsDate(
    _ value: JSONValue?,
    context: String,
    field: String
) throws -> Date? {
    guard let value else { return nil }
    if case .null = value { return nil }
    guard case let .integer(milliseconds) = value else {
        throw AppServerObservationAdapterError.malformed(context: context, field: field)
    }
    return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
}
