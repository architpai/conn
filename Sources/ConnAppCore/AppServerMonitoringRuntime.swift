import Foundation
import ConnAppServerAdapter
import ConnDomain

package protocol AppServerMonitoringConnection: Sendable {
    func connect(
        to endpoint: ControlEndpoint,
        serverVersion: SupportedAppServerVersion,
        mode: AppServerCapabilityMode
    ) async throws -> InitializeResponse
    func requestEnvelope(
        method: String,
        params: JSONValue?,
        timeout: Duration?
    ) async throws -> ConnAppServerResponseEnvelope
    func drainInboundEnvelopes() async -> [ConnAppServerInboundEnvelope]
    func monitoringState() async -> ConnAppServerConnectionState
    func monitoringIdentity() async -> ConnAppServerConnectionIdentity?
    func disconnect() async
}

extension ConnAppServerConnection: AppServerMonitoringConnection {
    package func monitoringState() async -> ConnAppServerConnectionState { state }
    package func monitoringIdentity() async -> ConnAppServerConnectionIdentity? { activeIdentity }
}

public struct AppServerMonitoringRuntimeConfiguration: Equatable, Sendable {
    public let pageSize: Int
    public let maximumThreads: Int
    public let maximumConcurrentHydrations: Int
    public let maximumBulkQualifiedThreads: Int
    public let inventoryRequestTimeout: Duration
    public let qualificationTimeout: Duration
    public let snapshotRecoveryAttempts: Int
    public let healthyRetryResetInterval: TimeInterval
    public let metadataRefreshInterval: TimeInterval
    public let metadataRefreshThreadLimit: Int
    public let bulkQualificationRequiresActiveStatus: Bool
    public let activeDiscoveryInterval: TimeInterval?
    public let activeDiscoveryThreadLimit: Int
    public let approvalRoutingPolicy: AppServerApprovalRoutingPolicy

    public init(
        pageSize: Int = 500,
        maximumThreads: Int = 1_000,
        maximumConcurrentHydrations: Int = 4,
        maximumBulkQualifiedThreads: Int = 15,
        inventoryRequestTimeout: Duration = .seconds(15),
        qualificationTimeout: Duration = .seconds(5),
        snapshotRecoveryAttempts: Int = 2,
        healthyRetryResetInterval: TimeInterval = 30,
        metadataRefreshInterval: TimeInterval = 60,
        metadataRefreshThreadLimit: Int = 100,
        bulkQualificationRequiresActiveStatus: Bool = false,
        activeDiscoveryInterval: TimeInterval? = nil,
        activeDiscoveryThreadLimit: Int = 20,
        approvalRoutingPolicy: AppServerApprovalRoutingPolicy = .connOriginatedTurnsOnly
    ) {
        self.pageSize = max(1, pageSize)
        self.maximumThreads = max(1, maximumThreads)
        self.maximumConcurrentHydrations = max(1, maximumConcurrentHydrations)
        self.maximumBulkQualifiedThreads = max(0, maximumBulkQualifiedThreads)
        self.inventoryRequestTimeout = inventoryRequestTimeout
        self.qualificationTimeout = qualificationTimeout
        self.snapshotRecoveryAttempts = max(1, snapshotRecoveryAttempts)
        self.healthyRetryResetInterval = max(1, healthyRetryResetInterval)
        self.metadataRefreshInterval = max(1, metadataRefreshInterval)
        self.metadataRefreshThreadLimit = min(
            self.maximumThreads,
            max(1, metadataRefreshThreadLimit)
        )
        self.bulkQualificationRequiresActiveStatus = bulkQualificationRequiresActiveStatus
        self.activeDiscoveryInterval = activeDiscoveryInterval.map { max(0.5, $0) }
        self.activeDiscoveryThreadLimit = min(
            self.metadataRefreshThreadLimit,
            max(1, activeDiscoveryThreadLimit)
        )
        self.approvalRoutingPolicy = approvalRoutingPolicy
    }
}

public enum AppServerRuntimePhase: String, Equatable, Sendable {
    case starting
    case discovery
    case daemon
    case connecting
    case hydrating
    case connected
    case reconnecting
    case incompatible
    case unsafe
    case unavailable
}

/// Presentation-safe evidence for the managed-daemon monitoring connection.
///
/// Versions and counts are protocol metadata. Conversation content and raw
/// diagnostics never enter this value. A connected status describes only the
/// threads this Conn connection successfully resumed; it never means all local
/// Codex work is visible.
public struct AppServerRuntimeStatus: Equatable, Sendable {
    public let phase: AppServerRuntimePhase
    public let detail: String
    public let connectionSource: AppServerConnectionSource
    public let connectionSourceLabel: String
    public let capabilityModeLabel: String
    public let scopeLabel: String
    public let cliVersion: String?
    public let appServerVersion: String?
    public let attempt: Int?
    public let listedThreadCount: Int?
    public let hydratedThreadCount: Int?
    public let monitoredThreadCount: Int?
    public let isThreadInventoryTruncated: Bool
    public let malformedInventoryRowCount: Int
    public let isThreadInventoryMembershipComplete: Bool

    public init(
        phase: AppServerRuntimePhase,
        detail: String,
        connectionSource: AppServerConnectionSource = .managedDaemon,
        capabilityModeLabel: String = "Stable API",
        scopeLabel: String = "Threads connected through this managed daemon",
        cliVersion: String? = nil,
        appServerVersion: String? = nil,
        attempt: Int? = nil,
        listedThreadCount: Int? = nil,
        hydratedThreadCount: Int? = nil,
        monitoredThreadCount: Int? = nil,
        isThreadInventoryTruncated: Bool = false,
        malformedInventoryRowCount: Int = 0,
        isThreadInventoryMembershipComplete: Bool = true
    ) {
        self.phase = phase
        self.detail = detail
        self.connectionSource = connectionSource
        connectionSourceLabel = connectionSource.presentationLabel
        self.capabilityModeLabel = capabilityModeLabel
        self.scopeLabel = scopeLabel
        self.cliVersion = cliVersion
        self.appServerVersion = appServerVersion
        self.attempt = attempt
        self.listedThreadCount = listedThreadCount
        self.hydratedThreadCount = hydratedThreadCount
        self.monitoredThreadCount = monitoredThreadCount
        self.isThreadInventoryTruncated = isThreadInventoryTruncated
        self.malformedInventoryRowCount = max(0, malformedInventoryRowCount)
        self.isThreadInventoryMembershipComplete = isThreadInventoryMembershipComplete
    }

    public var isConnected: Bool {
        phase == .hydrating || phase == .connected
    }

    /// True only while this runtime has current connection authority. Restored
    /// cache and reconnect diagnostics must not surface as current activity.
    public var isAuthoritative: Bool { isConnected }

    public var isCurrentPresentationAuthoritative: Bool { isAuthoritative }

    fileprivate func appendingDiagnostic(_ diagnostic: String?) -> Self {
        guard let diagnostic, !detail.contains(diagnostic) else { return self }
        return .init(
            phase: phase,
            detail: "\(detail) \(diagnostic)",
            connectionSource: connectionSource,
            capabilityModeLabel: capabilityModeLabel,
            scopeLabel: scopeLabel,
            cliVersion: cliVersion,
            appServerVersion: appServerVersion,
            attempt: attempt,
            listedThreadCount: listedThreadCount,
            hydratedThreadCount: hydratedThreadCount,
            monitoredThreadCount: monitoredThreadCount,
            isThreadInventoryTruncated: isThreadInventoryTruncated,
            malformedInventoryRowCount: malformedInventoryRowCount,
            isThreadInventoryMembershipComplete: isThreadInventoryMembershipComplete
        )
    }
}

/// Runtime-only proof progress for one explicitly user-attested Desktop
/// thread. This value is never checkpointed and does not grant response or
/// control authority.
public struct AppServerSharedDesktopThreadProofStatus: Equatable, Sendable {
    public let connection: AppServerConnectionIdentity?
    public let threadID: AppServerThreadID?
    public let didReadOnlyResume: Bool
    public let isWaitingForNewEvent: Bool
    public let didObserveNewEvent: Bool

    public init(
        connection: AppServerConnectionIdentity?,
        threadID: AppServerThreadID?,
        didReadOnlyResume: Bool,
        isWaitingForNewEvent: Bool,
        didObserveNewEvent: Bool
    ) {
        self.connection = connection
        self.threadID = threadID
        self.didReadOnlyResume = didReadOnlyResume
        self.isWaitingForNewEvent = isWaitingForNewEvent
        self.didObserveNewEvent = didObserveNewEvent
    }
}

package struct AppServerMonitoringScope: Equatable, Sendable {
    package private(set) var monitoredThreadIDs: Set<AppServerThreadID> = []

    package var count: Int { monitoredThreadIDs.count }

    package init() {}

    package mutating func include(_ threadID: AppServerThreadID) {
        monitoredThreadIDs.insert(threadID)
    }

    package mutating func include(contentsOf threadIDs: Set<AppServerThreadID>) {
        monitoredThreadIDs.formUnion(threadIDs)
    }

    package mutating func retain(only threadIDs: Set<AppServerThreadID>) {
        monitoredThreadIDs.formIntersection(threadIDs)
    }

    @discardableResult
    package mutating func qualify(
        requestedThreadID: AppServerThreadID,
        readInput: AppServerProjectionInput?,
        readApply: AppServerProjectionApplyResult?,
        resumeInput: AppServerProjectionInput?,
        resumeApply: AppServerProjectionApplyResult?
    ) -> Bool {
        let acceptedResults: [AppServerProjectionApplyResult] = [.applied, .duplicate]
        guard readInput?.scopedThreadID == requestedThreadID,
              resumeInput?.scopedThreadID == requestedThreadID,
              readApply.map(acceptedResults.contains) == true,
              resumeApply.map(acceptedResults.contains) == true
        else { return false }
        include(requestedThreadID)
        return true
    }

    package func accepts(_ input: AppServerProjectionInput) -> Bool {
        guard let threadID = input.scopedThreadID else { return false }
        return monitoredThreadIDs.contains(threadID)
    }

    package func filtered(_ snapshot: AppServerSnapshotInput) -> AppServerSnapshotInput {
        .init(
            cursor: snapshot.cursor,
            observedAt: snapshot.observedAt,
            threads: snapshot.threads.filter { monitoredThreadIDs.contains($0.id) },
            threadFreshness: snapshot.threadFreshness,
            contentAuthority: snapshot.contentAuthority,
            inventoryAuthority: snapshot.inventoryAuthority,
            authoritativeThreadIDs: snapshot.authoritativeThreadIDs
        )
    }
}

private extension AppServerProjectionInput {
    var scopedThreadID: AppServerThreadID? {
        guard case let .delta(input) = self else { return nil }
        switch input.delta {
        case let .threadUpsert(thread): return thread.id
        case let .threadStatus(threadID, _): return threadID
        case let .threadRemoved(threadID): return threadID
        case let .turnUpsert(threadID, _): return threadID
        case let .itemUpsert(threadID, _, _): return threadID
        case let .itemPresentationDelta(threadID, _, _, _): return threadID
        case let .threadTokenUsage(threadID, _, _): return threadID
        case let .turnPlanUpdated(threadID, _, _): return threadID
        case let .requestOpened(request): return request.threadID
        case let .requestResolved(threadID, _): return threadID
        }
    }

    var opensAttentionRequest: Bool {
        guard case let .delta(input) = self,
              case .requestOpened = input.delta else { return false }
        return true
    }

    var scopedThreadStatus: AppServerThreadStatus? {
        guard case let .delta(input) = self else { return nil }
        switch input.delta {
        case let .threadUpsert(thread): return thread.status
        case let .threadStatus(_, status): return status
        case .threadRemoved, .turnUpsert, .itemUpsert, .itemPresentationDelta,
             .threadTokenUsage,
             .turnPlanUpdated, .requestOpened, .requestResolved:
            return nil
        }
    }

    /// Drops turn/item payloads from `thread/started` so discovery can publish
    /// the tile immediately without defeating on-demand detail hydration.
    var metadataOnlyThreadUpsert: Self {
        guard case let .delta(input) = self,
              case let .threadUpsert(thread) = input.delta else { return self }
        let metadata = AppServerThreadInput(
            id: thread.id,
            sessionID: thread.sessionID,
            title: thread.title,
            workingDirectoryName: thread.workingDirectoryName,
            workingDirectoryPath: thread.workingDirectoryPath,
            projectRootPath: thread.projectRootPath,
            gitBranch: thread.gitBranch,
            source: thread.source,
            parentThreadID: thread.parentThreadID,
            forkedFromThreadID: thread.forkedFromThreadID,
            status: thread.status,
            createdAt: thread.createdAt,
            updatedAt: thread.updatedAt,
            turnsAreAuthoritative: false,
            turns: []
        )
        return .delta(.init(
            cursor: input.cursor,
            observedAt: input.observedAt,
            delta: .threadUpsert(metadata)
        ))
    }

    var containsTerminalConflictCandidate: Bool {
        guard case let .delta(input) = self else { return false }
        switch input.delta {
        case let .threadUpsert(thread):
            return thread.turns.contains { turn in
                turn.status == .unknown || turn.items.contains { $0.status == .unknown }
            }
        case let .turnUpsert(_, turn):
            return turn.status == .unknown || turn.items.contains { $0.status == .unknown }
        case let .itemUpsert(_, _, item):
            return item.status == .unknown
        case .threadStatus, .threadRemoved, .itemPresentationDelta,
             .threadTokenUsage, .turnPlanUpdated, .requestOpened, .requestResolved:
            return false
        }
    }
}

package enum AppServerPresentationDeltaCoalescer {
    private struct Key: Equatable {
        let connection: ConnAppServerConnectionIdentity
        let method: String
        let threadID: String
        let turnID: String
        let itemID: String
        let summaryIndex: Int64?
    }

    package static func coalesced(
        _ envelopes: [ConnAppServerInboundEnvelope],
        presentationLimits: AppServerItemPresentationLimits = .standard
    ) -> [ConnAppServerInboundEnvelope] {
        var result: [ConnAppServerInboundEnvelope] = []
        result.reserveCapacity(envelopes.count)

        for envelope in envelopes {
            guard let current = fragment(in: envelope) else {
                result.append(envelope)
                continue
            }
            let boundedCurrent = replacingDelta(
                in: envelope,
                fragment: current,
                text: boundedAppend(current.text, to: "", limits: presentationLimits)
            )
            guard let previousEnvelope = result.last,
                  let previous = fragment(in: previousEnvelope),
                  previousEnvelope.sequence < UInt64.max,
                  envelope.sequence == previousEnvelope.sequence + 1,
                  previous.key == current.key else {
                result.append(boundedCurrent)
                continue
            }
            result[result.count - 1] = replacingDelta(
                in: envelope,
                fragment: current,
                text: boundedAppend(
                    current.text,
                    to: previous.text,
                    limits: presentationLimits
                )
            )
        }
        return result
    }

    private static func replacingDelta(
        in envelope: ConnAppServerInboundEnvelope,
        fragment: (key: Key, text: String, params: [String: JSONValue]),
        text: String
    ) -> ConnAppServerInboundEnvelope {
        var params = fragment.params
        params["delta"] = .string(text)
        return ConnAppServerInboundEnvelope(
            connection: envelope.connection,
            sequence: envelope.sequence,
            message: .notification(.init(
                method: fragment.key.method,
                params: .object(params)
            ))
        )
    }

    private static func boundedAppend(
        _ fragment: String,
        to existing: String,
        limits: AppServerItemPresentationLimits
    ) -> String {
        var result = ""
        var byteCount = 0
        var lineCount = 1
        for source in [existing, fragment] {
            for character in source {
                let value = String(character)
                let nextLines = lines(in: value) - 1
                guard lineCount + nextLines <= limits.maximumTextLineCount else {
                    return result
                }
                let nextBytes = value.utf8.count
                guard byteCount + nextBytes <= limits.maximumTextUTF8Bytes else {
                    return result
                }
                result.append(character)
                byteCount += nextBytes
                lineCount += nextLines
            }
        }
        return result
    }

    private static func lines(in value: String) -> Int {
        var count = 1
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

    private static func fragment(
        in envelope: ConnAppServerInboundEnvelope
    ) -> (key: Key, text: String, params: [String: JSONValue])? {
        guard case let .notification(notification) = envelope.message,
              notification.method == "item/agentMessage/delta"
                || notification.method == "item/reasoning/summaryTextDelta",
              case let .object(params)? = notification.params,
              case let .string(threadID)? = params["threadId"],
              case let .string(turnID)? = params["turnId"],
              case let .string(itemID)? = params["itemId"],
              case let .string(text)? = params["delta"] else {
            return nil
        }
        let summaryIndex: Int64?
        switch params["summaryIndex"] {
        case let .integer(value)?: summaryIndex = value
        case nil: summaryIndex = nil
        default: return nil
        }
        return (
            Key(
                connection: envelope.connection,
                method: notification.method,
                threadID: threadID,
                turnID: turnID,
                itemID: itemID,
                summaryIndex: summaryIndex
            ),
            text,
            params
        )
    }
}

private extension ConnAppServerInboundMessage {
    var method: String {
        switch self {
        case let .request(request): request.method
        case let .notification(notification): notification.method
        }
    }
}

private enum ThreadQualificationRaceOutcome: Sendable {
    case value(scope: AppServerMonitoringScope, didQualify: Bool)
    case timedOut
    case cancelled
}

private enum ResponseEnvelopeRaceOutcome: Sendable {
    case response(ConnAppServerResponseEnvelope?)
    case timedOut
    case cancelled
}

/// Owns Conn's production managed-daemon monitoring lifecycle. It performs
/// safe read/rehydration retries only; no turn action is sent or replayed.
public actor AppServerMonitoringRuntime {
    public struct Update: Equatable, Sendable {
        public let snapshot: AppServerProjectionSnapshot
        public let threadModelSelections: [AppServerThreadID: AppServerThreadModelSelection]
        public let hooks: AppServerHookProjectionSnapshot
        public let legacyPluginCandidate: LegacySidequestPluginCandidate?
        public let legacyHookRetirementDiagnostic: String?
        public let status: AppServerRuntimeStatus
        public let observedAt: Date

        public init(
            snapshot: AppServerProjectionSnapshot,
            threadModelSelections: [AppServerThreadID: AppServerThreadModelSelection] = [:],
            hooks: AppServerHookProjectionSnapshot = .init(
                connection: nil,
                freshness: .stale,
                configuredHooks: [],
                runsByThread: [:]
            ),
            legacyPluginCandidate: LegacySidequestPluginCandidate? = nil,
            legacyHookRetirementDiagnostic: String? = nil,
            status: AppServerRuntimeStatus,
            observedAt: Date
        ) {
            self.snapshot = snapshot
            self.threadModelSelections = threadModelSelections
            self.hooks = hooks
            self.legacyPluginCandidate = legacyPluginCandidate
            self.legacyHookRetirementDiagnostic = legacyHookRetirementDiagnostic
            self.status = status
            self.observedAt = observedAt
        }
    }

    private struct SessionFailure: Error, Sendable {
        let status: AppServerRuntimeStatus
    }

    package struct InventoryResult: Equatable, Sendable {
        package let scope: AppServerMonitoringScope
        package let listedCount: Int
        package let hydratedCount: Int
        package let qualifiedThreadIDs: Set<AppServerThreadID>
        package let inventoryIsTruncated: Bool
        package let malformedRowCount: Int
        package let inventoryMembershipIsComplete: Bool
        package let recoveryCount: Int

        package init(
            scope: AppServerMonitoringScope,
            listedCount: Int,
            hydratedCount: Int,
            qualifiedThreadIDs: Set<AppServerThreadID>,
            inventoryIsTruncated: Bool,
            malformedRowCount: Int = 0,
            inventoryMembershipIsComplete: Bool = true,
            recoveryCount: Int
        ) {
            self.scope = scope
            self.listedCount = listedCount
            self.hydratedCount = hydratedCount
            self.qualifiedThreadIDs = qualifiedThreadIDs
            self.inventoryIsTruncated = inventoryIsTruncated
            self.malformedRowCount = max(0, malformedRowCount)
            self.inventoryMembershipIsComplete = inventoryMembershipIsComplete
            self.recoveryCount = recoveryCount
        }
    }

    package struct ActiveDiscoveryResult: Equatable, Sendable {
        package let scope: AppServerMonitoringScope
        package let activeQualifiedThreadIDs: Set<AppServerThreadID>
        package let newlyQualifiedThreadIDs: Set<AppServerThreadID>
        package let didApply: Bool
        package let requiresSnapshot: Bool
    }

    private static let projectionConfiguration = AppServerProjectionConfiguration.monitoring
    private static let presentationRefreshInterval: TimeInterval = 30
    private static let monitoringPollInterval = Duration.milliseconds(100)
    private static let retryDelays: [Duration] = [
        .milliseconds(500),
        .seconds(1),
        .seconds(2),
        .seconds(5),
    ]

    private let configuration: AppServerMonitoringRuntimeConfiguration
    private let connectionFactory: @Sendable (URL) -> any AppServerMonitoringConnection
    private let threadControls: AppServerThreadControlRuntime
    private let legacyPluginRetirement = LegacyPluginRetirementRuntime()
    private let legacyHookRetirement: @Sendable () -> String?
    private let hookProjection = AppServerHookProjectionStore()
    private var legacyHookRetirementDiagnostic: String?
    private var legacyPluginRetirementDiagnostic: String?
    private var knownHookWorkingDirectories: [String] = []
    private var knownHookWorkingDirectoryScopeIsComplete = false
    private var healthySessionStartedAt: Date?
    private var requestedThreadQualifications: Set<AppServerThreadID> = []
    private var threadModelSelections: [AppServerThreadID: AppServerThreadModelSelection] = [:]
    private struct AcknowledgedCreatedThreadQualificationLease: Sendable {
        let connection: AppServerConnectionIdentity
        let remainingAttempts: Int
    }
    private var acknowledgedCreatedThreadQualifications: [
        AppServerThreadID: AcknowledgedCreatedThreadQualificationLease
    ] = [:]
    private var inventoryRefreshRequested = false
    private var sharedDesktopProofConnection: AppServerConnectionIdentity?
    private var sharedDesktopProofThreadID: AppServerThreadID?
    private var sharedDesktopProofDidResume = false
    private var sharedDesktopProofResumeSequence: UInt64?
    private var sharedDesktopProofDidObserveEvent = false

    public init(
        configuration: AppServerMonitoringRuntimeConfiguration = .init()
    ) {
        self.configuration = configuration
        threadControls = AppServerThreadControlRuntime(configuration: .init(
            routingPolicy: configuration.approvalRoutingPolicy
        ))
        legacyHookRetirement = {
            do {
                switch try LegacyHookRetirementStore.userDefault().retire() {
                case .alreadyCompleted:
                    return nil
                case let .completed(removedLegacyRoots, legacyStateReappeared: false):
                    guard removedLegacyRoots > 0 else { return nil }
                    return "Legacy hook checkpoints were discarded. Verify the old Sidequest plugin is removed; managed-daemon monitoring remains active."
                case .completed(_, legacyStateReappeared: true):
                    return "Legacy hook state reappeared after retirement. Remove the old Sidequest plugin; managed-daemon monitoring remains active."
                }
            } catch {
                return "Legacy hook cleanup needs repair. Managed-daemon monitoring remains active; the retired bridge was not re-enabled."
            }
        }
        connectionFactory = { executableURL in
            ConnAppServerConnection.productionProxy(
                codexExecutableURL: executableURL
            )
        }
    }

    package init(
        configuration: AppServerMonitoringRuntimeConfiguration = .init(),
        connectionFactory: @escaping @Sendable (URL) -> any AppServerMonitoringConnection,
        threadControls: AppServerThreadControlRuntime? = nil,
        legacyHookRetirement: @escaping @Sendable () -> String? = { nil }
    ) {
        self.configuration = configuration
        self.connectionFactory = connectionFactory
        self.threadControls = threadControls ?? AppServerThreadControlRuntime(configuration: .init(
            routingPolicy: configuration.approvalRoutingPolicy
        ))
        self.legacyHookRetirement = legacyHookRetirement
    }

    package static func nextRetryAttempt(
        previousAttempt: Int,
        healthyDuration: TimeInterval?,
        resetInterval: TimeInterval
    ) -> Int {
        if let healthyDuration, healthyDuration >= resetInterval { return 1 }
        return previousAttempt + 1
    }

    package static func metadataRefreshIsDue(now: Date, nextRefresh: Date) -> Bool {
        now >= nextRefresh
    }

    package static func boundedHookWorkingDirectoryScope(
        _ directories: [String]
    ) -> (directories: [String], isComplete: Bool) {
        let unique = Array(Set(directories)).sorted()
        let bounded = Array(unique.prefix(32))
        return (bounded, unique.count == bounded.count)
    }

    package static func retainedQualifiedThreadIDs(
        previous: Set<AppServerThreadID>,
        currentScope: AppServerMonitoringScope,
        newlyQualified: Set<AppServerThreadID>
    ) -> Set<AppServerThreadID> {
        previous.intersection(currentScope.monitoredThreadIDs)
            .union(newlyQualified)
    }

    package static func hydrationQualificationBatch(
        requested: Set<AppServerThreadID>,
        listed: Set<AppServerThreadID>
    ) -> [AppServerThreadID] {
        requested.intersection(listed).sorted { $0.rawValue < $1.rawValue }
    }

    package static func connectedInventoryDetail(
        listedCount: Int,
        qualifiedCount: Int,
        scopeCount: Int
    ) -> String {
        "Inventory metadata: \(listedCount) managed-daemon threads; \(qualifiedCount) are status-qualified or opened. Detailed content is loaded only when opened. \(scopeCount) tiles are in live notification scope."
    }

    package static func hydratingInventoryDetail(
        listedCount: Int,
        qualifiedCount: Int,
        scopeCount: Int
    ) -> String {
        "Inventory metadata: \(listedCount) threads; \(qualifiedCount) are status-qualified or opened. \(scopeCount) tiles are in live notification scope."
    }

    package static let metadataRefreshUnavailableDiagnostic =
        "Metadata refresh unavailable; showing last-known inventory from this connected session."

    /// Requests full, turn-bearing hydration for a thread the user opened.
    /// Monitoring qualification and replay never send consequential actions;
    /// `executeControl` below is the sole explicit, UI-triggered entry point.
    public func requestThreadQualification(_ rawThreadID: String) {
        guard !rawThreadID.isEmpty else { return }
        requestedThreadQualifications.insert(.init(rawValue: rawThreadID))
    }

    /// Coalesces an explicit user request for a fresh metadata inventory.
    /// The active session consumes this by issuing only `thread/list`; detailed
    /// turn content remains deferred until `requestThreadQualification`.
    public func requestInventoryRefresh() async {
        inventoryRefreshRequested = true
        await refreshLegacyPluginRetirementStatus()
    }

    /// Begins a read-only proof for one exact user-attested thread. The active
    /// monitoring session performs its existing bounded thread/read plus
    /// thread/resume qualification; this path has no consequential send site.
    public func beginSharedDesktopThreadProof(_ rawThreadID: String) -> Bool {
        guard let connection = sharedDesktopProofConnection,
              !rawThreadID.isEmpty,
              rawThreadID.utf8.count <= 512,
              !rawThreadID.unicodeScalars.contains(where: {
                  $0.value == 0 || $0.properties.isWhitespace
              }) else { return false }
        let threadID = AppServerThreadID(rawValue: rawThreadID)
        sharedDesktopProofConnection = connection
        sharedDesktopProofThreadID = threadID
        sharedDesktopProofDidResume = false
        sharedDesktopProofResumeSequence = nil
        sharedDesktopProofDidObserveEvent = false
        requestedThreadQualifications.insert(threadID)
        return true
    }

    public func sharedDesktopThreadProofStatus() -> AppServerSharedDesktopThreadProofStatus {
        .init(
            connection: sharedDesktopProofConnection,
            threadID: sharedDesktopProofThreadID,
            didReadOnlyResume: sharedDesktopProofDidResume,
            isWaitingForNewEvent: sharedDesktopProofDidResume
                && sharedDesktopProofResumeSequence != nil
                && !sharedDesktopProofDidObserveEvent,
            didObserveNewEvent: sharedDesktopProofDidObserveEvent
        )
    }

    public func cancelSharedDesktopThreadProof() {
        if let threadID = sharedDesktopProofThreadID {
            requestedThreadQualifications.remove(threadID)
        }
        sharedDesktopProofThreadID = nil
        sharedDesktopProofDidResume = false
        sharedDesktopProofResumeSequence = nil
        sharedDesktopProofDidObserveEvent = false
    }

    /// The only consequential App Server path owned by the production runtime.
    /// Monitoring replay, hydration, reconnect, and quit never call this API.
    public func executeControl(
        _ intent: AppServerControlIntent,
        selectionGeneration: UInt64
    ) async -> AppServerControlExecutionResult {
        await threadControls.execute(intent, selectionGeneration: selectionGeneration)
    }

    /// Explicit two-stage New Chat transaction. Monitoring, replay, and
    /// reconnect paths never call this entry point.
    public func executeNewThread(
        _ intent: AppServerNewThreadIntent
    ) async -> AppServerNewThreadExecutionResult {
        let execution = await threadControls.executeNewThreadWithConnection(intent)
        let result = execution.result
        if result.outcome == .accepted,
           let threadID = result.createdThreadID,
           let connection = execution.connection {
            acknowledgedCreatedThreadQualifications[threadID] = .init(
                connection: connection,
                remainingAttempts: 3
            )
            requestedThreadQualifications.insert(threadID)
        }
        return result
    }

    /// Reads the current connection's visible model catalog for the New Chat
    /// picker. Catalog values remain inside the control/runtime presentation
    /// path and are never projected or checkpointed.
    public func loadNewThreadModelCatalog() async -> AppServerNewThreadModelCatalogResult {
        await threadControls.loadNewThreadModelCatalog()
    }

    public func updateControlSelectionGeneration(_ generation: UInt64) async {
        await threadControls.updateSelectionGeneration(generation)
    }

    public func controlAvailability() async -> AppServerThreadControlAvailability {
        await threadControls.availability()
    }

    public func uninstallLegacyPlugin(
        confirmed candidate: LegacySidequestPluginCandidate
    ) async -> LegacySidequestPluginUninstallOutcome {
        guard knownHookWorkingDirectoryScopeIsComplete else {
            return .staleConfirmation
        }
        return await legacyPluginRetirement.uninstall(
            confirmed: candidate,
            verificationWorkingDirectories: knownHookWorkingDirectories
        )
    }

    package func consumeInventoryRefreshRequestForTesting() -> Bool {
        consumeInventoryRefreshRequest()
    }

    package func resetSharedDesktopThreadProofForTesting(
        connection: AppServerConnectionIdentity?
    ) {
        resetSharedDesktopThreadProof(connection: connection)
    }

    package func hasRequestedThreadQualificationForTesting(
        _ threadID: AppServerThreadID
    ) -> Bool {
        requestedThreadQualifications.contains(threadID)
    }

    package func qualifyAcknowledgedCreatedThreadForTesting(
        _ threadID: AppServerThreadID,
        acknowledgedConnection: AppServerConnectionIdentity,
        connection: any AppServerMonitoringConnection,
        coordinator: AppServerDomainCoordinator
    ) async -> (scope: AppServerMonitoringScope, didQualify: Bool) {
        await qualifyThreadBounded(
            threadID,
            includeTurns: true,
            connection: connection,
            adapter: AppServerObservationAdapter(),
            coordinator: coordinator,
            scope: .init(),
            acknowledgedCreatedThreadConnection: acknowledgedConnection
        )
    }

    package func installAcknowledgedCreatedThreadQualificationForTesting(
        _ threadID: AppServerThreadID,
        connection: AppServerConnectionIdentity
    ) {
        acknowledgedCreatedThreadQualifications[threadID] = .init(
            connection: connection,
            remainingAttempts: 3
        )
        requestedThreadQualifications.insert(threadID)
    }

    package func activateHookProjectionForTesting(
        _ identity: AppServerConnectionIdentity
    ) async {
        _ = await hookProjection.activate(identity)
    }

    package func hookSnapshotForTesting() async -> AppServerHookProjectionSnapshot {
        await hookProjection.snapshot()
    }

    package func markHookConfigurationStaleForTesting(
        _ identity: AppServerConnectionIdentity
    ) async -> AppServerHookProjectionApplyResult {
        await hookProjection.markConfigurationStale(identity)
    }

    package func refreshConfiguredHooksForTesting(
        connection: any AppServerMonitoringConnection,
        coordinator: AppServerDomainCoordinator,
        knownWorkingDirectories: [String] = [],
        adapter: AppServerObservationAdapter = .init()
    ) async -> Bool {
        knownHookWorkingDirectories = knownWorkingDirectories
        return await refreshConfiguredHooks(
            connection: connection,
            adapter: adapter,
            coordinator: coordinator,
            fallbackWorkingDirectories: knownWorkingDirectories
        )
    }

    public func run(
        onUpdate: @escaping @MainActor @Sendable (Update) -> Void
    ) async {
        legacyHookRetirementDiagnostic = legacyHookRetirement()
        let projectionConfiguration = Self.projectionConfiguration
        let domain = AppServerProjectionStore(configuration: projectionConfiguration)
        var coordinator: AppServerDomainCoordinator
        do {
            let checkpointStore = try AppServerDomainCheckpointFileStore.userDefault(
                projectionConfiguration: projectionConfiguration
            )
            coordinator = AppServerDomainCoordinator(
                domain: domain,
                checkpointStore: checkpointStore
            )
        } catch {
            _ = AppServerDomainCheckpointFileStore.quarantineUserDefaultCache()
            if let repairedStore = try? AppServerDomainCheckpointFileStore.userDefault(
                projectionConfiguration: projectionConfiguration
            ) {
                coordinator = AppServerDomainCoordinator(
                    domain: domain,
                    checkpointStore: repairedStore
                )
            } else {
                coordinator = AppServerDomainCoordinator(domain: domain)
            }
        }

        do {
            _ = try await coordinator.restoreCheckpoint()
        } catch {
            _ = AppServerDomainCheckpointFileStore.quarantineUserDefaultCache()
            if let repairedStore = try? AppServerDomainCheckpointFileStore.userDefault(
                projectionConfiguration: projectionConfiguration
            ) {
                coordinator = AppServerDomainCoordinator(
                    domain: domain,
                    checkpointStore: repairedStore
                )
            } else {
                coordinator = AppServerDomainCoordinator(domain: domain)
            }
        }

        await publish(
            coordinator: coordinator,
            domain: domain,
            status: .init(
                phase: .starting,
                detail: "Preparing managed-daemon monitoring. Restored rows remain stale until refreshed."
            ),
            onUpdate: onUpdate
        )

        var retryAttempt = 0
        while !Task.isCancelled {
            let failureStatus: AppServerRuntimeStatus
            do {
                try await runSession(
                    coordinator: coordinator,
                    domain: domain,
                    onUpdate: onUpdate
                )
                return
            } catch is CancellationError {
                return
            } catch let failure as SessionFailure {
                failureStatus = failure.status
                await publish(
                    coordinator: coordinator,
                    domain: domain,
                    status: failure.status,
                    onUpdate: onUpdate
                )
            } catch {
                failureStatus = .init(
                    phase: .unavailable,
                    detail: "The managed-daemon connection became unavailable. Last-known rows are not current."
                )
                await publish(
                    coordinator: coordinator,
                    domain: domain,
                    status: failureStatus,
                    onUpdate: onUpdate
                )
            }

            guard !Task.isCancelled else { return }
            retryAttempt = Self.nextRetryAttempt(
                previousAttempt: retryAttempt,
                healthyDuration: healthySessionStartedAt.map {
                    Date().timeIntervalSince($0)
                },
                resetInterval: configuration.healthyRetryResetInterval
            )
            let delay = Self.retryDelays[min(retryAttempt - 1, Self.retryDelays.count - 1)]
            await publish(
                coordinator: coordinator,
                domain: domain,
                status: .init(
                    phase: .reconnecting,
                    detail: "\(failureStatus.detail) Retrying safe managed-daemon discovery and hydration with bounded backoff.",
                    cliVersion: failureStatus.cliVersion,
                    appServerVersion: failureStatus.appServerVersion,
                    attempt: retryAttempt
                ),
                onUpdate: onUpdate
            )
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
        }
    }

    private func runSession(
        coordinator: AppServerDomainCoordinator,
        domain: AppServerProjectionStore,
        onUpdate: @escaping @MainActor @Sendable (Update) -> Void
    ) async throws {
        try Task.checkCancellation()
        healthySessionStartedAt = nil
        threadModelSelections.removeAll(keepingCapacity: true)
        await publish(
            coordinator: coordinator,
            domain: domain,
            status: .init(
                phase: .discovery,
                detail: "Looking for a supported, trusted Codex CLI installation."
            ),
            onUpdate: onUpdate
        )

        let discovery = CodexExecutableDiscovery()
        let executable: CodexExecutable
        switch await discovery.discover() {
        case let .ready(value):
            executable = value
        case .missing:
            throw SessionFailure(status: .init(
                phase: .unavailable,
                detail: "No supported Codex CLI installation was found in Conn's documented locations."
            ))
        case let .unsafe(_, detail):
            throw SessionFailure(status: .init(phase: .unsafe, detail: detail))
        case let .unsupported(_, reportedVersion):
            let version = reportedVersion.map { " Reported CLI version: \($0)." } ?? ""
            throw SessionFailure(status: .init(
                phase: .incompatible,
                detail: "The discovered Codex CLI is not supported by this Conn release.\(version)",
                cliVersion: reportedVersion
            ))
        case .diagnosticFailure:
            throw SessionFailure(status: .init(
                phase: .unavailable,
                detail: "Conn could not safely inspect the discovered Codex CLI version."
            ))
        }

        let cliVersion = executable.version.rawValue
        let endpointDiscovery = EndpointDiscovery()
        let daemon = ManagedDaemonLifecycle(
            executable: executable,
            codexHome: endpointDiscovery.defaultCodexHome(),
            endpointDiscovery: endpointDiscovery
        )
        await publish(
            coordinator: coordinator,
            domain: domain,
            status: .init(
                phase: .daemon,
                detail: "Checking the Codex-managed daemon and its private current-user endpoint.",
                cliVersion: cliVersion
            ),
            onUpdate: onUpdate
        )

        let daemonResult = try await daemon.ensureRunning()
        let daemonStatus = daemonResult.status
        guard daemonStatus.kind == .running,
              let endpoint = daemonStatus.endpoint,
              let serverVersion = daemonStatus.supportedAppServerVersion
        else {
            let phase: AppServerRuntimePhase = switch daemonStatus.kind {
            case .incompatible: .incompatible
            case .endpointRefused: .unsafe
            case .running, .stopped, .unavailable, .malformed: .unavailable
            }
            throw SessionFailure(status: .init(
                phase: phase,
                detail: daemonStatus.detail,
                cliVersion: cliVersion,
                appServerVersion: daemonStatus.report?.appServerVersion
            ))
        }

        let appServerVersion = serverVersion.rawValue
        let connection = connectionFactory(executable.url)
        let adapter = AppServerObservationAdapter(
            presentationLimits: Self.projectionConfiguration.itemPresentationLimits,
            maximumTurnsPerThread: Self.projectionConfiguration.maximumTurnsPerThread,
            maximumItemsPerTurn: Self.projectionConfiguration.maximumItemsPerTurn
        )
        var capturedConnection: AppServerConnectionIdentity?
        var capturedWireIdentity: ConnAppServerConnectionIdentity?

        do {
            await publish(
                coordinator: coordinator,
                domain: domain,
                status: .init(
                    phase: .connecting,
                    detail: "Connecting to the validated managed-daemon endpoint with the stable API.",
                    cliVersion: cliVersion,
                    appServerVersion: appServerVersion
                ),
                onUpdate: onUpdate
            )
            _ = try await connection.connect(
                to: endpoint,
                serverVersion: serverVersion,
                mode: .stable
            )
            guard let wireIdentity = await connection.monitoringIdentity() else {
                throw ConnAppServerConnectionError.notConnected
            }
            capturedWireIdentity = wireIdentity
            let domainIdentity = adapter.connectionIdentity(from: wireIdentity)
            capturedConnection = domainIdentity
            knownHookWorkingDirectories = []
            knownHookWorkingDirectoryScopeIsComplete = false
            legacyPluginRetirementDiagnostic = nil
            _ = await hookProjection.activate(domainIdentity)
            resetSharedDesktopThreadProof(connection: domainIdentity)
            _ = try await coordinator.applyAndPersist(adapter.connectionActivated(
                identity: domainIdentity,
                source: .managedDaemon,
                serverVersion: serverVersion,
                mode: .stable
            ))
            if let controlConnection = connection as? any AppServerThreadControlConnection {
                await threadControls.attach(
                    connection: controlConnection,
                    wireIdentity: wireIdentity,
                    domainConnection: domainIdentity,
                    coordinator: coordinator,
                    serverVersion: serverVersion,
                    mode: .stable
                )
                await legacyPluginRetirement.attach(
                    connection: controlConnection,
                    wireIdentity: wireIdentity,
                    domainConnection: domainIdentity,
                    version: serverVersion
                )
            }
            await publish(
                coordinator: coordinator,
                domain: domain,
                status: .init(
                    phase: .hydrating,
                    detail: "Paging, refreshing, and subscribing to the managed-daemon thread inventory without starting a turn.",
                    cliVersion: cliVersion,
                    appServerVersion: appServerVersion
                ),
                onUpdate: onUpdate
            )
            var inventory = try await hydrateInventory(
                connection: connection,
                adapter: adapter,
                coordinator: coordinator,
                initialScope: .init(),
                qualifyRecentThreads: true,
                onProgress: { progress in
                    await self.publishHydrationProgress(
                        coordinator: coordinator,
                        domain: domain,
                        cliVersion: cliVersion,
                        appServerVersion: appServerVersion,
                        listedCount: progress.listedCount,
                        hydratedCount: progress.hydratedCount,
                        monitoredCount: progress.scope.count,
                        inventoryIsTruncated: progress.inventoryIsTruncated,
                        malformedRowCount: progress.malformedRowCount,
                        inventoryMembershipIsComplete: progress.inventoryMembershipIsComplete,
                        onUpdate: onUpdate
                    )
                }
            )
            _ = await refreshConfiguredHooks(
                connection: connection,
                adapter: adapter,
                coordinator: coordinator
            )
            await refreshLegacyPluginRetirementStatus()
            var monitoringScope = inventory.scope
            var listedCount = inventory.listedCount
            var qualifiedThreadIDs = inventory.qualifiedThreadIDs
            var activeQualifiedThreadIDs = inventory.qualifiedThreadIDs
            var hydratedCount = qualifiedThreadIDs.count
            var inventoryIsTruncated = inventory.inventoryIsTruncated
            var malformedRowCount = inventory.malformedRowCount
            var inventoryMembershipIsComplete = inventory.inventoryMembershipIsComplete
            // A refresh requested while initial inventory was in flight is
            // already satisfied by that newer inventory.
            inventoryRefreshRequested = false
            let monitoredCount = monitoringScope.count

            var connectedStatus = makeConnectedStatus(
                cliVersion: cliVersion,
                appServerVersion: appServerVersion,
                listedCount: listedCount,
                hydratedCount: hydratedCount,
                monitoredCount: monitoredCount,
                inventoryIsTruncated: inventoryIsTruncated,
                malformedRowCount: malformedRowCount,
                inventoryMembershipIsComplete: inventoryMembershipIsComplete
            )
            await publish(
                coordinator: coordinator,
                domain: domain,
                status: connectedStatus,
                onUpdate: onUpdate
            )
            healthySessionStartedAt = Date()

            var nextPresentationRefresh = Date().addingTimeInterval(
                Self.presentationRefreshInterval
            )
            var nextInventoryRefresh = Date().addingTimeInterval(
                configuration.metadataRefreshInterval
            )
            var nextActiveDiscovery = configuration.activeDiscoveryInterval.map {
                Date().addingTimeInterval($0)
            }
            var metadataRefreshDiagnostic: String?
            while !Task.isCancelled {
                var hookVisibilityDidChange = false
                var didQualifyOnDemand = false
                let requested = requestedThreadQualifications.sorted {
                    $0.rawValue < $1.rawValue
                }
                requestedThreadQualifications.subtract(requested)
                for threadID in requested {
                    let acknowledgedLease = acknowledgedCreatedThreadQualifications.removeValue(
                        forKey: threadID
                    )
                    let qualified = await qualifyThreadBounded(
                        threadID,
                        includeTurns: true,
                        connection: connection,
                        adapter: adapter,
                        coordinator: coordinator,
                        scope: monitoringScope,
                        acknowledgedCreatedThreadConnection: acknowledgedLease?.connection
                    )
                    monitoringScope = qualified.scope
                    if qualified.didQualify {
                        didQualifyOnDemand = true
                        qualifiedThreadIDs.insert(threadID)
                        activeQualifiedThreadIDs.insert(threadID)
                        hydratedCount = qualifiedThreadIDs.count
                    } else if let acknowledgedLease,
                              acknowledgedLease.remainingAttempts > 1,
                              (await coordinator.snapshot(at: Date())).connection
                                == acknowledgedLease.connection {
                        acknowledgedCreatedThreadQualifications[threadID] = .init(
                            connection: acknowledgedLease.connection,
                            remainingAttempts: acknowledgedLease.remainingAttempts - 1
                        )
                        requestedThreadQualifications.insert(threadID)
                    }
                }
                let inbound = try await processInbound(
                    connection: connection,
                    adapter: adapter,
                    coordinator: coordinator,
                    monitoringScope: monitoringScope
                )
                monitoringScope = inbound.scope
                let refreshClock = Date()
                var didDiscoverActiveThread = false
                var activeDiscoveryRequiresSnapshot = false
                if let activeDiscoveryInterval = configuration.activeDiscoveryInterval,
                   let activeDiscoveryDueAt = nextActiveDiscovery,
                   refreshClock >= activeDiscoveryDueAt {
                    let discovery = await refreshActiveSubscriptions(
                        connection: connection,
                        adapter: adapter,
                        coordinator: coordinator,
                        initialScope: monitoringScope,
                        activeQualifiedThreadIDs: activeQualifiedThreadIDs
                    )
                    monitoringScope = discovery.scope
                    activeQualifiedThreadIDs = discovery.activeQualifiedThreadIDs
                    qualifiedThreadIDs.formUnion(discovery.newlyQualifiedThreadIDs)
                    hydratedCount = qualifiedThreadIDs.count
                    didDiscoverActiveThread = discovery.didApply
                    activeDiscoveryRequiresSnapshot = discovery.requiresSnapshot
                    nextActiveDiscovery = refreshClock.addingTimeInterval(
                        activeDiscoveryInterval
                    )
                }
                let periodicInventoryRefresh = Self.metadataRefreshIsDue(
                    now: refreshClock,
                    nextRefresh: nextInventoryRefresh
                )
                let manualInventoryRefresh = consumeInventoryRefreshRequest()
                if inbound.requiresSnapshot || activeDiscoveryRequiresSnapshot
                    || manualInventoryRefresh
                    || periodicInventoryRefresh {
                    let refreshProgressStatus = connectedStatus
                    let onRefreshProgress: @Sendable (InventoryResult) async -> Void = { _ in
                        // Keep the connected shell stable while each page
                        // updates its tiles. The initial connection alone
                        // owns the global Hydrating presentation.
                        await self.publish(
                            coordinator: coordinator,
                            domain: domain,
                            status: refreshProgressStatus,
                            onUpdate: onUpdate
                        )
                    }
                    let refreshedInventory: InventoryResult?
                    if inbound.requiresSnapshot || activeDiscoveryRequiresSnapshot {
                        refreshedInventory = try await hydrateInventory(
                            connection: connection,
                            adapter: adapter,
                            coordinator: coordinator,
                            initialScope: monitoringScope,
                            qualifyRecentThreads: false,
                            onProgress: onRefreshProgress
                        )
                    } else {
                        refreshedInventory = try await optionalInventoryRefresh(
                            connection: connection,
                            adapter: adapter,
                            coordinator: coordinator,
                            initialScope: monitoringScope,
                            onProgress: onRefreshProgress
                        )
                    }
                    if let refreshedInventory {
                        inventory = refreshedInventory
                        monitoringScope = inventory.scope
                        qualifiedThreadIDs = Self.retainedQualifiedThreadIDs(
                            previous: qualifiedThreadIDs,
                            currentScope: monitoringScope,
                            newlyQualified: inventory.qualifiedThreadIDs
                        )
                        hydratedCount = qualifiedThreadIDs.count
                        if inbound.requiresSnapshot || activeDiscoveryRequiresSnapshot {
                            listedCount = inventory.listedCount
                            inventoryIsTruncated = inventory.inventoryIsTruncated
                            malformedRowCount = inventory.malformedRowCount
                            inventoryMembershipIsComplete = inventory.inventoryMembershipIsComplete
                        } else {
                            // A bounded working-set refresh is intentionally
                            // not global inventory evidence. Preserve the last
                            // authoritative inventory diagnostics while still
                            // allowing newly observed rows into live scope.
                            listedCount = max(listedCount, inventory.listedCount)
                            malformedRowCount = min(
                                10_000,
                                malformedRowCount + inventory.malformedRowCount
                            )
                        }
                        metadataRefreshDiagnostic = nil
                    } else {
                        metadataRefreshDiagnostic = Self.metadataRefreshUnavailableDiagnostic
                    }
                    nextInventoryRefresh = Date().addingTimeInterval(
                        configuration.metadataRefreshInterval
                    )
                    hookVisibilityDidChange = await refreshConfiguredHooks(
                        connection: connection,
                        adapter: adapter,
                        coordinator: coordinator
                    )
                    await refreshLegacyPluginRetirementStatus()
                }
                let state = await connection.monitoringState()
                guard case let .ready(generation, version) = state,
                      generation == wireIdentity.generation,
                      version == serverVersion,
                      await connection.monitoringIdentity() == wireIdentity
                else {
                    throw ConnAppServerConnectionError.staleConnection
                }

                let now = Date()
                if didQualifyOnDemand || didDiscoverActiveThread
                    || inbound.didApply || inbound.requiresSnapshot
                    || activeDiscoveryRequiresSnapshot
                    || manualInventoryRefresh || periodicInventoryRefresh
                    || hookVisibilityDidChange
                    || now >= nextPresentationRefresh {
                    if didQualifyOnDemand || didDiscoverActiveThread
                        || inbound.didApply || inbound.requiresSnapshot
                        || activeDiscoveryRequiresSnapshot
                        || manualInventoryRefresh || periodicInventoryRefresh {
                        connectedStatus = makeConnectedStatus(
                            cliVersion: cliVersion,
                            appServerVersion: appServerVersion,
                            listedCount: listedCount,
                            hydratedCount: hydratedCount,
                            monitoredCount: monitoringScope.count,
                            inventoryIsTruncated: inventoryIsTruncated,
                            malformedRowCount: malformedRowCount,
                            inventoryMembershipIsComplete: inventoryMembershipIsComplete
                        ).appendingDiagnostic(metadataRefreshDiagnostic)
                    }
                    await publish(
                        coordinator: coordinator,
                        domain: domain,
                        status: connectedStatus,
                        at: now,
                        onUpdate: onUpdate
                    )
                    nextPresentationRefresh = now.addingTimeInterval(
                        Self.presentationRefreshInterval
                    )
                }
                try await Task.sleep(for: Self.monitoringPollInterval)
            }
            throw CancellationError()
        } catch {
            if let wireIdentity = capturedWireIdentity {
                await threadControls.detach(ifWireIdentityMatches: wireIdentity)
                await legacyPluginRetirement.detach(ifWireIdentityMatches: wireIdentity)
            }
            if let capturedConnection {
                _ = await hookProjection.loseConnection(capturedConnection)
                _ = try? await coordinator.applyAndPersist(.connectionLost(capturedConnection))
            }
            knownHookWorkingDirectories = []
            knownHookWorkingDirectoryScopeIsComplete = false
            acknowledgedCreatedThreadQualifications.removeAll()
            legacyPluginRetirementDiagnostic = nil
            resetSharedDesktopThreadProof(connection: nil)
            await connection.disconnect()
            if error is CancellationError { throw CancellationError() }
            throw error
        }
    }

    private func makeConnectedStatus(
        cliVersion: String,
        appServerVersion: String,
        listedCount: Int,
        hydratedCount: Int,
        monitoredCount: Int,
        inventoryIsTruncated: Bool,
        malformedRowCount: Int = 0,
        inventoryMembershipIsComplete: Bool = true
    ) -> AppServerRuntimeStatus {
        let truncationDetail = inventoryIsTruncated
            ? " The configurable \(configuration.maximumThreads)-thread safety ceiling was reached; additional managed-daemon threads are not shown."
            : ""
        let malformedDetail = malformedRowCount > 0
            ? " Skipped \(malformedRowCount) malformed thread inventory row\(malformedRowCount == 1 ? "" : "s"); valid siblings remain visible."
            : ""
        let membershipDetail = inventoryMembershipIsComplete
            ? ""
            : " Inventory membership is incomplete, so cached rows were not deleted."
        return .init(
            phase: .connected,
            detail: Self.connectedInventoryDetail(
                listedCount: listedCount,
                qualifiedCount: hydratedCount,
                scopeCount: monitoredCount
            ) + truncationDetail + malformedDetail + membershipDetail,
            cliVersion: cliVersion,
            appServerVersion: appServerVersion,
            listedThreadCount: listedCount,
            hydratedThreadCount: hydratedCount,
            monitoredThreadCount: monitoredCount,
            isThreadInventoryTruncated: inventoryIsTruncated,
            malformedInventoryRowCount: malformedRowCount,
            isThreadInventoryMembershipComplete: inventoryMembershipIsComplete
        )
    }

    private struct InboundResult: Sendable {
        var scope: AppServerMonitoringScope
        var didApply = false
        var requiresSnapshot = false
    }

    package func hydrateInventoryForTesting(
        connection: any AppServerMonitoringConnection,
        coordinator: AppServerDomainCoordinator,
        adapter: AppServerObservationAdapter = .init(),
        initialScope: AppServerMonitoringScope = .init(),
        qualifyRecentThreads: Bool = true,
        onProgress: (@Sendable (InventoryResult) async -> Void)? = nil
    ) async throws -> InventoryResult {
        try await hydrateInventory(
            connection: connection,
            adapter: adapter,
            coordinator: coordinator,
            initialScope: initialScope,
            qualifyRecentThreads: qualifyRecentThreads,
            onProgress: onProgress
        )
    }

    package func refreshActiveSubscriptionsForTesting(
        connection: any AppServerMonitoringConnection,
        coordinator: AppServerDomainCoordinator,
        adapter: AppServerObservationAdapter = .init(),
        scope: AppServerMonitoringScope,
        activeQualifiedThreadIDs: Set<AppServerThreadID>
    ) async -> ActiveDiscoveryResult {
        await refreshActiveSubscriptions(
            connection: connection,
            adapter: adapter,
            coordinator: coordinator,
            initialScope: scope,
            activeQualifiedThreadIDs: activeQualifiedThreadIDs
        )
    }

    package func optionalInventoryRefreshForTesting(
        connection: any AppServerMonitoringConnection,
        coordinator: AppServerDomainCoordinator,
        adapter: AppServerObservationAdapter = .init(),
        initialScope: AppServerMonitoringScope
    ) async throws -> InventoryResult? {
        try await optionalInventoryRefresh(
            connection: connection,
            adapter: adapter,
            coordinator: coordinator,
            initialScope: initialScope,
            onProgress: nil
        )
    }

    package func processInboundForTesting(
        connection: any AppServerMonitoringConnection,
        coordinator: AppServerDomainCoordinator,
        adapter: AppServerObservationAdapter = .init(),
        monitoringScope: AppServerMonitoringScope
    ) async throws -> (
        scope: AppServerMonitoringScope,
        didApply: Bool,
        requiresSnapshot: Bool
    ) {
        let result = try await processInbound(
            connection: connection,
            adapter: adapter,
            coordinator: coordinator,
            monitoringScope: monitoringScope
        )
        return (result.scope, result.didApply, result.requiresSnapshot)
    }

    private func hydrateInventory(
        connection: any AppServerMonitoringConnection,
        adapter: AppServerObservationAdapter,
        coordinator: AppServerDomainCoordinator,
        initialScope: AppServerMonitoringScope,
        qualifyRecentThreads: Bool,
        onProgress: (@Sendable (InventoryResult) async -> Void)?
    ) async throws -> InventoryResult {
        var recoveryCount = 0
        var scope = initialScope
        var shouldQualifyRecentThreads = qualifyRecentThreads
        while true {
            let result = try await hydrateInventoryOnce(
                connection: connection,
                adapter: adapter,
                coordinator: coordinator,
                initialScope: scope,
                recoveryCount: recoveryCount,
                qualifyRecentThreads: shouldQualifyRecentThreads,
                onProgress: onProgress
            )
            // The recent status tier runs once for this established App Server
            // session. In-session recovery and metadata Sync remain list-only.
            shouldQualifyRecentThreads = false
            let metrics = await coordinator.storageMetrics()
            if !metrics.requiresSnapshot && !metrics.rejectsDeltasUntilReconnect {
                return result
            }
            guard recoveryCount < configuration.snapshotRecoveryAttempts else {
                throw SessionFailure(status: .init(
                    phase: .reconnecting,
                    detail: "The projection requested another authoritative inventory after bounded in-session recovery. Last-known rows remain stale."
                ))
            }
            recoveryCount += 1
            scope = result.scope
        }
    }

    private func qualifyNextRequestedThreadDuringHydration(
        connection: any AppServerMonitoringConnection,
        adapter: AppServerObservationAdapter,
        coordinator: AppServerDomainCoordinator,
        scope initialScope: AppServerMonitoringScope
    ) async -> (scope: AppServerMonitoringScope, qualifiedThreadID: AppServerThreadID?) {
        guard let threadID = requestedThreadQualifications
            .sorted(by: { $0.rawValue < $1.rawValue })
            .first else { return (initialScope, nil) }
        requestedThreadQualifications.remove(threadID)
        let acknowledgedLease = acknowledgedCreatedThreadQualifications.removeValue(
            forKey: threadID
        )
        let qualified: (scope: AppServerMonitoringScope, didQualify: Bool)
        if let acknowledgedLease,
           (await coordinator.snapshot(at: Date())).connection
            == acknowledgedLease.connection {
            var acknowledgedScope = initialScope
            acknowledgedScope.include(threadID)
            qualified = (acknowledgedScope, true)
        } else {
            qualified = await qualifyThreadBounded(
                threadID,
                includeTurns: true,
                connection: connection,
                adapter: adapter,
                coordinator: coordinator,
                scope: initialScope,
                acknowledgedCreatedThreadConnection: acknowledgedLease?.connection
            )
        }
        if !qualified.didQualify,
           let acknowledgedLease,
           acknowledgedLease.remainingAttempts > 1 {
            acknowledgedCreatedThreadQualifications[threadID] = .init(
                connection: acknowledgedLease.connection,
                remainingAttempts: acknowledgedLease.remainingAttempts - 1
            )
            requestedThreadQualifications.insert(threadID)
        }
        return (qualified.scope, qualified.didQualify ? threadID : nil)
    }

    private func optionalInventoryRefresh(
        connection: any AppServerMonitoringConnection,
        adapter: AppServerObservationAdapter,
        coordinator: AppServerDomainCoordinator,
        initialScope: AppServerMonitoringScope,
        onProgress: (@Sendable (InventoryResult) async -> Void)?
    ) async throws -> InventoryResult? {
        do {
            let metricsBeforeRefresh = await coordinator.storageMetrics()
            if metricsBeforeRefresh.requiresSnapshot
                || metricsBeforeRefresh.rejectsDeltasUntilReconnect {
                throw SessionFailure(status: .init(
                    phase: .reconnecting,
                    detail: "The projection requires authoritative recovery; an optional metadata refresh cannot preserve the session safely."
                ))
            }
            let result = try await applyStagedOptionalInventory(
                connection: connection,
                adapter: adapter,
                coordinator: coordinator,
                initialScope: initialScope,
                onProgress: onProgress
            )
            let metricsAfterRefresh = await coordinator.storageMetrics()
            if metricsAfterRefresh.requiresSnapshot
                || metricsAfterRefresh.rejectsDeltasUntilReconnect {
                throw SessionFailure(status: .init(
                    phase: .reconnecting,
                    detail: "The atomic metadata refresh exposed a projection authority requirement."
                ))
            }
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A manual or periodic refresh is advisory once the session has an
            // authoritative inventory. Keep that healthy session alive and
            // surface last-known metadata instead of entering reconnect churn.
            try Task.checkCancellation()
            let metrics = await coordinator.storageMetrics()
            if metrics.requiresSnapshot || metrics.rejectsDeltasUntilReconnect {
                throw error
            }
            return nil
        }
    }

    /// Discovers short-lived tasks started by another Codex surface without
    /// turning every metadata refresh into broad history hydration. Only a
    /// newly active row is inserted and qualified; unchanged and idle rows do
    /// not touch the projection or persistence layer.
    private func refreshActiveSubscriptions(
        connection: any AppServerMonitoringConnection,
        adapter: AppServerObservationAdapter,
        coordinator: AppServerDomainCoordinator,
        initialScope: AppServerMonitoringScope,
        activeQualifiedThreadIDs: Set<AppServerThreadID>
    ) async -> ActiveDiscoveryResult {
        guard configuration.activeDiscoveryInterval != nil else {
            return .init(
                scope: initialScope,
                activeQualifiedThreadIDs: activeQualifiedThreadIDs,
                newlyQualifiedThreadIDs: [],
                didApply: false,
                requiresSnapshot: false
            )
        }
        let params: JSONValue = .object([
            "limit": .integer(Int64(configuration.activeDiscoveryThreadLimit)),
            "sortDirection": .string("desc"),
            "sortKey": .string("updated_at"),
            "useStateDbOnly": .bool(true),
        ])
        guard let response = await requestEnvelopeBounded(
            connection: connection,
            method: "thread/list",
            params: params,
            timeout: min(configuration.inventoryRequestTimeout, .seconds(1))
        ),
              let page = try? adapter.threadListPage(response: response, observedAt: Date())
        else {
            return .init(
                scope: initialScope,
                activeQualifiedThreadIDs: activeQualifiedThreadIDs,
                newlyQualifiedThreadIDs: [],
                didApply: false,
                requiresSnapshot: false
            )
        }

        var seen: Set<AppServerThreadID> = []
        let activeThreads = page.snapshot.threads.filter { thread in
            guard case .active = thread.status, seen.insert(thread.id).inserted else {
                return false
            }
            return true
        }
        let activeIDs = Set(activeThreads.map(\.id))
        var retainedActiveQualifications = activeQualifiedThreadIDs.intersection(activeIDs)
        let candidates = activeThreads.filter { !retainedActiveQualifications.contains($0.id) }
        guard !candidates.isEmpty else {
            return .init(
                scope: initialScope,
                activeQualifiedThreadIDs: retainedActiveQualifications,
                newlyQualifiedThreadIDs: [],
                didApply: false,
                requiresSnapshot: false
            )
        }

        let stagedSnapshot = AppServerSnapshotInput(
            cursor: page.snapshot.cursor,
            observedAt: page.snapshot.observedAt,
            threads: candidates,
            threadFreshness: .live,
            contentAuthority: .metadataOnly,
            inventoryAuthority: .incremental,
            authoritativeThreadIDs: nil
        )
        let stagedApply: AppServerProjectionApplyResult
        do {
            stagedApply = try await coordinator.applyAndPersist(.snapshot(stagedSnapshot))
        } catch {
            return .init(
                scope: initialScope,
                activeQualifiedThreadIDs: retainedActiveQualifications,
                newlyQualifiedThreadIDs: [],
                didApply: false,
                requiresSnapshot: false
            )
        }
        guard stagedApply == .applied else {
            return .init(
                scope: initialScope,
                activeQualifiedThreadIDs: retainedActiveQualifications,
                newlyQualifiedThreadIDs: [],
                didApply: stagedApply == .appliedPendingSnapshot,
                requiresSnapshot: stagedApply == .appliedPendingSnapshot
            )
        }
        let stagedMetrics = await coordinator.storageMetrics()
        if stagedMetrics.requiresSnapshot || stagedMetrics.rejectsDeltasUntilReconnect {
            return .init(
                scope: initialScope,
                activeQualifiedThreadIDs: retainedActiveQualifications,
                newlyQualifiedThreadIDs: [],
                didApply: true,
                requiresSnapshot: true
            )
        }

        var scope = initialScope
        let batch = candidates.prefix(configuration.maximumConcurrentHydrations).map(\.id)
        let newlyQualified = Set(await qualifyBatch(
            batch,
            includeTurns: true,
            connection: connection,
            adapter: adapter,
            coordinator: coordinator
        ))
        scope.include(contentsOf: newlyQualified)
        retainedActiveQualifications.formUnion(newlyQualified)

        var requiresSnapshot = false
        if let inbound = try? await processInbound(
            connection: connection,
            adapter: adapter,
            coordinator: coordinator,
            monitoringScope: scope
        ) {
            scope = inbound.scope
            requiresSnapshot = inbound.requiresSnapshot
        }
        return .init(
            scope: scope,
            activeQualifiedThreadIDs: retainedActiveQualifications,
            newlyQualifiedThreadIDs: newlyQualified,
            didApply: true,
            requiresSnapshot: requiresSnapshot
        )
    }

    /// Manual and periodic refreshes update only the newest working set. They
    /// are deliberately incremental: absence from this bounded page cannot
    /// remove an older cached thread. Full cursor pagination remains reserved
    /// for initial hydration and authoritative recovery.
    private func applyStagedOptionalInventory(
        connection: any AppServerMonitoringConnection,
        adapter: AppServerObservationAdapter,
        coordinator: AppServerDomainCoordinator,
        initialScope: AppServerMonitoringScope,
        onProgress: (@Sendable (InventoryResult) async -> Void)?
    ) async throws -> InventoryResult {
        var scope = initialScope
        try Task.checkCancellation()
        let params: JSONValue = .object([
            "limit": .integer(Int64(configuration.metadataRefreshThreadLimit)),
            "sortDirection": .string("desc"),
            "sortKey": .string("updated_at"),
            "useStateDbOnly": .bool(true),
        ])
        guard let response = await requestEnvelopeBounded(
            connection: connection,
            method: "thread/list",
            params: params,
            timeout: configuration.inventoryRequestTimeout
        ) else {
            throw SessionFailure(status: .init(
                phase: .connected,
                detail: Self.metadataRefreshUnavailableDiagnostic
            ))
        }
        let page = try adapter.threadListPage(response: response, observedAt: Date())
        var listedThreadIDs: Set<AppServerThreadID> = []
        var orderedThreads: [AppServerThreadInput] = []
        var omittedRows = false
        for thread in page.snapshot.threads where !listedThreadIDs.contains(thread.id) {
            guard listedThreadIDs.count < configuration.metadataRefreshThreadLimit else {
                omittedRows = true
                continue
            }
            listedThreadIDs.insert(thread.id)
            orderedThreads.append(thread)
        }
        for threadID in page.inventoryThreadIDs.sorted(by: { $0.rawValue < $1.rawValue })
        where !listedThreadIDs.contains(threadID) {
            guard listedThreadIDs.count < configuration.metadataRefreshThreadLimit else {
                omittedRows = true
                continue
            }
            listedThreadIDs.insert(threadID)
        }
        let stagedSnapshot = AppServerSnapshotInput(
            cursor: page.snapshot.cursor,
            observedAt: page.snapshot.observedAt,
            threads: orderedThreads,
            threadFreshness: .live,
            contentAuthority: .metadataOnly,
            inventoryAuthority: .incremental,
            authoritativeThreadIDs: nil
        )
        _ = try await coordinator.applyAndPersist(.snapshot(stagedSnapshot))
        scope.include(contentsOf: listedThreadIDs)
        let result = InventoryResult(
            scope: scope,
            listedCount: listedThreadIDs.count,
            hydratedCount: 0,
            qualifiedThreadIDs: [],
            inventoryIsTruncated: page.nextCursor != nil || omittedRows,
            malformedRowCount: page.malformedRowCount,
            inventoryMembershipIsComplete: false,
            recoveryCount: 0
        )
        await onProgress?(result)
        return result
    }

    private func hydrateInventoryOnce(
        connection: any AppServerMonitoringConnection,
        adapter: AppServerObservationAdapter,
        coordinator: AppServerDomainCoordinator,
        initialScope: AppServerMonitoringScope,
        recoveryCount: Int,
        qualifyRecentThreads: Bool,
        onProgress: (@Sendable (InventoryResult) async -> Void)?
    ) async throws -> InventoryResult {
        var scope = initialScope
        var cursor: String?
        var listedThreadIDs: Set<AppServerThreadID> = []
        var orderedListedThreadIDs: [AppServerThreadID] = []
        var activeListedThreadIDs: Set<AppServerThreadID> = []
        var hydratedThreadIDs: Set<AppServerThreadID> = []
        var inventoryIsTruncated = false
        var malformedRowCount = 0
        var inventoryMembershipIsComplete = true

        // Stage one is metadata-only. Every page is reduced immediately so
        // the complete Projects & Threads inventory can render without
        // waiting for per-thread read/resume qualification.
        while true {
            try Task.checkCancellation()
            var params: [String: JSONValue] = [
                "limit": .integer(Int64(configuration.pageSize)),
                "sortDirection": .string("desc"),
                "sortKey": .string("updated_at"),
                "useStateDbOnly": .bool(true),
            ]
            if let cursor { params["cursor"] = .string(cursor) }
            guard let response = await requestEnvelopeBounded(
                connection: connection,
                method: "thread/list",
                params: .object(params),
                timeout: configuration.inventoryRequestTimeout
            ) else {
                throw SessionFailure(status: .init(
                    phase: .reconnecting,
                    detail: "The read-only thread inventory request did not complete within Conn's runtime bound."
                ))
            }
            let page = try adapter.threadListPage(response: response, observedAt: Date())
            malformedRowCount = min(10_000, malformedRowCount + page.malformedRowCount)
            inventoryMembershipIsComplete = inventoryMembershipIsComplete
                && page.inventoryMembershipIsComplete
            let remaining = max(0, configuration.maximumThreads - listedThreadIDs.count)
            let candidates = page.snapshot.threads.filter {
                !listedThreadIDs.contains($0.id)
            }.prefix(remaining)
            let pageThreads = Array(candidates)
            for thread in pageThreads {
                listedThreadIDs.insert(thread.id)
                orderedListedThreadIDs.append(thread.id)
                if case .active = thread.status {
                    activeListedThreadIDs.insert(thread.id)
                }
            }
            for threadID in page.inventoryThreadIDs.sorted(by: {
                $0.rawValue < $1.rawValue
            }) where !listedThreadIDs.contains(threadID) {
                guard listedThreadIDs.count < configuration.maximumThreads else { break }
                listedThreadIDs.insert(threadID)
            }
            // A server may return an oversized final page even when its cursor
            // is nil. Any unique membership row omitted by Conn's safety bound
            // makes the inventory incomplete and therefore non-authoritative.
            let omittedUniqueThreadAtCeiling = !page.inventoryThreadIDs
                .subtracting(listedThreadIDs)
                .isEmpty
            let reachedCeiling = omittedUniqueThreadAtCeiling
                || (listedThreadIDs.count >= configuration.maximumThreads
                    && page.nextCursor != nil)
            if reachedCeiling { inventoryMembershipIsComplete = false }
            let completedInventory = page.nextCursor == nil
                && !reachedCeiling
                && inventoryMembershipIsComplete
            inventoryIsTruncated = inventoryIsTruncated || reachedCeiling

            let metadataPage = AppServerSnapshotInput(
                cursor: page.snapshot.cursor,
                observedAt: page.snapshot.observedAt,
                threads: pageThreads,
                threadFreshness: .live,
                contentAuthority: .metadataOnly,
                inventoryAuthority: completedInventory ? .authoritative : .incremental,
                authoritativeThreadIDs: completedInventory ? listedThreadIDs : nil
            )
            _ = try await coordinator.applyAndPersist(.snapshot(metadataPage))
            // Current thread/list metadata is sufficient authority for tile
            // identity, order, and status. It is not detailed hydration, but
            // it lets global lifecycle/status notifications update known rows
            // without an eager read/resume sweep.
            scope.include(contentsOf: page.inventoryThreadIDs.intersection(listedThreadIDs))
            await onProgress?(InventoryResult(
                scope: scope,
                listedCount: listedThreadIDs.count,
                hydratedCount: hydratedThreadIDs.count,
                qualifiedThreadIDs: hydratedThreadIDs,
                inventoryIsTruncated: inventoryIsTruncated,
                malformedRowCount: malformedRowCount,
                inventoryMembershipIsComplete: inventoryMembershipIsComplete,
                recoveryCount: recoveryCount
            ))

            // The expanded shell can request a restored selection while the
            // global inventory is still paging. Hydrate it before continuing
            // through hundreds of metadata rows.
            let priority = await qualifyNextRequestedThreadDuringHydration(
                connection: connection,
                adapter: adapter,
                coordinator: coordinator,
                scope: scope
            )
            scope = priority.scope
            if let threadID = priority.qualifiedThreadID {
                hydratedThreadIDs.insert(threadID)
                await onProgress?(InventoryResult(
                    scope: scope,
                    listedCount: listedThreadIDs.count,
                    hydratedCount: hydratedThreadIDs.count,
                    qualifiedThreadIDs: hydratedThreadIDs,
                    inventoryIsTruncated: inventoryIsTruncated,
                    malformedRowCount: malformedRowCount,
                    inventoryMembershipIsComplete: inventoryMembershipIsComplete,
                    recoveryCount: recoveryCount
                ))
            }

            // Paging a large inventory must not suspend the live event stream.
            // Resume and Desktop can both enqueue selected-thread updates while
            // later metadata pages are still loading; reduce them between pages
            // so the visible transcript remains current throughout startup.
            let pageInbound = try await processInbound(
                connection: connection,
                adapter: adapter,
                coordinator: coordinator,
                monitoringScope: scope
            )
            scope = pageInbound.scope
            if pageInbound.didApply {
                await onProgress?(InventoryResult(
                    scope: scope,
                    listedCount: listedThreadIDs.count,
                    hydratedCount: hydratedThreadIDs.count,
                    qualifiedThreadIDs: hydratedThreadIDs,
                    inventoryIsTruncated: inventoryIsTruncated,
                    malformedRowCount: malformedRowCount,
                    inventoryMembershipIsComplete: inventoryMembershipIsComplete,
                    recoveryCount: recoveryCount
                ))
            }

            if completedInventory {
                scope.retain(only: listedThreadIDs)
                break
            }
            if reachedCeiling { break }
            // An empty data page is not terminal when the server supplies a
            // cursor; continue until nextCursor is actually null.
            guard let nextCursor = page.nextCursor else { break }
            cursor = nextCursor
        }

        // Stage two subscribes only active loaded threads. Recent idle rows
        // need metadata for the picker, but resuming them can transfer a full
        // turn-bearing response that Conn would immediately discard.
        let loadedThreadIDs: [AppServerThreadID]
        if qualifyRecentThreads,
           configuration.maximumBulkQualifiedThreads > 0,
           !orderedListedThreadIDs.isEmpty {
            loadedThreadIDs = try await fetchLoadedThreadIDs(
                connection: connection,
                adapter: adapter
            )
        } else {
            loadedThreadIDs = []
        }
        let postLoadedInbound = try await processInbound(
            connection: connection,
            adapter: adapter,
            coordinator: coordinator,
            monitoringScope: scope
        )
        scope = postLoadedInbound.scope
        let postLoadedPriority = await qualifyNextRequestedThreadDuringHydration(
            connection: connection,
            adapter: adapter,
            coordinator: coordinator,
            scope: scope
        )
        scope = postLoadedPriority.scope
        if let threadID = postLoadedPriority.qualifiedThreadID {
            hydratedThreadIDs.insert(threadID)
        }
        let loadedThreadIDSet = Set(loadedThreadIDs)
        let requiresActiveStatus = configuration.bulkQualificationRequiresActiveStatus
        let bulkIDs = Array(orderedListedThreadIDs.lazy
            .filter(loadedThreadIDSet.contains)
            .filter {
                !requiresActiveStatus
                    || activeListedThreadIDs.contains($0)
            }
            .prefix(configuration.maximumBulkQualifiedThreads))
        var batchStart = 0
        while batchStart < bulkIDs.count {
            let batchEnd = min(
                bulkIDs.count,
                batchStart + configuration.maximumConcurrentHydrations
            )
            let batch = Array(bulkIDs[batchStart..<batchEnd])
            let qualifiedIDs = await qualifyBatch(
                batch,
                includeTurns: false,
                connection: connection,
                adapter: adapter,
                coordinator: coordinator
            )
            scope.include(contentsOf: Set(qualifiedIDs))
            hydratedThreadIDs.formUnion(qualifiedIDs)

            // thread/resume emits notifications. Reduce them before starting
            // another batch so the bounded connection queue cannot grow with
            // inventory size.
            let inbound = try await processInbound(
                connection: connection,
                adapter: adapter,
                coordinator: coordinator,
                monitoringScope: scope
            )
            scope = inbound.scope
            let batchPriority = await qualifyNextRequestedThreadDuringHydration(
                connection: connection,
                adapter: adapter,
                coordinator: coordinator,
                scope: scope
            )
            scope = batchPriority.scope
            if let threadID = batchPriority.qualifiedThreadID {
                hydratedThreadIDs.insert(threadID)
            }
            batchStart = batchEnd
            await onProgress?(InventoryResult(
                scope: scope,
                listedCount: listedThreadIDs.count,
                hydratedCount: hydratedThreadIDs.count,
                qualifiedThreadIDs: hydratedThreadIDs,
                inventoryIsTruncated: inventoryIsTruncated,
                malformedRowCount: malformedRowCount,
                inventoryMembershipIsComplete: inventoryMembershipIsComplete,
                recoveryCount: recoveryCount
            ))
            if inbound.requiresSnapshot { break }
        }

        // Consume one immutable batch before declaring hydration complete.
        // A publish can make SwiftUI request the same selected thread again;
        // those reentrant requests remain queued for the connected loop rather
        // than keeping initial hydration alive forever.
        let requestedBatch = Self.hydrationQualificationBatch(
            requested: requestedThreadQualifications,
            listed: listedThreadIDs
        )
        requestedThreadQualifications.subtract(requestedBatch)
        for threadID in requestedBatch {
            let acknowledgedLease = acknowledgedCreatedThreadQualifications.removeValue(
                forKey: threadID
            )
            let qualified: (scope: AppServerMonitoringScope, didQualify: Bool)
            if let acknowledgedLease,
               (await coordinator.snapshot(at: Date())).connection
                == acknowledgedLease.connection {
                // Initial thread/list membership is already authoritative for
                // this exact acknowledged empty thread. Never read or resume it.
                var acknowledgedScope = scope
                acknowledgedScope.include(threadID)
                qualified = (acknowledgedScope, true)
            } else {
                qualified = await qualifyThreadBounded(
                    threadID,
                    includeTurns: true,
                    connection: connection,
                    adapter: adapter,
                    coordinator: coordinator,
                    scope: scope,
                    acknowledgedCreatedThreadConnection: acknowledgedLease?.connection
                )
            }
            scope = qualified.scope
            if qualified.didQualify {
                hydratedThreadIDs.insert(threadID)
            } else if let acknowledgedLease,
                      acknowledgedLease.remainingAttempts > 1,
                      (await coordinator.snapshot(at: Date())).connection
                        == acknowledgedLease.connection {
                acknowledgedCreatedThreadQualifications[threadID] = .init(
                    connection: acknowledgedLease.connection,
                    remainingAttempts: acknowledgedLease.remainingAttempts - 1
                )
                requestedThreadQualifications.insert(threadID)
            }
            let inbound = try await processInbound(
                connection: connection,
                adapter: adapter,
                coordinator: coordinator,
                monitoringScope: scope
            )
            scope = inbound.scope
            if inbound.requiresSnapshot { break }
        }

        return InventoryResult(
            scope: scope,
            listedCount: listedThreadIDs.count,
            hydratedCount: hydratedThreadIDs.count,
            qualifiedThreadIDs: hydratedThreadIDs,
            inventoryIsTruncated: inventoryIsTruncated,
            malformedRowCount: malformedRowCount,
            inventoryMembershipIsComplete: inventoryMembershipIsComplete,
            recoveryCount: recoveryCount
        )
    }

    /// Discovers only sessions already resident in this App Server. The status
    /// tier intersects this set with authoritative `thread/list` recency before
    /// calling `thread/resume`, restricting automatic resume attempts to IDs the
    /// server reported as already loaded.
    private func fetchLoadedThreadIDs(
        connection: any AppServerMonitoringConnection,
        adapter: AppServerObservationAdapter
    ) async throws -> [AppServerThreadID] {
        var cursor: String?
        var visitedCursors: Set<String> = []
        var seenThreadIDs: Set<AppServerThreadID> = []
        var loadedThreadIDs: [AppServerThreadID] = []
        var pageCount = 0

        while pageCount < configuration.maximumThreads,
              loadedThreadIDs.count < configuration.maximumThreads {
            try Task.checkCancellation()
            var params: [String: JSONValue] = [
                "limit": .integer(Int64(configuration.pageSize)),
            ]
            if let cursor { params["cursor"] = .string(cursor) }
            guard let response = await requestEnvelopeBounded(
                connection: connection,
                method: "thread/loaded/list",
                params: .object(params),
                timeout: configuration.inventoryRequestTimeout
            ) else { break }
            guard let page = try? adapter.threadLoadedListPage(response: response) else {
                break
            }
            let remaining = max(0, configuration.maximumThreads - loadedThreadIDs.count)
            let targetCount = loadedThreadIDs.count + remaining
            for threadID in page.threadIDs where loadedThreadIDs.count < targetCount {
                guard seenThreadIDs.insert(threadID).inserted else { continue }
                loadedThreadIDs.append(threadID)
            }
            pageCount += 1

            guard let nextCursor = page.nextCursor,
                  loadedThreadIDs.count < configuration.maximumThreads
            else { break }
            guard visitedCursors.insert(nextCursor).inserted else { break }
            cursor = nextCursor
        }
        return loadedThreadIDs
    }

    private func qualifyBatch(
        _ threadIDs: [AppServerThreadID],
        includeTurns: Bool,
        connection: any AppServerMonitoringConnection,
        adapter: AppServerObservationAdapter,
        coordinator: AppServerDomainCoordinator
    ) async -> [AppServerThreadID] {
        await withTaskGroup(
            of: (Int, AppServerThreadID, Bool).self,
            returning: [AppServerThreadID].self
        ) { group in
            for (offset, threadID) in threadIDs.enumerated() {
                group.addTask {
                    let qualified = await self.qualifyThreadBounded(
                        threadID,
                        includeTurns: includeTurns,
                        connection: connection,
                        adapter: adapter,
                        coordinator: coordinator,
                        scope: .init()
                    )
                    return (offset, threadID, qualified.didQualify)
                }
            }
            var ordered: [(Int, AppServerThreadID)] = []
            for await (offset, threadID, didQualify) in group where didQualify {
                ordered.append((offset, threadID))
            }
            return ordered.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func qualifyThread(
        _ threadID: AppServerThreadID,
        includeTurns: Bool,
        connection: any AppServerMonitoringConnection,
        adapter: AppServerObservationAdapter,
        coordinator: AppServerDomainCoordinator,
        scope initialScope: AppServerMonitoringScope,
        acknowledgedCreatedThreadConnection: AppServerConnectionIdentity? = nil
    ) async throws -> (scope: AppServerMonitoringScope, didQualify: Bool) {
        var scope = initialScope
        if let acknowledgedCreatedThreadConnection {
            let snapshot = await coordinator.snapshot(at: Date())
            guard snapshot.connection == acknowledgedCreatedThreadConnection else {
                return (scope, false)
            }
        }
        guard let boundedRead = await requestEnvelopeBounded(
            connection: connection,
            method: "thread/read",
            params: .object([
                "threadId": .string(threadID.rawValue),
                // Resume is the subscription boundary and already returns
                // turns. Keep the identity/status preflight metadata-only so
                // an opened long task does not transfer full history twice.
                "includeTurns": .bool(false),
            ])
        ) else { return (scope, false) }
        let readInput: AppServerProjectionInput
        do {
            readInput = try adapter.threadStatusDelta(
                response: boundedRead,
                expectedThreadID: threadID,
                observedAt: Date()
            )
        } catch {
            return (scope, false)
        }
        guard readInput.scopedThreadID == threadID,
              !readInput.containsTerminalConflictCandidate
        else { return (scope, false) }

        if let acknowledgedCreatedThreadConnection {
            let snapshotBeforeApply = await coordinator.snapshot(at: Date())
            guard snapshotBeforeApply.connection == acknowledgedCreatedThreadConnection else {
                return (scope, false)
            }
            if !snapshotBeforeApply.threads.contains(where: { $0.id == threadID }) {
                _ = try await coordinator.applyAndPersist(readInput.metadataOnlyThreadUpsert)
            }
            let readApply = try await coordinator.applyAndPersist(readInput)
            let snapshotAfterApply = await coordinator.snapshot(at: Date())
            guard snapshotAfterApply.connection == acknowledgedCreatedThreadConnection,
                  readApply == .applied || snapshotAfterApply.threads.contains(where: {
                      $0.id == threadID
                  }) else {
                return (scope, false)
            }
            scope.include(threadID)
            return (scope, true)
        }

        // Loaded-list discovery is advisory and can race unloading. A current
        // notLoaded read is authoritative enough to avoid a resume that might
        // load cold state merely to update a tile.
        if !includeTurns, readInput.scopedThreadStatus == .notLoaded {
            _ = try await coordinator.applyAndPersist(readInput)
            return (scope, false)
        }

        guard let boundedResume = await requestEnvelopeBounded(
            connection: connection,
            method: "thread/resume",
            params: .object(["threadId": .string(threadID.rawValue)])
        ) else { return (scope, false) }
        let resumeInput: AppServerProjectionInput
        do {
            resumeInput = includeTurns
                ? try adapter.threadReadDelta(response: boundedResume, observedAt: Date())
                : try adapter.threadStatusDelta(
                    response: boundedResume,
                    expectedThreadID: threadID,
                    observedAt: Date()
                )
            guard resumeInput.scopedThreadID == threadID,
                  !resumeInput.containsTerminalConflictCandidate
            else { return (scope, false) }
        } catch {
            return (scope, false)
        }
        let readApply = try await coordinator.applyAndPersist(readInput)
        let resumeApply = try await coordinator.applyAndPersist(resumeInput)
        let qualified = scope.qualify(
            requestedThreadID: threadID,
            readInput: readInput,
            readApply: readApply,
            resumeInput: resumeInput,
            resumeApply: resumeApply
        )
        if qualified {
            if let selection = Self.threadModelSelection(from: boundedResume.result) {
                threadModelSelections[threadID] = selection
            }
            markSharedDesktopCandidateResumed(
                threadID,
                connection: boundedResume.connection,
                resumeSequence: boundedResume.sequence
            )
        }
        return (scope, qualified)
    }

    package static func threadModelSelection(
        from result: JSONValue
    ) -> AppServerThreadModelSelection? {
        guard let object = result.objectValue,
              let model = boundedMetadataValue(object["model"]?.stringValue, maximumBytes: 256)
        else { return nil }
        let reasoningEffort = boundedMetadataValue(
            object["reasoningEffort"]?.stringValue,
            maximumBytes: 64
        )
        return .init(model: model, reasoningEffort: reasoningEffort)
    }

    private static func boundedMetadataValue(
        _ value: String?,
        maximumBytes: Int
    ) -> String? {
        guard let value,
              !value.isEmpty,
              value.utf8.count <= maximumBytes,
              value.rangeOfCharacter(from: .newlines) == nil
        else { return nil }
        return value
    }

    private func qualifyThreadBounded(
        _ threadID: AppServerThreadID,
        includeTurns: Bool = false,
        connection: any AppServerMonitoringConnection,
        adapter: AppServerObservationAdapter,
        coordinator: AppServerDomainCoordinator,
        scope: AppServerMonitoringScope,
        acknowledgedCreatedThreadConnection: AppServerConnectionIdentity? = nil
    ) async -> (scope: AppServerMonitoringScope, didQualify: Bool) {
        let timeout = configuration.qualificationTimeout
        return await withTaskGroup(
            of: ThreadQualificationRaceOutcome.self,
            returning: (scope: AppServerMonitoringScope, didQualify: Bool).self
        ) { group in
            group.addTask {
                do {
                    let value = try await self.qualifyThread(
                        threadID,
                        includeTurns: includeTurns,
                        connection: connection,
                        adapter: adapter,
                        coordinator: coordinator,
                        scope: scope,
                        acknowledgedCreatedThreadConnection: acknowledgedCreatedThreadConnection
                    )
                    return .value(scope: value.scope, didQualify: value.didQualify)
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .value(scope: scope, didQualify: false)
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return .timedOut
                } catch {
                    return .cancelled
                }
            }

            let winner = await group.next() ?? .cancelled
            group.cancelAll()
            // Structured cancellation is part of the timeout contract: do not
            // return while a losing read/resume task could still subscribe or
            // apply a late response.
            while await group.next() != nil {}
            switch winner {
            case let .value(scope, didQualify): return (scope, didQualify)
            case .timedOut, .cancelled: return (scope, false)
            }
        }
    }

    private func requestEnvelopeBounded(
        connection: any AppServerMonitoringConnection,
        method: String,
        params: JSONValue?,
        timeout: Duration? = nil
    ) async -> ConnAppServerResponseEnvelope? {
        let timeout = timeout ?? configuration.qualificationTimeout
        return await withTaskGroup(
            of: ResponseEnvelopeRaceOutcome.self,
            returning: ConnAppServerResponseEnvelope?.self
        ) { group in
            group.addTask {
                do {
                    return .response(try await connection.requestEnvelope(
                        method: method,
                        params: params,
                        timeout: timeout
                    ))
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .response(nil)
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return .timedOut
                } catch {
                    return .cancelled
                }
            }

            let winner = await group.next() ?? .cancelled
            group.cancelAll()
            while await group.next() != nil {}
            switch winner {
            case let .response(response): return response
            case .timedOut, .cancelled: return nil
            }
        }
    }

    private func processInbound(
        connection: any AppServerMonitoringConnection,
        adapter: AppServerObservationAdapter,
        coordinator: AppServerDomainCoordinator,
        monitoringScope: AppServerMonitoringScope
    ) async throws -> InboundResult {
        let envelopes = AppServerPresentationDeltaCoalescer.coalesced(
            await connection.drainInboundEnvelopes(),
            presentationLimits: Self.projectionConfiguration.itemPresentationLimits
        )
        var result = InboundResult(scope: monitoringScope)
        for envelope in envelopes {
            try Task.checkCancellation()
            if envelope.message.method == "hook/started"
                || envelope.message.method == "hook/completed" {
                do {
                    guard let observation = try adapter.hookRun(from: envelope),
                          result.scope.monitoredThreadIDs.contains(observation.run.threadID)
                    else { continue }
                    let apply = await hookProjection.applyRun(
                        observation.run, cursor: observation.cursor
                    )
                    if apply == .applied { result.didApply = true }
                } catch {
                    // Isolate malformed hook activity without changing the
                    // thread lifecycle or the healthy monitoring session.
                }
                continue
            }
            let input: AppServerProjectionInput?
            do {
                input = try adapter.projectionInput(from: envelope, observedAt: Date())
            } catch {
                // A malformed instance of a known notification is isolated to
                // that envelope. Other threads and the healthy session live on.
                continue
            }
            guard let input, let threadID = input.scopedThreadID else { continue }
            if sharedDesktopProofDidResume,
               let proofConnection = sharedDesktopProofConnection,
               let resumeSequence = sharedDesktopProofResumeSequence,
               proofConnection.instanceID == envelope.connection.instanceID,
               proofConnection.generation == envelope.connection.generation,
               envelope.sequence > resumeSequence,
               envelope.message.method == "turn/started",
               sharedDesktopProofThreadID == threadID {
                sharedDesktopProofDidObserveEvent = true
            }
            let requiresQualification = envelope.message.method == "thread/started"
                || input.opensAttentionRequest
            if !result.scope.accepts(input), envelope.message.method == "thread/started" {
                // Publish a newly started thread immediately from its current
                // connection metadata. Its timeline remains on-demand.
                result.scope.include(threadID)
                let apply = try await coordinator.applyAndPersist(input.metadataOnlyThreadUpsert)
                if apply == .applied { result.didApply = true }
                if apply == .appliedPendingSnapshot { result.requiresSnapshot = true }
                continue
            }
            if !result.scope.accepts(input) && requiresQualification {
                let qualified = try await qualifyThread(
                    threadID,
                    includeTurns: false,
                    connection: connection,
                    adapter: adapter,
                    coordinator: coordinator,
                    scope: result.scope
                )
                result.scope = qualified.scope
                guard qualified.didQualify else {
                    throw SessionFailure(status: .init(
                        phase: .reconnecting,
                        detail: "A new or attention-bearing thread could not be qualified safely; Conn will refresh the full inventory instead of dropping its request."
                    ))
                }
            }
            guard result.scope.accepts(input) else { continue }
            let apply = try await coordinator.applyAndPersist(input)
            if apply == .applied { result.didApply = true }
            if apply == .appliedPendingSnapshot { result.requiresSnapshot = true }
            let metrics = await coordinator.storageMetrics()
            if metrics.requiresSnapshot || metrics.rejectsDeltasUntilReconnect {
                result.requiresSnapshot = true
            }
        }
        return result
    }

    private func refreshConfiguredHooks(
        connection: any AppServerMonitoringConnection,
        adapter: AppServerObservationAdapter,
        coordinator: AppServerDomainCoordinator,
        fallbackWorkingDirectories: [String] = []
    ) async -> Bool {
        let snapshot = await coordinator.snapshot(at: Date())
        let workingDirectoryScope = Self.boundedHookWorkingDirectoryScope(
            snapshot.threads.compactMap(\.workingDirectoryPath)
                + fallbackWorkingDirectories
        )
        let allWorkingDirectories = workingDirectoryScope.directories
        guard !allWorkingDirectories.isEmpty else {
            knownHookWorkingDirectories = []
            knownHookWorkingDirectoryScopeIsComplete = true
            if let identity = snapshot.connection {
                return await hookProjection.markConfigurationStale(identity) == .applied
            }
            return false
        }
        knownHookWorkingDirectories = allWorkingDirectories
        let scopeIsTruncated = !workingDirectoryScope.isComplete
        knownHookWorkingDirectoryScopeIsComplete = workingDirectoryScope.isComplete
        let cwds = knownHookWorkingDirectories.map(JSONValue.string)
        guard let response = await requestEnvelopeBounded(
            connection: connection,
            method: "hooks/list",
            params: .object(["cwds": .array(Array(cwds))]),
            timeout: configuration.qualificationTimeout
        ), let observation = try? adapter.configuredHooks(response: response)
        else {
            guard let identity = snapshot.connection else { return false }
            return await hookProjection.markConfigurationStale(identity) == .applied
        }
        let applied = await hookProjection.replaceConfiguredHooks(
            observation.hooks, cursor: observation.cursor
        ) == .applied
        if applied, scopeIsTruncated, let identity = snapshot.connection {
            _ = await hookProjection.markConfigurationStale(identity)
        }
        return applied
    }

    private func resetSharedDesktopThreadProof(
        connection: AppServerConnectionIdentity?
    ) {
        if let oldThreadID = sharedDesktopProofThreadID {
            requestedThreadQualifications.remove(oldThreadID)
        }
        sharedDesktopProofConnection = connection
        sharedDesktopProofThreadID = nil
        sharedDesktopProofDidResume = false
        sharedDesktopProofResumeSequence = nil
        sharedDesktopProofDidObserveEvent = false
    }

    private func refreshLegacyPluginRetirementStatus() async {
        let outcome = await legacyPluginRetirement.scan(
            workingDirectories: knownHookWorkingDirectories
        )
        if !knownHookWorkingDirectoryScopeIsComplete {
            // A partial workspace-directory marketplace scan can report a
            // candidate but can never authorize the global pluginId uninstall.
            // Clear captured authority after observing the outcome. Absence is
            // non-consequential; it is not promoted to proof or persisted.
            _ = await legacyPluginRetirement.scan(workingDirectories: [])
            switch outcome {
            case .absent:
                legacyPluginRetirementDiagnostic = nil
            case .candidate, .ambiguous:
                legacyPluginRetirementDiagnostic = "Conn cannot safely scope a global legacy-plugin uninstall across every workspace. Remove the exact Sidequest selector manually in Codex /plugins."
            case .invalidResponse, .unavailable, .unsupported:
                legacyPluginRetirementDiagnostic = "Conn cannot verify that the retired Sidequest plugin is absent. Check and remove its exact selector manually in Codex /plugins."
            case .connectionInvalidated:
                legacyPluginRetirementDiagnostic = nil
            }
            return
        }
        switch outcome {
        case .absent, .candidate:
            legacyPluginRetirementDiagnostic = nil
        case .ambiguous:
            legacyPluginRetirementDiagnostic = "Legacy plugin identity is ambiguous across marketplaces. Remove the exact Sidequest selectors manually in Codex /plugins."
        case .invalidResponse, .unavailable, .unsupported:
            legacyPluginRetirementDiagnostic = "Conn cannot verify that the retired Sidequest plugin is absent. Check and remove its exact selector manually in Codex /plugins."
        case .connectionInvalidated:
            legacyPluginRetirementDiagnostic = nil
        }
    }

    private func markSharedDesktopCandidateResumed(
        _ threadID: AppServerThreadID,
        connection: ConnAppServerConnectionIdentity,
        resumeSequence: UInt64
    ) {
        guard let proofConnection = sharedDesktopProofConnection,
              proofConnection.instanceID == connection.instanceID,
              proofConnection.generation == connection.generation,
              sharedDesktopProofThreadID == threadID else { return }
        sharedDesktopProofDidResume = true
        // Only a later exact-thread turn/started lifecycle event can prove new
        // cross-client activity. Status and item replay never satisfy proof.
        sharedDesktopProofResumeSequence = resumeSequence
        sharedDesktopProofDidObserveEvent = false
    }

    private func consumeInventoryRefreshRequest() -> Bool {
        let requested = inventoryRefreshRequested
        inventoryRefreshRequested = false
        return requested
    }

    private func publishHydrationProgress(
        coordinator: AppServerDomainCoordinator,
        domain: AppServerProjectionStore,
        cliVersion: String,
        appServerVersion: String,
        listedCount: Int,
        hydratedCount: Int,
        monitoredCount: Int,
        inventoryIsTruncated: Bool,
        malformedRowCount: Int,
        inventoryMembershipIsComplete: Bool,
        onUpdate: @escaping @MainActor @Sendable (Update) -> Void
    ) async {
        await publish(
            coordinator: coordinator,
            domain: domain,
            status: .init(
                phase: .hydrating,
                detail: Self.hydratingInventoryDetail(
                    listedCount: listedCount,
                    qualifiedCount: hydratedCount,
                    scopeCount: monitoredCount
                ) + (malformedRowCount > 0
                    ? " Skipped \(malformedRowCount) malformed thread inventory row\(malformedRowCount == 1 ? "" : "s"); valid siblings remain visible."
                    : "") + (inventoryMembershipIsComplete
                        ? ""
                        : " Inventory membership is incomplete, so cached rows were not deleted."),
                cliVersion: cliVersion,
                appServerVersion: appServerVersion,
                listedThreadCount: listedCount,
                hydratedThreadCount: hydratedCount,
                monitoredThreadCount: monitoredCount,
                isThreadInventoryTruncated: inventoryIsTruncated,
                malformedInventoryRowCount: malformedRowCount,
                isThreadInventoryMembershipComplete: inventoryMembershipIsComplete
            ),
            onUpdate: onUpdate
        )
    }

    private func publish(
        coordinator: AppServerDomainCoordinator?,
        domain: AppServerProjectionStore,
        status: AppServerRuntimeStatus,
        at date: Date = Date(),
        onUpdate: @escaping @MainActor @Sendable (Update) -> Void
    ) async {
        let retirementDiagnostic = [
            legacyHookRetirementDiagnostic,
            legacyPluginRetirementDiagnostic,
        ].compactMap { $0 }.joined(separator: " ")
        let presentedRetirementDiagnostic = retirementDiagnostic.isEmpty
            ? nil
            : retirementDiagnostic
        let snapshot: AppServerProjectionSnapshot
        let publishedStatus: AppServerRuntimeStatus
        if let coordinator {
            snapshot = await coordinator.snapshot(at: date)
            publishedStatus = status
                .appendingDiagnostic(await coordinator.persistenceDiagnostic())
                .appendingDiagnostic(presentedRetirementDiagnostic)
        } else {
            snapshot = await domain.snapshot(at: date)
            publishedStatus = status.appendingDiagnostic(presentedRetirementDiagnostic)
        }
        await onUpdate(.init(
            snapshot: snapshot,
            threadModelSelections: snapshot.connection == nil ? [:] : threadModelSelections,
            hooks: await hookProjection.snapshot(),
            legacyPluginCandidate: await legacyPluginRetirement.currentCandidate(),
            legacyHookRetirementDiagnostic: presentedRetirementDiagnostic,
            status: publishedStatus,
            observedAt: date
        ))
    }
}
