import Foundation
import ConnAppCore
import ConnAppServerAdapter
import ConnDomain

enum Phase10SharedDesktopRuntimeTestCases {
    private static let instanceID = UUID(uuidString: "10101010-2020-3030-4040-505050505050")!
    private static let wireIdentity = ConnAppServerConnectionIdentity(
        instanceID: instanceID,
        generation: 7
    )
    private static let domainIdentity = AppServerConnectionIdentity(
        instanceID: instanceID,
        generation: 7
    )

    static func run(into suite: inout TestSuite) async throws {
        await rejectsWithoutActiveConnectionAndRejectsUnsafeIDs(into: &suite)
        try await provesReadOnlyResumeAndPostReplayEventBoundary(into: &suite)
        await reconnectClearsRuntimeOnlyCandidate(into: &suite)
        try await neverRestoresSharedDesktopVerification(into: &suite)
    }

    private static func rejectsWithoutActiveConnectionAndRejectsUnsafeIDs(
        into suite: inout TestSuite
    ) async {
        let runtime = AppServerMonitoringRuntime()
        let acceptedWithoutConnection = await runtime.beginSharedDesktopThreadProof("desktop-thread")
        suite.check(!acceptedWithoutConnection, "proof rejects without an active connection")

        await runtime.resetSharedDesktopThreadProofForTesting(connection: domainIdentity)
        let invalidIDs = [
            "",
            " leading",
            "trailing ",
            "two words",
            "line\nbreak",
            "nul\0byte",
            String(repeating: "x", count: 513),
            String(repeating: "😀", count: 129),
        ]
        for rawID in invalidIDs {
            let accepted = await runtime.beginSharedDesktopThreadProof(rawID)
            suite.check(!accepted, "empty, whitespace, NUL, or over-bound thread identity is refused")
        }

        let exactBound = String(repeating: "x", count: 512)
        let acceptedExactBound = await runtime.beginSharedDesktopThreadProof(exactBound)
        suite.check(acceptedExactBound, "an exact 512-byte non-whitespace identity remains bounded and valid")
        await runtime.cancelSharedDesktopThreadProof()
    }

    private static func provesReadOnlyResumeAndPostReplayEventBoundary(
        into suite: inout TestSuite
    ) async throws {
        let candidateID = "desktop-proof-thread"
        let replay = statusNotification(threadID: candidateID, sequence: 2)
        let connection = SharedDesktopProofMonitoringConnection(
            identity: wireIdentity,
            responses: [
                .init(method: "thread/list", response: listResponse(
                    sequence: 1,
                    threadIDs: [candidateID, "other-thread"]
                )),
                .init(method: "thread/read", response: readResponse(sequence: 2, threadID: candidateID)),
                .init(method: "thread/resume", response: readResponse(sequence: 3, threadID: candidateID)),
            ],
            inbound: [replay]
        )
        let runtime = AppServerMonitoringRuntime(configuration: .init(
            maximumBulkQualifiedThreads: 0
        ))
        await runtime.resetSharedDesktopThreadProofForTesting(connection: domainIdentity)
        let acceptedCandidate = await runtime.beginSharedDesktopThreadProof(candidateID)
        suite.check(acceptedCandidate, "active connection accepts one exact attested candidate")

        let coordinator = await activatedCoordinator()
        let inventory = try await runtime.hydrateInventoryForTesting(
            connection: connection,
            coordinator: coordinator,
            qualifyRecentThreads: false
        )

        let methods = await connection.requestedMethods()
        suite.checkEqual(methods, ["thread/list", "thread/read", "thread/resume"], "candidate proof adds only read then resume after metadata inventory")
        suite.checkEqual(Array(methods.dropFirst()), ["thread/read", "thread/resume"], "proof qualification has exactly two read-only methods")
        suite.check(!methods.contains(where: {
            $0.hasPrefix("turn/")
                || $0.contains("requestApproval")
                || $0.contains("requestUserInput")
        }), "proof sends no turn, control, approval, or question response")
        suite.checkEqual(await connection.requestedThreadIDs(), [candidateID, candidateID], "read and resume remain bound to the exact candidate")
        suite.checkEqual(
            await connection.requestedReadIncludeTurns(),
            [false],
            "explicit proof preflight is metadata-only because its exact resume supplies detailed turns"
        )

        var status = await runtime.sharedDesktopThreadProofStatus()
        suite.check(status.didReadOnlyResume, "successful qualification records read-only resume")
        suite.check(status.isWaitingForNewEvent, "successful resume records its receive-sequence boundary")
        suite.check(!status.didObserveNewEvent, "pre-resume replay cannot count as a new event")

        await connection.enqueue(statusNotification(threadID: "other-thread", sequence: 5))
        _ = try await runtime.processInboundForTesting(
            connection: connection,
            coordinator: coordinator,
            monitoringScope: inventory.scope
        )
        status = await runtime.sharedDesktopThreadProofStatus()
        suite.check(status.isWaitingForNewEvent, "another thread's later event leaves proof waiting")
        suite.check(!status.didObserveNewEvent, "another thread cannot satisfy exact candidate proof")

        await connection.enqueue(statusNotification(threadID: candidateID, sequence: 6))
        _ = try await runtime.processInboundForTesting(
            connection: connection,
            coordinator: coordinator,
            monitoringScope: inventory.scope
        )
        status = await runtime.sharedDesktopThreadProofStatus()
        suite.check(!status.didObserveNewEvent, "a later status notification remains replay-like and cannot satisfy proof")

        await connection.enqueue(turnStartedNotification(threadID: candidateID, sequence: 7))
        _ = try await runtime.processInboundForTesting(
            connection: connection,
            coordinator: coordinator,
            monitoringScope: inventory.scope
        )
        status = await runtime.sharedDesktopThreadProofStatus()
        suite.check(status.didObserveNewEvent, "a post-resume exact-thread turn lifecycle event satisfies new-event proof")
        suite.check(!status.isWaitingForNewEvent, "observed exact event ends the waiting state")
    }

    private static func reconnectClearsRuntimeOnlyCandidate(into suite: inout TestSuite) async {
        let runtime = AppServerMonitoringRuntime()
        await runtime.resetSharedDesktopThreadProofForTesting(connection: domainIdentity)
        let acceptedCandidate = await runtime.beginSharedDesktopThreadProof("runtime-only-canary")
        suite.check(acceptedCandidate, "candidate starts on active generation")
        let queuedOnOriginalConnection = await runtime.hasRequestedThreadQualificationForTesting(
            .init(rawValue: "runtime-only-canary")
        )
        suite.check(
            queuedOnOriginalConnection,
            "candidate queues qualification only on its active generation"
        )

        let replacement = AppServerConnectionIdentity(
            instanceID: UUID(uuidString: "60606060-7070-8080-9090-A0A0A0A0A0A0")!,
            generation: 1
        )
        await runtime.resetSharedDesktopThreadProofForTesting(connection: replacement)
        let reset = await runtime.sharedDesktopThreadProofStatus()
        suite.checkEqual(reset.connection, replacement, "reconnect publishes only the replacement runtime identity")
        suite.check(reset.threadID == nil, "reconnect clears candidate identity")
        suite.check(!reset.didReadOnlyResume && !reset.isWaitingForNewEvent && !reset.didObserveNewEvent, "reconnect clears every proof bit")
        let queuedOnReplacementConnection = await runtime.hasRequestedThreadQualificationForTesting(
            .init(rawValue: "runtime-only-canary")
        )
        suite.check(
            !queuedOnReplacementConnection,
            "reconnect removes the old-generation queued qualification"
        )

        let reconstructed = AppServerMonitoringRuntime()
        let fresh = await reconstructed.sharedDesktopThreadProofStatus()
        suite.check(fresh.connection == nil && fresh.threadID == nil, "proof status is runtime-only and cannot restore into a new runtime")

        await runtime.resetSharedDesktopThreadProofForTesting(connection: nil)
        let disconnected = await runtime.sharedDesktopThreadProofStatus()
        suite.check(disconnected.connection == nil && disconnected.threadID == nil, "disconnect removes all proof authority")
        let acceptedAfterDisconnect = await runtime.beginSharedDesktopThreadProof("runtime-only-canary")
        suite.check(!acceptedAfterDisconnect, "disconnected runtime cannot reuse the old candidate")
    }

    private static func neverRestoresSharedDesktopVerification(
        into suite: inout TestSuite
    ) async throws {
        let store = AppServerProjectionStore(configuration: .monitoring)
        _ = await store.apply(.connectionActivated(
            identity: domainIdentity,
            source: .verifiedSharedDesktop,
            featureSupport: .init(features: [.monitor])
        ))
        let live = await store.snapshot()
        suite.checkEqual(
            live.connectionSource,
            .verifiedSharedDesktop,
            "live exact-version proof may label only the current runtime"
        )

        let checkpoint = await store.checkpoint()
        suite.checkEqual(
            checkpoint.connectionSource,
            .managedDaemon,
            "runtime-only Shared Desktop proof is normalized before persistence"
        )

        let legacyProofCache = AppServerProjectionCheckpoint(
            savedAt: Date(),
            connectionSource: .verifiedSharedDesktop,
            threads: []
        )
        let restored = AppServerProjectionStore(configuration: .monitoring)
        try await restored.restore(from: legacyProofCache)
        let restoredSnapshot = await restored.snapshot()
        suite.checkEqual(
            restoredSnapshot.connectionSource,
            .managedDaemon,
            "an older cache cannot restore Shared Desktop verification"
        )
        suite.check(
            restoredSnapshot.connection == nil,
            "restored cache has no live verification authority"
        )
    }

    private static func activatedCoordinator() async -> AppServerDomainCoordinator {
        let coordinator = AppServerDomainCoordinator(
            domain: AppServerProjectionStore(configuration: .monitoring)
        )
        _ = try? await coordinator.applyAndPersist(.connectionActivated(
            identity: domainIdentity,
            source: .managedDaemon,
            featureSupport: .init(features: [.monitor])
        ))
        return coordinator
    }

    private static func listResponse(
        sequence: UInt64,
        threadIDs: [String]
    ) -> ConnAppServerResponseEnvelope {
        .init(
            connection: wireIdentity,
            sequence: sequence,
            result: .object([
                "data": .array(threadIDs.map { .object(threadObject(id: $0)) }),
                "nextCursor": .null,
                "backwardsCursor": .null,
            ])
        )
    }

    private static func readResponse(
        sequence: UInt64,
        threadID: String
    ) -> ConnAppServerResponseEnvelope {
        .init(
            connection: wireIdentity,
            sequence: sequence,
            result: .object(["thread": .object(threadObject(id: threadID))])
        )
    }

    private static func statusNotification(
        threadID: String,
        sequence: UInt64
    ) -> ConnAppServerInboundEnvelope {
        .init(
            connection: wireIdentity,
            sequence: sequence,
            message: .notification(.init(
                method: "thread/status/changed",
                params: .object([
                    "threadId": .string(threadID),
                    "status": .object([
                        "type": .string("active"),
                        "activeFlags": .array([]),
                    ]),
                ])
            ))
        )
    }

    private static func turnStartedNotification(
        threadID: String,
        sequence: UInt64
    ) -> ConnAppServerInboundEnvelope {
        .init(
            connection: wireIdentity,
            sequence: sequence,
            message: .notification(.init(
                method: "turn/started",
                params: .object([
                    "threadId": .string(threadID),
                    "turn": .object([
                        "id": .string("desktop-proof-new-turn"),
                        "status": .string("inProgress"),
                        "items": .array([]),
                    ]),
                ])
            ))
        )
    }

    private static func threadObject(id: String) -> [String: JSONValue] {
        [
            "id": .string(id),
            "sessionId": .string("session-\(id)"),
            "cliVersion": .string("0.144.6"),
            "name": .string("Synthetic proof thread"),
            "preview": .string("discarded"),
            "cwd": .string("/tmp/project"),
            "gitInfo": .null,
            "modelProvider": .string("openai"),
            "source": .string("appServer"),
            "status": .object([
                "type": .string("idle"),
                "activeFlags": .array([]),
            ]),
            "ephemeral": .bool(false),
            "createdAt": .integer(1_830_000_000),
            "updatedAt": .integer(1_830_000_001),
            "turns": .array([]),
        ]
    }
}

private actor SharedDesktopProofMonitoringConnection: AppServerMonitoringConnection {
    struct Expected: Sendable {
        let method: String
        let response: ConnAppServerResponseEnvelope
    }

    enum Failure: Error { case unexpectedRequest(String) }

    private let identity: ConnAppServerConnectionIdentity
    private var responses: [Expected]
    private var inbound: [ConnAppServerInboundEnvelope]
    private var methods: [String] = []
    private var threadIDs: [String] = []
    private var readIncludeTurns: [Bool] = []

    init(
        identity: ConnAppServerConnectionIdentity,
        responses: [Expected],
        inbound: [ConnAppServerInboundEnvelope]
    ) {
        self.identity = identity
        self.responses = responses
        self.inbound = inbound
    }

    func connect(
        to endpoint: ControlEndpoint,
        serverVersion: SupportedAppServerVersion,
        mode: AppServerCapabilityMode
    ) async throws -> InitializeResponse {
        throw Failure.unexpectedRequest("connect")
    }

    func requestEnvelope(
        method: String,
        params: JSONValue?,
        timeout: Duration?
    ) async throws -> ConnAppServerResponseEnvelope {
        methods.append(method)
        if method == "thread/read" || method == "thread/resume" {
            if let threadID = params?.objectValue?["threadId"]?.stringValue {
                threadIDs.append(threadID)
            }
        }
        if method == "thread/read" {
            readIncludeTurns.append(params?.objectValue?["includeTurns"] == .bool(true))
        }
        guard !responses.isEmpty, responses[0].method == method else {
            throw Failure.unexpectedRequest(method)
        }
        return responses.removeFirst().response
    }

    func drainInboundEnvelopes() async -> [ConnAppServerInboundEnvelope] {
        let drained = inbound
        inbound.removeAll()
        return drained
    }

    func monitoringState() async -> ConnAppServerConnectionState {
        .ready(generation: identity.generation, version: .v0_144_6)
    }

    func monitoringIdentity() async -> ConnAppServerConnectionIdentity? { identity }
    func disconnect() async {}

    func enqueue(_ envelope: ConnAppServerInboundEnvelope) {
        inbound.append(envelope)
    }

    func requestedMethods() -> [String] { methods }
    func requestedThreadIDs() -> [String] { threadIDs }
    func requestedReadIncludeTurns() -> [Bool] { readIncludeTurns }
}
