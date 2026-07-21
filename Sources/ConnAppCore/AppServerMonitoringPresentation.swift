import Foundation
import ConnDomain

public enum AppServerPresentationTone: String, Equatable, Sendable {
    case neutral
    case active
    case attention
    case success
    case failure
    case warning
    case unavailable
}

public enum AppServerTimelineCategory: String, Equatable, Sendable {
    case userMessage
    case agentOutput
    case finalAnswer
    case plan
    case reasoning
    case command
    case fileChange
    case tool
    case subagent
    case webSearch
    case image
    case compaction
    case lifecycle
    case outcome
    case unknown
}

/// The five mock-aligned current states plus an explicit neutral fallback.
/// `unknown` is intentionally not folded into idle: absence of current evidence
/// must not become a claim that a Codex thread is idle.
public enum AppServerThreadVisualState: String, CaseIterable, Equatable, Sendable {
    case waitingForApproval
    case needsInput
    case running
    case failed
    case unreviewedOutcome
    case idle
    case notLoaded
    case unknown

    public var urgency: Int {
        switch self {
        case .waitingForApproval: 0
        case .needsInput: 1
        case .running: 2
        case .failed: 3
        case .unreviewedOutcome: 4
        case .idle: 5
        case .notLoaded: 6
        case .unknown: 7
        }
    }

    public var statusLabel: String {
        switch self {
        case .waitingForApproval: "Needs approval"
        case .needsInput: "Needs input"
        case .running: "Running"
        case .failed: "Failed"
        case .unreviewedOutcome: "Completed"
        case .idle: "Idle"
        case .notLoaded: "Not loaded"
        case .unknown: "Status unavailable"
        }
    }

    public var accessibilityLabel: String {
        self == .unreviewedOutcome
            ? "Status: Completed, not reviewed"
            : "Status: \(statusLabel)"
    }

    fileprivate var tone: AppServerPresentationTone {
        switch self {
        case .waitingForApproval, .needsInput: .attention
        case .running: .active
        case .failed: .failure
        case .unreviewedOutcome: .success
        case .idle, .notLoaded, .unknown: .neutral
        }
    }
}

public struct AppServerStatusPillPresentation: Equatable, Sendable, Identifiable {
    public let id: String
    public let visualState: AppServerThreadVisualState
    public let count: Int
    public let countLabel: String
    public let accessibilityLabel: String
    public let highestPriorityThreadID: String

    fileprivate init(
        visualState: AppServerThreadVisualState,
        threads: [AppServerThreadPresentation]
    ) {
        id = visualState.rawValue
        self.visualState = visualState
        count = threads.count
        countLabel = String(threads.count)
        highestPriorityThreadID = threads[0].id
        accessibilityLabel = AppServerPresentationText.accessibility(
            "\(threads.count) thread\(threads.count == 1 ? "" : "s"), \(visualState.statusLabel.lowercased())"
        )
    }
}

public struct AppServerTokenUsagePresentation: Equatable, Sendable {
    public static let warningThreshold = 80

    public let usedTokens: Int64
    public let contextWindow: Int64?
    public let percentage: Int?
    public let ringProgress: Double?
    public let isWarning: Bool
    public let percentageLabel: String
    public let detailLabel: String
    public let accessibilityLabel: String

    public init(usedTokens: Int64, contextWindow: Int64?) {
        self.usedTokens = max(0, usedTokens)
        self.contextWindow = contextWindow.flatMap { $0 > 0 ? $0 : nil }

        if let window = self.contextWindow {
            let progress = min(1, max(0, Double(self.usedTokens) / Double(window)))
            let percentage = Int((progress * 100).rounded())
            self.percentage = percentage
            ringProgress = progress
            isWarning = progress >= Double(Self.warningThreshold) / 100
            percentageLabel = "\(percentage)%"
            detailLabel = "\(self.usedTokens) of \(window) tokens used"
            accessibilityLabel = AppServerPresentationText.accessibility(
                "Context usage \(percentage) percent, \(detailLabel)"
            )
        } else {
            percentage = nil
            ringProgress = nil
            isWarning = false
            percentageLabel = "Unavailable"
            detailLabel = "Context window unavailable"
            accessibilityLabel = "Context usage unavailable"
        }
    }
}

public enum AppServerTurnPlanStepVisualState: String, Equatable, Sendable {
    case pending
    case inProgress
    case completed
    case unknown

    public var statusLabel: String {
        switch self {
        case .pending: "Pending"
        case .inProgress: "In progress"
        case .completed: "Completed"
        case .unknown: "Status unavailable"
        }
    }
}

public struct AppServerTurnPlanStepPresentation: Equatable, Sendable, Identifiable {
    public let id: Int
    public let index: Int
    public let text: String
    public let state: AppServerTurnPlanStepVisualState
    public let statusLabel: String
    public let accessibilityLabel: String

    fileprivate init(index: Int, step: String, state: AppServerTurnPlanStepVisualState) {
        id = index
        self.index = index
        text = AppServerPresentationText.oneLine(step)
        self.state = state
        statusLabel = state.statusLabel
        accessibilityLabel = AppServerPresentationText.accessibility(
            "Step \(index + 1), \(text), \(statusLabel)"
        )
    }
}

public struct AppServerTurnPlanPresentation: Equatable, Sendable {
    public let title: String
    public let steps: [AppServerTurnPlanStepPresentation]
    public let updatedAt: Date
    public let accessibilityLabel: String

    fileprivate init(plan: AppServerTurnPlan, title: String = "Turn plan") {
        self.title = title
        steps = plan.steps.enumerated().map { index, step in
            AppServerTurnPlanStepPresentation(
                index: index,
                step: step.step,
                state: Self.visualState(step.status)
            )
        }
        updatedAt = plan.updatedAt
        accessibilityLabel = AppServerPresentationText.accessibility(
            ([title] + steps.map(\.accessibilityLabel)).joined(separator: ", ")
        )
    }

    private static func visualState(
        _ status: AppServerTurnPlanStepStatus
    ) -> AppServerTurnPlanStepVisualState {
        switch status {
        case .pending: .pending
        case .inProgress: .inProgress
        case .completed: .completed
        case .unknown: .unknown
        }
    }
}

public struct AppServerTimelineItemPresentation: Equatable, Sendable, Identifiable {
    public static let maximumVisibleDetailLineCount = 4
    public static let maximumVisibleDetailCharacterCount = 512
    public static let maximumVisibleDetailUTF8Bytes = 1_024
    public static let maximumFinalAnswerLineCount = 40
    public static let maximumFinalAnswerCharacterCount = 4_096
    public static let maximumFinalAnswerUTF8Bytes = 4_096
    public static let maximumExpandedFinalAnswerLineCount = 10_000
    public static let maximumExpandedFinalAnswerCharacterCount = 262_144
    public static let maximumExpandedFinalAnswerUTF8Bytes = 262_144

    public let id: String
    public let turnID: String?
    public let sourceOrder: Int
    public let category: AppServerTimelineCategory
    public let title: String
    public let detail: String?
    public let expandedDetail: String?
    public let isDetailTruncated: Bool
    public let statusLabel: String
    public let observedLabel: String
    public let observedAt: Date
    public let tone: AppServerPresentationTone
    public let accessibilityLabel: String

    fileprivate init(
        id: String,
        turnID: String? = nil,
        sourceOrder: Int = .max,
        category: AppServerTimelineCategory,
        title: String,
        detail: String?,
        statusLabel: String,
        observedLabel: String,
        observedAt: Date,
        tone: AppServerPresentationTone
    ) {
        self.id = id
        self.turnID = turnID
        self.sourceOrder = sourceOrder
        self.category = category
        self.title = title
        let isAgentAuthoredText = category == .agentOutput || category == .finalAnswer
        self.detail = isAgentAuthoredText
            ? AppServerTimelineDetail.bounded(
                detail,
                maximumLines: Self.maximumFinalAnswerLineCount,
                maximumCharacters: Self.maximumFinalAnswerCharacterCount,
                maximumUTF8Bytes: Self.maximumFinalAnswerUTF8Bytes
            )
            : AppServerTimelineDetail.bounded(detail)
        let expandedFinalDetail = isAgentAuthoredText
            ? AppServerTimelineDetail.bounded(
                detail,
                maximumLines: Self.maximumExpandedFinalAnswerLineCount,
                maximumCharacters: Self.maximumExpandedFinalAnswerCharacterCount,
                maximumUTF8Bytes: Self.maximumExpandedFinalAnswerUTF8Bytes
            )
            : nil
        isDetailTruncated = expandedFinalDetail != self.detail
        expandedDetail = isDetailTruncated ? expandedFinalDetail : nil
        self.statusLabel = statusLabel
        self.observedLabel = observedLabel
        self.observedAt = observedAt
        self.tone = tone
        let fullAccessibilityLabel = [title, self.detail, statusLabel, observedLabel]
            .compactMap { $0 }
            .joined(separator: ", ")
        accessibilityLabel = isAgentAuthoredText
            ? AppServerPresentationText.accessibility(fullAccessibilityLabel)
            : fullAccessibilityLabel
    }
}

public enum AppServerAttentionResponseStyle: Equatable, Sendable {
    case approval
    case input
}

public struct AppServerAttentionPresentation: Equatable, Sendable, Identifiable {
    public let id: String
    public let scopedRequestID: AppServerScopedRequestID
    public let threadID: AppServerThreadID
    public let turnID: AppServerTurnID?
    public let title: String
    public let detail: String
    public let kindLabel: String
    public let responseStyle: AppServerAttentionResponseStyle
    public let facts: AppServerRequestFacts
    public let availableApprovalChoices: [AppServerApprovalChoice]
    public let questions: [AppServerStructuredQuestion]
    public let responseSupportDetail: String
    public let isResponseShapeSupported: Bool
    public let observedAt: Date

    fileprivate init(request: AppServerProjectedRequest) {
        id = Self.identity(request.id.requestID)
        scopedRequestID = request.id
        threadID = request.threadID
        turnID = request.turnID
        observedAt = request.startedAt
        facts = request.facts
        availableApprovalChoices = Self.approvalChoices(request.facts)
        questions = Self.questions(request.facts)
        isResponseShapeSupported = Self.isResponseShapeSupported(request.facts)
        responseSupportDetail = isResponseShapeSupported
            ? "Conn can submit a response correlated to this exact request."
            : "This request shape cannot be answered safely in Conn. Respond in Codex."
        switch request.kind {
        case .commandApproval:
            title = "Command approval required"
            detail = Self.commandDetail(request.facts)
            kindLabel = "Approval"
            responseStyle = .approval
        case .fileChangeApproval:
            title = "File change approval required"
            detail = Self.fileChangeDetail(request.facts)
            kindLabel = "Approval"
            responseStyle = .approval
        case .permissionsApproval:
            title = "Permission required"
            detail = Self.permissionsDetail(request.facts)
            kindLabel = "Permission"
            responseStyle = .approval
        case .structuredQuestion:
            title = "Answer required"
            detail = Self.questionDetail(request.facts)
            kindLabel = "Question"
            responseStyle = .input
        case .mcpElicitation:
            title = "Tool input required"
            detail = "A connected tool is waiting for input, but the pinned stable request does not expose a safely answerable form."
            kindLabel = "Tool request"
            responseStyle = .input
        case .unknown:
            title = "Attention required"
            detail = "This connected thread is waiting for a response."
            kindLabel = "Request"
            responseStyle = .input
        }
    }

    private static func approvalChoices(
        _ facts: AppServerRequestFacts
    ) -> [AppServerApprovalChoice] {
        switch facts {
        case let .commandApproval(value): value.availableChoices
        case let .fileChangeApproval(value): value.availableChoices
        case let .permissionsApproval(value): value.availableChoices
        case .structuredQuestions, .unsupported: []
        }
    }

    private static func questions(
        _ facts: AppServerRequestFacts
    ) -> [AppServerStructuredQuestion] {
        guard case let .structuredQuestions(value) = facts else { return [] }
        return value.questions
    }

    private static func isResponseShapeSupported(_ facts: AppServerRequestFacts) -> Bool {
        switch facts {
        case .commandApproval, .fileChangeApproval, .structuredQuestions:
            true
        case let .permissionsApproval(value):
            permissionsAreFullyVisibleAndKnown(value)
        case .unsupported:
            false
        }
    }

    private static func commandDetail(_ facts: AppServerRequestFacts) -> String {
        guard case let .commandApproval(value) = facts else {
            return "Command details are unavailable. Respond in Codex."
        }
        return joinedDetail([
            value.command,
            value.reason.map { "Reason: \($0)" },
            value.workingDirectory.map { "Working directory: \($0)" },
        ], fallback: "This connected thread is waiting for a command decision.")
    }

    private static func fileChangeDetail(_ facts: AppServerRequestFacts) -> String {
        guard case let .fileChangeApproval(value) = facts else {
            return "File-change details are unavailable. Respond in Codex."
        }
        return joinedDetail([
            value.reason.map { "Reason: \($0)" },
            value.grantRoot.map { "Requested root: \($0)" },
        ], fallback: "This connected thread is waiting for a file-change decision.")
    }

    private static func permissionsDetail(_ facts: AppServerRequestFacts) -> String {
        guard case let .permissionsApproval(value) = facts else {
            return "Permission details are unavailable. Respond in Codex."
        }
        return AppServerPresentationText.accessibility(
            unboundedPermissionsDetail(value)
        )
    }

    private static func permissionsAreFullyVisibleAndKnown(
        _ value: AppServerPermissionsApprovalFacts
    ) -> Bool {
        let entries = value.requestedPermissions.fileSystem?.entries ?? []
        guard !entries.contains(where: { entry in
            guard case let .special(special) = entry.path else { return false }
            if case .unknown = special { return true }
            return false
        }) else { return false }
        return unboundedPermissionsDetail(value).utf8.count
            <= AppServerPresentationText.maximumAccessibilityUTF8Bytes
    }

    private static func unboundedPermissionsDetail(
        _ value: AppServerPermissionsApprovalFacts
    ) -> String {
        let fileSystem = value.requestedPermissions.fileSystem
        let entries = fileSystem?.entries?.map(permissionEntryDetail) ?? []
        let readPaths = fileSystem?.readPaths?.map {
            "Filesystem read path: \($0)"
        } ?? []
        let writePaths = fileSystem?.writePaths?.map {
            "Filesystem write path: \($0)"
        } ?? []
        let depth = fileSystem?.globScanMaximumDepth.map {
            "Filesystem glob scan max depth: \($0)"
        }
        let network = value.requestedPermissions.network?.enabled.map {
            $0 ? "Network access requested" : "Network access disabled"
        }
        let details = [
            value.reason.map { "Reason: \($0)" },
            "Working directory: \(value.workingDirectory)",
        ].compactMap { $0 } + entries + readPaths + writePaths + [depth, network].compactMap { $0 }
        return details.joined(separator: "\n")
    }

    private static func permissionEntryDetail(
        _ entry: AppServerFileSystemPermissionEntry
    ) -> String {
        let prefix = "Filesystem entry · \(entry.access.rawValue)"
        switch entry.path {
        case let .path(path):
            return "\(prefix) · path: \(path)"
        case let .globPattern(pattern):
            return "\(prefix) · glob_pattern: \(pattern)"
        case let .special(special):
            switch special {
            case .root:
                return "\(prefix) · root"
            case .minimal:
                return "\(prefix) · minimal"
            case let .projectRoots(subpath):
                return [prefix, "project_roots", subpath.map { "subpath: \($0)" }]
                    .compactMap { $0 }
                    .joined(separator: " · ")
            case .temporaryDirectory:
                return "\(prefix) · tmpdir"
            case .slashTemporaryDirectory:
                return "\(prefix) · slash_tmp"
            case let .unknown(path, subpath):
                return [prefix, "unknown", "path: \(path)", subpath.map { "subpath: \($0)" }]
                    .compactMap { $0 }
                    .joined(separator: " · ")
            }
        }
    }

    private static func questionDetail(_ facts: AppServerRequestFacts) -> String {
        guard case let .structuredQuestions(value) = facts,
              let first = value.questions.first else {
            return "Question details are unavailable. Respond in Codex."
        }
        if value.questions.count == 1 { return first.prompt }
        return "\(value.questions.count) questions · \(first.prompt)"
    }

    private static func joinedDetail(
        _ values: [String?],
        fallback: String
    ) -> String {
        let detail = values.compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }.joined(separator: "\n")
        return detail.isEmpty ? fallback : detail
    }

    private static func identity(_ id: AppServerRequestID) -> String {
        switch id {
        case let .integer(value): "integer:\(value)"
        case let .string(value): "string:\(value)"
        }
    }
}

public struct AppServerThreadPresentation: Equatable, Sendable, Identifiable {
    public let id: String
    public let threadID: AppServerThreadID
    public let title: String
    public let identifierLabel: String
    public let sourceLabel: String
    public let activity: AppServerActivityKind
    public let activityLabel: String
    public let visualState: AppServerThreadVisualState
    public let statusLabel: String
    public let statusAccessibilityLabel: String
    public let headline: String
    public let workingDirectoryLabel: String?
    public let gitBranchLabel: String?
    public let metaLabel: String?
    public let freshness: AppServerProjectionFreshness
    public let freshnessLabel: String
    public let freshnessDetail: String
    public let lastObservedLabel: String
    public let lastObservedAt: Date
    /// App Server's authoritative thread activity time. Unlike
    /// `lastObservedAt`, this does not change when Conn opens a row.
    public let updatedAt: Date
    public let attention: AppServerAttentionPresentation?
    public let attentionCount: Int
    public let outcomeLabel: String?
    public let outcomeIdentity: AppServerOutcomeIdentity?
    public let isOutcomeUnreviewed: Bool
    public let timeline: [AppServerTimelineItemPresentation]
    public let tokenUsage: AppServerTokenUsagePresentation?
    public let plan: AppServerTurnPlanPresentation?
    public let rowPriority: ShellRowPriority
    public let tone: AppServerPresentationTone
    public let isActive: Bool
    public let supportsExactThreadNavigation: Bool
    public let accessibilityLabel: String

    /// Runtime-only empty state for an exact, acknowledged `thread/start`
    /// identity while the monitoring projection catches up. It is replaced by
    /// the authoritative projection and is never checkpointed.
    public init(
        newlyCreatedThreadID: AppServerThreadID,
        workingDirectory: String,
        now: Date
    ) {
        id = newlyCreatedThreadID.rawValue
        threadID = newlyCreatedThreadID
        title = "New chat"
        identifierLabel = "Thread \(Self.shortIdentifier(newlyCreatedThreadID.rawValue))"
        sourceLabel = "Managed daemon"
        activity = .idle
        activityLabel = "Idle"
        visualState = .idle
        statusLabel = visualState.statusLabel
        statusAccessibilityLabel = visualState.accessibilityLabel
        headline = "Ready for your first message"
        workingDirectoryLabel = AppServerPresentationText.optionalOneLine(workingDirectory)
        gitBranchLabel = nil
        metaLabel = workingDirectoryLabel
        freshness = .live
        freshnessLabel = Self.freshnessLabel(.live)
        freshnessDetail = Self.freshnessDetail(.live)
        lastObservedLabel = "Observed just now"
        lastObservedAt = now
        updatedAt = now
        attention = nil
        attentionCount = 0
        outcomeLabel = nil
        outcomeIdentity = nil
        isOutcomeUnreviewed = false
        timeline = []
        tokenUsage = nil
        plan = nil
        rowPriority = .recent
        tone = .neutral
        isActive = false
        supportsExactThreadNavigation = false
        accessibilityLabel = AppServerPresentationText.accessibility(
            [title, statusLabel, headline, workingDirectoryLabel, freshnessLabel]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
    }

    fileprivate init(
        thread: AppServerProjectedThread,
        hasCurrentAuthority: Bool,
        unreviewedOutcomeIDs: Set<AppServerOutcomeIdentity>,
        reviewedOutcomeIDs: Set<AppServerOutcomeIdentity>,
        includeTimeline: Bool = true,
        now: Date
    ) {
        let effectiveFreshness: AppServerProjectionFreshness = hasCurrentAuthority
            ? thread.freshness
            : .stale
        let effectiveStatusFreshness: AppServerProjectionFreshness = hasCurrentAuthority
            ? thread.statusFreshness
            : .stale
        let hasCurrentAttention = effectiveFreshness == .live && !thread.requests.isEmpty
        let projectedOutcomeIdentity = thread.outcome.map {
            AppServerOutcomeIdentity(threadID: $0.threadID, turnID: $0.turnID)
        }
        let outcomeIsUnreviewed = effectiveFreshness == .live
            && projectedOutcomeIdentity.map(unreviewedOutcomeIDs.contains) == true
        let outcomeIsReviewed = projectedOutcomeIdentity.map(reviewedOutcomeIDs.contains) == true
        id = thread.id.rawValue
        threadID = thread.id
        title = Self.title(thread)
        identifierLabel = "Thread \(Self.shortIdentifier(thread.id.rawValue))"
        sourceLabel = thread.sourceLabel
        activity = thread.activity
        activityLabel = Self.activityLabel(thread.activity)
        visualState = Self.visualState(
            thread,
            freshness: effectiveFreshness,
            statusFreshness: effectiveStatusFreshness,
            isOutcomeUnreviewed: outcomeIsUnreviewed,
            isOutcomeReviewed: outcomeIsReviewed
        )
        statusLabel = visualState.statusLabel
        statusAccessibilityLabel = visualState.accessibilityLabel
        freshness = effectiveFreshness
        freshnessLabel = Self.freshnessLabel(effectiveFreshness)
        freshnessDetail = Self.freshnessDetail(effectiveFreshness)
        lastObservedLabel = "Observed \(AppServerRelativeTime.label(from: thread.lastObservedAt, to: now).lowercased())"
        lastObservedAt = thread.lastObservedAt
        updatedAt = thread.updatedAt
        attention = hasCurrentAttention
            ? Self.highestPriorityRequest(in: thread.requests)
                .map(AppServerAttentionPresentation.init(request:))
            : nil
        attentionCount = hasCurrentAttention ? thread.requests.count : 0
        outcomeLabel = thread.outcome.map { Self.outcomeLabel($0.kind) }
        outcomeIdentity = projectedOutcomeIdentity
        isOutcomeUnreviewed = outcomeIsUnreviewed
        timeline = includeTimeline ? Self.timeline(thread, now: now) : []
        headline = Self.headline(
            thread,
            visualState: visualState,
            timeline: timeline,
            now: now
        )
        workingDirectoryLabel = AppServerPresentationText.optionalOneLine(
            thread.workingDirectoryPath ?? thread.workingDirectoryName
        )
        gitBranchLabel = AppServerPresentationText.optionalOneLine(thread.gitBranch)
        let meta = [workingDirectoryLabel, gitBranchLabel]
            .compactMap { $0 }
            .joined(separator: " · ")
        metaLabel = meta.isEmpty ? nil : AppServerPresentationText.oneLine(meta)
        tokenUsage = thread.tokenUsage.map {
            AppServerTokenUsagePresentation(
                usedTokens: $0.usedTokens,
                contextWindow: $0.contextWindow
            )
        }
        plan = Self.currentOrLatestPlan(thread)
        let visualStateIsActive = switch visualState {
        case .waitingForApproval, .needsInput, .running, .failed, .unreviewedOutcome: true
        case .idle, .notLoaded, .unknown: false
        }
        isActive = visualStateIsActive
            && (effectiveFreshness == .live || effectiveStatusFreshness == .live)
        // Phase 8 has no reviewed public action that can target a selected
        // thread. Generic Codex activation remains a separate shell action.
        supportsExactThreadNavigation = false
        tone = Self.tone(thread, freshness: effectiveFreshness, visualState: visualState)
        rowPriority = Self.rowPriority(
            thread,
            freshness: effectiveFreshness,
            visualState: visualState,
            isOutcomeUnreviewed: outcomeIsUnreviewed
        )
        accessibilityLabel = AppServerPresentationText.accessibility(
            [title, statusLabel, headline, metaLabel, freshnessLabel]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
    }

    private static func title(_ thread: AppServerProjectedThread) -> String {
        let explicitTitle = thread.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !explicitTitle.isEmpty { return explicitTitle }
        let directoryName = thread.workingDirectoryName?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !directoryName.isEmpty {
            return productDisplayName(directoryName)
        }
        return "Connected thread"
    }

    private static func productDisplayName(_ name: String) -> String {
        name.caseInsensitiveCompare("SideQuest") == .orderedSame ? "Conn" : name
    }

    /// The shell intentionally presents one bounded unresolved request card.
    /// Keep that card aligned with the status taxonomy: approval decisions win
    /// over structured input, then request age and identity make selection
    /// deterministic within the same class.
    private static func highestPriorityRequest(
        in requests: [AppServerProjectedRequest]
    ) -> AppServerProjectedRequest? {
        requests.min {
            let lhsPriority = requestPriority($0.kind)
            let rhsPriority = requestPriority($1.kind)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return String(describing: $0.id.requestID) < String(describing: $1.id.requestID)
        }
    }

    private static func requestPriority(_ kind: AppServerRequestKind) -> Int {
        switch kind {
        case .commandApproval, .fileChangeApproval, .permissionsApproval: 0
        case .structuredQuestion, .mcpElicitation: 1
        case .unknown: 2
        }
    }

    private static func shortIdentifier(_ value: String) -> String {
        let suffix = value.suffix(8)
        return suffix.isEmpty ? "unknown" : String(suffix)
    }

    private static func visualState(
        _ thread: AppServerProjectedThread,
        freshness: AppServerProjectionFreshness,
        statusFreshness: AppServerProjectionFreshness,
        isOutcomeUnreviewed: Bool,
        isOutcomeReviewed: Bool
    ) -> AppServerThreadVisualState {
        let hasCurrentStatus = statusFreshness == .live

        if (hasCurrentStatus && thread.status == .systemError)
            || (freshness == .live
                && !isOutcomeReviewed
                && thread.outcome?.kind == .failed) {
            return .failed
        }

        let flags: Set<AppServerThreadActiveFlag>
        if hasCurrentStatus, case let .active(activeFlags) = thread.status {
            flags = activeFlags
        } else {
            flags = []
        }
        let hasApprovalRequest = thread.requests.contains {
            switch $0.kind {
            case .commandApproval, .fileChangeApproval, .permissionsApproval: true
            case .structuredQuestion, .mcpElicitation, .unknown: false
            }
        }
        let hasInputRequest = thread.requests.contains {
            switch $0.kind {
            case .structuredQuestion, .mcpElicitation: true
            case .commandApproval, .fileChangeApproval, .permissionsApproval, .unknown: false
            }
        }
        if flags.contains(.waitingOnApproval)
            || (freshness == .live && (hasApprovalRequest || thread.activity == .waitingForApproval)) {
            return .waitingForApproval
        }
        if flags.contains(.waitingOnUserInput)
            || (freshness == .live && (hasInputRequest || thread.activity == .waitingForInput)) {
            return .needsInput
        }

        if hasCurrentStatus, case .active = thread.status {
            return .running
        }

        if freshness == .live,
           isOutcomeUnreviewed,
           thread.outcome?.kind == .completed {
            return .unreviewedOutcome
        }

        if hasCurrentStatus {
            switch thread.status {
            case .active: return .running
            case .idle: return .idle
            case .notLoaded: return .notLoaded
            case .unknown, .systemError: return .unknown
            }
        }
        return .unknown
    }

    private static func headline(
        _ thread: AppServerProjectedThread,
        visualState: AppServerThreadVisualState,
        timeline: [AppServerTimelineItemPresentation],
        now: Date
    ) -> String {
        switch visualState {
        case .waitingForApproval:
            let detail = thread.requests.first(where: {
                switch $0.kind {
                case .commandApproval, .fileChangeApproval, .permissionsApproval: true
                case .structuredQuestion, .mcpElicitation, .unknown: false
                }
            }).map(AppServerAttentionPresentation.init(request:))?.title
            return AppServerPresentationText.headline("Awaiting approval", detail)
        case .needsInput:
            let detail = thread.requests.first(where: {
                $0.kind == .structuredQuestion || $0.kind == .mcpElicitation
            }).map(AppServerAttentionPresentation.init(request:))?.title
            return AppServerPresentationText.headline("Awaiting input", detail)
        case .failed:
            if thread.status == .systemError {
                return "System error"
            }
            return "Turn failed"
        case .unreviewedOutcome:
            let relative = thread.outcome.map {
                AppServerRelativeTime.label(
                    from: $0.completedAt ?? thread.lastObservedAt,
                    to: now
                ).lowercased()
            }
            return AppServerPresentationText.headline(
                "Completed",
                relative.map { "not reviewed · \($0)" }
            )
        case .running:
            switch thread.activity {
            case .runningCommand:
                return AppServerPresentationText.headline(
                    "Running a command",
                    latestDetail(in: timeline, category: .command)
                )
            case .changingFiles:
                return AppServerPresentationText.headline(
                    "Changing files",
                    latestDetail(in: timeline, category: .fileChange)
                )
            case .usingTool:
                return AppServerPresentationText.headline(
                    "Using a tool",
                    latestDetail(in: timeline, category: .tool)
                )
            case .working:
                return AppServerPresentationText.headline(
                    "Working",
                    latestActivityDetail(in: timeline)
                )
            case .waitingForApproval:
                return "Awaiting approval"
            case .waitingForInput:
                return "Awaiting input"
            case .idle, .completed, .failed, .interrupted, .unknown:
                return "Running"
            }
        case .idle:
            if let outcome = thread.outcome {
                let observedAt = outcome.completedAt ?? thread.lastObservedAt
                let relative = AppServerRelativeTime.label(from: observedAt, to: now).lowercased()
                switch outcome.kind {
                case .completed:
                    return AppServerPresentationText.headline(
                        "Idle",
                        "last turn finished \(relative)"
                    )
                case .interrupted:
                    return AppServerPresentationText.headline(
                        "Idle",
                        "turn interrupted \(relative)"
                    )
                case .failed:
                    return "Turn failed"
                }
            }
            return "Idle"
        case .notLoaded:
            return "Not currently loaded by managed daemon"
        case .unknown:
            return "Status unavailable"
        }
    }

    private static func latestDetail(
        in timeline: [AppServerTimelineItemPresentation],
        category: AppServerTimelineCategory
    ) -> String? {
        guard let item = timeline.last(where: { $0.category == category }) else { return nil }
        return item.detail ?? item.title
    }

    private static func latestActivityDetail(
        in timeline: [AppServerTimelineItemPresentation]
    ) -> String? {
        guard let item = timeline.last(where: {
            $0.category != .outcome && $0.category != .lifecycle
        }) else { return nil }
        return item.detail ?? item.title
    }

    private static func currentOrLatestPlan(
        _ thread: AppServerProjectedThread
    ) -> AppServerTurnPlanPresentation? {
        let activeTurns = thread.turns.filter {
            $0.status == .inProgress || thread.activeTurnIDs.contains($0.id)
        }
        if !activeTurns.isEmpty {
            // An active turn without a plan must not inherit a completed turn's
            // plan and present it as current.
            return activeTurns.max(by: turnComesBefore).flatMap { turn in
                turn.plan.map { AppServerTurnPlanPresentation(plan: $0) }
            }
        }
        return latestTurn(in: thread).flatMap { turn in
            turn.plan.map {
                AppServerTurnPlanPresentation(plan: $0, title: "Last turn plan")
            }
        }
    }

    private static func turnComesBefore(
        _ lhs: AppServerProjectedTurn,
        _ rhs: AppServerProjectedTurn
    ) -> Bool {
        let leftDate = lhs.completedAt ?? lhs.startedAt ?? .distantPast
        let rightDate = rhs.completedAt ?? rhs.startedAt ?? .distantPast
        if leftDate != rightDate { return leftDate < rightDate }
        return lhs.id < rhs.id
    }

    private static func latestTurn(
        in thread: AppServerProjectedThread
    ) -> AppServerProjectedTurn? {
        thread.turns.max {
            let leftDate = $0.completedAt ?? $0.startedAt ?? .distantPast
            let rightDate = $1.completedAt ?? $1.startedAt ?? .distantPast
            if leftDate != rightDate { return leftDate < rightDate }
            return $0.id < $1.id
        }
    }

    private static func activityLabel(_ activity: AppServerActivityKind) -> String {
        switch activity {
        case .idle: "Idle"
        case .working: "Working"
        case .runningCommand: "Running a command"
        case .changingFiles: "Changing files"
        case .usingTool: "Using a tool"
        case .waitingForApproval: "Waiting for approval"
        case .waitingForInput: "Waiting for input"
        case .completed: "Completed"
        case .failed: "Failed"
        case .interrupted: "Interrupted"
        case .unknown: "Status unavailable"
        }
    }

    private static func freshnessLabel(_ freshness: AppServerProjectionFreshness) -> String {
        switch freshness {
        case .live: "Live"
        case .rehydrated: "Rehydrated"
        case .stale: "Stale"
        }
    }

    private static func freshnessDetail(_ freshness: AppServerProjectionFreshness) -> String {
        switch freshness {
        case .live:
            "Updated through the current App Server connection."
        case .rehydrated:
            "Reloaded from the managed daemon; live subscription evidence has not arrived yet."
        case .stale:
            "This cached state may no longer describe current Codex work."
        }
    }

    private static func outcomeLabel(_ outcome: AppServerOutcomeKind) -> String {
        switch outcome {
        case .completed: "Turn completed"
        case .failed: "Turn failed"
        case .interrupted: "Turn interrupted"
        }
    }

    private static func tone(
        _ thread: AppServerProjectedThread,
        freshness: AppServerProjectionFreshness,
        visualState: AppServerThreadVisualState
    ) -> AppServerPresentationTone {
        switch visualState {
        case .running: return .active
        case .waitingForApproval, .needsInput: return .attention
        case .failed where thread.status == .systemError: return .failure
        case .failed, .unreviewedOutcome, .idle, .notLoaded, .unknown: break
        }
        if freshness == .stale { return .warning }
        if !thread.requests.isEmpty { return .attention }
        if visualState == .unreviewedOutcome { return .success }
        if visualState == .idle { return .neutral }
        switch thread.activity {
        case .completed: return .success
        case .failed: return .failure
        case .interrupted: return .warning
        case .working, .runningCommand, .changingFiles, .usingTool: return .active
        case .waitingForApproval, .waitingForInput: return .attention
        case .idle, .unknown: return .neutral
        }
    }

    private static func rowPriority(
        _ thread: AppServerProjectedThread,
        freshness: AppServerProjectionFreshness,
        visualState: AppServerThreadVisualState,
        isOutcomeUnreviewed: Bool
    ) -> ShellRowPriority {
        if visualState == .running { return .running }
        guard freshness == .live else { return .noRecentSignals }
        if !thread.requests.isEmpty { return .attention }
        if isOutcomeUnreviewed { return .outcome }
        if thread.isActive { return .running }
        return .noRecentSignals
    }

    private static func timeline(
        _ thread: AppServerProjectedThread,
        now: Date
    ) -> [AppServerTimelineItemPresentation] {
        var items = thread.turns.flatMap { turn in
            turn.items.enumerated().map { sourceOrder, item in
                timelineItem(
                    item,
                    turnID: turn.id,
                    sourceOrder: sourceOrder,
                    turnStartedAt: turn.startedAt,
                    turnCompletedAt: turn.completedAt,
                    threadUpdatedAt: thread.updatedAt,
                    now: now
                )
            }
        }
        if let outcome = thread.outcome {
            let observedAt = outcome.completedAt ?? thread.lastObservedAt
            let title = outcomeLabel(outcome.kind)
            let tone: AppServerPresentationTone
            switch outcome.kind {
            case .completed: tone = .success
            case .failed: tone = .failure
            case .interrupted: tone = .warning
            }
            items.append(.init(
                id: "outcome:\(outcome.turnID.rawValue)",
                category: .outcome,
                title: title,
                detail: nil,
                statusLabel: title,
                observedLabel: AppServerRelativeTime.label(from: observedAt, to: now),
                observedAt: observedAt,
                tone: tone
            ))
        }
        let newestFirst = items.sorted {
            if $0.observedAt != $1.observedAt { return $0.observedAt > $1.observedAt }
            if $0.turnID == $1.turnID, $0.sourceOrder != $1.sourceOrder {
                return $0.sourceOrder > $1.sourceOrder
            }
            return $0.id < $1.id
        }
        var retained: [AppServerTimelineItemPresentation] = []
        var retainedIDs: Set<String> = []
        func retain(_ candidates: [AppServerTimelineItemPresentation]) {
            for candidate in candidates where retained.count < 40 {
                if retainedIDs.insert(candidate.id).inserted { retained.append(candidate) }
            }
        }

        // Keep the readable conversation and the inspectable operational trail
        // independently bounded. A burst of tools must not erase commentary;
        // a long conversation must not erase a fresh command failure either.
        let conversationCategories: Set<AppServerTimelineCategory> = [
            .userMessage, .agentOutput, .finalAnswer,
        ]
        retain(Array(newestFirst.filter { conversationCategories.contains($0.category) }.prefix(24)))
        retain(Array(newestFirst.filter { !conversationCategories.contains($0.category) }.prefix(16)))
        retain(newestFirst)

        return retained.sorted {
            if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
            if $0.turnID == $1.turnID, $0.sourceOrder != $1.sourceOrder {
                return $0.sourceOrder < $1.sourceOrder
            }
            return $0.id < $1.id
        }
    }

    private static func timelineItem(
        _ item: AppServerProjectedItem,
        turnID: AppServerTurnID,
        sourceOrder: Int,
        turnStartedAt: Date?,
        turnCompletedAt: Date?,
        threadUpdatedAt: Date,
        now: Date
    ) -> AppServerTimelineItemPresentation {
        let observedAt = item.completedAt
            ?? item.startedAt
            ?? turnCompletedAt
            ?? turnStartedAt
            ?? threadUpdatedAt
        let metadata = itemMetadata(item)
        return .init(
            id: "item:\(turnID.rawValue):\(item.id.rawValue)",
            turnID: turnID.rawValue,
            sourceOrder: sourceOrder,
            category: metadata.category,
            title: metadata.title,
            detail: metadata.detail,
            statusLabel: itemStatusLabel(item.status),
            observedLabel: AppServerRelativeTime.label(from: observedAt, to: now),
            observedAt: observedAt,
            tone: item.status == .failed ? .failure : metadata.tone
        )
    }

    private static func itemMetadata(
        _ item: AppServerProjectedItem
    ) -> (
        category: AppServerTimelineCategory,
        title: String,
        detail: String?,
        tone: AppServerPresentationTone
    ) {
        let fallback = fallbackMetadata(item.kind)
        guard let presentation = item.presentation else { return fallback }
        switch presentation {
        case let .userText(text):
            return (.userMessage, "User message", normalized(text), .neutral)
        case let .agentText(text):
            return (.agentOutput, "Agent output", normalized(text), .active)
        case let .agentFinalText(text):
            return (.finalAnswer, "Answer", normalized(text), .active)
        case let .planText(text):
            return (.plan, "Plan updated", normalized(text), .active)
        case let .reasoningSummary(parts):
            return (
                .reasoning,
                "Reasoning summary",
                summarized(parts, maximumVisibleParts: 4),
                .neutral
            )
        case let .command(command):
            return (.command, "Command", normalized(command), .active)
        case let .fileChanges(changes):
            return (
                .fileChange,
                changes.count == 1 ? "File change" : "\(changes.count) file changes",
                fileChangeSummary(changes),
                .active
            )
        case let .tool(name, server):
            let tool = normalized(name)
            let server = server.flatMap(normalized)
            let detail = [server, tool].compactMap { $0 }.joined(separator: " · ")
            return (.tool, "Tool call", detail.isEmpty ? nil : detail, .active)
        }
    }

    private static func fallbackMetadata(
        _ kind: AppServerItemKind
    ) -> (
        category: AppServerTimelineCategory,
        title: String,
        detail: String?,
        tone: AppServerPresentationTone
    ) {
        switch kind {
        case .userMessage: return (.userMessage, "User message received", nil, .neutral)
        case .hookPrompt: return (.lifecycle, "Hook prompt observed", nil, .neutral)
        case .agentMessage: return (.agentOutput, "Agent output", nil, .active)
        case .plan: return (.plan, "Plan updated", nil, .active)
        case .reasoning: return (.reasoning, "Reasoning summary", nil, .neutral)
        case .commandExecution: return (.command, "Command", nil, .active)
        case .fileChange: return (.fileChange, "File change", nil, .active)
        case .mcpToolCall, .dynamicToolCall: return (.tool, "Tool call", nil, .active)
        case .collabAgentToolCall, .subagentActivity:
            return (.subagent, "Subagent activity", nil, .active)
        case .webSearch: return (.webSearch, "Web search", nil, .active)
        case .imageView: return (.image, "Image viewed", nil, .neutral)
        case .sleep: return (.lifecycle, "Waiting", nil, .neutral)
        case .imageGeneration: return (.image, "Image generated", nil, .active)
        case .enteredReviewMode: return (.lifecycle, "Entered review mode", nil, .neutral)
        case .exitedReviewMode: return (.lifecycle, "Exited review mode", nil, .neutral)
        case .contextCompaction: return (.compaction, "Context compacted", nil, .neutral)
        case .unknown: return (.unknown, "Codex activity", nil, .neutral)
        }
    }

    private static func itemStatusLabel(_ status: AppServerItemStatus) -> String {
        switch status {
        case .started: "In progress"
        case .completed: "Completed"
        case .failed: "Failed"
        case .unknown: "Status unavailable"
        }
    }

    private static func fileChangeSummary(
        _ changes: [AppServerFileChangePresentation]
    ) -> String? {
        guard !changes.isEmpty else { return nil }
        let maximumVisibleChanges = 6
        var values = changes.prefix(maximumVisibleChanges).map { change in
            let verb: String = switch change.kind {
            case .add: "Added"
            case .delete: "Deleted"
            case .update: "Updated"
            case .unknown: "Changed"
            }
            let counts = [
                change.additions.map { "+\($0)" },
                change.deletions.map { "-\($0)" },
            ].compactMap { $0 }.joined(separator: " ")
            return counts.isEmpty
                ? "\(verb) \(change.path)"
                : "\(verb) \(change.path) · \(counts)"
        }
        if changes.count > maximumVisibleChanges {
            values.append("+\(changes.count - maximumVisibleChanges) more")
        }
        return values.joined(separator: "\n")
    }

    private static func summarized(
        _ values: [String],
        maximumVisibleParts: Int
    ) -> String? {
        let normalized = values.compactMap(normalized)
        guard !normalized.isEmpty else { return nil }
        var visible = Array(normalized.prefix(maximumVisibleParts))
        if normalized.count > maximumVisibleParts {
            visible.append("+\(normalized.count - maximumVisibleParts) more")
        }
        return visible.joined(separator: "\n")
    }

    private static func normalized(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

public struct AppServerProjectPresentation: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let threads: [AppServerThreadPresentation]
    public let threadCount: Int
    public let activeCount: Int
    public let attentionCount: Int
    public let activityLabel: String
    public let tone: AppServerPresentationTone
    public let accessibilityLabel: String

    fileprivate init(
        id: String,
        name: String,
        threads: [AppServerThreadPresentation]
    ) {
        self.id = id
        self.name = name
        self.threads = threads
        threadCount = threads.count
        activeCount = threads.filter { $0.freshness == .live && $0.isActive }.count
        attentionCount = threads.reduce(0) { $0 + $1.attentionCount }

        if activeCount > 0 {
            activityLabel = "\(activeCount) active"
            tone = attentionCount > 0 ? .attention : .active
        } else {
            activityLabel = "\(threadCount)"
            tone = threads.allSatisfy({ $0.freshness == .stale }) ? .warning : .neutral
        }

        let threadLabel = "\(threadCount) thread\(threadCount == 1 ? "" : "s")"
        accessibilityLabel = AppServerPresentationText.accessibility(
            "\(name), \(threadLabel), \(activityLabel)"
        )
    }
}

public struct AppServerConnectionPresentation: Equatable, Sendable {
    public let phase: AppServerRuntimePhase
    public let title: String
    public let statusLabel: String
    public let detail: String
    public let sourceLabel: String
    public let capabilityModeLabel: String
    public let scopeLabel: String
    public let coverageLabel: String?
    public let versionLabel: String?
    public let tone: AppServerPresentationTone
    public let showsDiagnostic: Bool
    public let isAuthoritative: Bool

    fileprivate init(status: AppServerRuntimeStatus) {
        phase = status.phase
        detail = status.detail
        sourceLabel = status.connectionSourceLabel
        capabilityModeLabel = status.capabilityModeLabel
        scopeLabel = status.scopeLabel
        if let monitored = status.monitoredThreadCount,
           let listed = status.listedThreadCount {
            let suffix = status.isThreadInventoryTruncated
                ? " · safety ceiling reached; more not shown"
                : ""
            coverageLabel = "\(monitored) of \(listed) connected threads monitored\(suffix)"
        } else {
            coverageLabel = nil
        }
        let versions = [
            status.cliVersion.map { "Codex CLI \($0)" },
            status.appServerVersion.map { "App Server \($0)" },
        ].compactMap { $0 }
        versionLabel = versions.isEmpty ? nil : versions.joined(separator: " · ")
        isAuthoritative = status.isAuthoritative
        switch status.phase {
        case .starting:
            title = "Starting Conn"
            statusLabel = "Starting"
            tone = .neutral
        case .discovery:
            title = "Finding Codex"
            statusLabel = "Discovering"
            tone = .neutral
        case .daemon:
            title = "Starting managed daemon"
            statusLabel = "Starting"
            tone = .neutral
        case .connecting:
            title = "Connecting to managed daemon"
            statusLabel = "Connecting"
            tone = .neutral
        case .hydrating:
            title = "Loading connected threads"
            statusLabel = "Hydrating"
            tone = .active
        case .connected:
            title = "Managed daemon connected"
            statusLabel = "Connected"
            tone = .active
        case .reconnecting:
            title = "Reconnecting to managed daemon"
            statusLabel = "Reconnecting"
            tone = .warning
        case .incompatible:
            title = "App Server version incompatible"
            statusLabel = "Incompatible"
            tone = .unavailable
        case .unsafe:
            title = "Control endpoint refused"
            statusLabel = "Unsafe endpoint"
            tone = .unavailable
        case .unavailable:
            title = "Managed daemon unavailable"
            statusLabel = "Unavailable"
            tone = .unavailable
        }
        showsDiagnostic = status.phase != .connected
    }
}

public struct AppServerDomainPresentation: Equatable, Sendable {
    public let connection: AppServerConnectionPresentation
    /// Flat Threads mode, newest authoritative thread activity first.
    public let threads: [AppServerThreadPresentation]
    public let urgencySortedThreads: [AppServerThreadPresentation]
    public let projects: [AppServerProjectPresentation]
    public let statusPills: [AppServerStatusPillPresentation]
    public let activeCount: Int
    public let attentionCount: Int
    public let compactActivityTitle: String?
    public let isPresentationPaused: Bool
    public let presentationDate: Date
    public let genericOpenCodexDetail: String

    public static func detailedThreadIDs(
        snapshot: AppServerProjectionSnapshot,
        selectedThreadID: String?,
        now: Date,
        recentInterval: TimeInterval = 120
    ) -> Set<AppServerThreadID> {
        let recentDetailCutoff = now.addingTimeInterval(-max(0, recentInterval))
        return Set(snapshot.threads.compactMap { thread in
            let isSelected = thread.id.rawValue == selectedThreadID
            let needsLiveDetail = thread.isActive || !thread.requests.isEmpty
            let hasRecentDetail = !thread.turns.isEmpty
                && thread.lastObservedAt >= recentDetailCutoff
            return isSelected || needsLiveDetail || hasRecentDetail ? thread.id : nil
        })
    }

    public init(
        snapshot: AppServerProjectionSnapshot,
        runtimeStatus: AppServerRuntimeStatus,
        now: Date = Date(),
        isPresentationPaused: Bool = false,
        unreviewedOutcomeIDs: Set<AppServerOutcomeIdentity> = [],
        reviewedOutcomeIDs: Set<AppServerOutcomeIdentity> = [],
        detailedThreadIDs: Set<AppServerThreadID>? = nil
    ) {
        connection = AppServerConnectionPresentation(status: runtimeStatus)
        let hasAuthority = connection.isAuthoritative && snapshot.connection != nil
        let presentedThreads = snapshot.threads.map {
            AppServerThreadPresentation(
                thread: $0,
                hasCurrentAuthority: hasAuthority,
                unreviewedOutcomeIDs: unreviewedOutcomeIDs,
                reviewedOutcomeIDs: reviewedOutcomeIDs,
                includeTimeline: detailedThreadIDs?.contains($0.id) ?? true,
                now: now
            )
        }
        threads = Self.sortedByRecency(presentedThreads)
        urgencySortedThreads = Self.sortedByUrgency(presentedThreads)
        projects = Self.projects(
            projectedThreads: snapshot.threads,
            presentedThreads: presentedThreads
        )
        statusPills = Self.statusPills(threads)
        activeCount = hasAuthority && !isPresentationPaused
            ? presentedThreads.filter(\.isActive).count
            : 0
        attentionCount = hasAuthority && !isPresentationPaused
            ? snapshot.threads.filter { $0.freshness == .live }.reduce(0) {
                $0 + $1.requests.count
            }
            : 0
        if hasAuthority, !isPresentationPaused {
            compactActivityTitle = urgencySortedThreads.first {
                $0.isActive
            }.map {
                $0.freshness == .stale && $0.visualState == .running
                    ? "Running"
                    : $0.activityLabel
            }
        } else {
            compactActivityTitle = nil
        }
        self.isPresentationPaused = isPresentationPaused
        presentationDate = now
        genericOpenCodexDetail = "Opens Codex, but cannot target the selected thread."
    }

    private static func projects(
        projectedThreads: [AppServerProjectedThread],
        presentedThreads: [AppServerThreadPresentation]
    ) -> [AppServerProjectPresentation] {
        struct Group {
            let id: String
            let name: String
            var threads: [AppServerThreadPresentation]
        }

        var groups: [Group] = []
        var groupIndexByID: [String: Int] = [:]

        for (thread, presentation) in zip(projectedThreads, presentedThreads) {
            let identity = projectIdentity(thread)
            if let index = groupIndexByID[identity.id] {
                groups[index].threads.append(presentation)
            } else {
                groupIndexByID[identity.id] = groups.count
                groups.append(Group(
                    id: identity.id,
                    name: identity.name,
                    threads: [presentation]
                ))
            }
        }

        return groups.map {
            AppServerProjectPresentation(
                id: $0.id,
                name: $0.name,
                threads: sortedByRecency($0.threads)
            )
        }
    }

    private static func sortedByRecency(
        _ threads: [AppServerThreadPresentation]
    ) -> [AppServerThreadPresentation] {
        threads.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }

    private static func sortedByUrgency(
        _ threads: [AppServerThreadPresentation]
    ) -> [AppServerThreadPresentation] {
        threads.sorted {
            if $0.visualState.urgency != $1.visualState.urgency {
                return $0.visualState.urgency < $1.visualState.urgency
            }
            if $0.lastObservedAt != $1.lastObservedAt {
                return $0.lastObservedAt > $1.lastObservedAt
            }
            return $0.id < $1.id
        }
    }

    private static func statusPills(
        _ threads: [AppServerThreadPresentation]
    ) -> [AppServerStatusPillPresentation] {
        AppServerThreadVisualState.allCases.compactMap { state in
            // Full inventory intentionally retains not-loaded rows, but a
            // hundreds-wide aggregate is navigation noise rather than a
            // useful compact status signal. Those rows remain in Threads and
            // Projects and become pill-eligible if their live state changes.
            guard state != .notLoaded, state != .unknown else { return nil }
            let matching = threads.filter { $0.visualState == state }
            guard !matching.isEmpty else { return nil }
            return AppServerStatusPillPresentation(
                visualState: state,
                threads: matching
            )
        }
    }

    private static func projectIdentity(
        _ thread: AppServerProjectedThread
    ) -> (id: String, name: String) {
        // Phase 8.5's domain projection supplies repository root and cwd as
        // runtime-only grouping metadata. Until a thread has either value,
        // avoid grouping by its title or content; a final thread-ID fallback
        // prevents unrelated unknown-directory threads from being conflated.
        let path = normalizedPath(thread.projectRootPath)
            ?? normalizedPath(thread.workingDirectoryPath)
        if let path {
            let name = URL(fileURLWithPath: path).lastPathComponent
            return (
                id: "path:\(path)",
                name: name.isEmpty ? "Other" : productDisplayName(name)
            )
        }

        if let directoryName = normalizedName(thread.workingDirectoryName) {
            return (id: "directory:\(directoryName)", name: productDisplayName(directoryName))
        }
        return (id: "thread:\(thread.id.rawValue)", name: "Other")
    }

    private static func normalizedPath(_ value: String?) -> String? {
        guard let value = normalizedName(value) else { return nil }
        let path = URL(fileURLWithPath: value).standardizedFileURL.path
        return path
    }

    private static func normalizedName(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    private static func productDisplayName(_ name: String) -> String {
        name.caseInsensitiveCompare("SideQuest") == .orderedSame ? "Conn" : name
    }
}

private enum AppServerTimelineDetail {
    static func bounded(
        _ value: String?,
        maximumLines: Int = AppServerTimelineItemPresentation.maximumVisibleDetailLineCount,
        maximumCharacters: Int = AppServerTimelineItemPresentation.maximumVisibleDetailCharacterCount,
        maximumUTF8Bytes: Int = AppServerTimelineItemPresentation.maximumVisibleDetailUTF8Bytes
    ) -> String? {
        guard let value else { return nil }
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let visibleLines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(maximumLines)
        let lineBounded = visibleLines.joined(separator: "\n")

        var bounded = ""
        bounded.reserveCapacity(min(
            lineBounded.count,
            maximumCharacters
        ))
        var characterCount = 0
        var byteCount = 0
        for character in lineBounded {
            let value = String(character)
            let bytes = value.utf8.count
            guard characterCount
                    < maximumCharacters,
                  byteCount + bytes
                    <= maximumUTF8Bytes
            else { break }
            bounded.append(character)
            characterCount += 1
            byteCount += bytes
        }
        return bounded.isEmpty ? nil : bounded
    }
}

private enum AppServerPresentationText {
    static let maximumOneLineUTF8Bytes = 256
    static let maximumAccessibilityUTF8Bytes = 1_024

    static func optionalOneLine(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        return bounded(normalized, maximumUTF8Bytes: maximumOneLineUTF8Bytes)
    }

    static func oneLine(_ value: String) -> String {
        optionalOneLine(value) ?? "Unavailable"
    }

    static func headline(_ label: String, _ detail: String?) -> String {
        guard let detail = optionalOneLine(detail), detail != label else {
            return oneLine(label)
        }
        return oneLine("\(label) · \(detail)")
    }

    static func accessibility(_ value: String) -> String {
        bounded(value, maximumUTF8Bytes: maximumAccessibilityUTF8Bytes)
    }

    private static func bounded(_ value: String, maximumUTF8Bytes: Int) -> String {
        guard value.utf8.count > maximumUTF8Bytes else { return value }
        var result = ""
        result.reserveCapacity(min(value.count, maximumUTF8Bytes))
        var byteCount = 0
        for character in value {
            let text = String(character)
            let bytes = text.utf8.count
            guard byteCount + bytes <= maximumUTF8Bytes else { break }
            result.append(character)
            byteCount += bytes
        }
        return result
    }
}

private enum AppServerRelativeTime {
    static func label(from date: Date, to now: Date) -> String {
        guard date != .distantPast else { return "Time unavailable" }
        let interval = max(0, now.timeIntervalSince(date))
        if interval < 60 { return "Just now" }
        if interval < 60 * 60 { return "\(Int(interval / 60))m ago" }
        if interval < 24 * 60 * 60 { return "\(Int(interval / (60 * 60)))h ago" }
        return "\(Int(interval / (24 * 60 * 60)))d ago"
    }
}
