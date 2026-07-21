import Foundation
import ConnAppCore
import ConnAppServerAdapter
import ConnDomain

enum Phase11HookVisibilityTestCases {
    private static let wireIdentity = ConnAppServerConnectionIdentity(
        instanceID: UUID(uuidString: "11000000-0000-4000-8000-000000000011")!,
        generation: 11
    )
    private static let identity = AppServerConnectionIdentity(
        instanceID: wireIdentity.instanceID,
        generation: wireIdentity.generation
    )
    private static let threadID = AppServerThreadID(rawValue: "phase11-thread")

    static func run(into suite: inout TestSuite) async throws {
        try configuredHooksAreBoundedAndPrivate(into: &suite)
        try hookRunsRetainOnlyLifecycleFacts(into: &suite)
        try malformedAndUnknownHookFactsAreIsolated(into: &suite)
        await orderingBoundsAndReconnectAreDeterministic(into: &suite)
        await hookFactsCannotMutateThreadLifecycle(into: &suite)
        await runtimeRefreshUsesStableHooksList(into: &suite)
        boundedWorkspaceScopeFailsClosed(into: &suite)
    }

    private static func configuredHooksAreBoundedAndPrivate(
        into suite: inout TestSuite
    ) throws {
        let response = ConnAppServerResponseEnvelope(
            connection: wireIdentity,
            sequence: 5,
            result: .object(["data": .array([.object([
                "cwd": .string("/PRIVATE-CWD-CANARY"),
                "errors": .array([.object([
                    "message": .string("PRIVATE-ERROR-CANARY"),
                    "path": .string("/PRIVATE-ERROR-PATH-CANARY"),
                ])]),
                "warnings": .array([.string("PRIVATE-WARNING-CANARY")]),
                "hooks": .array([hookMetadata()]),
            ])])])
        )
        let observation = try AppServerObservationAdapter().configuredHooks(response: response)
        suite.checkEqual(observation.cursor.sequence, 5, "hooks/list keeps correlated receive order")
        suite.checkEqual(observation.hooks.count, 1, "hooks/list produces one safe summary")
        suite.checkEqual(observation.hooks.first?.pluginID, "legacy.conn", "bounded plugin identity is retained")
        let reflected = String(reflecting: observation)
        for canary in [
            "PRIVATE-COMMAND-CANARY", "PRIVATE-CWD-CANARY", "PRIVATE-PATH-CANARY",
            "PRIVATE-HASH-CANARY", "PRIVATE-KEY-CANARY", "PRIVATE-MATCHER-CANARY", "PRIVATE-STATUS-CANARY",
            "PRIVATE-ERROR-CANARY", "PRIVATE-WARNING-CANARY",
        ] {
            suite.check(!reflected.contains(canary), "configured hook projection drops \(canary)")
        }
    }

    private static func hookRunsRetainOnlyLifecycleFacts(
        into suite: inout TestSuite
    ) throws {
        let observation = try AppServerObservationAdapter().hookRun(from: hookEnvelope(
            method: "hook/completed", sequence: 9, status: "completed", completedAt: .integer(1_900_000_001_000)
        ))
        let run = observation?.run
        suite.checkEqual(run?.threadID, threadID, "hook activity keeps exact thread identity")
        suite.checkEqual(run?.turnID?.rawValue, "phase11-turn", "hook activity keeps optional exact turn identity")
        suite.checkEqual(run?.id, "phase11-run", "hook activity keeps exact run identity")
        suite.checkEqual(run?.status, .completed, "hook completion keeps typed status")
        let reflected = String(reflecting: observation)
        for canary in ["PRIVATE-RUN-PATH-CANARY", "PRIVATE-ENTRY-CANARY", "PRIVATE-RUN-STATUS-CANARY"] {
            suite.check(!reflected.contains(canary), "hook run projection drops \(canary)")
        }
    }

    private static func malformedAndUnknownHookFactsAreIsolated(
        into suite: inout TestSuite
    ) throws {
        let adapter = AppServerObservationAdapter()
        let unknown = try adapter.hookRun(from: .init(
            connection: wireIdentity,
            sequence: 1,
            message: .notification(.init(method: "unrelated/event", params: .object([:])))
        ))
        suite.check(
            unknown == nil,
            "unknown notifications remain outside hook projection"
        )
        do {
            _ = try adapter.hookRun(from: hookEnvelope(
                method: "hook/started", sequence: 2, status: "invented", completedAt: .null
            ))
            suite.check(false, "unknown hook status must be rejected")
        } catch let error as AppServerObservationAdapterError {
            suite.checkEqual(
                error,
                .malformed(context: "hook/started", field: "status"),
                "unknown hook status fails locally"
            )
        }
        do {
            _ = try adapter.configuredHooks(response: .init(
                connection: wireIdentity,
                sequence: 3,
                result: .object(["data": .array([.object([
                    "errors": .array([]),
                    "warnings": .array([]),
                    "hooks": .array([]),
                ])])])
            ))
            suite.check(false, "hooks/list rows missing privacy-dropped required fields must be rejected")
        } catch let error as AppServerObservationAdapterError {
            suite.checkEqual(
                error,
                .malformed(context: "hooks/list result", field: "cwd"),
                "privacy-dropped hooks/list fields are still schema-validated"
            )
        }
        do {
            _ = try adapter.hookRun(from: .init(
                connection: wireIdentity,
                sequence: 4,
                message: .notification(.init(method: "hook/started", params: .object([
                    "threadId": .string(threadID.rawValue),
                    "run": .object([
                        "id": .string("malformed-run"),
                        "eventName": .string("preToolUse"),
                        "executionMode": .string("sync"),
                        "handlerType": .string("command"),
                        "scope": .string("turn"),
                        "startedAt": .integer(1_900_000_000_000),
                        "status": .string("running"),
                    ]),
                ])))
            ))
            suite.check(false, "hook notifications missing privacy-dropped required fields must be rejected")
        } catch let error as AppServerObservationAdapterError {
            suite.checkEqual(
                error,
                .malformed(context: "hook/started", field: "displayOrder"),
                "privacy-dropped hook run fields are still schema-validated"
            )
        }
    }

    private static func orderingBoundsAndReconnectAreDeterministic(
        into suite: inout TestSuite
    ) async {
        let store = AppServerHookProjectionStore()
        suite.checkEqual(await store.activate(identity), .applied, "hook projection activates exact connection")
        suite.checkEqual(await store.snapshot().freshness, .stale, "hook configuration stays stale until hooks/list succeeds")
        let started = run(status: .running, completedAt: nil)
        let completed = run(status: .completed, completedAt: Date(timeIntervalSince1970: 10))
        suite.checkEqual(await store.applyRun(started, cursor: cursor(3)), .applied, "started hook applies")
        suite.checkEqual(await store.applyRun(started, cursor: cursor(3)), .duplicate, "duplicate hook cursor is ignored")
        suite.checkEqual(await store.applyRun(completed, cursor: cursor(2)), .rejectedOutOfOrder, "older completion cannot overwrite newer evidence")
        suite.checkEqual(await store.applyRun(completed, cursor: cursor(4)), .applied, "newer completion replaces started evidence")
        suite.checkEqual(await store.snapshot().runsByThread[threadID]?.count, 1, "one run identity remains bounded")

        for index in 1..<AppServerHookProjectionStore.maximumRunsPerThread {
            let extra = AppServerHookRunSummary(
                id: "extra-\(index)",
                threadID: threadID,
                turnID: nil,
                eventName: .stop,
                executionMode: .async,
                handlerType: .agent,
                scope: .thread,
                status: .completed,
                startedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                completedAt: Date(timeIntervalSince1970: TimeInterval(index + 1))
            )
            _ = await store.applyRun(extra, cursor: cursor(UInt64(10 + index)))
        }
        let overflow = AppServerHookRunSummary(
            id: "overflow",
            threadID: threadID,
            turnID: nil,
            eventName: .stop,
            executionMode: .async,
            handlerType: .agent,
            scope: .thread,
            status: .completed,
            startedAt: Date(),
            completedAt: Date()
        )
        suite.checkEqual(
            await store.applyRun(overflow, cursor: cursor(1_000)),
            .applied,
            "per-thread hook activity evicts oldest evidence at its hard bound"
        )
        let boundedRuns = await store.snapshot().runsByThread[threadID] ?? []
        suite.checkEqual(boundedRuns.count, AppServerHookProjectionStore.maximumRunsPerThread, "run timeline remains bounded")
        suite.check(boundedRuns.contains(where: { $0.id == "overflow" }), "newest run remains visible after eviction")
        suite.check(!boundedRuns.contains(where: { $0.id == "phase11-run" }), "oldest run is evicted instead of freezing the timeline")

        let configuredOverflow = (0...AppServerHookProjectionStore.maximumConfiguredHooks).map { index in
            AppServerConfiguredHookSummary(
                eventName: .preToolUse,
                handlerType: .command,
                source: .plugin,
                enabled: true,
                trustStatus: .trusted,
                pluginID: "plugin-\(index)"
            )
        }
        suite.checkEqual(
            await store.replaceConfiguredHooks(configuredOverflow, cursor: cursor(1_001)),
            .rejectedBound,
            "configured hook summaries have a hard bound"
        )
        suite.checkEqual(await store.loseConnection(identity), .applied, "disconnect marks hook evidence stale")
        suite.checkEqual(await store.snapshot().freshness, .stale, "disconnected hook evidence is explicitly stale")

        let next = AppServerConnectionIdentity(instanceID: UUID(), generation: 12)
        suite.checkEqual(await store.activate(next), .applied, "reconnect activates a new exact identity")
        let reconnected = await store.snapshot()
        suite.check(reconnected.runsByThread.isEmpty, "reconnect does not replay prior hook activity as current")
        suite.checkEqual(await store.applyRun(started, cursor: cursor(5)), .rejectedStaleConnection, "prior generation cannot write after reconnect")
    }

    private static func hookFactsCannotMutateThreadLifecycle(
        into suite: inout TestSuite
    ) async {
        let threadStore = AppServerProjectionStore()
        _ = await threadStore.apply(.connectionActivated(
            identity: identity,
            source: .managedDaemon,
            featureSupport: .init(features: [.monitor])
        ))
        let before = await threadStore.snapshot()
        let hookStore = AppServerHookProjectionStore()
        _ = await hookStore.activate(identity)
        _ = await hookStore.applyRun(run(status: .blocked, completedAt: nil), cursor: cursor(1))
        let after = await threadStore.snapshot()
        suite.checkEqual(after, before, "hook activity cannot mutate lifecycle, outcomes, or attention")
    }

    private static func runtimeRefreshUsesStableHooksList(
        into suite: inout TestSuite
    ) async {
        let connection = Phase11HookListConnection(
            identity: wireIdentity,
            result: .object(["data": .array([.object([
                "cwd": .string("/not-retained"),
                "errors": .array([]),
                "warnings": .array([]),
                "hooks": .array([hookMetadata()]),
            ])])])
        )
        let runtime = AppServerMonitoringRuntime(configuration: .init(
            qualificationTimeout: .seconds(1)
        ))
        await runtime.activateHookProjectionForTesting(identity)
        let coordinator = AppServerDomainCoordinator(domain: AppServerProjectionStore())
        let refreshed = await runtime.refreshConfiguredHooksForTesting(
            connection: connection,
            coordinator: coordinator,
            knownWorkingDirectories: ["/tmp/known"]
        )
        let methods = await connection.requestedMethods()
        let snapshot = await runtime.hookSnapshotForTesting()
        suite.check(refreshed, "runtime applies a valid hooks/list refresh")
        suite.checkEqual(methods, ["hooks/list"], "runtime uses the pinned stable hooks/list method")
        suite.checkEqual(snapshot.configuredHooks.count, 1, "runtime publishes refreshed hook summaries")
        suite.checkEqual(snapshot.freshness, .current, "valid hooks/list response marks configuration current")
        suite.checkEqual(
            await runtime.markHookConfigurationStaleForTesting(identity),
            .applied,
            "failed refresh can mark previously current hook configuration stale"
        )
    }

    private static func boundedWorkspaceScopeFailsClosed(into suite: inout TestSuite) {
        let input = (0..<33).map { "/tmp/workspace-\($0)" }
        let scope = AppServerMonitoringRuntime.boundedHookWorkingDirectoryScope(input)
        suite.checkEqual(scope.directories.count, 32, "hook workspace scope remains bounded")
        suite.check(!scope.isComplete, "a truncated workspace scope cannot authorize global plugin uninstall")
    }

    private static func hookMetadata() -> JSONValue {
        .object([
            "command": .string("PRIVATE-COMMAND-CANARY"),
            "currentHash": .string("PRIVATE-HASH-CANARY"),
            "displayOrder": .integer(1),
            "enabled": .bool(true),
            "eventName": .string("preToolUse"),
            "handlerType": .string("command"),
            "isManaged": .bool(false),
            "key": .string("PRIVATE-KEY-CANARY"),
            "matcher": .string("PRIVATE-MATCHER-CANARY"),
            "pluginId": .string("legacy.conn"),
            "source": .string("plugin"),
            "sourcePath": .string("/PRIVATE-PATH-CANARY"),
            "statusMessage": .string("PRIVATE-STATUS-CANARY"),
            "timeoutSec": .integer(10),
            "trustStatus": .string("trusted"),
        ])
    }

    private static func hookEnvelope(
        method: String,
        sequence: UInt64,
        status: String,
        completedAt: JSONValue
    ) -> ConnAppServerInboundEnvelope {
        .init(
            connection: wireIdentity,
            sequence: sequence,
            message: .notification(.init(method: method, params: .object([
                "threadId": .string(threadID.rawValue),
                "turnId": .string("phase11-turn"),
                "run": .object([
                    "id": .string("phase11-run"),
                    "displayOrder": .integer(1),
                    "entries": .array([.object([
                        "kind": .string("error"),
                        "text": .string("PRIVATE-ENTRY-CANARY"),
                    ])]),
                    "eventName": .string("preToolUse"),
                    "executionMode": .string("sync"),
                    "handlerType": .string("command"),
                    "scope": .string("turn"),
                    "source": .string("project"),
                    "sourcePath": .string("/PRIVATE-RUN-PATH-CANARY"),
                    "startedAt": .integer(1_900_000_000_000),
                    "completedAt": completedAt,
                    "status": .string(status),
                    "statusMessage": .string("PRIVATE-RUN-STATUS-CANARY"),
                ]),
            ])))
        )
    }

    private static func run(
        status: AppServerHookRunStatus,
        completedAt: Date?
    ) -> AppServerHookRunSummary {
        .init(
            id: "phase11-run",
            threadID: threadID,
            turnID: .init(rawValue: "phase11-turn"),
            eventName: .preToolUse,
            executionMode: .sync,
            handlerType: .command,
            scope: .turn,
            status: status,
            startedAt: Date(timeIntervalSince1970: 1),
            completedAt: completedAt
        )
    }

    private static func cursor(_ sequence: UInt64) -> AppServerObservationCursor {
        .init(connection: identity, sequence: sequence)
    }
}

private actor Phase11HookListConnection: AppServerMonitoringConnection {
    private let identity: ConnAppServerConnectionIdentity
    private let result: JSONValue
    private var methods: [String] = []

    init(identity: ConnAppServerConnectionIdentity, result: JSONValue) {
        self.identity = identity
        self.result = result
    }

    func connect(
        to endpoint: ControlEndpoint,
        serverVersion: SupportedAppServerVersion,
        mode: AppServerCapabilityMode
    ) async throws -> InitializeResponse {
        throw CancellationError()
    }

    func requestEnvelope(
        method: String,
        params: JSONValue?,
        timeout: Duration?
    ) async throws -> ConnAppServerResponseEnvelope {
        methods.append(method)
        return .init(connection: identity, sequence: UInt64(methods.count), result: result)
    }

    func drainInboundEnvelopes() async -> [ConnAppServerInboundEnvelope] { [] }
    func monitoringState() async -> ConnAppServerConnectionState { .disconnected }
    func monitoringIdentity() async -> ConnAppServerConnectionIdentity? { identity }
    func disconnect() async {}
    func requestedMethods() -> [String] { methods }
}
