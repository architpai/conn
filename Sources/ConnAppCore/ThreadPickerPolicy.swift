import Foundation

public enum ThreadPickerActivityWindow: String, CaseIterable, Equatable, Sendable {
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
        case .all: "All threads"
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

public enum ThreadPickerGrouping: String, CaseIterable, Equatable, Sendable {
    case flat
    case project
}

public struct ThreadPickerConfiguration: Equatable, Sendable {
    public var activityWindow: ThreadPickerActivityWindow
    public var searchText: String
    public var grouping: ThreadPickerGrouping

    public init(
        activityWindow: ThreadPickerActivityWindow = .default,
        searchText: String = "",
        grouping: ThreadPickerGrouping = .flat
    ) {
        self.activityWindow = activityWindow
        self.searchText = searchText
        self.grouping = grouping
    }
}

public struct ThreadPickerRow: Equatable, Sendable, Identifiable {
    public let thread: AppServerThreadPresentation
    public let projectID: String
    public let projectLabel: String

    public var id: String { thread.id }
}

public struct ThreadPickerGroup: Equatable, Sendable, Identifiable {
    public let id: String
    public let projectLabel: String
    public let rows: [ThreadPickerRow]
}

public struct ThreadPickerResult: Equatable, Sendable {
    public let grouping: ThreadPickerGrouping
    public let rows: [ThreadPickerRow]
    public let groups: [ThreadPickerGroup]

    public var isEmpty: Bool { rows.isEmpty }
}

public enum ThreadPickerPolicy {
    public static let maximumSearchCharacters = 256

    private struct ProjectIdentity {
        let id: String
        let label: String
    }

    private static let ungroupedProject = ProjectIdentity(
        id: "conn.thread-picker.ungrouped",
        label: "Other"
    )

    /// Applies the picker window and search in one deterministic pass. Search
    /// is token-based: every normalized token must occur in either the thread
    /// title or its project name. Activity bypasses only the date window, never
    /// an explicit search.
    public static func select(
        threads: [AppServerThreadPresentation],
        projects: [AppServerProjectPresentation],
        configuration: ThreadPickerConfiguration = .init(),
        now: Date = Date()
    ) -> ThreadPickerResult {
        let projectByThreadID = projectLookup(projects)
        let searchTokens = normalizedSearchTokens(configuration.searchText)

        let rows = threads.lazy.compactMap { thread -> ThreadPickerRow? in
            let project = projectByThreadID[thread.id] ?? ungroupedProject
            let isActivelySteerable = thread.isActive && {
                switch thread.visualState {
                case .running, .waitingForApproval, .needsInput: true
                case .unreviewedOutcome, .failed, .idle, .notLoaded, .unknown: false
                }
            }()
            guard isActivelySteerable
                    || configuration.activityWindow.includes(thread.updatedAt, relativeTo: now)
            else { return nil }
            guard matches(
                tokens: searchTokens,
                title: thread.title,
                projectLabel: project.label
            ) else { return nil }
            return ThreadPickerRow(
                thread: thread,
                projectID: project.id,
                projectLabel: project.label
            )
        }.sorted(by: rowComesFirst)

        let groups = configuration.grouping == .project
            ? grouped(rows)
            : []
        return ThreadPickerResult(
            grouping: configuration.grouping,
            rows: rows,
            groups: groups
        )
    }

    private static func projectLookup(
        _ projects: [AppServerProjectPresentation]
    ) -> [String: ProjectIdentity] {
        var result: [String: ProjectIdentity] = [:]
        for project in projects {
            let identity = ProjectIdentity(id: project.id, label: project.name)
            for thread in project.threads where result[thread.id] == nil {
                result[thread.id] = identity
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

    private static func rowComesFirst(_ lhs: ThreadPickerRow, _ rhs: ThreadPickerRow) -> Bool {
        if lhs.thread.updatedAt != rhs.thread.updatedAt {
            return lhs.thread.updatedAt > rhs.thread.updatedAt
        }
        return lhs.id < rhs.id
    }

    private static func grouped(_ rows: [ThreadPickerRow]) -> [ThreadPickerGroup] {
        var rowsByProjectID: [String: [ThreadPickerRow]] = [:]
        var labelByProjectID: [String: String] = [:]
        for row in rows {
            rowsByProjectID[row.projectID, default: []].append(row)
            labelByProjectID[row.projectID] = row.projectLabel
        }
        return rowsByProjectID.map { id, projectRows in
            ThreadPickerGroup(
                id: id,
                projectLabel: labelByProjectID[id] ?? ungroupedProject.label,
                rows: projectRows
            )
        }.sorted { lhs, rhs in
            let lhsDate = lhs.rows.first?.thread.updatedAt ?? .distantPast
            let rhsDate = rhs.rows.first?.thread.updatedAt ?? .distantPast
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
