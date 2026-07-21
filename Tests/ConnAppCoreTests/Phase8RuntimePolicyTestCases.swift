import Foundation
import ConnAppCore
import ConnAppServerAdapter
import ConnDomain

enum Phase8RuntimePolicyTestCases {
    private static let observedAt = Date(timeIntervalSince1970: 1_820_000_000)
    private static let connection = ConnAppServerConnectionIdentity(
        instanceID: UUID(uuidString: "88000000-0000-4000-8000-000000000008")!,
        generation: 8
    )

    static func run(into suite: inout TestSuite) async throws {
        try acceptsBoundedTruncatedInventory(into: &suite)
        try filtersProjectionToSuccessfullyResumedThreads(into: &suite)
        try await preservesClosedPersistedThreads(into: &suite)
        await surfacesTruncatedCoverage(into: &suite)
    }

    private static func preservesClosedPersistedThreads(
        into suite: inout TestSuite
    ) async throws {
        let adapter = AppServerObservationAdapter()
        let domainIdentity = adapter.connectionIdentity(from: connection)
        let domain = AppServerProjectionStore()
        _ = await domain.apply(adapter.connectionActivated(
            identity: domainIdentity,
            source: .managedDaemon,
            serverVersion: .v0_144_6
        ))
        let page = try adapter.threadListPage(
            response: listResponse(ids: ["thread-closed"], nextCursor: nil),
            observedAt: observedAt
        )
        _ = await domain.apply(.snapshot(page.snapshot))
        let closed = try adapter.projectionInput(
            from: .init(
                method: "thread/closed",
                params: .object(["threadId": .string("thread-closed")])
            ),
            cursor: .init(connection: domainIdentity, sequence: 11),
            observedAt: observedAt.addingTimeInterval(1)
        )
        if let closed { _ = await domain.apply(closed) }
        let snapshot = await domain.snapshot(at: observedAt.addingTimeInterval(1))

        suite.checkEqual(
            snapshot.threads.map(\.id.rawValue),
            ["thread-closed"],
            "thread/closed preserves the persisted row instead of treating unload as deletion"
        )
        suite.checkEqual(
            snapshot.threads.first?.status,
            .notLoaded,
            "thread/closed projects the documented unloaded thread state"
        )
    }

    private static func acceptsBoundedTruncatedInventory(
        into suite: inout TestSuite
    ) throws {
        let page = try AppServerObservationAdapter().threadListPage(
            response: listResponse(ids: ["thread-first-page"], nextCursor: "more"),
            observedAt: observedAt
        )

        suite.check(page.isTruncated, "a non-empty thread/list cursor marks bounded inventory as truncated")
        suite.checkEqual(page.nextCursor, "more", "the bounded page retains its coverage cursor evidence")
        suite.checkEqual(
            page.snapshot.threads.map(\.id.rawValue),
            ["thread-first-page"],
            "the first bounded thread/list page remains usable for qualification"
        )
    }

    private static func filtersProjectionToSuccessfullyResumedThreads(
        into suite: inout TestSuite
    ) throws {
        let adapter = AppServerObservationAdapter()
        let page = try adapter.threadListPage(
            response: listResponse(
                ids: ["thread-resumed", "thread-read-failed", "thread-resume-failed"],
                nextCursor: nil
            ),
            observedAt: observedAt
        )
        var scope = AppServerMonitoringScope()
        let accepted = try adapter.threadReadDelta(
            response: readResponse(id: "thread-resumed", sequence: 20),
            observedAt: observedAt
        )
        let readFailed = try adapter.threadReadDelta(
            response: readResponse(id: "thread-read-failed", sequence: 21),
            observedAt: observedAt
        )
        let resumeFailed = try adapter.threadReadDelta(
            response: readResponse(id: "thread-resume-failed", sequence: 22),
            observedAt: observedAt
        )
        suite.check(scope.qualify(
            requestedThreadID: .init(rawValue: "thread-resumed"),
            readInput: accepted,
            readApply: .applied,
            resumeInput: accepted,
            resumeApply: .applied
        ), "a matching successful read and resume qualifies the requested thread")
        suite.check(!scope.qualify(
            requestedThreadID: .init(rawValue: "thread-read-failed"),
            readInput: nil,
            readApply: nil,
            resumeInput: readFailed,
            resumeApply: .applied
        ), "a failed read cannot qualify a listed thread")
        suite.check(!scope.qualify(
            requestedThreadID: .init(rawValue: "thread-resume-failed"),
            readInput: resumeFailed,
            readApply: .applied,
            resumeInput: nil,
            resumeApply: nil
        ), "a failed resume cannot qualify a successfully read thread")

        let filtered = scope.filtered(page.snapshot)
        suite.checkEqual(
            filtered.threads.map(\.id.rawValue),
            ["thread-resumed"],
            "listed threads enter the connected snapshot only after successful read and resume"
        )
        suite.check(scope.accepts(accepted), "inbound facts for a successfully resumed thread are accepted")
        suite.check(!scope.accepts(readFailed), "inbound facts for a thread that failed read are rejected")
        suite.check(!scope.accepts(resumeFailed), "inbound facts for a thread that failed resume are rejected")
    }

    private static func surfacesTruncatedCoverage(
        into suite: inout TestSuite
    ) async {
        let snapshot = await AppServerProjectionStore().snapshot(at: observedAt)
        let presentation = AppServerDomainPresentation(
            snapshot: snapshot,
            runtimeStatus: .init(
                phase: .connected,
                detail: "Monitoring the successfully resumed subset up to the configured safety ceiling.",
                listedThreadCount: 2,
                hydratedThreadCount: 1,
                monitoredThreadCount: 1,
                isThreadInventoryTruncated: true
            ),
            now: observedAt
        )

        suite.checkEqual(
            presentation.connection.coverageLabel,
            "1 of 2 connected threads monitored · safety ceiling reached; more not shown",
            "connected presentation surfaces ceiling-truncated inventory coverage"
        )
        suite.check(
            !(presentation.connection.coverageLabel ?? "").lowercased().contains("all local"),
            "truncated coverage never implies visibility into all local threads"
        )
    }

    private static func listResponse(ids: [String], nextCursor: String?) -> ConnAppServerResponseEnvelope {
        .init(
            connection: connection,
            sequence: 10,
            result: .object([
                "data": .array(ids.map(threadValue)),
                "nextCursor": nextCursor.map(JSONValue.string) ?? .null,
            ])
        )
    }

    private static func readResponse(id: String, sequence: UInt64) -> ConnAppServerResponseEnvelope {
        .init(
            connection: connection,
            sequence: sequence,
            result: .object(["thread": threadValue(id)])
        )
    }

    private static func threadValue(_ id: String) -> JSONValue {
        .object([
            "id": .string(id),
            "sessionId": .string("session-\(id)"),
            "cliVersion": .string("0.144.6"),
            "cwd": .string("/tmp/SideQuest"),
            "modelProvider": .string("openai"),
            "preview": .string("discarded"),
            "source": .string("appServer"),
            "status": .object(["type": .string("idle")]),
            "ephemeral": .bool(false),
            "createdAt": .integer(1_820_000_000),
            "updatedAt": .integer(1_820_000_001),
            "turns": .array([]),
        ])
    }
}
