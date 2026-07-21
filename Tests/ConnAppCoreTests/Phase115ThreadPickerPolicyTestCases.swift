import Foundation
import ConnAppCore
import ConnDomain

enum Phase115ThreadPickerPolicyTestCases {
    private static let now = Date(timeIntervalSince1970: 1_900_000_000)
    private static let connection = AppServerConnectionIdentity(
        instanceID: UUID(uuidString: "11500000-0000-4000-8000-000000000115")!,
        generation: 115
    )

    static func run(into suite: inout TestSuite) async {
        let presentation = await fixturePresentation()
        filtersByDefaultWindowAndKeepsOldActiveThreads(presentation, into: &suite)
        exposesStableSettingsPresets(into: &suite)
        searchesTitlesAndProjectsWithoutCaseOrDiacritics(presentation, into: &suite)
        shapesFlatAndGroupedResultsDeterministically(presentation, into: &suite)
    }

    private static func filtersByDefaultWindowAndKeepsOldActiveThreads(
        _ presentation: AppServerDomainPresentation,
        into suite: inout TestSuite
    ) {
        let result = ThreadPickerPolicy.select(
            threads: presentation.threads,
            projects: presentation.projects,
            now: now
        )
        suite.checkEqual(
            result.rows.map(\.id),
            ["recent-resume", "boundary", "old-running"],
            "default picker includes the inclusive 24-hour window plus old active work"
        )
        suite.check(!result.rows.map(\.id).contains("old-idle"), "old terminal work is hidden by the default window")

        func ids(_ window: ThreadPickerActivityWindow) -> [String] {
            ThreadPickerPolicy.select(
                threads: presentation.threads,
                projects: presentation.projects,
                configuration: .init(activityWindow: window),
                now: now
            ).rows.map(\.id)
        }
        suite.checkEqual(ids(.last3Days), ["recent-resume", "boundary", "old-running"], "three-day preset excludes four-day terminal work")
        suite.checkEqual(ids(.last7Days), ["recent-resume", "boundary", "old-idle", "old-running"], "seven-day preset includes four-day work")
        suite.checkEqual(ids(.last30Days), ["recent-resume", "boundary", "old-idle", "cafe-project", "old-running"], "thirty-day preset includes eight-day work")
        suite.checkEqual(ids(.all), ["recent-resume", "boundary", "old-idle", "cafe-project", "old-running"], "all preset removes the date cutoff")
    }

    private static func exposesStableSettingsPresets(into suite: inout TestSuite) {
        suite.checkEqual(ThreadPickerActivityWindow.default, .last24Hours, "the picker defaults to a 24-hour activity window")
        suite.checkEqual(
            ThreadPickerActivityWindow.allCases.map(\.settingsLabel),
            ["Last 24 hours", "Last 3 days", "Last 7 days", "Last 30 days", "All threads"],
            "settings expose the complete ordered activity-window preset list"
        )
    }

    private static func searchesTitlesAndProjectsWithoutCaseOrDiacritics(
        _ presentation: AppServerDomainPresentation,
        into suite: inout TestSuite
    ) {
        func ids(_ searchText: String) -> [String] {
            ThreadPickerPolicy.select(
                threads: presentation.threads,
                projects: presentation.projects,
                configuration: .init(activityWindow: .all, searchText: searchText),
                now: now
            ).rows.map(\.id)
        }

        suite.checkEqual(ids("RESUME"), ["recent-resume"], "search ignores title case and diacritics")
        suite.checkEqual(ids("cafe"), ["cafe-project", "old-running"], "search ignores project-name diacritics")
        suite.checkEqual(ids("resume alpha"), ["recent-resume"], "search tokens can match across title and project name")
        suite.checkEqual(ids("missing"), [], "an unmatched search returns an honest empty result")
    }

    private static func shapesFlatAndGroupedResultsDeterministically(
        _ presentation: AppServerDomainPresentation,
        into suite: inout TestSuite
    ) {
        let flat = ThreadPickerPolicy.select(
            threads: presentation.threads.reversed(),
            projects: presentation.projects,
            configuration: .init(activityWindow: .all),
            now: now
        )
        suite.checkEqual(flat.grouping, .flat, "flat rows are the default picker shape")
        suite.checkEqual(flat.groups, [], "flat mode does not manufacture project sections")
        suite.checkEqual(
            flat.rows.map { "\($0.id)|\($0.projectLabel)" },
            [
                "recent-resume|Alpha",
                "boundary|Alpha",
                "old-idle|Alpha",
                "cafe-project|Café Tools",
                "old-running|Café Tools",
            ],
            "flat rows are recency-stable and expose their project labels"
        )

        let grouped = ThreadPickerPolicy.select(
            threads: presentation.threads,
            projects: presentation.projects,
            configuration: .init(activityWindow: .all, grouping: .project),
            now: now
        )
        suite.checkEqual(grouped.groups.map(\.projectLabel), ["Alpha", "Café Tools"], "groups follow their newest visible activity")
        suite.checkEqual(
            grouped.groups.map { $0.rows.map(\.id) },
            [["recent-resume", "boundary", "old-idle"], ["cafe-project", "old-running"]],
            "group rows retain deterministic recency order"
        )
    }

    private static func fixturePresentation() async -> AppServerDomainPresentation {
        let store = AppServerProjectionStore()
        _ = await store.apply(.connectionActivated(
            identity: connection,
            source: .managedDaemon,
            featureSupport: .init(features: [.monitor])
        ))
        _ = await store.apply(.snapshot(.init(
            cursor: .init(connection: connection, sequence: 1),
            observedAt: now,
            threads: [
                thread(id: "recent-resume", title: "Résumé polish", project: "Alpha", age: 60 * 60),
                thread(id: "boundary", title: "Boundary", project: "Alpha", age: 24 * 60 * 60),
                thread(id: "old-idle", title: "Archived", project: "Alpha", age: 4 * 24 * 60 * 60),
                thread(id: "cafe-project", title: "Utilities", project: "Café Tools", age: 8 * 24 * 60 * 60),
                thread(id: "old-running", title: "Long migration", project: "Café Tools", age: 40 * 24 * 60 * 60, isRunning: true),
            ]
        )))
        _ = await store.apply(.delta(.init(
            cursor: .init(connection: connection, sequence: 2),
            observedAt: now,
            delta: .threadStatus(
                threadID: .init(rawValue: "old-running"),
                status: .active([])
            )
        )))
        return AppServerDomainPresentation(
            snapshot: await store.snapshot(at: now),
            runtimeStatus: .init(phase: .connected, detail: "Testing thread picker."),
            now: now
        )
    }

    private static func thread(
        id: String,
        title: String,
        project: String,
        age: TimeInterval,
        isRunning: Bool = false
    ) -> AppServerThreadInput {
        AppServerThreadInput(
            id: .init(rawValue: id),
            sessionID: .init(rawValue: "session-\(id)"),
            title: title,
            workingDirectoryName: project,
            workingDirectoryPath: "/workspace/\(project)",
            projectRootPath: "/workspace/\(project)",
            source: .appServer,
            status: isRunning ? .active([]) : .idle,
            createdAt: now.addingTimeInterval(-age),
            updatedAt: now.addingTimeInterval(-age)
        )
    }
}
