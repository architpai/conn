import Foundation
import ConnDomain

public enum SessionPickerActivityWindow: String, CaseIterable, Equatable, Sendable {
    case last24Hours
    case last3Days
    case last7Days
    case last30Days
    case all

    public static let `default`: Self = .last24Hours

    public var settingsLabel: String {
        switch self {
        case .last24Hours: "Last 24 hours"
        case .last3Days: "Last 3 days"
        case .last7Days: "Last 7 days"
        case .last30Days: "Last 30 days"
        case .all: "All sessions"
        }
    }

    fileprivate func includes(_ date: Date, relativeTo now: Date) -> Bool {
        guard let duration else { return true }
        return date >= now.addingTimeInterval(-duration)
    }

    private var duration: TimeInterval? {
        switch self {
        case .last24Hours: 24 * 60 * 60
        case .last3Days: 3 * 24 * 60 * 60
        case .last7Days: 7 * 24 * 60 * 60
        case .last30Days: 30 * 24 * 60 * 60
        case .all: nil
        }
    }
}

public enum SessionPickerGrouping: String, CaseIterable, Equatable, Sendable {
    case flat
    case project
}

public struct SessionPickerConfiguration: Equatable, Sendable {
    public var activityWindow: SessionPickerActivityWindow
    public var searchText: String
    public var grouping: SessionPickerGrouping
    public var dismissedSessionIDs: Set<ConnSessionID>
    public var retainedSessionIDs: Set<ConnSessionID>

    public init(
        activityWindow: SessionPickerActivityWindow = .default,
        searchText: String = "",
        grouping: SessionPickerGrouping = .flat,
        dismissedSessionIDs: Set<ConnSessionID> = [],
        retainedSessionIDs: Set<ConnSessionID> = []
    ) {
        self.activityWindow = activityWindow
        self.searchText = searchText
        self.grouping = grouping
        self.dismissedSessionIDs = dismissedSessionIDs
        self.retainedSessionIDs = retainedSessionIDs
    }
}

public struct SessionPickerRow: Equatable, Sendable, Identifiable {
    public let session: ConnSessionPresentation
    public let projectID: ConnProjectID
    public let projectLabel: String

    public var id: ConnSessionID { session.id }
}

public struct SessionPickerGroup: Equatable, Sendable, Identifiable {
    public let id: ConnProjectID
    public let projectLabel: String
    public let rows: [SessionPickerRow]
}

public struct SessionPickerResult: Equatable, Sendable {
    public let grouping: SessionPickerGrouping
    public let rows: [SessionPickerRow]
    public let groups: [SessionPickerGroup]

    public var isEmpty: Bool { rows.isEmpty }
}

public enum SessionPickerPolicy {
    public static let maximumSearchCharacters = 256

    private struct ProjectIdentity {
        let id: ConnProjectID
        let label: String
    }

    private static let ungroupedProject = ProjectIdentity(
        id: .init(rawValue: "conn.session-picker.ungrouped"),
        label: "Other"
    )

    /// Applies normal visibility and explicit search in one deterministic
    /// pass. A non-empty search is token-based and searches the complete
    /// retained inventory, including dismissed Sessions and those outside the
    /// activity window.
    public static func select(
        sessions: [ConnSessionPresentation],
        projects: [ConnProjectPresentation],
        configuration: SessionPickerConfiguration = .init(),
        now: Date = Date()
    ) -> SessionPickerResult {
        let projectBySessionID = projectLookup(projects)
        let searchTokens = normalizedSearchTokens(configuration.searchText)

        let rows = sessions.lazy.compactMap { session -> SessionPickerRow? in
            let project = projectBySessionID[session.id] ?? ungroupedProject
            if !searchTokens.isEmpty {
                guard matches(
                    tokens: searchTokens,
                    title: session.title,
                    projectLabel: project.label
                ) else { return nil }
                return SessionPickerRow(
                    session: session,
                    projectID: project.id,
                    projectLabel: project.label
                )
            }
            guard !configuration.dismissedSessionIDs.contains(session.id) else {
                return nil
            }
            let isActivelySteerable = session.isActive && {
                switch session.visualState {
                case .working, .waitingForAttention: true
                case .completed, .failed, .idle, .stale, .unknown: false
                }
            }()
            guard isActivelySteerable
                    || configuration.retainedSessionIDs.contains(session.id)
                    || configuration.activityWindow.includes(session.updatedAt, relativeTo: now)
            else { return nil }
            return SessionPickerRow(
                session: session,
                projectID: project.id,
                projectLabel: project.label
            )
        }.sorted(by: rowComesFirst)

        let groups = configuration.grouping == .project
            ? grouped(rows)
            : []
        return SessionPickerResult(
            grouping: configuration.grouping,
            rows: rows,
            groups: groups
        )
    }

    private static func projectLookup(
        _ projects: [ConnProjectPresentation]
    ) -> [ConnSessionID: ProjectIdentity] {
        var result: [ConnSessionID: ProjectIdentity] = [:]
        for project in projects {
            let identity = ProjectIdentity(id: project.id, label: project.name)
            for session in project.sessions where result[session.id] == nil {
                result[session.id] = identity
            }
        }
        return result
    }

    private static func normalizedSearchTokens(_ searchText: String) -> [String] {
        normalize(String(searchText.prefix(maximumSearchCharacters)))
            .split(whereSeparator: \Character.isWhitespace)
            .map(String.init)
    }

    private static func matches(
        tokens: [String],
        title: String,
        projectLabel: String
    ) -> Bool {
        guard !tokens.isEmpty else { return true }
        let searchableText = normalize("\(title) \(projectLabel)")
        return tokens.allSatisfy(searchableText.contains)
    }

    private static func normalize(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func rowComesFirst(_ lhs: SessionPickerRow, _ rhs: SessionPickerRow) -> Bool {
        if lhs.session.updatedAt != rhs.session.updatedAt {
            return lhs.session.updatedAt > rhs.session.updatedAt
        }
        return lhs.id < rhs.id
    }

    private static func grouped(_ rows: [SessionPickerRow]) -> [SessionPickerGroup] {
        var rowsByProjectID: [ConnProjectID: [SessionPickerRow]] = [:]
        var labelByProjectID: [ConnProjectID: String] = [:]
        for row in rows {
            rowsByProjectID[row.projectID, default: []].append(row)
            labelByProjectID[row.projectID] = row.projectLabel
        }
        return rowsByProjectID.map { id, projectRows in
            SessionPickerGroup(
                id: id,
                projectLabel: labelByProjectID[id] ?? ungroupedProject.label,
                rows: projectRows
            )
        }.sorted { lhs, rhs in
            let lhsDate = lhs.rows.first?.session.updatedAt ?? .distantPast
            let rhsDate = rhs.rows.first?.session.updatedAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            let lhsLabel = normalize(lhs.projectLabel)
            let rhsLabel = normalize(rhs.projectLabel)
            if lhsLabel != rhsLabel { return lhsLabel < rhsLabel }
            if lhs.projectLabel != rhs.projectLabel {
                return lhs.projectLabel < rhs.projectLabel
            }
            return lhs.id < rhs.id
        }
    }
}
