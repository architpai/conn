import Foundation

// MARK: - Stable identity

public struct HarnessID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct IntegrationID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct UpstreamSessionID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct ConnSessionID: Codable, Hashable, Comparable, Sendable {
    public let integrationID: IntegrationID
    public let upstreamID: UpstreamSessionID

    public init(integrationID: IntegrationID, upstreamID: UpstreamSessionID) {
        self.integrationID = integrationID
        self.upstreamID = upstreamID
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.integrationID != rhs.integrationID {
            return lhs.integrationID < rhs.integrationID
        }
        return lhs.upstreamID < rhs.upstreamID
    }
}

public struct RunID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct ActivityID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct AttentionRequestID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct SessionIssueID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

// MARK: - Runtime authority

/// Authority for exactly one live Integration connection. It is deliberately
/// not Codable so restored state can never regain action authority.
public struct IntegrationConnectionGeneration: Hashable, Sendable {
    public let instanceID: UUID
    public let ordinal: UInt64

    public init(instanceID: UUID, ordinal: UInt64) {
        self.instanceID = instanceID
        self.ordinal = ordinal
    }
}

public struct IntegrationUpdateCursor: Hashable, Comparable, Sendable {
    public let generation: IntegrationConnectionGeneration
    public let sequence: UInt64

    public init(generation: IntegrationConnectionGeneration, sequence: UInt64) {
        self.generation = generation
        self.sequence = sequence
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.generation.instanceID != rhs.generation.instanceID {
            return lhs.generation.instanceID.uuidString
                < rhs.generation.instanceID.uuidString
        }
        if lhs.generation.ordinal != rhs.generation.ordinal {
            return lhs.generation.ordinal < rhs.generation.ordinal
        }
        return lhs.sequence < rhs.sequence
    }
}

// MARK: - Integration and Session state

public enum IntegrationFreshness: String, Codable, Hashable, Sendable {
    case rehydrated
    case live
    case stale
}

public enum InventoryAuthority: String, Codable, Hashable, Sendable {
    case complete
    case partial
}

public enum SessionOrigin: String, Codable, Hashable, Sendable {
    case conn
    case external
    case unknown
}

public enum SessionOwnership: String, Codable, Hashable, Sendable {
    case harness
}

public enum SessionRetention: String, Codable, Hashable, Sendable {
    case ephemeral
    case persistent
    case unknown
}

public enum ConnSessionStatus: String, Codable, Hashable, Sendable {
    case notLoaded
    case idle
    case working
    case waitingForAttention
    case completed
    case failed
    case unknown
}

public enum ConnRunStatus: String, Codable, Hashable, Sendable {
    case inProgress
    case completed
    case interrupted
    case failed
    case unknown
}

public enum ConnActivityKind: String, Codable, Hashable, Sendable {
    case userMessage
    case agentMessage
    case plan
    case reasoning
    case command
    case fileChange
    case toolCall
    case subagent
    case webSearch
    case image
    case compaction
    case unknown
}

public enum ConnActivityStatus: String, Codable, Hashable, Sendable {
    case started
    case completed
    case failed
    case unknown
}

public enum AttentionRequestKind: String, Codable, Hashable, Sendable {
    case approval
    case structuredQuestion
}

public enum SessionIssueKind: String, Codable, Hashable, Sendable {
    case integration
    case session
    case run
}

public struct WorkspaceEvidence: Codable, Equatable, Hashable, Sendable {
    public let canonicalPath: String
    public let equivalenceKey: String?

    public init(canonicalPath: String, equivalenceKey: String? = nil) {
        self.canonicalPath = canonicalPath
        self.equivalenceKey = equivalenceKey
    }
}

public struct ConnRun: Codable, Equatable, Identifiable, Sendable {
    public let id: RunID
    public let status: ConnRunStatus
    public let startedAt: Date?
    public let completedAt: Date?

    public init(
        id: RunID,
        status: ConnRunStatus,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

public struct ConnActivity: Codable, Equatable, Identifiable, Sendable {
    public let id: ActivityID
    public let runID: RunID?
    public let kind: ConnActivityKind
    public let status: ConnActivityStatus
    public let summary: String?
    public let observedAt: Date

    public init(
        id: ActivityID,
        runID: RunID? = nil,
        kind: ConnActivityKind,
        status: ConnActivityStatus,
        summary: String? = nil,
        observedAt: Date,
        bounds: ConnDomainBounds = .default
    ) {
        self.id = id
        self.runID = runID
        self.kind = kind
        self.status = status
        self.summary = summary.map {
            ConnDomainBounds.boundedSingleLine($0, maximumUTF8Bytes: bounds.maximumSummaryUTF8Bytes)
        }
        self.observedAt = observedAt
    }
}

public struct AttentionRequest: Equatable, Identifiable, Sendable {
    public let id: AttentionRequestID
    public let sessionID: ConnSessionID
    public let runID: RunID?
    public let kind: AttentionRequestKind
    public let summary: String
    public let observedAt: Date

    public init(
        id: AttentionRequestID,
        sessionID: ConnSessionID,
        runID: RunID? = nil,
        kind: AttentionRequestKind,
        summary: String,
        observedAt: Date,
        bounds: ConnDomainBounds = .default
    ) {
        self.id = id
        self.sessionID = sessionID
        self.runID = runID
        self.kind = kind
        self.summary = ConnDomainBounds.boundedSingleLine(
            summary,
            maximumUTF8Bytes: bounds.maximumSummaryUTF8Bytes
        )
        self.observedAt = observedAt
    }
}

public struct SessionIssue: Codable, Equatable, Identifiable, Sendable {
    public let id: SessionIssueID
    public let kind: SessionIssueKind
    public let summary: String
    public let observedAt: Date

    public init(
        id: SessionIssueID,
        kind: SessionIssueKind,
        summary: String,
        observedAt: Date,
        bounds: ConnDomainBounds = .default
    ) {
        self.id = id
        self.kind = kind
        self.summary = ConnDomainBounds.boundedSingleLine(
            summary,
            maximumUTF8Bytes: bounds.maximumSummaryUTF8Bytes
        )
        self.observedAt = observedAt
    }
}

public struct ConnSession: Codable, Equatable, Identifiable, Sendable {
    public let id: ConnSessionID
    public let title: String?
    public let workspace: WorkspaceEvidence?
    public let origin: SessionOrigin
    public let ownership: SessionOwnership
    public let retention: SessionRetention
    public let status: ConnSessionStatus
    public let runs: [ConnRun]
    public let activities: [ConnActivity]
    public let issues: [SessionIssue]
    public let updatedAt: Date

    public init(
        id: ConnSessionID,
        title: String? = nil,
        workspace: WorkspaceEvidence? = nil,
        origin: SessionOrigin = .unknown,
        ownership: SessionOwnership = .harness,
        retention: SessionRetention = .unknown,
        status: ConnSessionStatus,
        runs: [ConnRun] = [],
        activities: [ConnActivity] = [],
        issues: [SessionIssue] = [],
        updatedAt: Date,
        bounds: ConnDomainBounds = .default
    ) {
        self.id = id
        self.title = title.map {
            ConnDomainBounds.boundedSingleLine($0, maximumUTF8Bytes: bounds.maximumTitleUTF8Bytes)
        }
        self.workspace = workspace
        self.origin = origin
        self.ownership = ownership
        self.retention = retention
        self.status = status
        self.runs = Array(runs.prefix(bounds.maximumRunsPerSession))
        self.activities = Array(activities.suffix(bounds.maximumActivitiesPerSession))
        self.issues = Array(issues.suffix(bounds.maximumIssuesPerSession))
        self.updatedAt = updatedAt
    }
}

// MARK: - Capabilities and actions

public enum ConnActionKind: String, Codable, Hashable, Sendable {
    case open
    case createSession
    case followUp
    case steer
    case interrupt
    case answer
    case resolveApproval
}

public struct IntegrationCapabilities: Equatable, Sendable {
    public let canMonitor: Bool
    public let actions: Set<ConnActionKind>

    public init(canMonitor: Bool, actions: Set<ConnActionKind> = []) {
        self.canMonitor = canMonitor
        self.actions = actions
    }

    public func supports(_ action: ConnActionKind) -> Bool {
        actions.contains(action)
    }
}

public struct SessionActionAvailabilityInput: Equatable, Sendable {
    public let sessionID: ConnSessionID
    public let freshness: IntegrationFreshness
    public let capabilities: IntegrationCapabilities
    public let hasCurrentAuthority: Bool
    public let activeRunID: RunID?
    public let attentionRequestIDs: Set<AttentionRequestID>

    public init(
        sessionID: ConnSessionID,
        freshness: IntegrationFreshness,
        capabilities: IntegrationCapabilities,
        hasCurrentAuthority: Bool,
        activeRunID: RunID? = nil,
        attentionRequestIDs: Set<AttentionRequestID> = []
    ) {
        self.sessionID = sessionID
        self.freshness = freshness
        self.capabilities = capabilities
        self.hasCurrentAuthority = hasCurrentAuthority
        self.activeRunID = activeRunID
        self.attentionRequestIDs = attentionRequestIDs
    }
}

/// Runtime-only semantic authority for resolving one upstream request. Any
/// provider response token remains adapter-internal and is recovered from this
/// scoped identity only while the connection generation is current.
public struct AttentionResponseAuthority: Hashable, Sendable {
    public let requestID: AttentionRequestID
    public let generation: IntegrationConnectionGeneration

    public init(
        requestID: AttentionRequestID,
        generation: IntegrationConnectionGeneration
    ) {
        self.requestID = requestID
        self.generation = generation
    }
}

public enum ApprovalDecision: String, Hashable, Sendable {
    case approve
    case approveForSession
    case deny
    case cancel
}

public enum ConnActionPayloadError: Error, Equatable, Sendable {
    case empty
    case exceedsUTF8Limit(Int)
    case tooManyAnswers
}

/// Runtime-only user text. Construction rejects oversize input rather than
/// silently truncating a prompt that will be sent to a Harness.
public struct ConnActionText: Equatable, Sendable {
    public let value: String

    public init(_ value: String, bounds: ConnDomainBounds = .default) throws {
        guard !value.isEmpty else { throw ConnActionPayloadError.empty }
        guard value.utf8.count <= bounds.maximumActionTextUTF8Bytes else {
            throw ConnActionPayloadError.exceedsUTF8Limit(
                bounds.maximumActionTextUTF8Bytes
            )
        }
        self.value = value
    }
}

public struct ConnWorkspacePath: Equatable, Sendable {
    public let value: String

    public init(_ value: String, bounds: ConnDomainBounds = .default) throws {
        guard !value.isEmpty else { throw ConnActionPayloadError.empty }
        guard value.utf8.count <= bounds.maximumWorkspacePathUTF8Bytes else {
            throw ConnActionPayloadError.exceedsUTF8Limit(
                bounds.maximumWorkspacePathUTF8Bytes
            )
        }
        self.value = value
    }
}

/// Runtime-only structured answers. It is intentionally not Codable and
/// rejects rather than truncates values that would change the user's answer.
public struct ConnStructuredAnswers: Equatable, Sendable {
    public let valuesByQuestionID: [String: [String]]

    public init(
        valuesByQuestionID: [String: [String]],
        bounds: ConnDomainBounds = .default
    ) throws {
        guard valuesByQuestionID.count <= bounds.maximumStructuredQuestions,
              valuesByQuestionID.values.allSatisfy({
                  $0.count <= bounds.maximumAnswersPerQuestion
              }) else {
            throw ConnActionPayloadError.tooManyAnswers
        }
        for (questionID, values) in valuesByQuestionID {
            guard !questionID.isEmpty, !values.isEmpty, values.allSatisfy({ !$0.isEmpty }) else {
                throw ConnActionPayloadError.empty
            }
            guard questionID.utf8.count <= bounds.maximumIdentifierUTF8Bytes else {
                throw ConnActionPayloadError.exceedsUTF8Limit(
                    bounds.maximumIdentifierUTF8Bytes
                )
            }
            guard values.allSatisfy({
                $0.utf8.count <= bounds.maximumStructuredAnswerUTF8Bytes
            }) else {
                throw ConnActionPayloadError.exceedsUTF8Limit(
                    bounds.maximumStructuredAnswerUTF8Bytes
                )
            }
        }
        self.valuesByQuestionID = valuesByQuestionID
    }
}

public enum ConnAction: Equatable, Sendable {
    case open(sessionID: ConnSessionID)
    case createSession(
        integrationID: IntegrationID,
        workspacePath: ConnWorkspacePath,
        initialPrompt: ConnActionText
    )
    case followUp(sessionID: ConnSessionID, text: ConnActionText)
    case steer(sessionID: ConnSessionID, runID: RunID, text: ConnActionText)
    case interrupt(sessionID: ConnSessionID, runID: RunID)
    case answer(
        sessionID: ConnSessionID,
        authority: AttentionResponseAuthority,
        answers: ConnStructuredAnswers
    )
    case resolveApproval(
        sessionID: ConnSessionID,
        authority: AttentionResponseAuthority,
        decision: ApprovalDecision
    )

    public var kind: ConnActionKind {
        switch self {
        case .open: .open
        case .createSession: .createSession
        case .followUp: .followUp
        case .steer: .steer
        case .interrupt: .interrupt
        case .answer: .answer
        case .resolveApproval: .resolveApproval
        }
    }

    public var integrationID: IntegrationID {
        switch self {
        case let .createSession(integrationID, _, _):
            integrationID
        case let .open(sessionID),
             let .followUp(sessionID, _),
             let .steer(sessionID, _, _),
             let .interrupt(sessionID, _),
             let .answer(sessionID, _, _),
             let .resolveApproval(sessionID, _, _):
            sessionID.integrationID
        }
    }
}

public enum ConnActionOutcomeKind: String, Hashable, Sendable {
    case unavailable
    case rejected
    case accepted
    case acknowledgementUncertain
    case invalidated
    case resolvedElsewhere
}

public struct ConnActionOutcome: Equatable, Sendable {
    public let integrationID: IntegrationID
    public let action: ConnActionKind
    public let kind: ConnActionOutcomeKind
    public let evidence: String?

    public init(
        integrationID: IntegrationID,
        action: ConnActionKind,
        kind: ConnActionOutcomeKind,
        evidence: String? = nil,
        bounds: ConnDomainBounds = .default
    ) {
        self.integrationID = integrationID
        self.action = action
        self.kind = kind
        self.evidence = evidence.map {
            ConnDomainBounds.boundedSingleLine($0, maximumUTF8Bytes: bounds.maximumSummaryUTF8Bytes)
        }
    }
}

// MARK: - Bounds

public struct ConnDomainBounds: Equatable, Sendable {
    public static let `default` = ConnDomainBounds()

    public let maximumTitleUTF8Bytes: Int
    public let maximumSummaryUTF8Bytes: Int
    public let maximumIdentifierUTF8Bytes: Int
    public let maximumWorkspacePathUTF8Bytes: Int
    public let maximumActionTextUTF8Bytes: Int
    public let maximumStructuredQuestions: Int
    public let maximumAnswersPerQuestion: Int
    public let maximumStructuredAnswerUTF8Bytes: Int
    public let maximumSessionsPerIntegration: Int
    public let maximumAttentionRequestsPerIntegration: Int
    public let maximumRunsPerSession: Int
    public let maximumActivitiesPerSession: Int
    public let maximumIssuesPerSession: Int
    public let maximumBufferedUpdates: Int

    public init(
        maximumTitleUTF8Bytes: Int = 512,
        maximumSummaryUTF8Bytes: Int = 2_048,
        maximumIdentifierUTF8Bytes: Int = 512,
        maximumWorkspacePathUTF8Bytes: Int = 4_096,
        maximumActionTextUTF8Bytes: Int = 64 * 1_024,
        maximumStructuredQuestions: Int = 64,
        maximumAnswersPerQuestion: Int = 32,
        maximumStructuredAnswerUTF8Bytes: Int = 16 * 1_024,
        maximumSessionsPerIntegration: Int = 10_000,
        maximumAttentionRequestsPerIntegration: Int = 1_000,
        maximumRunsPerSession: Int = 1_000,
        maximumActivitiesPerSession: Int = 2_000,
        maximumIssuesPerSession: Int = 100,
        maximumBufferedUpdates: Int = 2_048
    ) {
        precondition(maximumTitleUTF8Bytes > 0)
        precondition(maximumSummaryUTF8Bytes > 0)
        precondition(maximumIdentifierUTF8Bytes > 0)
        precondition(maximumWorkspacePathUTF8Bytes > 0)
        precondition(maximumActionTextUTF8Bytes > 0)
        precondition(maximumStructuredQuestions > 0)
        precondition(maximumAnswersPerQuestion > 0)
        precondition(maximumStructuredAnswerUTF8Bytes > 0)
        precondition(maximumSessionsPerIntegration > 0)
        precondition(maximumAttentionRequestsPerIntegration > 0)
        precondition(maximumRunsPerSession > 0)
        precondition(maximumActivitiesPerSession > 0)
        precondition(maximumIssuesPerSession > 0)
        precondition(maximumBufferedUpdates > 0)
        self.maximumTitleUTF8Bytes = maximumTitleUTF8Bytes
        self.maximumSummaryUTF8Bytes = maximumSummaryUTF8Bytes
        self.maximumIdentifierUTF8Bytes = maximumIdentifierUTF8Bytes
        self.maximumWorkspacePathUTF8Bytes = maximumWorkspacePathUTF8Bytes
        self.maximumActionTextUTF8Bytes = maximumActionTextUTF8Bytes
        self.maximumStructuredQuestions = maximumStructuredQuestions
        self.maximumAnswersPerQuestion = maximumAnswersPerQuestion
        self.maximumStructuredAnswerUTF8Bytes = maximumStructuredAnswerUTF8Bytes
        self.maximumSessionsPerIntegration = maximumSessionsPerIntegration
        self.maximumAttentionRequestsPerIntegration = maximumAttentionRequestsPerIntegration
        self.maximumRunsPerSession = maximumRunsPerSession
        self.maximumActivitiesPerSession = maximumActivitiesPerSession
        self.maximumIssuesPerSession = maximumIssuesPerSession
        self.maximumBufferedUpdates = maximumBufferedUpdates
    }

    static func boundedSingleLine(_ value: String, maximumUTF8Bytes: Int) -> String {
        let firstLine = value.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        ).first.map(String.init) ?? ""
        guard firstLine.utf8.count > maximumUTF8Bytes else { return firstLine }
        var result = ""
        result.reserveCapacity(maximumUTF8Bytes)
        for scalar in firstLine.unicodeScalars {
            let candidate = result + String(scalar)
            guard candidate.utf8.count <= maximumUTF8Bytes else { break }
            result = candidate
        }
        return result
    }
}
