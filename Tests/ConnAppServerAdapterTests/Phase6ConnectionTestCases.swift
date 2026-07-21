import Foundation
import ConnAppServerAdapter

enum Phase6ConnectionTestCases {
    static func run(in suite: inout TestSuite) async {
        await initializesExactlyOnceInStableMode(in: &suite)
        await keepsHealthyIdleConnectionsReadyByDefault(in: &suite)
        await cleansUpTimedOutAndCancelledRequests(in: &suite)
        await honorsPerRequestTimeoutOverride(in: &suite)
        await rejectsStaleGenerationReplies(in: &suite)
        loadsStableAndUnknownVersionedFixtures(in: &suite)
        await dropsRawReasoningAndToleratesUnknownNotifications(in: &suite)
        await keepsTraceMetadataOnlyAndBounded(in: &suite)
        await failsUnsupportedMethodsBeforeSend(in: &suite)
        await failsClosedWhenLifecycleFactsFillQueue(in: &suite)
        await boundsUnresolvedServerRequestAuthority(in: &suite)
        await gatesAndRetiresServerResponseAuthority(in: &suite)
        await shedsOnlyPresentationDeltas(in: &suite)
        await receiveTimeoutDisconnectsCancelledTransport(in: &suite)
    }

    private static func keepsHealthyIdleConnectionsReadyByDefault(in suite: inout TestSuite) async {
        let transport = ScriptedPhase6Transport()
        let connection = makeConnection(transport: transport)
        do {
            _ = try await connection.connect(to: .phase6TestEndpoint(), serverVersion: .v0_144_5)
            try await Task.sleep(for: .milliseconds(60))
            if case .ready = await connection.state {
                suite.check(true, "healthy silence does not become connection failure")
            } else {
                suite.fail("default connection failed only because it was idle")
            }
        } catch {
            suite.fail("healthy-idle setup failed: \(error)")
        }
        await connection.disconnect()
    }

    private static func loadsStableAndUnknownVersionedFixtures(in suite: inout TestSuite) {
        let testsRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for version in ["0.144.5", "0.144.6"] {
            let url = testsRoot
                .appendingPathComponent("Fixtures/AppServer/\(version)/phase6-wire-messages.json")
            do {
                let data = try Data(contentsOf: url)
                let fixture = try JSONDecoder().decode(Phase6WireFixture.self, from: data)
                suite.check(fixture.codexVersion == version, "fixture records exact supported version \(version)")
                let messages = try fixture.messages.map {
                    try JSONRPCWireMessage(data: $0.wire.encodedData())
                }
                suite.check(
                    messages.contains { if case let .notification(value) = $0 { value.method == "turn/completed" } else { false } },
                    "\(version) fixture carries a stable lifecycle notification"
                )
                suite.check(
                    messages.contains { if case let .notification(value) = $0 { value.method == "future/unrecognizedEvent" } else { false } },
                    "\(version) fixture carries a tolerable unknown method"
                )
                suite.check(messages.contains { if case .unknown = $0 { true } else { false } }, "\(version) fixture carries an unknown envelope")
                suite.check(
                    !String(decoding: data, as: UTF8.self).contains(ConnAppServerConnection.reasoningTextDeltaMethod),
                    "\(version) fixture persists no raw reasoning subscription or payload"
                )
            } catch {
                suite.fail("could not load Phase 6 fixture for \(version): \(error)")
            }
        }
    }

    private static func initializesExactlyOnceInStableMode(in suite: inout TestSuite) async {
        let transport = ScriptedPhase6Transport()
        let connection = makeConnection(transport: transport)
        do {
            _ = try await connection.connect(
                to: .phase6TestEndpoint(),
                serverVersion: .v0_144_5
            )
            let sent = await transport.sentWireMessages()
            suite.check(sent.count == 2, "connect should send only initialize followed by initialized")
            guard sent.count == 2,
                  case let .request(initialize) = sent[0],
                  case let .notification(initialized) = sent[1]
            else {
                suite.fail("initialize exchange had the wrong envelope order")
                await connection.disconnect()
                return
            }
            suite.check(initialize.method == "initialize", "the first message must be initialize")
            suite.check(initialized.method == "initialized", "initialized must follow the initialize response")
            let capabilities = initialize.params?.objectValue?["capabilities"]?.objectValue
            suite.check(capabilities?["experimentalApi"] == nil, "stable mode must not opt into experimental API")
            suite.check(
                capabilities?["optOutNotificationMethods"]
                    == .array([.string("item/reasoning/textDelta")]),
                "initialize must contain the exact raw-reasoning notification opt-out"
            )
        } catch {
            suite.fail("stable initialization failed: \(error)")
        }
        await connection.disconnect()
    }

    private static func cleansUpTimedOutAndCancelledRequests(in suite: inout TestSuite) async {
        let transport = ScriptedPhase6Transport()
        let connection = makeConnection(transport: transport, requestTimeout: .milliseconds(40))
        do {
            _ = try await connection.connect(to: .phase6TestEndpoint(), serverVersion: .v0_144_5)
            do {
                _ = try await connection.request(method: "thread/list", params: .object([:]))
                suite.fail("an unanswered request should time out")
            } catch ConnAppServerConnectionError.timedOut(.request) {
                let pending = await connection.pendingRequestCount
                suite.check(pending == 0, "timeout must clear local correlation")
            } catch {
                suite.fail("unanswered request returned the wrong error: \(error)")
            }

            let cancelled = Task {
                try await connection.request(
                    method: "thread/read",
                    params: .object([:]),
                    timeout: .seconds(1)
                )
            }
            await waitForSentCount(4, transport: transport)
            cancelled.cancel()
            do {
                _ = try await cancelled.value
                suite.fail("cancelled request should not complete")
            } catch is CancellationError {
                let pending = await connection.pendingRequestCount
                suite.check(pending == 0, "cancellation must clear local correlation")
            } catch {
                suite.fail("cancelled request returned the wrong error: \(error)")
            }
        } catch {
            suite.fail("timeout/cancellation setup failed: \(error)")
        }
        await connection.disconnect()
    }

    private static func honorsPerRequestTimeoutOverride(in suite: inout TestSuite) async {
        let transport = ScriptedPhase6Transport()
        let connection = makeConnection(transport: transport, requestTimeout: .milliseconds(20))
        do {
            _ = try await connection.connect(to: .phase6TestEndpoint(), serverVersion: .v0_144_5)
            let request = Task {
                try await connection.request(
                    method: "thread/list",
                    params: .object([:]),
                    timeout: .milliseconds(250)
                )
            }
            await waitForSentCount(3, transport: transport)
            try await Task.sleep(for: .milliseconds(60))
            guard let requestID = await transport.lastRequestID() else {
                suite.fail("per-request timeout test could not observe its request ID")
                request.cancel()
                _ = try? await request.value
                await connection.disconnect()
                return
            }
            await transport.push(response(
                id: requestID,
                result: .object(["override": .bool(true)])
            ))
            let value = try await request.value
            suite.check(
                value.objectValue?["override"] == .bool(true),
                "a longer per-request timeout overrides the shorter connection default"
            )
        } catch {
            suite.fail("per-request timeout override failed: \(error)")
        }
        await connection.disconnect()
    }

    private static func rejectsStaleGenerationReplies(in suite: inout TestSuite) async {
        let transport = ScriptedPhase6Transport()
        let connection = makeConnection(transport: transport, requestTimeout: .seconds(1))
        do {
            _ = try await connection.connect(to: .phase6TestEndpoint(), serverVersion: .v0_144_5)
            let oldRequest = Task { try await connection.request(method: "thread/list") }
            await waitForSentCount(3, transport: transport)
            let oldID = await transport.lastRequestID()
            await connection.disconnect()
            oldRequest.cancel()
            _ = try? await oldRequest.value

            _ = try await connection.connect(to: .phase6TestEndpoint(), serverVersion: .v0_144_6)
            let currentRequest = Task { try await connection.request(method: "thread/list") }
            await waitForSentCount(6, transport: transport)
            guard let currentID = await transport.lastRequestID(), let oldID else {
                suite.fail("could not observe request identifiers for stale-generation test")
                await connection.disconnect()
                return
            }
            suite.check(currentID != oldID, "request IDs must remain unique across generations")
            await transport.push(response(id: oldID, result: .object(["stale": .bool(true)])))
            try? await Task.sleep(for: .milliseconds(10))
            let pendingAfterStaleReply = await connection.pendingRequestCount
            suite.check(pendingAfterStaleReply == 1, "old-generation response must not resolve the new request")
            await transport.push(response(id: currentID, result: .object(["fresh": .bool(true)])))
            let value = try await currentRequest.value
            suite.check(value.objectValue?["fresh"] == .bool(true), "only the current-generation reply may resolve")
        } catch {
            suite.fail("generation invalidation test failed: \(error)")
        }
        await connection.disconnect()
    }

    private static func dropsRawReasoningAndToleratesUnknownNotifications(in suite: inout TestSuite) async {
        let transport = ScriptedPhase6Transport()
        let connection = makeConnection(transport: transport)
        do {
            _ = try await connection.connect(to: .phase6TestEndpoint(), serverVersion: .v0_144_5)
            await transport.push(notification(
                method: "item/reasoning/textDelta",
                params: .object([:])
            ))
            await transport.push(notification(
                method: "future/unrecognizedEvent",
                params: .object(["content": .string("peer-controlled")])
            ))
            await transport.push(notification(method: "turn/started", params: .object([:])))
            await waitForInboundCount(2, connection: connection)
            let messages = await connection.drainInboundMessages()
            suite.check(messages.count == 2, "raw reasoning delta must be dropped before delivery")
            suite.check(
                messages.contains { if case let .notification(value) = $0 { value.method == "future/unrecognizedEvent" } else { false } },
                "unknown notifications should remain tolerantly deliverable"
            )
            let trace = await connection.traceEntries()
            suite.check(
                !trace.contains(where: { $0.method == "future/unrecognizedEvent" }),
                "unrecognized peer-controlled method text must not persist in trace"
            )
            suite.check(
                trace.contains(where: { $0.envelope == .dropped && $0.method == "item/reasoning/textDelta" }),
                "reasoning drop should leave metadata-only evidence"
            )
            suite.check(!String(describing: trace).contains("params"), "trace must not retain raw reasoning parameters")
        } catch {
            suite.fail("reasoning/unknown notification test failed: \(error)")
        }
        await connection.disconnect()
    }

    private static func keepsTraceMetadataOnlyAndBounded(in suite: inout TestSuite) async {
        let transport = ScriptedPhase6Transport()
        let connection = ConnAppServerConnection(
            transport: transport,
            configuration: configuration(maximumTraceEntries: 3)
        )
        do {
            _ = try await connection.connect(to: .phase6TestEndpoint(), serverVersion: .v0_144_5)
            for _ in 0..<5 {
                await transport.push(notification(method: "turn/started", params: .object([
                    "content": .string("must-not-enter-trace")
                ])))
            }
            await waitForInboundCount(5, connection: connection)
            let trace = await connection.traceEntries()
            suite.check(trace.count == 3, "connection trace must retain only its configured bound")
            let encoded = String(decoding: try JSONEncoder().encode(trace), as: UTF8.self)
            suite.check(!encoded.contains("params"), "trace schema must omit parameters")
            suite.check(!encoded.contains("result"), "trace schema must omit results")
            suite.check(!encoded.contains("content"), "trace schema must omit content")
            suite.check(!encoded.contains("message"), "trace schema must omit error text")
        } catch {
            suite.fail("trace sanitization test failed: \(error)")
        }
        await connection.disconnect()
    }

    private static func failsUnsupportedMethodsBeforeSend(in suite: inout TestSuite) async {
        let transport = ScriptedPhase6Transport()
        let connection = makeConnection(transport: transport)
        do {
            _ = try await connection.connect(to: .phase6TestEndpoint(), serverVersion: .v0_144_6)
            let before = await transport.sentCount
            do {
                _ = try await connection.request(method: "unknown/consequentialAction")
                suite.fail("unknown methods must fail closed")
            } catch ConnAppServerConnectionError.unsupportedMethod {
                let after = await transport.sentCount
                let pending = await connection.pendingRequestCount
                suite.check(after == before, "unsupported method must fail before transport send")
                suite.check(pending == 0, "unsupported method must allocate no correlation")
            } catch {
                suite.fail("unsupported method returned the wrong error: \(error)")
            }
        } catch {
            suite.fail("unsupported-method setup failed: \(error)")
        }
        await connection.disconnect()
    }

    private static func failsClosedWhenLifecycleFactsFillQueue(in suite: inout TestSuite) async {
        let transport = ScriptedPhase6Transport()
        let connection = ConnAppServerConnection(
            transport: transport,
            configuration: configuration(maximumInboundMessages: 2)
        )
        do {
            _ = try await connection.connect(to: .phase6TestEndpoint(), serverVersion: .v0_144_5)
            await transport.push(notification(method: "turn/started"))
            await transport.push(notification(method: "turn/completed"))
            await transport.push(notification(method: "thread/closed"))
            await waitForFailedState(connection)
            if case .failed = await connection.state {
                suite.check(true, "fact-only queue overflow failed the connection closed")
            } else {
                suite.fail("lifecycle facts must never be evicted to satisfy the queue bound")
            }
            let retained = await connection.queuedInboundCount
            suite.check(retained == 0, "failed generation must retain no stale inbound facts")
        } catch {
            suite.fail("fact queue setup failed: \(error)")
        }
        await connection.disconnect()
    }

    private static func shedsOnlyPresentationDeltas(in suite: inout TestSuite) async {
        let transport = ScriptedPhase6Transport()
        let connection = ConnAppServerConnection(
            transport: transport,
            configuration: configuration(maximumInboundMessages: 2)
        )
        do {
            _ = try await connection.connect(to: .phase6TestEndpoint(), serverVersion: .v0_144_5)
            await transport.push(notification(method: "item/agentMessage/delta"))
            await transport.push(notification(method: "turn/started"))
            await transport.push(notification(method: "turn/completed"))
            await waitForInboundCount(2, connection: connection)
            let messages = await connection.drainInboundMessages()
            let methods = messages.compactMap { message -> String? in
                if case let .notification(value) = message { return value.method }
                return nil
            }
            suite.check(methods == ["turn/started", "turn/completed"], "only the presentation delta should be shed")
        } catch {
            suite.fail("presentation delta shedding test failed: \(error)")
        }
        await connection.disconnect()
    }

    private static func boundsUnresolvedServerRequestAuthority(in suite: inout TestSuite) async {
        let transport = ScriptedPhase6Transport()
        let connection = ConnAppServerConnection(
            transport: transport,
            configuration: configuration(maximumInboundMessages: 2)
        )
        do {
            _ = try await connection.connect(to: .phase6TestEndpoint(), serverVersion: .v0_144_5)
            await transport.push(serverRequest(id: .integer(801), method: "item/tool/requestUserInput"))
            await transport.push(serverRequest(id: .integer(802), method: "item/tool/requestUserInput"))
            await waitForInboundCount(2, connection: connection)
            _ = await connection.drainInboundMessages()
            await transport.push(serverRequest(id: .integer(803), method: "item/tool/requestUserInput"))
            await waitForFailedState(connection)
            if case .failed = await connection.state {
                suite.check(true, "unanswered server-request authority has a hard bound after queue drains")
            } else {
                suite.fail("unresolved server-request identifiers grew past their configured bound")
            }
        } catch {
            suite.fail("server-request bound setup failed: \(error)")
        }
        await connection.disconnect()
    }

    private static func gatesAndRetiresServerResponseAuthority(in suite: inout TestSuite) async {
        let transport = ScriptedPhase6Transport()
        let connection = makeConnection(transport: transport)
        do {
            _ = try await connection.connect(to: .phase6TestEndpoint(), serverVersion: .v0_144_6)

            await transport.push(serverRequest(
                id: .string("supported-approval"),
                method: "item/commandExecution/requestApproval"
            ))
            await waitForInboundCount(1, connection: connection)
            _ = await connection.drainInboundMessages()
            try await connection.respond(
                to: .string("supported-approval"),
                result: .object(["decision": .string("decline")])
            )
            let afterSupported = await transport.sentCount
            suite.check(afterSupported == 3, "a supported exact server-request method may send one correlated response")

            await transport.push(serverRequest(
                id: .string("future-request"),
                method: "future/requestApproval"
            ))
            await waitForInboundCount(1, connection: connection)
            _ = await connection.drainInboundMessages()
            do {
                try await connection.respond(
                    to: .string("future-request"),
                    result: .object([:])
                )
                suite.fail("an observed future request must not imply response capability")
            } catch ConnAppServerConnectionError.unsupportedMethod {
                let afterUnsupported = await transport.sentCount
                suite.check(
                    afterUnsupported == afterSupported,
                    "unsupported server response must fail before transport send"
                )
            } catch {
                suite.fail("unsupported server response returned the wrong error: \(error)")
            }

            await transport.push(serverRequest(
                id: .integer(903),
                method: "item/tool/requestUserInput"
            ))
            await waitForInboundCount(1, connection: connection)
            _ = await connection.drainInboundMessages()
            await transport.push(notification(
                method: "serverRequest/resolved",
                params: .object([
                    "requestId": .integer(903),
                    "threadId": .string("throwaway-thread"),
                ])
            ))
            await waitForInboundCount(1, connection: connection)
            _ = await connection.drainInboundMessages()
            do {
                try await connection.respond(
                    to: .integer(903),
                    result: .object(["answers": .object([:])])
                )
                suite.fail("resolved-elsewhere request authority must be retired before response")
            } catch ConnAppServerConnectionError.unknownServerRequest(.integer(903)) {
                let afterResolved = await transport.sentCount
                suite.check(
                    afterResolved == afterSupported,
                    "resolved-elsewhere reconciliation must not write a duplicate response"
                )
            } catch {
                suite.fail("resolved-elsewhere response returned the wrong error: \(error)")
            }
        } catch {
            suite.fail("server response authority setup failed: \(error)")
        }
        await connection.disconnect()
    }

    private static func receiveTimeoutDisconnectsCancelledTransport(in suite: inout TestSuite) async {
        let transport = ScriptedPhase6Transport()
        let connection = ConnAppServerConnection(
            transport: transport,
            configuration: configuration(receiveTimeout: .milliseconds(30))
        )
        do {
            _ = try await connection.connect(to: .phase6TestEndpoint(), serverVersion: .v0_144_5)
            await waitForFailedState(connection)
            if case .failed = await connection.state {
                suite.check(true, "receive timeout must invalidate the connection")
            } else {
                suite.fail("receive timeout must not continue in ready state after receive cancellation")
            }
            let disconnects = await transport.disconnectCount
            suite.check(disconnects > 0, "receive timeout must disconnect the transport")
        } catch {
            suite.fail("receive-timeout setup failed: \(error)")
        }
        await connection.disconnect()
    }

    private static func makeConnection(
        transport: ScriptedPhase6Transport,
        requestTimeout: Duration = .milliseconds(250)
    ) -> ConnAppServerConnection {
        ConnAppServerConnection(
            transport: transport,
            configuration: configuration(requestTimeout: requestTimeout)
        )
    }

    private static func configuration(
        receiveTimeout: Duration? = nil,
        requestTimeout: Duration = .milliseconds(250),
        maximumInboundMessages: Int = 32,
        maximumTraceEntries: Int = 32
    ) -> ConnAppServerConnectionConfiguration {
        .init(
            connectTimeout: .milliseconds(250),
            sendTimeout: .milliseconds(250),
            receiveTimeout: receiveTimeout,
            requestTimeout: requestTimeout,
            maximumInboundMessages: maximumInboundMessages,
            maximumInboundBytes: 64 * 1_024,
            maximumTraceEntries: maximumTraceEntries
        )
    }

    private static func notification(method: String, params: JSONValue? = nil) -> String {
        let value = JSONRPCWireMessage.notification(.init(method: method, params: params))
        return String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }

    private static func response(id: RequestID, result: JSONValue) -> String {
        let value = JSONRPCWireMessage.response(.init(id: id, result: result))
        return String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }

    private static func serverRequest(id: RequestID, method: String) -> String {
        let value = JSONRPCWireMessage.request(.init(id: id, method: method, params: .object([:])))
        return String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }

    private static func waitForSentCount(_ count: Int, transport: ScriptedPhase6Transport) async {
        for _ in 0..<100 {
            if await transport.sentCount >= count { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private static func waitForInboundCount(_ count: Int, connection: ConnAppServerConnection) async {
        for _ in 0..<100 {
            if await connection.queuedInboundCount >= count { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private static func waitForFailedState(_ connection: ConnAppServerConnection) async {
        for _ in 0..<100 {
            if case .failed = await connection.state { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}

private struct Phase6WireFixture: Decodable {
    struct Entry: Decodable {
        let label: String
        let wire: JSONValue
    }

    let schemaVersion: Int
    let codexVersion: String
    let messages: [Entry]
}

private extension ControlEndpoint {
    static func phase6TestEndpoint() -> ControlEndpoint {
        .init(
            socketURL: URL(fileURLWithPath: "/tmp/conn-phase6-test.sock"),
            ownerUserID: getuid()
        )
    }
}

private enum ScriptedPhase6TransportError: Error {
    case notConnected
    case receiveAlreadyPending
}

private actor ScriptedPhase6Transport: ControlTransport {
    private var connected = false
    private var sent: [String] = []
    private var inbound: [String] = []
    private var receiveWaiter: CheckedContinuation<String, any Error>?
    private(set) var disconnectCount = 0

    var sentCount: Int { sent.count }

    func connect(to endpoint: ControlEndpoint) async throws {
        connected = true
    }

    func send(text: String) async throws {
        guard connected else { throw ScriptedPhase6TransportError.notConnected }
        sent.append(text)
        guard let message = try? JSONRPCWireMessage(data: Data(text.utf8)),
              case let .request(request) = message,
              request.method == "initialize"
        else { return }

        let result: JSONValue = .object([
            "codexHome": .string("/tmp/codex"),
            "platformFamily": .string("unix"),
            "platformOs": .string("macos"),
            "userAgent": .string("codex-cli/0.144.5"),
        ])
        push(Self.response(id: request.id, result: result))
    }

    func receiveText() async throws -> String {
        guard connected else { throw ScriptedPhase6TransportError.notConnected }
        if !inbound.isEmpty { return inbound.removeFirst() }
        guard receiveWaiter == nil else { throw ScriptedPhase6TransportError.receiveAlreadyPending }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                receiveWaiter = continuation
                if Task.isCancelled { cancelReceive() }
            }
        } onCancel: {
            Task { await self.cancelReceive() }
        }
    }

    func disconnect() async {
        connected = false
        disconnectCount += 1
        receiveWaiter?.resume(throwing: CancellationError())
        receiveWaiter = nil
    }

    func observations() async -> [ControlTransportObservation] { [] }

    func push(_ text: String) {
        if let waiter = receiveWaiter {
            receiveWaiter = nil
            waiter.resume(returning: text)
        } else {
            inbound.append(text)
        }
    }

    func sentWireMessages() -> [JSONRPCWireMessage] {
        sent.compactMap { try? JSONRPCWireMessage(data: Data($0.utf8)) }
    }

    func lastRequestID() -> RequestID? {
        sent.reversed().compactMap { text -> RequestID? in
            guard let message = try? JSONRPCWireMessage(data: Data(text.utf8)),
                  case let .request(request) = message
            else { return nil }
            return request.id
        }.first
    }

    private func cancelReceive() {
        connected = false
        receiveWaiter?.resume(throwing: CancellationError())
        receiveWaiter = nil
    }

    private static func response(id: RequestID, result: JSONValue) -> String {
        let message = JSONRPCWireMessage.response(.init(id: id, result: result))
        return String(decoding: try! JSONEncoder().encode(message), as: UTF8.self)
    }
}
