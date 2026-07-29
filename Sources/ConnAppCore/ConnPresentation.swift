import Foundation
import ConnDomain

public enum ConnPresentationTone: String, Equatable, Sendable {
    case neutral
    case active
    case attention
    case success
    case failure
    case stale
}

public enum ConnSessionVisualState: String, Equatable, Sendable {
    case working
    case waitingForAttention
    case completed
    case failed
    case idle
    case stale
    case unknown
}

public enum ConnStatusPillKind:
    String,
    CaseIterable,
    Equatable,
    Hashable,
    Sendable
{
    case attention
    case working
    case failed
    case completed
    case idle
    case stale
    case unknown
}

public struct ConnStatusPillPresentation: Equatable, Identifiable, Sendable {
    public var id: ConnStatusPillKind { kind }
    public let kind: ConnStatusPillKind
    public let count: Int
    public let label: String
    public let tone: ConnPresentationTone
    public let primarySessionID: ConnSessionID

    public init(
        kind: ConnStatusPillKind,
        count: Int,
        label: String,
        tone: ConnPresentationTone,
        primarySessionID: ConnSessionID
    ) {
        self.kind = kind
        self.count = count
        self.label = label
        self.tone = tone
        self.primarySessionID = primarySessionID
    }
}

public enum ConnStatusPillPolicy {
    public static func make(
        from sessions: [ConnSessionPresentation]
    ) -> [ConnStatusPillPresentation] {
        ConnStatusPillKind.allCases.compactMap { kind in
            let matching = sessions.filter {
                statusPillKind(for: $0.visualState) == kind
            }.sorted {
                if $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt > $1.updatedAt
                }
                return $0.id < $1.id
            }
            guard let primary = matching.first else { return nil }
            let presentation: (String, ConnPresentationTone) = switch kind {
            case .attention: ("Needs attention", .attention)
            case .working: ("Working", .active)
            case .failed: ("Failed", .failure)
            case .completed: ("Completed", .success)
            case .idle: ("Idle", .neutral)
            case .stale: ("Stale", .stale)
            case .unknown: ("Unknown", .neutral)
            }
            return .init(
                kind: kind,
                count: matching.count,
                label: presentation.0,
                tone: presentation.1,
                primarySessionID: primary.id
            )
        }
    }

    private static func statusPillKind(
        for visualState: ConnSessionVisualState
    ) -> ConnStatusPillKind {
        switch visualState {
        case .waitingForAttention: .attention
        case .working: .working
        case .failed: .failed
        case .completed: .completed
        case .idle: .idle
        case .stale: .stale
        case .unknown: .unknown
        }
    }
}

public struct ConnIntegrationPresentation: Equatable, Identifiable, Sendable {
    public var id: IntegrationID { state.id }
    public let state: ConnIntegrationState
    public let statusLabel: String
    public let detail: String
    public let tone: ConnPresentationTone

    public init(
        state: ConnIntegrationState,
        statusLabel: String,
        detail: String,
        tone: ConnPresentationTone
    ) {
        self.state = state
        self.statusLabel = statusLabel
        self.detail = detail
        self.tone = tone
    }
}

public struct ConnActivityPresentation: Equatable, Identifiable, Sendable {
    public var id: ActivityID { activity.id }
    public let activity: ConnActivity
    public let label: String
    public let detail: String?
    public let tone: ConnPresentationTone

    public init(
        activity: ConnActivity,
        label: String,
        detail: String?,
        tone: ConnPresentationTone
    ) {
        self.activity = activity
        self.label = label
        self.detail = detail
        self.tone = tone
    }
}

public struct ConnRunPresentation: Equatable, Identifiable, Sendable {
    public var id: RunID { run.id }
    public let run: ConnRun
    public let title: String
    public let triggeringUserMessage: String?
    public let summary: String?
    public let workedForLabel: String?
    public let activities: [ConnActivityPresentation]
    public let isCollapsedByDefault: Bool

    public init(
        run: ConnRun,
        title: String,
        triggeringUserMessage: String? = nil,
        summary: String?,
        workedForLabel: String? = nil,
        activities: [ConnActivityPresentation],
        isCollapsedByDefault: Bool
    ) {
        self.run = run
        self.title = title
        self.triggeringUserMessage = triggeringUserMessage
        self.summary = summary
        self.workedForLabel = workedForLabel
        self.activities = activities
        self.isCollapsedByDefault = isCollapsedByDefault
    }
}

public struct ConnAttentionPresentation: Equatable, Identifiable, Sendable {
    public var id: AttentionRequestID { state.id }
    public let state: ConnAttentionState
    public let label: String
    public let tone: ConnPresentationTone

    public init(
        state: ConnAttentionState,
        label: String,
        tone: ConnPresentationTone = .attention
    ) {
        self.state = state
        self.label = label
        self.tone = tone
    }
}

public struct ConnHarnessAttribution: Equatable, Sendable {
    public let harnessID: HarnessID
    public let label: String
    /// A source-level asset name supplied by ConnApp. The neutral UI always
    /// keeps `label` visible to accessibility and falls back to text.
    public let assetName: String?

    public init(
        harnessID: HarnessID,
        label: String,
        assetName: String? = nil
    ) {
        self.harnessID = harnessID
        self.label = label
        self.assetName = assetName
    }
}

public struct ConnSessionPresentation: Equatable, Identifiable, Sendable {
    public var id: ConnSessionID { state.id }
    public let state: ConnSessionState
    public let title: String
    public let workspaceLabel: String
    public let statusLabel: String
    public let visualState: ConnSessionVisualState
    public let tone: ConnPresentationTone
    public let harness: ConnHarnessAttribution
    public let runs: [ConnRunPresentation]
    public let activities: [ConnActivityPresentation]
    public let attention: [ConnAttentionPresentation]

    public var updatedAt: Date { state.session.updatedAt }
    public var isActive: Bool {
        visualState == .working || visualState == .waitingForAttention
    }

    public init(
        state: ConnSessionState,
        title: String,
        workspaceLabel: String,
        statusLabel: String,
        visualState: ConnSessionVisualState,
        tone: ConnPresentationTone,
        harness: ConnHarnessAttribution,
        runs: [ConnRunPresentation] = [],
        activities: [ConnActivityPresentation],
        attention: [ConnAttentionPresentation]
    ) {
        self.state = state
        self.title = title
        self.workspaceLabel = workspaceLabel
        self.statusLabel = statusLabel
        self.visualState = visualState
        self.tone = tone
        self.harness = harness
        self.runs = runs
        self.activities = activities
        self.attention = attention
    }
}

public struct ConnProjectPresentation: Equatable, Identifiable, Sendable {
    public var id: ConnProjectID { state.id }
    public let state: ConnProjectState
    public let name: String
    public let sessions: [ConnSessionPresentation]

    public init(
        state: ConnProjectState,
        name: String,
        sessions: [ConnSessionPresentation]
    ) {
        self.state = state
        self.name = name
        self.sessions = sessions
    }
}

public struct ConnDomainPresentation: Equatable, Sendable {
    public let revision: UInt64
    public let integrations: [ConnIntegrationPresentation]
    public let sessions: [ConnSessionPresentation]
    public let projects: [ConnProjectPresentation]
    public let attentionCount: Int
    public let activeSessionCount: Int
    public let persistenceHealth: ConnPersistenceHealth

    public init(
        revision: UInt64,
        integrations: [ConnIntegrationPresentation],
        sessions: [ConnSessionPresentation],
        projects: [ConnProjectPresentation],
        attentionCount: Int,
        activeSessionCount: Int,
        persistenceHealth: ConnPersistenceHealth
    ) {
        self.revision = revision
        self.integrations = integrations
        self.sessions = sessions
        self.projects = projects
        self.attentionCount = attentionCount
        self.activeSessionCount = activeSessionCount
        self.persistenceHealth = persistenceHealth
    }
}

public enum ConnPresentationBuilder {
    public static func make(
        _ snapshot: ConnAggregateSnapshot,
        harnessAssets: [HarnessID: String] = [:]
    ) -> ConnDomainPresentation {
        let integrations = snapshot.integrations.map(integration)
        let sessions = snapshot.sessions.map {
            session($0, harnessAssets: harnessAssets)
        }
        let byID = Dictionary(
            sessions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let projects = snapshot.projects.map { project in
            ConnProjectPresentation(
                state: project,
                name: projectName(project.workspacePath),
                sessions: project.sessions.compactMap { byID[$0] }
            )
        }
        return .init(
            revision: snapshot.revision,
            integrations: integrations,
            sessions: sessions,
            projects: projects,
            attentionCount: sessions.reduce(0) { $0 + $1.attention.count },
            activeSessionCount: sessions.filter(\.isActive).count,
            persistenceHealth: snapshot.persistenceHealth
        )
    }

    private static func integration(
        _ state: ConnIntegrationState
    ) -> ConnIntegrationPresentation {
        switch state.freshness {
        case .live:
            return .init(
                state: state,
                statusLabel: "Live",
                detail: "\(state.sessionCount) Sessions",
                tone: .active
            )
        case .rehydrated:
            return .init(
                state: state,
                statusLabel: "Reconnecting",
                detail: "Showing restored Sessions",
                tone: .stale
            )
        case .stale:
            return .init(
                state: state,
                statusLabel: "Unavailable",
                detail: "Sessions are retained without action authority",
                tone: .stale
            )
        }
    }

    private static func session(
        _ state: ConnSessionState,
        harnessAssets: [HarnessID: String]
    ) -> ConnSessionPresentation {
        let visual = visualState(state)
        let tone: ConnPresentationTone = switch visual {
        case .working: .active
        case .waitingForAttention: .attention
        case .completed: .success
        case .failed: .failure
        case .stale: .stale
        case .idle, .unknown: .neutral
        }
        let activities = state.session.activities.map(activity)
        let activitiesByRun = Dictionary(grouping: activities) {
            $0.activity.runID
        }
        return .init(
            state: state,
            title: state.session.title?.nonEmpty ?? "Untitled Session",
            workspaceLabel: state.session.workspace.map {
                projectName($0.canonicalPath)
            } ?? "No Workspace",
            statusLabel: statusLabel(visual),
            visualState: visual,
            tone: tone,
            harness: .init(
                harnessID: state.integration.harnessID,
                label: state.integration.displayName,
                assetName: harnessAssets[state.integration.harnessID]
            ),
            runs: state.session.runs.map { run in
                let runActivities = activitiesByRun[run.id] ?? []
                return .init(
                    run: run,
                    title: runTitle(run.status),
                    triggeringUserMessage: runActivities.first {
                        $0.activity.kind == .userMessage
                    }?.detail,
                    summary: runActivities.last {
                        $0.activity.kind == .agentMessage
                    }?.detail,
                    workedForLabel: workedForLabel(run),
                    activities: runActivities,
                    isCollapsedByDefault: run.status == .completed
                )
            },
            activities: activities,
            attention: state.attention.map {
                .init(
                    state: $0,
                    label: $0.request.kind == .approval
                        ? "Approval requested"
                        : "Input requested"
                )
            }
        )
    }

    private static func runTitle(_ status: ConnRunStatus) -> String {
        switch status {
        case .inProgress: "Current Run"
        case .completed: "Completed Run"
        case .interrupted: "Interrupted Run"
        case .failed: "Failed Run"
        case .unknown: "Run"
        }
    }

    private static func workedForLabel(_ run: ConnRun) -> String? {
        guard let startedAt = run.startedAt,
              let completedAt = run.completedAt,
              completedAt >= startedAt else {
            return nil
        }
        let totalSeconds = max(
            1,
            Int(completedAt.timeIntervalSince(startedAt).rounded(.down))
        )
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        let duration: String
        if hours > 0 {
            duration = minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        } else if minutes > 0 {
            duration = "\(minutes)m \(seconds)s"
        } else {
            duration = "\(seconds)s"
        }
        return "Worked for \(duration)"
    }

    private static func visualState(
        _ state: ConnSessionState
    ) -> ConnSessionVisualState {
        guard state.freshness == .live else { return .stale }
        return switch state.session.status {
        case .working: .working
        case .waitingForAttention: .waitingForAttention
        case .completed: .completed
        case .failed: .failed
        case .idle, .notLoaded: .idle
        case .unknown: .unknown
        }
    }

    private static func statusLabel(_ state: ConnSessionVisualState) -> String {
        switch state {
        case .working: "Working"
        case .waitingForAttention: "Needs attention"
        case .completed: "Completed"
        case .failed: "Failed"
        case .idle: "Idle"
        case .stale: "Reconnecting"
        case .unknown: "Unknown"
        }
    }

    private static func activity(
        _ activity: ConnActivity
    ) -> ConnActivityPresentation {
        let label: String = switch activity.kind {
        case .userMessage: "You"
        case .agentMessage: "Assistant"
        case .plan: "Plan"
        case .reasoning: "Reasoning"
        case .command: "Command"
        case .fileChange: "File change"
        case .toolCall: "Tool"
        case .subagent: "Subagent"
        case .webSearch: "Web search"
        case .image: "Image"
        case .compaction: "Compaction"
        case .unknown: "Activity"
        }
        let tone: ConnPresentationTone = switch activity.status {
        case .failed: .failure
        case .started: .active
        case .completed, .unknown: .neutral
        }
        return .init(
            activity: activity,
            label: label,
            detail: activity.summary,
            tone: tone
        )
    }

    private static func projectName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent.nonEmpty ?? path
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
