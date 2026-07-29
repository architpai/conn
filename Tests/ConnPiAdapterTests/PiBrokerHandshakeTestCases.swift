import Foundation
import ConnPiAdapter

enum PiBrokerHandshakeTestCases {
    private static let generation =
        UUID(uuidString: "A1000000-0000-4000-8000-000000000001")!

    static func run(into suite: inout TestSuite) {
        acceptsExactAuthenticatedHandshake(into: &suite)
        rejectsUntrustedOrMalformedFrames(into: &suite)
        rejectsOversizedFrames(into: &suite)
    }

    private static func acceptsExactAuthenticatedHandshake(
        into suite: inout TestSuite
    ) {
        let data = Data(
            """
            {"type":"register","protocol":1,"generation":"\(generation.uuidString)","secret":"test-secret","extensionVersion":"0.2.1","piVersion":"0.82.1","instanceId":"instance-1","pid":42,"sessionId":"session-1","reason":"startup","cwd":"/tmp/project","modelProvider":"openai-codex","modelId":"gpt-5.4-mini","thinking":"low"}
            """.utf8
        )
        do {
            let handshake = try PiBrokerHandshakeDecoder.decode(
                data,
                expectedGeneration: generation,
                expectedSecret: "test-secret"
            )
            suite.check(handshake.sessionID == "session-1", "Session identity decodes exactly")
            suite.check(handshake.processID == 42, "PID remains diagnostic evidence")
            suite.check(handshake.workspace == "/tmp/project", "Workspace decodes exactly")
        } catch {
            suite.fail("valid Pi handshake was rejected: \(error)")
        }
    }

    private static func rejectsUntrustedOrMalformedFrames(
        into suite: inout TestSuite
    ) {
        let wrongSecret = Data(
            """
            {"type":"register","protocol":1,"generation":"\(generation.uuidString)","secret":"wrong","extensionVersion":"0.2.1","piVersion":"0.82.1","instanceId":"instance-1","pid":42,"sessionId":"session-1","reason":"startup","cwd":"/tmp/project","modelProvider":"openai-codex","modelId":"gpt-5.4-mini","thinking":"low"}
            """.utf8
        )
        do {
            _ = try PiBrokerHandshakeDecoder.decode(
                wrongSecret,
                expectedGeneration: generation,
                expectedSecret: "test-secret"
            )
            suite.fail("a handshake with the wrong secret must fail closed")
        } catch PiBrokerProtocolError.authenticationFailed {
            suite.check(true, "wrong-secret handshake failed closed")
        } catch {
            suite.fail("wrong-secret handshake returned the wrong error: \(error)")
        }

        do {
            _ = try PiBrokerHandshakeDecoder.decode(
                Data(#"{"type":"future"}"#.utf8),
                expectedGeneration: generation,
                expectedSecret: "test-secret"
            )
            suite.fail("unknown handshake types must fail closed")
        } catch PiBrokerProtocolError.unsupportedMessage {
            suite.check(true, "unknown handshake type failed closed")
        } catch {
            suite.fail("unknown handshake returned the wrong error: \(error)")
        }
    }

    private static func rejectsOversizedFrames(into suite: inout TestSuite) {
        let data = Data(repeating: 0x61, count: PiBrokerProtocolBounds.maximumFrameBytes + 1)
        do {
            _ = try PiBrokerHandshakeDecoder.decode(
                data,
                expectedGeneration: generation,
                expectedSecret: "test-secret"
            )
            suite.fail("oversized broker frames must fail before decoding")
        } catch PiBrokerProtocolError.frameTooLarge {
            suite.check(true, "oversized broker frame failed closed")
        } catch {
            suite.fail("oversized frame returned the wrong error: \(error)")
        }
    }
}
