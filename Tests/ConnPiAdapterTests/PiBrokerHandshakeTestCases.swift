import Foundation
import ConnPiAdapter

enum PiBrokerHandshakeTestCases {
    private static let generation =
        UUID(uuidString: "A1000000-0000-4000-8000-000000000001")!

    static func run(into suite: inout TestSuite) {
        acceptsExactAuthenticatedHandshake(into: &suite)
        rejectsUntrustedOrMalformedFrames(into: &suite)
        rejectsOversizedFrames(into: &suite)
        decodesClosedStateAndResponseFrames(into: &suite)
        encodesOnlyClosedSemanticCommands(into: &suite)
    }

    private static func acceptsExactAuthenticatedHandshake(
        into suite: inout TestSuite
    ) {
        let data = Data(
            """
            {"type":"register","protocol":1,"generation":"\(generation.uuidString)","secret":"test-secret","extensionVersion":"0.2.1","piVersion":"0.83.0","instanceId":"instance-1","pid":42,"sessionId":"session-1","reason":"resume","cwd":"/tmp/project","modelProvider":"openai-codex","modelId":"gpt-5.4-mini","thinking":"low","isIdle":true,"outcome":"completed","activities":[{"id":"entry-user","kind":"userMessage","text":"continue"},{"id":"entry-agent","kind":"agentMessage","text":"done"}],"availableModels":[{"provider":"openai-codex","id":"gpt-5.4-mini","name":"GPT-5.4 mini","thinkingLevels":["off","low","high"]},{"provider":"anthropic","id":"claude-opus-4-1","name":"Claude Opus 4.1","thinkingLevels":["off"]}]}
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
            suite.check(
                handshake.outcome == .completed,
                "reconnection handshake preserves the bounded settled outcome"
            )
            suite.check(
                handshake.activities.map(\.id) == ["entry-user", "entry-agent"],
                "resume registration hydrates stable Pi entry identities"
            )
            suite.check(
                handshake.availableModels.map(\.modelID)
                    == ["gpt-5.4-mini", "claude-opus-4-1"]
                    && handshake.availableModels[0].thinkingLevels
                        == ["off", "low", "high"],
                "registration exposes a bounded authenticated Pi model catalog"
            )
        } catch {
            suite.fail("valid Pi handshake was rejected: \(error)")
        }
    }

    private static func rejectsUntrustedOrMalformedFrames(
        into suite: inout TestSuite
    ) {
        let wrongSecret = Data(
            """
            {"type":"register","protocol":1,"generation":"\(generation.uuidString)","secret":"wrong","extensionVersion":"0.2.1","piVersion":"0.83.0","instanceId":"instance-1","pid":42,"sessionId":"session-1","reason":"startup","cwd":"/tmp/project","modelProvider":"openai-codex","modelId":"gpt-5.4-mini","thinking":"low"}
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

    private static func decodesClosedStateAndResponseFrames(
        into suite: inout TestSuite
    ) {
        let data = Data(
            #"{"type":"response","id":"command-1","success":true,"state":{"sessionId":"session-1","sessionName":"Work","cwd":"/tmp/project","isIdle":true,"hasPendingMessages":false,"lastEvent":"agent_settled","activeToolCount":0,"modelProvider":"openai-codex","modelId":"gpt-5.4-mini","modelName":"GPT-5.4 mini","thinking":"low","availableModels":[{"provider":"openai-codex","id":"gpt-5.4-mini","name":"GPT-5.4 mini","thinkingLevels":["off","low","high"]}]}}"#.utf8
        )
        do {
            guard case let .response(response) = try PiBrokerMessageDecoder.decode(data)
            else {
                suite.fail("correlated response frame must keep its closed discriminator")
                return
            }
            suite.check(response.id == "command-1", "response correlation ID decodes exactly")
            suite.check(response.state.isIdle, "effective Pi state accompanies acknowledgement")
            suite.check(
                response.state.availableModels.first?.displayName == "GPT-5.4 mini",
                "response state refreshes the authoritative model catalog"
            )
        } catch {
            suite.fail("valid response frame failed to decode: \(error)")
        }

        let eventData = Data(
            #"{"type":"event","event":"agent_settled","outcome":"completed","state":{"sessionId":"session-1","sessionName":"Work","cwd":"/tmp/project","isIdle":true,"hasPendingMessages":false,"lastEvent":"agent_settled","activeToolCount":0,"modelProvider":"openai-codex","modelId":"gpt-5.4-mini","modelName":"GPT-5.4 mini","thinking":"low"}}"#.utf8
        )
        do {
            guard case let .event(event) = try PiBrokerMessageDecoder.decode(eventData)
            else {
                suite.fail("settled event frame must keep its closed discriminator")
                return
            }
            suite.check(
                event.outcome == .completed,
                "settled event decodes only the bounded run outcome"
            )
        } catch {
            suite.fail("valid settled event frame failed to decode: \(error)")
        }

        let unsupportedOutcome = Data(
            #"{"type":"event","event":"agent_settled","outcome":"future","state":{"sessionId":"session-1","sessionName":"Work","cwd":"/tmp/project","isIdle":true,"hasPendingMessages":false,"lastEvent":"agent_settled","activeToolCount":0,"modelProvider":"openai-codex","modelId":"gpt-5.4-mini","modelName":"GPT-5.4 mini","thinking":"low"}}"#.utf8
        )
        do {
            _ = try PiBrokerMessageDecoder.decode(unsupportedOutcome)
            suite.fail("unknown Pi run outcomes must fail closed")
        } catch PiBrokerProtocolError.malformedFrame {
            suite.check(true, "unknown Pi run outcome failed closed")
        } catch {
            suite.fail("unknown Pi run outcome returned the wrong error: \(error)")
        }
    }

    private static func encodesOnlyClosedSemanticCommands(
        into suite: inout TestSuite
    ) {
        do {
            let data = try PiBrokerCommandEncoder.encode(
                .followUp(id: "command-2", message: "continue")
            )
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            suite.check(object?["type"] as? String == "follow_up", "follow-up uses one closed command")
            suite.check(object?["message"] as? String == "continue", "bounded message is preserved")
            suite.check(object?["method"] == nil, "no arbitrary provider method escape hatch is encoded")
        } catch {
            suite.fail("closed command encoding failed: \(error)")
        }
    }
}
