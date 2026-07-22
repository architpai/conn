import Foundation
import ConnAppServerAdapter

enum ProtocolTestCases {
    static func run(in suite: inout TestSuite) async {
        decodesWireMessages(in: &suite)
        decodesCapabilitiesTolerantly(in: &suite)
        await correlatesResponses(in: &suite)
        await cancelsAwaitingResponses(in: &suite)
        await cancelsPreResolvedResponses(in: &suite)
    }

    private static func decodesWireMessages(in suite: inout TestSuite) {
        do {
            let success = try JSONRPCWireMessage(
                data: Data(#"{"id":7,"result":{"ok":true},"future":"kept"}"#.utf8)
            )
            guard case let .response(response) = success else {
                suite.fail("success payload should classify as a response")
                return
            }
            suite.check(response.id == .integer(7), "integer request IDs should decode exactly")
            suite.check(
                response.additionalFields["future"] == .string("kept"),
                "unknown response fields should be preserved"
            )

            let request = try JSONRPCWireMessage(
                data: Data(#"{"id":"approval-1","method":"future/request","params":{"scope":"exact"}}"#.utf8)
            )
            guard case let .request(serverRequest) = request else {
                suite.fail("method plus id should classify as a server request")
                return
            }
            suite.check(serverRequest.id == .string("approval-1"), "string request IDs should decode exactly")
            suite.check(serverRequest.method == "future/request", "unknown request methods should be retained")
            suite.check(
                serverRequest.params?.objectValue?["scope"] == .string("exact"),
                "unknown request params should remain inspectable"
            )

            let notification = try JSONRPCWireMessage(
                data: Data(#"{"method":"future/event","params":{"value":42}}"#.utf8)
            )
            guard case let .notification(event) = notification else {
                suite.fail("method without id should classify as a notification")
                return
            }
            suite.check(event.method == "future/event", "unknown notifications should not crash decoding")

            let failure = try JSONRPCWireMessage(
                data: Data(#"{"id":8,"error":{"code":-32600,"message":"invalid","data":{"retry":false}}}"#.utf8)
            )
            guard case let .error(errorResponse) = failure else {
                suite.fail("error payload should classify as an error response")
                return
            }
            suite.check(errorResponse.error.code == -32600, "error codes should decode exactly")
            suite.check(
                errorResponse.error.data?.objectValue?["retry"] == .bool(false),
                "error data should remain inspectable"
            )

            let unknown = try JSONRPCWireMessage(data: Data(#"{"unexpected":true}"#.utf8))
            guard case .unknown = unknown else {
                suite.fail("unclassifiable objects should remain unknown values")
                return
            }
            suite.check(unknown.rawValue.objectValue?["unexpected"] == .bool(true), "unknown values should be preserved")

            let ambiguous = try JSONRPCWireMessage(
                data: Data(#"{"id":7,"result":{},"error":{"code":-1,"message":"conflict"}}"#.utf8)
            )
            guard case .unknown = ambiguous else {
                suite.fail("conflicting JSON-RPC discriminators must remain unknown")
                return
            }
            suite.check(
                ambiguous.rawValue.objectValue?["error"] != nil,
                "ambiguous envelope fields should remain inspectable"
            )
        } catch {
            suite.fail("wire decoding threw unexpectedly: \(error)")
        }
    }

    private static func decodesCapabilitiesTolerantly(in suite: inout TestSuite) {
        let payload = Data(
            #"{"clientInfo":{"name":"conn","title":"Conn","version":"0.1.1"},"capabilities":{"experimentalApi":true,"requestAttestation":false,"futureCapability":{"mode":"observe"}}}"#.utf8
        )

        do {
            let params = try JSONDecoder().decode(InitializeParams.self, from: payload)
            suite.check(params.clientInfo.name == "conn", "initialize client name should decode")
            suite.check(params.capabilities?.experimentalAPI == true, "experimental API request should decode")
            suite.check(
                params.capabilities?.additionalFields["futureCapability"]
                    == .object(["mode": .string("observe")]),
                "unknown capability fields should be preserved"
            )
        } catch {
            suite.fail("initialize capability decoding threw unexpectedly: \(error)")
        }
    }

    private static func correlatesResponses(in suite: inout TestSuite) async {
        let store = RequestCorrelationStore(historyLimit: 2)
        let id = RequestID.integer(9)

        do {
            try await store.register(id)
            let message = try JSONRPCWireMessage(data: Data(#"{"id":9,"result":{"turnId":"turn-1"}}"#.utf8))
            let disposition = await store.resolve(message)
            suite.check(disposition == .stored(id), "early responses should be stored for a registered request")

            let response = try await store.response(for: id)
            guard case let .success(success) = response else {
                suite.fail("stored success should resolve as a correlated success")
                return
            }
            suite.check(success.id == id, "correlated response should keep its request ID")

            let lateDisposition = await store.resolve(message)
            suite.check(
                lateDisposition == .recorded(id, reason: .lateResponse),
                "late duplicate responses should be recorded and not retried"
            )

            do {
                try await store.register(id)
                suite.fail("completed request IDs must not be reusable on one connection")
            } catch RequestCorrelationError.duplicateRequestID(id) {
                suite.check(true, "completed request ID reuse was rejected")
            } catch {
                suite.fail("request ID reuse returned the wrong error: \(error)")
            }

            let unknown = try JSONRPCWireMessage(data: Data(#"{"id":404,"result":{}}"#.utf8))
            let unknownDisposition = await store.resolve(unknown)
            suite.check(
                unknownDisposition == .recorded(.integer(404), reason: .unknownRequest),
                "unknown response IDs should remain diagnosable"
            )
            let unmatchedResponses = await store.unmatchedResponses
            suite.check(unmatchedResponses.count == 2, "unmatched response history should be bounded")
        } catch {
            suite.fail("request correlation threw unexpectedly: \(error)")
        }
    }

    private static func cancelsAwaitingResponses(in suite: inout TestSuite) async {
        let store = RequestCorrelationStore(historyLimit: 4)
        let id = RequestID.integer(10)

        do {
            try await store.register(id)
            let waiter = Task { try await store.response(for: id) }
            try await Task.sleep(for: .milliseconds(10))
            waiter.cancel()

            do {
                _ = try await waiter.value
                suite.fail("a cancelled response waiter should throw")
            } catch is CancellationError {
                suite.check(true, "response waiter observed structured cancellation")
            } catch {
                suite.fail("cancelled response waiter returned the wrong error: \(error)")
            }
            let pendingCount = await store.pendingCount
            suite.check(pendingCount == 0, "cancelled waiters should leave no pending correlation")

            let late = try JSONRPCWireMessage(data: Data(#"{"id":10,"result":{}}"#.utf8))
            let lateDisposition = await store.resolve(late)
            suite.check(
                lateDisposition == .recorded(id, reason: .lateResponse),
                "a response arriving after waiter cancellation should be recorded as late"
            )
        } catch {
            suite.fail("response cancellation setup failed: \(error)")
        }
    }

    private static func cancelsPreResolvedResponses(in suite: inout TestSuite) async {
        let store = RequestCorrelationStore(historyLimit: 4)
        let id = RequestID.integer(11)

        do {
            try await store.register(id)
            let response = try JSONRPCWireMessage(data: Data(#"{"id":11,"result":{"ok":true}}"#.utf8))
            _ = await store.resolve(response)

            let cancelledConsumer = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await store.response(for: id)
            }
            do {
                _ = try await cancelledConsumer.value
                suite.fail("a cancelled consumer must not receive a pre-resolved response")
            } catch is CancellationError {
                suite.check(true, "pre-resolved response honored consumer cancellation")
            } catch {
                suite.fail("pre-resolved cancellation returned the wrong error: \(error)")
            }

            let unmatched = await store.unmatchedResponses
            suite.check(
                unmatched.last?.reason == .lateResponse,
                "a pre-resolved response rejected by cancellation should remain diagnosable"
            )
        } catch {
            suite.fail("pre-resolved cancellation setup failed: \(error)")
        }
    }
}
