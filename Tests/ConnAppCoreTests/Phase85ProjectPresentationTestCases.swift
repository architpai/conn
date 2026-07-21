import Foundation
import ConnAppCore
import ConnDomain

enum Phase85ProjectPresentationTestCases {
    private static let baseDate = Date(timeIntervalSince1970: 1_821_000_000)
    private static let connection = AppServerConnectionIdentity(
        instanceID: UUID(uuidString: "88500000-0000-4000-8000-000000000001")!,
        generation: 85
    )

    static func run(into suite: inout TestSuite) async {
        await testRepositoryRootAndCWDGrouping(into: &suite)
    }

    private static func testRepositoryRootAndCWDGrouping(
        into suite: inout TestSuite
    ) async {
        let repositoryThread = AppServerThreadID(rawValue: "thread-repository-root")
        let repositoryChildThread = AppServerThreadID(rawValue: "thread-repository-child")
        let cwdThread = AppServerThreadID(rawValue: "thread-cwd-first")
        let sharedCWDThread = AppServerThreadID(rawValue: "thread-cwd-second")
        let store = AppServerProjectionStore()

        _ = await store.apply(.connectionActivated(
            identity: connection,
            source: .managedDaemon,
            featureSupport: .init(features: [.monitor])
        ))
        _ = await store.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: at(1),
            threads: [
                thread(
                    id: repositoryThread,
                    title: nil,
                    directoryName: "SideQuest",
                    cwd: "/workspace/SideQuest",
                    projectRoot: "/workspace/SideQuest",
                    updatedAt: at(4)
                ),
                thread(
                    id: repositoryChildThread,
                    title: "Project grouping",
                    directoryName: "Sources",
                    cwd: "/workspace/SideQuest/Sources",
                    projectRoot: "/workspace/SideQuest",
                    updatedAt: at(3)
                ),
                thread(
                    id: cwdThread,
                    title: nil,
                    directoryName: "Scratch",
                    cwd: "/tmp/Scratch",
                    projectRoot: nil,
                    updatedAt: at(2)
                ),
                thread(
                    id: sharedCWDThread,
                    title: "Second scratch thread",
                    directoryName: "Scratch",
                    cwd: "/tmp/Scratch",
                    projectRoot: nil,
                    updatedAt: at(1)
                ),
            ]
        )))
        _ = await store.apply(.delta(.init(
            cursor: cursor(2),
            observedAt: at(5),
            delta: .threadStatus(threadID: repositoryThread, status: .active([]))
        )))
        _ = await store.apply(.delta(.init(
            cursor: cursor(3),
            observedAt: at(6),
            delta: .requestOpened(.init(
                requestID: .string("project-question"),
                threadID: repositoryChildThread,
                kind: .structuredQuestion,
                startedAt: at(6)
            ))
        )))

        let presentation = AppServerDomainPresentation(
            snapshot: await store.snapshot(at: at(7)),
            runtimeStatus: .init(
                phase: .connected,
                detail: "Monitoring four threads in two projects.",
                listedThreadCount: 4,
                hydratedThreadCount: 4,
                monitoredThreadCount: 4
            ),
            now: at(7)
        )

        suite.checkEqual(
            presentation.projects.count,
            2,
            "repository root and shared cwd produce two project groups"
        )
        suite.checkEqual(
            presentation.projects.map(\.name),
            ["Conn", "Scratch"],
            "projects are ordered by newest activity and the legacy product directory is presented as Conn"
        )
        guard let conn = presentation.projects.first(where: { $0.name == "Conn" }),
              let scratch = presentation.projects.first(where: { $0.name == "Scratch" })
        else {
            suite.check(false, "project groups expose directory basenames")
            return
        }

        suite.checkEqual(conn.threadCount, 2, "repo-root grouping combines nested cwd threads")
        suite.checkEqual(
            conn.threads.map(\.id),
            [repositoryThread.rawValue, repositoryChildThread.rawValue],
            "threads inside a project remain authoritative newest-first despite later status observations"
        )
        suite.checkEqual(conn.attentionCount, 1, "project header aggregates attention")
        suite.checkEqual(conn.activeCount, 2, "project header aggregates active threads")
        suite.checkEqual(conn.activityLabel, "2 active", "project header reports its active-thread count")
        suite.checkEqual(conn.tone, .attention, "attention wins aggregate project tone")
        suite.checkEqual(
            conn.accessibilityLabel,
            "Conn, 2 threads, 2 active",
            "project header exposes its name, count, and aggregate state to VoiceOver"
        )
        suite.checkEqual(
            conn.threads.first(where: { $0.threadID == repositoryThread })?.title,
            "Conn",
            "a null thread name presents the legacy product directory as Conn"
        )

        suite.checkEqual(scratch.threadCount, 2, "threads without gitInfo group by shared cwd")
        suite.checkEqual(scratch.attentionCount, 0, "unattended cwd group stays neutral")
        suite.checkEqual(
            scratch.activityLabel,
            "2",
            "a project without active work reports its total thread count"
        )
        suite.checkEqual(
            scratch.threads.first(where: { $0.threadID == cwdThread })?.title,
            "Scratch",
            "null-name fallback remains readable when gitInfo is absent"
        )
    }

    private static func thread(
        id: AppServerThreadID,
        title: String?,
        directoryName: String,
        cwd: String,
        projectRoot: String?,
        updatedAt: Date
    ) -> AppServerThreadInput {
        AppServerThreadInput(
            id: id,
            sessionID: .init(rawValue: "session-\(id.rawValue)"),
            title: title,
            workingDirectoryName: directoryName,
            workingDirectoryPath: cwd,
            projectRootPath: projectRoot,
            source: .appServer,
            status: .idle,
            createdAt: at(0),
            updatedAt: updatedAt
        )
    }

    private static func cursor(_ sequence: UInt64) -> AppServerObservationCursor {
        .init(connection: connection, sequence: sequence)
    }

    private static func at(_ seconds: TimeInterval) -> Date {
        baseDate.addingTimeInterval(seconds)
    }
}
