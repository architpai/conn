import Foundation

// MARK: - Upstream identity

public struct AppServerThreadID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct AppServerSessionID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct AppServerTurnID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct AppServerItemID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Preserves the JSON-RPC distinction between numeric and string identifiers.
/// No conversion through UUID or String is performed at the domain seam.
public enum AppServerRequestID: Hashable, Comparable, Codable, Sendable {
    case integer(Int64)
    case string(String)

    public static func < (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.integer(left), .integer(right)): left < right
        case let (.string(left), .string(right)): left < right
        case (.integer, .string): true
        case (.string, .integer): false
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .integer(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        }
    }
}

/// Runtime-only authority. Deliberately not Codable: a connection instance or
/// generation restored from disk must never become current request authority.
public struct AppServerConnectionIdentity: Hashable, Sendable {
    public let instanceID: UUID
    public let generation: UInt64

    public init(instanceID: UUID, generation: UInt64) {
        self.instanceID = instanceID
        self.generation = generation
    }
}

/// A monotonic receive position within one initialized connection generation.
/// Reducer application order may vary; source sequence remains authoritative.
public struct AppServerObservationCursor: Hashable, Comparable, Sendable {
    public let connection: AppServerConnectionIdentity
    public let sequence: UInt64

    public init(connection: AppServerConnectionIdentity, sequence: UInt64) {
        self.connection = connection
        self.sequence = sequence
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.connection.instanceID != rhs.connection.instanceID {
            return lhs.connection.instanceID.uuidString < rhs.connection.instanceID.uuidString
        }
        if lhs.connection.generation != rhs.connection.generation {
            return lhs.connection.generation < rhs.connection.generation
        }
        return lhs.sequence < rhs.sequence
    }
}

// MARK: - Capability and source evidence

public enum AppServerConnectionSource: String, Codable, Hashable, Sendable {
    case managedDaemon
    case verifiedSharedDesktop

    public var presentationLabel: String {
        switch self {
        case .managedDaemon: "Managed Daemon"
        case .verifiedSharedDesktop: "Shared Desktop"
        }
    }
}

public enum AppServerThreadSource: String, Codable, Hashable, Sendable {
    case appServer
    case cli
    case vscode
    case exec
    case subagent
    case custom
    case unknown

    public var presentationLabel: String {
        switch self {
        case .appServer: "Codex App Server"
        case .cli: "Codex CLI"
        case .vscode: "Codex VS Code"
        case .exec: "Codex Exec"
        case .subagent: "Codex Subagent"
        case .custom: "Codex"
        case .unknown: "Codex"
        }
    }
}

public enum AppServerFeature: String, Codable, Hashable, Sendable {
    case monitor
    case openInCodex
    case createThread
    case answer
    case steer
    case followUp
    case stopTurn
    case resolveApproval
}

/// Supplied by AppCore only after version/schema qualification. The domain does
/// not infer feature support from initialize responses or arbitrary methods.
public struct AppServerFeatureSupport: Codable, Equatable, Sendable {
    public let features: Set<AppServerFeature>

    public init(features: Set<AppServerFeature> = []) {
        self.features = features
    }

    public func supports(_ feature: AppServerFeature) -> Bool {
        features.contains(feature)
    }
}

// MARK: - Typed App Server facts

public enum AppServerThreadActiveFlag: String, Codable, Hashable, Sendable {
    case waitingOnApproval
    case waitingOnUserInput
}

public enum AppServerThreadStatus: Codable, Equatable, Sendable {
    case notLoaded
    case idle
    case systemError
    case active(Set<AppServerThreadActiveFlag>)
    case unknown
}

public enum AppServerTurnStatus: String, Codable, Hashable, Sendable {
    case inProgress
    case completed
    case interrupted
    case failed
    case unknown

    public var isTerminal: Bool {
        self == .completed || self == .interrupted || self == .failed
    }
}

public enum AppServerTurnItemsView: String, Codable, Hashable, Sendable {
    case notLoaded
    case summary
    case full
}

public enum AppServerItemKind: String, Codable, Hashable, Sendable {
    case userMessage
    case hookPrompt
    case agentMessage
    case plan
    case reasoning
    case commandExecution
    case fileChange
    case mcpToolCall
    case dynamicToolCall
    case collabAgentToolCall
    case subagentActivity = "subAgentActivity"
    case webSearch
    case imageView
    case sleep
    case imageGeneration
    case enteredReviewMode
    case exitedReviewMode
    case contextCompaction
    case unknown

    public init(from decoder: any Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        // Accept Phase 8's pre-release spelling only when restoring an older
        // disposable checkpoint; all newly encoded/wire-facing values use the
        // schema-faithful `subAgentActivity` discriminator.
        if rawValue == "subagentActivity" {
            self = .subagentActivity
        } else if let value = Self(rawValue: rawValue) {
            self = value
        } else {
            self = .unknown
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum AppServerItemStatus: String, Codable, Hashable, Sendable {
    case started
    case completed
    case failed
    case unknown

    public var isTerminal: Bool { self == .completed || self == .failed }
}

public struct AppServerItemInput: Equatable, Sendable {
    public let id: AppServerItemID
    public let kind: AppServerItemKind
    public let status: AppServerItemStatus
    public let startedAt: Date?
    public let completedAt: Date?
    /// Bounded display-only content. This is intentionally runtime-only and
    /// is omitted from durable App Server checkpoints.
    public let presentation: AppServerItemPresentationPayload?

    public init(
        id: AppServerItemID,
        kind: AppServerItemKind,
        status: AppServerItemStatus,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        presentation: AppServerItemPresentationPayload? = nil
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.presentation = presentation
    }
}

public struct AppServerTurnInput: Equatable, Sendable {
    public let id: AppServerTurnID
    public let status: AppServerTurnStatus
    public let startedAt: Date?
    public let completedAt: Date?
    public let itemsView: AppServerTurnItemsView
    public let items: [AppServerItemInput]

    public init(
        id: AppServerTurnID,
        status: AppServerTurnStatus,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        itemsView: AppServerTurnItemsView = .full,
        items: [AppServerItemInput] = []
    ) {
        self.id = id
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.itemsView = itemsView
        self.items = items
    }
}

public struct AppServerThreadInput: Equatable, Sendable {
    public let id: AppServerThreadID
    public let sessionID: AppServerSessionID
    public let title: String?
    public let workingDirectoryName: String?
    /// Privacy-safe path metadata used only to distinguish project groups.
    public let workingDirectoryPath: String?
    /// Locally resolved repository root when upstream gitInfo proves this is a
    /// git-backed thread. Origin URLs are deliberately not retained.
    public let projectRootPath: String?
    /// Bounded display-only Git branch. This is intentionally runtime-only;
    /// origin URLs and commit SHAs never cross the observation seam.
    public let gitBranch: String?
    public let source: AppServerThreadSource
    public let parentThreadID: AppServerThreadID?
    public let forkedFromThreadID: AppServerThreadID?
    public let status: AppServerThreadStatus
    public let createdAt: Date?
    public let updatedAt: Date
    /// True only for a response that loaded the complete turn collection, such
    /// as thread/read with includeTurns. thread/list must leave this false.
    public let turnsAreAuthoritative: Bool
    public let turns: [AppServerTurnInput]

    public init(
        id: AppServerThreadID,
        sessionID: AppServerSessionID,
        title: String? = nil,
        workingDirectoryName: String? = nil,
        workingDirectoryPath: String? = nil,
        projectRootPath: String? = nil,
        gitBranch: String? = nil,
        source: AppServerThreadSource = .unknown,
        parentThreadID: AppServerThreadID? = nil,
        forkedFromThreadID: AppServerThreadID? = nil,
        status: AppServerThreadStatus,
        createdAt: Date? = nil,
        updatedAt: Date,
        turnsAreAuthoritative: Bool = false,
        turns: [AppServerTurnInput] = []
    ) {
        self.id = id
        self.sessionID = sessionID
        self.title = title
        self.workingDirectoryName = workingDirectoryName
        self.workingDirectoryPath = workingDirectoryPath
        self.projectRootPath = projectRootPath
        self.gitBranch = gitBranch
        self.source = source
        self.parentThreadID = parentThreadID
        self.forkedFromThreadID = forkedFromThreadID
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.turnsAreAuthoritative = turnsAreAuthoritative
        self.turns = turns
    }
}

public enum AppServerRequestKind: String, Codable, Hashable, Sendable {
    case commandApproval
    case fileChangeApproval
    case permissionsApproval
    case structuredQuestion
    case mcpElicitation
    case unknown
}

/// Decisions whose response shapes are reviewed in the pinned stable schemas.
/// Amendment-bearing command decisions remain unsupported because Conn cannot
/// safely synthesize policy changes from a two-button notch card.
public enum AppServerApprovalChoice: String, Equatable, Hashable, Sendable {
    case approve
    case approveForSession
    case deny
    case cancel
}

public struct AppServerCommandApprovalFacts: Equatable, Sendable {
    public let command: String?
    public let workingDirectory: String?
    public let reason: String?
    public let availableChoices: [AppServerApprovalChoice]

    public init(
        command: String?,
        workingDirectory: String?,
        reason: String?,
        availableChoices: [AppServerApprovalChoice] = [
            .approve, .approveForSession, .deny, .cancel,
        ]
    ) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.reason = reason
        self.availableChoices = availableChoices
    }
}

public struct AppServerFileChangeApprovalFacts: Equatable, Sendable {
    public let reason: String?
    public let grantRoot: String?
    public let availableChoices: [AppServerApprovalChoice]

    public init(
        reason: String?,
        grantRoot: String?,
        availableChoices: [AppServerApprovalChoice] = [
            .approve, .approveForSession, .deny, .cancel,
        ]
    ) {
        self.reason = reason
        self.grantRoot = grantRoot
        self.availableChoices = availableChoices
    }
}

public enum AppServerFileSystemAccess: String, Equatable, Hashable, Sendable {
    case read
    case write
    case deny
}

public enum AppServerFileSystemSpecialPath: Equatable, Hashable, Sendable {
    case root
    case minimal
    case projectRoots(subpath: String?)
    case temporaryDirectory
    case slashTemporaryDirectory
    case unknown(path: String, subpath: String?)
}

public enum AppServerFileSystemPath: Equatable, Hashable, Sendable {
    case path(String)
    case globPattern(String)
    case special(AppServerFileSystemSpecialPath)
}

public struct AppServerFileSystemPermissionEntry: Equatable, Hashable, Sendable {
    public let access: AppServerFileSystemAccess
    public let path: AppServerFileSystemPath

    public init(access: AppServerFileSystemAccess, path: AppServerFileSystemPath) {
        self.access = access
        self.path = path
    }
}

public struct AppServerRequestedFileSystemPermissions: Equatable, Sendable {
    public let entries: [AppServerFileSystemPermissionEntry]?
    public let globScanMaximumDepth: UInt?
    public let readPaths: [String]?
    public let writePaths: [String]?

    public init(
        entries: [AppServerFileSystemPermissionEntry]? = nil,
        globScanMaximumDepth: UInt? = nil,
        readPaths: [String]? = nil,
        writePaths: [String]? = nil
    ) {
        self.entries = entries
        self.globScanMaximumDepth = globScanMaximumDepth
        self.readPaths = readPaths
        self.writePaths = writePaths
    }
}

public struct AppServerRequestedNetworkPermissions: Equatable, Sendable {
    public let enabled: Bool?

    public init(enabled: Bool?) {
        self.enabled = enabled
    }
}

public struct AppServerRequestedPermissionProfile: Equatable, Sendable {
    public let fileSystem: AppServerRequestedFileSystemPermissions?
    public let network: AppServerRequestedNetworkPermissions?

    public init(
        fileSystem: AppServerRequestedFileSystemPermissions? = nil,
        network: AppServerRequestedNetworkPermissions? = nil
    ) {
        self.fileSystem = fileSystem
        self.network = network
    }
}

public struct AppServerPermissionsApprovalFacts: Equatable, Sendable {
    public let workingDirectory: String
    public let reason: String?
    public let requestedPermissions: AppServerRequestedPermissionProfile
    public let availableChoices: [AppServerApprovalChoice]

    public init(
        workingDirectory: String,
        reason: String?,
        requestedPermissions: AppServerRequestedPermissionProfile,
        availableChoices: [AppServerApprovalChoice] = [
            .approve, .approveForSession, .deny,
        ]
    ) {
        self.workingDirectory = workingDirectory
        self.reason = reason
        self.requestedPermissions = requestedPermissions
        self.availableChoices = availableChoices
    }
}

public struct AppServerQuestionOption: Equatable, Hashable, Sendable {
    public let label: String
    public let detail: String

    public init(label: String, detail: String) {
        self.label = label
        self.detail = detail
    }
}

public struct AppServerStructuredQuestion: Equatable, Sendable {
    public let id: String
    public let header: String
    public let prompt: String
    public let options: [AppServerQuestionOption]?
    public let permitsOther: Bool
    public let isSecret: Bool

    public init(
        id: String,
        header: String,
        prompt: String,
        options: [AppServerQuestionOption]?,
        permitsOther: Bool,
        isSecret: Bool
    ) {
        self.id = id
        self.header = header
        self.prompt = prompt
        self.options = options
        self.permitsOther = permitsOther
        self.isSecret = isSecret
    }
}

public struct AppServerStructuredQuestionFacts: Equatable, Sendable {
    public let questions: [AppServerStructuredQuestion]
    public let autoResolutionMilliseconds: UInt64?

    public init(
        questions: [AppServerStructuredQuestion],
        autoResolutionMilliseconds: UInt64?
    ) {
        self.questions = questions
        self.autoResolutionMilliseconds = autoResolutionMilliseconds
    }
}

/// Runtime-only details needed to present and answer a server request exactly.
/// This type is deliberately not Codable, and requests are structurally absent
/// from AppServerProjectionCheckpoint.
public enum AppServerRequestFacts: Equatable, Sendable {
    case commandApproval(AppServerCommandApprovalFacts)
    case fileChangeApproval(AppServerFileChangeApprovalFacts)
    case permissionsApproval(AppServerPermissionsApprovalFacts)
    case structuredQuestions(AppServerStructuredQuestionFacts)
    case unsupported
}

public struct AppServerRequestInput: Equatable, Sendable {
    public let requestID: AppServerRequestID
    public let threadID: AppServerThreadID
    public let turnID: AppServerTurnID?
    public let itemID: AppServerItemID?
    public let kind: AppServerRequestKind
    public let facts: AppServerRequestFacts
    public let startedAt: Date

    public init(
        requestID: AppServerRequestID,
        threadID: AppServerThreadID,
        turnID: AppServerTurnID? = nil,
        itemID: AppServerItemID? = nil,
        kind: AppServerRequestKind,
        facts: AppServerRequestFacts = .unsupported,
        startedAt: Date
    ) {
        self.requestID = requestID
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.kind = kind
        self.facts = facts
        self.startedAt = startedAt
    }
}

/// Bounded, runtime-only presentation fragments from stable App Server item
/// notifications. Raw reasoning text, command output, patches, and arbitrary
/// tool progress never enter this type.
public enum AppServerItemPresentationDelta: Equatable, Sendable {
    case agentText(String)
    case reasoningSummaryPartAdded(index: Int)
    case reasoningSummaryText(index: Int, text: String)
}

public enum AppServerProjectionDelta: Equatable, Sendable {
    case threadUpsert(AppServerThreadInput)
    case threadStatus(threadID: AppServerThreadID, status: AppServerThreadStatus)
    case threadRemoved(AppServerThreadID)
    case turnUpsert(threadID: AppServerThreadID, turn: AppServerTurnInput)
    case itemUpsert(threadID: AppServerThreadID, turnID: AppServerTurnID, item: AppServerItemInput)
    case itemPresentationDelta(
        threadID: AppServerThreadID,
        turnID: AppServerTurnID,
        itemID: AppServerItemID,
        delta: AppServerItemPresentationDelta
    )
    case threadTokenUsage(
        threadID: AppServerThreadID,
        turnID: AppServerTurnID,
        usage: AppServerTokenUsage
    )
    case turnPlanUpdated(
        threadID: AppServerThreadID,
        turnID: AppServerTurnID,
        plan: AppServerTurnPlan
    )
    case requestOpened(AppServerRequestInput)
    case requestResolved(threadID: AppServerThreadID, requestID: AppServerRequestID)
}

public struct AppServerSnapshotInput: Equatable, Sendable {
    public let cursor: AppServerObservationCursor
    public let observedAt: Date
    public let threads: [AppServerThreadInput]
    /// Provenance for the rows in this snapshot. Ordinary domain snapshots
    /// remain `rehydrated`; the monitoring runtime opts into `live` only for
    /// metadata returned by the current qualified App Server connection.
    public let threadFreshness: AppServerProjectionFreshness
    /// Metadata-only inventories update tiles and membership but cannot fence
    /// or erase live request/turn/item notifications racing with thread/list.
    public let contentAuthority: AppServerSnapshotContentAuthority
    /// Only a completed inventory may remove rows absent from this snapshot.
    /// Incremental pagination and pre-qualification gates merge included rows
    /// while retaining restored rows as stale until inventory is complete.
    public let inventoryAuthority: AppServerSnapshotInventoryAuthority
    /// Complete listed identity set when qualification yields fewer hydrated
    /// thread values than the authoritative inventory. Defaults to the IDs in
    /// `threads`; listed-but-unqualified cached rows therefore remain stale.
    public let authoritativeThreadIDs: Set<AppServerThreadID>?

    public init(
        cursor: AppServerObservationCursor,
        observedAt: Date,
        threads: [AppServerThreadInput],
        threadFreshness: AppServerProjectionFreshness = .rehydrated,
        contentAuthority: AppServerSnapshotContentAuthority = .complete,
        inventoryAuthority: AppServerSnapshotInventoryAuthority = .authoritative,
        authoritativeThreadIDs: Set<AppServerThreadID>? = nil
    ) {
        self.cursor = cursor
        self.observedAt = observedAt
        self.threads = threads
        self.threadFreshness = threadFreshness
        self.contentAuthority = contentAuthority
        self.inventoryAuthority = inventoryAuthority
        self.authoritativeThreadIDs = authoritativeThreadIDs
    }
}

public enum AppServerSnapshotContentAuthority: Equatable, Sendable {
    case complete
    case metadataOnly
}

public enum AppServerSnapshotInventoryAuthority: Equatable, Sendable {
    /// The snapshot represents the complete inventory at its cursor. Rows not
    /// present may be authoritatively removed.
    case authoritative
    /// The snapshot is an incremental page or qualification gate. Missing rows
    /// remain cached and stale until a completed inventory proves removal.
    case incremental
}

public struct AppServerDeltaInput: Equatable, Sendable {
    public let cursor: AppServerObservationCursor
    public let observedAt: Date
    public let delta: AppServerProjectionDelta

    public init(
        cursor: AppServerObservationCursor,
        observedAt: Date,
        delta: AppServerProjectionDelta
    ) {
        self.cursor = cursor
        self.observedAt = observedAt
        self.delta = delta
    }
}

public enum AppServerProjectionInput: Equatable, Sendable {
    case connectionActivated(
        identity: AppServerConnectionIdentity,
        source: AppServerConnectionSource,
        featureSupport: AppServerFeatureSupport
    )
    case snapshot(AppServerSnapshotInput)
    case delta(AppServerDeltaInput)
    case connectionLost(AppServerConnectionIdentity)
}

public enum AppServerProjectionApplyResult: Equatable, Sendable {
    case applied
    /// Accepted but not published as a live projection because the reducer
    /// requires a new authoritative snapshot. Callers must not count this as
    /// successful hydration.
    case appliedPendingSnapshot
    case duplicate
    case rejectedStaleConnection
    case ignoredTombstoned
    case ignoredInvalidIdentity
}

// MARK: - Presentation projection

public enum AppServerProjectionFreshness: String, Codable, Hashable, Sendable {
    case live
    case rehydrated
    case stale
}

public enum AppServerActivityKind: String, Codable, Hashable, Sendable {
    case idle
    case working
    case runningCommand
    case changingFiles
    case usingTool
    case waitingForApproval
    case waitingForInput
    case completed
    case failed
    case interrupted
    case unknown
}

public enum AppServerOutcomeKind: String, Codable, Hashable, Sendable {
    case completed
    case failed
    case interrupted
}

/// Shared limits for presentation-only App Server item content. Every limit is
/// enforced at the wire adapter and revalidated by the projection store.
public struct AppServerItemPresentationLimits: Equatable, Sendable {
    public static let standard = AppServerItemPresentationLimits()

    public let maximumTextUTF8Bytes: Int
    public let maximumTextLineCount: Int
    public let maximumReasoningSummaryParts: Int
    public let maximumFileChanges: Int
    public let maximumPathUTF8Bytes: Int
    public let maximumNameUTF8Bytes: Int
    public let maximumPlanSteps: Int
    public let maximumPlanStepUTF8Bytes: Int

    public init(
        maximumTextUTF8Bytes: Int = 8 * 1_024,
        maximumTextLineCount: Int = 80,
        maximumReasoningSummaryParts: Int = 16,
        maximumFileChanges: Int = 64,
        maximumPathUTF8Bytes: Int = 512,
        maximumNameUTF8Bytes: Int = 256,
        maximumPlanSteps: Int = 32,
        maximumPlanStepUTF8Bytes: Int = 512
    ) {
        self.maximumTextUTF8Bytes = max(1, maximumTextUTF8Bytes)
        self.maximumTextLineCount = max(1, maximumTextLineCount)
        self.maximumReasoningSummaryParts = max(1, maximumReasoningSummaryParts)
        self.maximumFileChanges = max(1, maximumFileChanges)
        self.maximumPathUTF8Bytes = max(1, maximumPathUTF8Bytes)
        self.maximumNameUTF8Bytes = max(1, maximumNameUTF8Bytes)
        self.maximumPlanSteps = max(1, maximumPlanSteps)
        self.maximumPlanStepUTF8Bytes = max(1, maximumPlanStepUTF8Bytes)
    }
}

public enum AppServerFileChangeKind: String, Equatable, Sendable {
    case add
    case delete
    case update
    case unknown
}

public struct AppServerFileChangePresentation: Equatable, Sendable {
    public let path: String
    public let kind: AppServerFileChangeKind
    public let additions: Int?
    public let deletions: Int?

    public init(
        path: String,
        kind: AppServerFileChangeKind,
        additions: Int? = nil,
        deletions: Int? = nil
    ) {
        self.path = path
        self.kind = kind
        self.additions = additions.map { max(0, $0) }
        self.deletions = deletions.map { max(0, $0) }
    }
}

/// Safe, bounded content for the notch presentation. The enum is deliberately
/// not Codable so it cannot silently become part of a durable checkpoint.
public enum AppServerItemPresentationPayload: Equatable, Sendable {
    case userText(String)
    case agentText(String)
    case agentFinalText(String)
    case planText(String)
    case reasoningSummary([String])
    case command(String)
    case fileChanges([AppServerFileChangePresentation])
    case tool(name: String, server: String?)
}

/// Bounded integers from `thread/tokenUsage/updated`. The fact is runtime-only
/// and is never part of `AppServerProjectionCheckpoint`.
public struct AppServerTokenUsage: Equatable, Sendable {
    public let usedTokens: Int64
    public let contextWindow: Int64?

    public init(usedTokens: Int64, contextWindow: Int64?) {
        self.usedTokens = usedTokens
        self.contextWindow = contextWindow
    }
}

public enum AppServerTurnPlanStepStatus: String, Equatable, Sendable {
    case pending
    case inProgress
    case completed
    case unknown
}

public struct AppServerTurnPlanStep: Equatable, Sendable {
    public let step: String
    public let status: AppServerTurnPlanStepStatus

    public init(step: String, status: AppServerTurnPlanStepStatus) {
        self.step = step
        self.status = status
    }
}

/// Latest bounded `turn/plan/updated` fact for one turn. Plan text remains
/// runtime-only and is excluded by `AppServerProjectedTurn`'s custom Codable.
public struct AppServerTurnPlan: Equatable, Sendable {
    public let steps: [AppServerTurnPlanStep]
    public let updatedAt: Date

    public init(steps: [AppServerTurnPlanStep], updatedAt: Date) {
        self.steps = steps
        self.updatedAt = updatedAt
    }
}

public struct AppServerProjectedItem: Codable, Equatable, Sendable, Identifiable {
    public let id: AppServerItemID
    public let kind: AppServerItemKind
    public let status: AppServerItemStatus
    public let startedAt: Date?
    public let completedAt: Date?
    /// Runtime presentation content. Custom Codable intentionally omits it.
    public let presentation: AppServerItemPresentationPayload?

    public init(input: AppServerItemInput) {
        id = input.id
        kind = input.kind
        status = input.status
        startedAt = input.startedAt
        completedAt = input.completedAt
        presentation = input.presentation
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case status
        case startedAt
        case completedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(AppServerItemID.self, forKey: .id)
        kind = try container.decode(AppServerItemKind.self, forKey: .kind)
        status = try container.decode(AppServerItemStatus.self, forKey: .status)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        presentation = nil
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
    }
}

public struct AppServerProjectedTurn: Codable, Equatable, Sendable, Identifiable {
    public let id: AppServerTurnID
    public let status: AppServerTurnStatus
    public let startedAt: Date?
    public let completedAt: Date?
    public let itemsView: AppServerTurnItemsView
    public let items: [AppServerProjectedItem]
    /// Runtime-only structured plan. Custom Codable intentionally omits it.
    public let plan: AppServerTurnPlan?

    public init(
        id: AppServerTurnID,
        status: AppServerTurnStatus,
        startedAt: Date?,
        completedAt: Date?,
        itemsView: AppServerTurnItemsView,
        items: [AppServerProjectedItem],
        plan: AppServerTurnPlan? = nil
    ) {
        self.id = id
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.itemsView = itemsView
        self.items = items
        self.plan = plan
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case status
        case startedAt
        case completedAt
        case itemsView
        case items
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(AppServerTurnID.self, forKey: .id)
        status = try container.decode(AppServerTurnStatus.self, forKey: .status)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        itemsView = try container.decode(AppServerTurnItemsView.self, forKey: .itemsView)
        items = try container.decode([AppServerProjectedItem].self, forKey: .items)
        plan = nil
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encode(itemsView, forKey: .itemsView)
        try container.encode(items, forKey: .items)
    }
}

public struct AppServerProjectedOutcome: Codable, Equatable, Sendable, Identifiable {
    public let threadID: AppServerThreadID
    public let turnID: AppServerTurnID
    public let kind: AppServerOutcomeKind
    public let completedAt: Date?

    public var id: AppServerTurnID { turnID }

    public init(
        threadID: AppServerThreadID,
        turnID: AppServerTurnID,
        kind: AppServerOutcomeKind,
        completedAt: Date?
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.kind = kind
        self.completedAt = completedAt
    }
}

/// Runtime-only request authority. It cannot enter AppServerProjectionCheckpoint.
public struct AppServerScopedRequestID: Hashable, Sendable {
    public let connection: AppServerConnectionIdentity
    public let requestID: AppServerRequestID

    public init(connection: AppServerConnectionIdentity, requestID: AppServerRequestID) {
        self.connection = connection
        self.requestID = requestID
    }
}

public struct AppServerProjectedRequest: Equatable, Sendable, Identifiable {
    public let id: AppServerScopedRequestID
    public let threadID: AppServerThreadID
    public let turnID: AppServerTurnID?
    public let itemID: AppServerItemID?
    public let kind: AppServerRequestKind
    public let facts: AppServerRequestFacts
    public let startedAt: Date
}

public struct AppServerProjectedThread: Equatable, Sendable, Identifiable {
    public let id: AppServerThreadID
    public let sessionID: AppServerSessionID?
    public let title: String?
    public let workingDirectoryName: String?
    public let workingDirectoryPath: String?
    public let projectRootPath: String?
    public let gitBranch: String?
    public let source: AppServerThreadSource
    public let sourceLabel: String
    public let parentThreadID: AppServerThreadID?
    public let forkedFromThreadID: AppServerThreadID?
    public let status: AppServerThreadStatus
    /// Freshness of the thread status independently of detailed turn content.
    /// A current metadata inventory can authoritatively report `active` while
    /// an older cached timeline still requires explicit hydration.
    public let statusFreshness: AppServerProjectionFreshness
    public let freshness: AppServerProjectionFreshness
    public let activity: AppServerActivityKind
    public let createdAt: Date?
    public let updatedAt: Date
    public let lastObservedAt: Date
    public let turns: [AppServerProjectedTurn]
    public let activeTurnIDs: [AppServerTurnID]
    public let requests: [AppServerProjectedRequest]
    public let outcome: AppServerProjectedOutcome?
    /// Latest refresh-style context usage. Runtime-only and checkpoint-excluded.
    public let tokenUsage: AppServerTokenUsage?

    public var isActive: Bool {
        (statusFreshness == .live && status.isActive)
            || (freshness != .stale && (!activeTurnIDs.isEmpty || !requests.isEmpty))
    }
}

public struct AppServerProjectionSnapshot: Equatable, Sendable {
    public let connection: AppServerConnectionIdentity?
    public let connectionSource: AppServerConnectionSource
    public let connectionSourceLabel: String
    public let featureSupport: AppServerFeatureSupport
    public let threads: [AppServerProjectedThread]

    public var activeThreads: [AppServerProjectedThread] { threads.filter(\.isActive) }
    public var attentionRequests: [AppServerProjectedRequest] { threads.flatMap(\.requests) }
}

private extension AppServerThreadStatus {
    var isActive: Bool {
        if case .active = self { return true }
        return false
    }
}

// MARK: - Bounded durable cache

public enum AppServerCheckpointKind: String, Codable, Sendable {
    case appServerProjection
}

public struct AppServerCachedThread: Codable, Equatable, Sendable {
    public let id: AppServerThreadID
    public let sessionID: AppServerSessionID?
    public let title: String?
    public let workingDirectoryName: String?
    public let workingDirectoryPath: String?
    public let projectRootPath: String?
    public let source: AppServerThreadSource
    public let parentThreadID: AppServerThreadID?
    public let forkedFromThreadID: AppServerThreadID?
    public let status: AppServerThreadStatus
    public let createdAt: Date?
    public let updatedAt: Date
    public let lastObservedAt: Date
    public let turns: [AppServerProjectedTurn]

    public init(
        id: AppServerThreadID,
        sessionID: AppServerSessionID?,
        title: String?,
        workingDirectoryName: String?,
        workingDirectoryPath: String? = nil,
        projectRootPath: String? = nil,
        source: AppServerThreadSource,
        parentThreadID: AppServerThreadID?,
        forkedFromThreadID: AppServerThreadID?,
        status: AppServerThreadStatus,
        createdAt: Date?,
        updatedAt: Date,
        lastObservedAt: Date,
        turns: [AppServerProjectedTurn]
    ) {
        self.id = id
        self.sessionID = sessionID
        self.title = title
        self.workingDirectoryName = workingDirectoryName
        self.workingDirectoryPath = workingDirectoryPath
        self.projectRootPath = projectRootPath
        self.source = source
        self.parentThreadID = parentThreadID
        self.forkedFromThreadID = forkedFromThreadID
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastObservedAt = lastObservedAt
        self.turns = turns
    }
}

public struct AppServerProjectionCheckpoint: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let checkpointKind: AppServerCheckpointKind
    public let schemaVersion: Int
    public let savedAt: Date
    public let connectionSource: AppServerConnectionSource
    public let threads: [AppServerCachedThread]

    public init(
        checkpointKind: AppServerCheckpointKind = .appServerProjection,
        schemaVersion: Int = currentSchemaVersion,
        savedAt: Date,
        connectionSource: AppServerConnectionSource,
        threads: [AppServerCachedThread]
    ) {
        self.checkpointKind = checkpointKind
        self.schemaVersion = schemaVersion
        self.savedAt = savedAt
        self.connectionSource = connectionSource
        self.threads = threads
    }
}

public enum AppServerProjectionCheckpointError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidCheckpoint
}

public struct AppServerProjectionConfiguration: Equatable, Sendable {
    /// Production monitoring keeps Phase 7's protocol-shape bounds while
    /// adding a strict aggregate ceiling for runtime-only presentation bytes.
    /// Metadata remains available when older presentation payloads are shed.
    public static let monitoring = AppServerProjectionConfiguration(
        maximumThreads: 1_000,
        maximumTurnsPerThread: 100,
        maximumItemsPerTurn: 300,
        maximumAggregatePresentationBytes: 8 * 1_024 * 1_024,
        itemPresentationLimits: .init(
            maximumTextUTF8Bytes: 4 * 1_024,
            maximumTextLineCount: 40,
            maximumReasoningSummaryParts: 8,
            maximumFileChanges: 32,
            maximumPathUTF8Bytes: 512,
            maximumNameUTF8Bytes: 256
        )
    )

    public let maximumThreads: Int
    public let maximumTurnsPerThread: Int
    public let maximumItemsPerTurn: Int
    public let maximumUnresolvedRequests: Int
    public let maximumThreadTombstones: Int
    public let maximumResolvedRequestTombstones: Int
    public let maximumHydrationDeltas: Int
    public let maximumStringBytes: Int
    /// Nil preserves the Phase 7 general-purpose reducer defaults. Production
    /// monitoring uses an explicit finite ceiling.
    public let maximumAggregatePresentationBytes: Int?
    public let itemPresentationLimits: AppServerItemPresentationLimits

    public init(
        maximumThreads: Int = 100,
        maximumTurnsPerThread: Int = 20,
        maximumItemsPerTurn: Int = 100,
        maximumUnresolvedRequests: Int = 256,
        maximumThreadTombstones: Int = 256,
        maximumResolvedRequestTombstones: Int = 512,
        maximumHydrationDeltas: Int = 512,
        maximumStringBytes: Int = 512,
        maximumAggregatePresentationBytes: Int? = nil,
        itemPresentationLimits: AppServerItemPresentationLimits = .standard
    ) {
        self.maximumThreads = max(1, maximumThreads)
        self.maximumTurnsPerThread = max(1, maximumTurnsPerThread)
        self.maximumItemsPerTurn = max(1, maximumItemsPerTurn)
        self.maximumUnresolvedRequests = max(1, maximumUnresolvedRequests)
        self.maximumThreadTombstones = max(1, maximumThreadTombstones)
        self.maximumResolvedRequestTombstones = max(1, maximumResolvedRequestTombstones)
        self.maximumHydrationDeltas = max(1, maximumHydrationDeltas)
        self.maximumStringBytes = max(1, maximumStringBytes)
        self.maximumAggregatePresentationBytes = maximumAggregatePresentationBytes.map {
            max(1, $0)
        }
        self.itemPresentationLimits = itemPresentationLimits
    }
}

public struct AppServerProjectionStorageMetrics: Equatable, Sendable {
    public let threadCount: Int
    public let turnCount: Int
    public let itemCount: Int
    public let presentationByteCount: Int
    public let unresolvedRequestCount: Int
    public let threadTombstoneCount: Int
    public let resolvedRequestTombstoneCount: Int
    public let bufferedDeltaCount: Int
    public let requiresSnapshot: Bool
    public let rejectsDeltasUntilReconnect: Bool
}
