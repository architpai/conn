import Darwin
import Foundation
import ConnAppServerAdapter

enum Phase7InboundEnvelopeTestCases {
    static func run(in suite: inout TestSuite) async {
        await preservesIdentitySequenceAndLegacyDrain(in: &suite)
        await preservesRetainedOrderWhenSheddingDeltas(in: &suite)
        await evictsOldestResumeNoiseBeforeRequiredFacts(in: &suite)
        await dropsIncomingResumeNoiseBehindRequiredFacts(in: &suite)
        await failsOnlyWhenRequiredFactsExceedTheQueue(in: &suite)
        await sequencesCorrelatedResponsesWithNotifications(in: &suite)
    }

    private static func preservesIdentitySequenceAndLegacyDrain(
        in suite: inout TestSuite
    ) async {
        let transport = Phase7InboundTransport()
        let connection = makeConnection(transport: transport, maximumInboundMessages: 8)

        do {
            let disconnectedIdentity = await connection.activeIdentity
            suite.check(disconnectedIdentity == nil, "disconnected connection has no active identity")
            _ = try await connection.connect(
                to: .phase7InboundTestEndpoint,
                serverVersion: .v0_144_5
            )
            guard let firstIdentity = await connection.activeIdentity else {
                suite.fail("ready connection exposes its active identity")
                await connection.disconnect()
                return
            }
            suite.check(firstIdentity.generation == 1, "first connection uses generation one")

            await transport.push(notification("turn/started"))
            await transport.push(notification("item/started"))
            await transport.push(notification("turn/completed"))
            await waitForInboundCount(3, connection: connection)

            let firstEnvelopes = await connection.drainInboundEnvelopes()
            suite.check(firstEnvelopes.count == 3, "preferred drain returns all queued envelopes")
            suite.check(
                firstEnvelopes.allSatisfy { $0.connection == firstIdentity },
                "every envelope retains the exact active instance UUID and generation"
            )
            suite.check(
                firstEnvelopes.map(\.sequence) == [2, 3, 4],
                "inbound envelope sequences are strictly monotonic"
            )
            guard let oldEnvelope = firstEnvelopes.first else {
                suite.fail("first generation produced an envelope for stale-identity comparison")
                await connection.disconnect()
                return
            }

            _ = try await connection.reconnect(
                to: .phase7InboundTestEndpoint,
                serverVersion: .v0_144_6
            )
            guard let secondIdentity = await connection.activeIdentity else {
                suite.fail("reconnected connection exposes a replacement identity")
                await connection.disconnect()
                return
            }
            suite.check(
                secondIdentity.instanceID == firstIdentity.instanceID,
                "reconnect retains the actor instance UUID"
            )
            suite.check(secondIdentity.generation == 3, "reconnect advances through invalidation to generation three")
            suite.check(secondIdentity != oldEnvelope.connection, "old envelope identity differs from reconnect authority")

            await transport.push(notification("thread/status/changed"))
            await waitForInboundCount(1, connection: connection)
            let currentEnvelopes = await connection.drainInboundEnvelopes()
            suite.check(currentEnvelopes.first?.connection == secondIdentity, "new envelope uses reconnect identity")
            suite.check(currentEnvelopes.first?.sequence == 2, "receive sequence restarts within the new generation")

            await transport.push(notification("serverRequest/resolved"))
            await waitForInboundCount(1, connection: connection)
            let legacyMessages = await connection.drainInboundMessages()
            suite.check(legacyMessages.count == 1, "legacy drain remains available")
            suite.check(
                method(of: legacyMessages.first) == "serverRequest/resolved",
                "legacy drain preserves the inbound message"
            )
            let remainingEnvelopes = await connection.drainInboundEnvelopes()
            suite.check(remainingEnvelopes.isEmpty, "legacy drain consumes the same bounded queue")
        } catch {
            suite.fail("Phase 7 inbound identity test failed: \(error)")
        }
        await connection.disconnect()
    }

    private static func preservesRetainedOrderWhenSheddingDeltas(
        in suite: inout TestSuite
    ) async {
        let transport = Phase7InboundTransport()
        let connection = makeConnection(transport: transport, maximumInboundMessages: 3)

        do {
            _ = try await connection.connect(
                to: .phase7InboundTestEndpoint,
                serverVersion: .v0_144_5
            )
            await transport.push(notification("turn/started"))
            await transport.push(notification("item/agentMessage/delta"))
            await transport.push(notification("item/started"))
            await transport.push(notification("turn/completed"))
            // A correlated response is a FIFO receive barrier proving all four
            // earlier messages were processed, even though shedding caps the
            // observable queue at three.
            _ = try await connection.requestEnvelope(method: "thread/list")

            let retained = await connection.drainInboundEnvelopes()
            suite.check(
                retained.map { method(of: $0.message) } == [
                    "turn/started",
                    "item/started",
                    "turn/completed",
                ],
                "delta shedding preserves retained lifecycle order"
            )
            suite.check(
                retained.map(\.sequence) == [2, 4, 5],
                "retained envelopes keep their original monotonic receive positions"
            )
            suite.check(
                zip(retained, retained.dropFirst()).allSatisfy { pair in
                    pair.0.sequence < pair.1.sequence
                },
                "retained envelope sequences remain strictly increasing after shedding"
            )
        } catch {
            suite.fail("Phase 7 inbound shedding test failed: \(error)")
        }
        await connection.disconnect()
    }

    private static func sequencesCorrelatedResponsesWithNotifications(
        in suite: inout TestSuite
    ) async {
        let transport = Phase7InboundTransport()
        let connection = makeConnection(transport: transport, maximumInboundMessages: 8)

        do {
            _ = try await connection.connect(
                to: .phase7InboundTestEndpoint,
                serverVersion: .v0_144_5
            )
            await transport.push(notification("thread/status/changed"))
            await waitForInboundCount(1, connection: connection)

            let response = try await connection.requestEnvelope(method: "thread/list")
            await transport.push(notification("turn/started"))
            await waitForInboundCount(2, connection: connection)
            let notifications = await connection.drainInboundEnvelopes()

            suite.check(response.sequence == 3, "correlated response consumes its exact receive position")
            suite.check(
                notifications.map(\.sequence) == [2, 4],
                "notifications retain positions on both sides of the response"
            )
            suite.check(
                notifications.allSatisfy { $0.connection == response.connection },
                "response and notifications share one connection authority"
            )

            let legacyResult = try await connection.request(method: "thread/list")
            suite.check(
                legacyResult == .object(["data": .array([]), "nextCursor": .null]),
                "legacy bare request remains a compatibility wrapper"
            )
        } catch {
            suite.fail("Phase 7 correlated response ordering test failed: \(error)")
        }
        await connection.disconnect()
    }

    private static func evictsOldestResumeNoiseBeforeRequiredFacts(
        in suite: inout TestSuite
    ) async {
        let transport = Phase7InboundTransport()
        let connection = makeConnection(transport: transport, maximumInboundMessages: 3)

        do {
            _ = try await connection.connect(
                to: .phase7InboundTestEndpoint,
                serverVersion: .v0_144_6
            )
            await transport.push(notification("thread/tokenUsage/updated"))
            await transport.push(notification("turn/started"))
            await transport.push(notification("thread/goal/cleared"))
            await transport.push(notification("item/started"))
            _ = try await connection.requestEnvelope(method: "thread/list")

            let retained = await connection.drainInboundEnvelopes()
            suite.check(
                retained.map { method(of: $0.message) } == [
                    "turn/started",
                    "thread/goal/cleared",
                    "item/started",
                ],
                "overflow evicts the oldest queued resume-noise notification first"
            )
            suite.check(
                retained.map(\.sequence) == [3, 4, 5],
                "oldest-sheddable eviction preserves original receive positions and retained order"
            )
        } catch {
            suite.fail("resume-noise eviction test failed: \(error)")
        }
        await connection.disconnect()
    }

    private static func dropsIncomingResumeNoiseBehindRequiredFacts(
        in suite: inout TestSuite
    ) async {
        let transport = Phase7InboundTransport()
        let connection = makeConnection(transport: transport, maximumInboundMessages: 2)

        do {
            _ = try await connection.connect(
                to: .phase7InboundTestEndpoint,
                serverVersion: .v0_144_6
            )
            await transport.push(notification("turn/started"))
            await transport.push(notification("item/started"))
            await transport.push(notification("thread/goal/cleared"))
            _ = try await connection.requestEnvelope(method: "thread/list")

            let retained = await connection.drainInboundEnvelopes()
            suite.check(
                retained.map { method(of: $0.message) } == ["turn/started", "item/started"],
                "incoming resume noise is dropped when only required facts occupy the queue"
            )
            if case .ready = await connection.state {
                suite.check(true, "dropping incoming resume noise keeps the connection healthy")
            } else {
                suite.fail("sheddable resume noise must not fail a required-fact queue")
            }
        } catch {
            suite.fail("incoming resume-noise shedding test failed: \(error)")
        }
        await connection.disconnect()
    }

    private static func failsOnlyWhenRequiredFactsExceedTheQueue(
        in suite: inout TestSuite
    ) async {
        let transport = Phase7InboundTransport()
        let connection = makeConnection(transport: transport, maximumInboundMessages: 2)

        do {
            _ = try await connection.connect(
                to: .phase7InboundTestEndpoint,
                serverVersion: .v0_144_6
            )
            await transport.push(notification("turn/started"))
            await transport.push(notification("item/started"))
            await transport.push(notification("turn/completed"))
            await waitForFailedState(connection)

            if case .failed = await connection.state {
                suite.check(true, "required-facts-only overflow remains a fail-closed last resort")
            } else {
                suite.fail("a required fact must never be silently evicted or dropped")
            }
            let retainedCount = await connection.queuedInboundCount
            suite.check(
                retainedCount == 0,
                "the failed generation retains no partial required-fact queue"
            )
        } catch {
            suite.fail("required-fact overflow test failed: \(error)")
        }
        await connection.disconnect()
    }

    private static func makeConnection(
        transport: Phase7InboundTransport,
        maximumInboundMessages: Int
    ) -> ConnAppServerConnection {
        ConnAppServerConnection(
            transport: transport,
            configuration: .init(
                connectTimeout: .milliseconds(250),
                sendTimeout: .milliseconds(250),
                requestTimeout: .milliseconds(250),
                maximumInboundMessages: maximumInboundMessages,
                maximumInboundBytes: 64 * 1_024,
                maximumTraceEntries: 32
            )
        )
    }

    private static func notification(_ method: String) -> String {
        let message = JSONRPCWireMessage.notification(.init(method: method, params: .object([:])))
        return String(decoding: try! JSONEncoder().encode(message), as: UTF8.self)
    }

    private static func method(of message: ConnAppServerInboundMessage?) -> String? {
        guard let message else { return nil }
        switch message {
        case let .notification(notification): return notification.method
        case let .request(request): return request.method
        }
    }

    private static func waitForInboundCount(
        _ count: Int,
        connection: ConnAppServerConnection
    ) async {
        for _ in 0..<100 {
            if await connection.queuedInboundCount >= count { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private static func waitForFailedState(
        _ connection: ConnAppServerConnection
    ) async {
        for _ in 0..<100 {
            if case .failed = await connection.state { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}

private extension ControlEndpoint {
    static var phase7InboundTestEndpoint: ControlEndpoint {
        .init(
            socketURL: URL(fileURLWithPath: "/tmp/conn-phase7-inbound-test.sock"),
            ownerUserID: getuid()
        )
    }
}

private enum Phase7InboundTransportError: Error {
    case notConnected
    case receiveAlreadyPending
}

private actor Phase7InboundTransport: ControlTransport {
    private var connected = false
    private var inbound: [String] = []
    private var receiveWaiter: CheckedContinuation<String, any Error>?

    func connect(to endpoint: ControlEndpoint) async throws {
        connected = true
    }

    func send(text: String) async throws {
        guard connected else { throw Phase7InboundTransportError.notConnected }
        guard let message = try? JSONRPCWireMessage(data: Data(text.utf8)),
              case let .request(request) = message
        else { return }

        let result: JSONValue
        switch request.method {
        case "initialize":
            result = .object([
                "codexHome": .string("/tmp/codex"),
                "platformFamily": .string("unix"),
                "platformOs": .string("macos"),
                "userAgent": .string("codex-cli/0.144.5"),
            ])
        case "thread/list":
            result = .object(["data": .array([]), "nextCursor": .null])
        default:
            return
        }

        let response = JSONRPCWireMessage.response(.init(
            id: request.id,
            result: result
        ))
        push(String(decoding: try! JSONEncoder().encode(response), as: UTF8.self))
    }

    func receiveText() async throws -> String {
        guard connected else { throw Phase7InboundTransportError.notConnected }
        if !inbound.isEmpty { return inbound.removeFirst() }
        guard receiveWaiter == nil else { throw Phase7InboundTransportError.receiveAlreadyPending }

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

    private func cancelReceive() {
        connected = false
        receiveWaiter?.resume(throwing: CancellationError())
        receiveWaiter = nil
    }
}
