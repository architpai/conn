import Darwin
import Foundation
import ConnDomain
import ConnPiAdapter

enum PiExternalIntegrationTestCases {
    static func run(into suite: inout TestSuite) async {
        let suffix = UUID().uuidString.prefix(8)
        let root = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("conn-pi-integration-\(suffix)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PiRuntimeDescriptorStore(
            directory: root.appendingPathComponent("runtime", isDirectory: true)
        )
        let socketURL = root.appendingPathComponent("broker.sock")
        let broker = PiLocalBroker(
            runtimeStore: store,
            socketURL: socketURL
        )
        let integration = PiExternalIntegration(broker: broker, enabled: true)
        do {
            let feed = try await integration.establishFeed()
            suite.check(feed.snapshot.sessions.isEmpty, "external feed begins with honest empty inventory")
            suite.check(
                feed.snapshot.capabilities.actions
                    == [.followUp, .steer, .interrupt],
                "Pi advertises only its standard external Session controls"
            )
            let runtime = try require(
                store.load(),
                "live integration publishes its runtime descriptor"
            )
            let client = try PiLocalBrokerTestCases.openRegisteredClient(
                socketURL: socketURL,
                descriptor: runtime,
                outcome: .completed
            )
            var iterator = feed.updates.makeAsyncIterator()
            guard let registrationUpdate = await iterator.next(),
                  case let .sessionUpsert(session) = registrationUpdate.update else {
                suite.fail("authenticated registration must upsert one neutral Session")
                Darwin.close(client.descriptor)
                await integration.disconnect()
                return
            }
            suite.check(
                session.id.upstreamID.rawValue == "session-live"
                    && session.origin == .external
                    && session.status == .completed,
                "Pi reconnection preserves Session identity, ownership, and settled outcome"
            )

            try PiLocalBrokerTestCases.writeLine(
                """
                {"type":"event","event":"agent_start","state":\(stateJSON(isIdle: false, lastEvent: "agent_start"))}
                """,
                to: client.descriptor
            )
            guard let lifecycleUpdate = await iterator.next(),
                  case let .sessionUpsert(lifecycleSession) =
                    lifecycleUpdate.update else {
                suite.fail("Pi lifecycle state must upsert the Session")
                Darwin.close(client.descriptor)
                await integration.disconnect()
                return
            }
            suite.check(
                lifecycleSession.status == .working
                    && lifecycleSession.activities.isEmpty,
                "Pi lifecycle state stays internal instead of leaking into the transcript"
            )

            try PiLocalBrokerTestCases.writeLine(
                """
                {"type":"event","event":"tool_execution_start","state":\(stateJSON(isIdle: false, lastEvent: "tool_execution_start")),"activity":{"id":"custom-tool-1","kind":"toolCall","text":"acme_custom_tool"}}
                """,
                to: client.descriptor
            )
            guard let toolUpdate = await iterator.next(),
                  case let .sessionUpsert(toolSession) = toolUpdate.update else {
                suite.fail("Pi custom tool activity must upsert the Session")
                Darwin.close(client.descriptor)
                await integration.disconnect()
                return
            }
            suite.check(
                toolSession.activities.map(\.summary) == ["acme_custom_tool"]
                    && toolSession.activities.last?.kind == .toolCall,
                "Pi preserves arbitrary custom tool calls as transcript activity"
            )

            let followUp = try ConnActionText("continue")
            let action = ConnAction.followUp(
                sessionID: session.id,
                text: followUp
            )
            let outcomeTask = Task { await integration.perform(action) }
            let command = try PiLocalBrokerTestCases.readLine(
                from: client.descriptor
            )
            suite.check(
                command.contains(#""type":"follow_up""#),
                "neutral follow-up reaches the original Pi bridge"
            )
            try PiLocalBrokerTestCases.writeLine(
                """
                {"type":"response","id":\(jsonString(commandID(command))),"success":true,"state":\(stateJSON(isIdle: false, lastEvent: "turn_start"))}
                """,
                to: client.descriptor
            )
            let followUpOutcome = await outcomeTask.value
            suite.check(
                followUpOutcome.kind == .accepted,
                "correlated Pi acknowledgement maps to accepted"
            )

            try PiLocalBrokerTestCases.writeLine(
                """
                {"type":"event","event":"message_end","state":\(stateJSON(isIdle: false, lastEvent: "message_end")),"activity":{"id":"activity-1","kind":"agentMessage","text":"first"}}
                """,
                to: client.descriptor
            )
            guard let firstActivityUpdate = await iterator.next(),
                  case let .sessionUpsert(firstActivitySession) =
                    firstActivityUpdate.update else {
                suite.fail("first Pi activity must upsert the Session")
                Darwin.close(client.descriptor)
                await integration.disconnect()
                return
            }
            try PiLocalBrokerTestCases.writeLine(
                """
                {"type":"event","event":"message_end","state":\(stateJSON(isIdle: false, lastEvent: "message_end")),"activity":{"id":"activity-2","kind":"agentMessage","text":"second"}}
                """,
                to: client.descriptor
            )
            guard let secondActivityUpdate = await iterator.next(),
                  case let .sessionUpsert(secondActivitySession) =
                    secondActivityUpdate.update else {
                suite.fail("second Pi activity must upsert the Session")
                Darwin.close(client.descriptor)
                await integration.disconnect()
                return
            }
            suite.check(
                firstActivitySession.activities.count == 2
                    && secondActivitySession.activities.map(\.id.rawValue)
                        == ["custom-tool-1", "activity-1", "activity-2"],
                "successive Pi state updates retain bounded Session activity history"
            )

            try PiLocalBrokerTestCases.writeLine(
                """
                {"type":"event","event":"agent_end","state":\(stateJSON(isIdle: true, lastEvent: "agent_end"))}
                """,
                to: client.descriptor
            )
            guard let agentEndUpdate = await iterator.next(),
                  case let .sessionUpsert(agentEndSession) = agentEndUpdate.update else {
                suite.fail("low-level Pi agent end must upsert the Session")
                Darwin.close(client.descriptor)
                await integration.disconnect()
                return
            }
            suite.check(
                agentEndSession.status == .working
                    && agentEndSession.runs.last?.status == .inProgress,
                "low-level agent end waits for fully settled Pi outcome"
            )

            try PiLocalBrokerTestCases.writeLine(
                """
                {"type":"event","event":"agent_settled","outcome":"completed","state":\(stateJSON(isIdle: true, lastEvent: "agent_settled"))}
                """,
                to: client.descriptor
            )
            guard let settledUpdate = await iterator.next(),
                  case let .sessionUpsert(settledSession) = settledUpdate.update else {
                suite.fail("settled Pi lifecycle state must upsert the Session")
                Darwin.close(client.descriptor)
                await integration.disconnect()
                return
            }
            suite.check(
                settledSession.status == .completed
                    && settledSession.runs.last?.status == .completed,
                "a fully settled Pi agent marks its Conn Session completed"
            )

            try PiLocalBrokerTestCases.writeLine(
                """
                {"type":"event","event":"model_select","state":\(stateJSON(isIdle: true, lastEvent: "model_select"))}
                """,
                to: client.descriptor
            )
            guard let metadataUpdate = await iterator.next(),
                  case let .sessionUpsert(metadataSession) = metadataUpdate.update else {
                suite.fail("Pi metadata state must upsert the Session")
                Darwin.close(client.descriptor)
                await integration.disconnect()
                return
            }
            suite.check(
                metadataSession.status == .completed,
                "idle Pi metadata events preserve the terminal Session status"
            )

            try PiLocalBrokerTestCases.writeLine(
                """
                {"type":"event","event":"agent_start","state":\(stateJSON(isIdle: false, lastEvent: "agent_start"))}
                """,
                to: client.descriptor
            )
            _ = await iterator.next()
            try PiLocalBrokerTestCases.writeLine(
                """
                {"type":"event","event":"agent_settled","outcome":"interrupted","state":\(stateJSON(isIdle: true, lastEvent: "agent_settled"))}
                """,
                to: client.descriptor
            )
            guard let interruptedUpdate = await iterator.next(),
                  case let .sessionUpsert(interruptedSession) = interruptedUpdate.update else {
                suite.fail("interrupted Pi outcome must upsert the Session")
                Darwin.close(client.descriptor)
                await integration.disconnect()
                return
            }
            suite.check(
                interruptedSession.status == .idle
                    && interruptedSession.runs.last?.status == .interrupted,
                "an aborted settled Pi run maps to interrupted without claiming completion"
            )

            try PiLocalBrokerTestCases.writeLine(
                """
                {"type":"event","event":"agent_start","state":\(stateJSON(isIdle: false, lastEvent: "agent_start"))}
                """,
                to: client.descriptor
            )
            _ = await iterator.next()
            try PiLocalBrokerTestCases.writeLine(
                """
                {"type":"event","event":"agent_settled","outcome":"failed","state":\(stateJSON(isIdle: true, lastEvent: "agent_settled"))}
                """,
                to: client.descriptor
            )
            guard let failedUpdate = await iterator.next(),
                  case let .sessionUpsert(failedSession) = failedUpdate.update else {
                suite.fail("failed Pi outcome must upsert the Session")
                Darwin.close(client.descriptor)
                await integration.disconnect()
                return
            }
            suite.check(
                failedSession.status == .failed
                    && failedSession.runs.last?.status == .failed,
                "an errored settled Pi run maps to failed"
            )

            Darwin.close(client.descriptor)
            await integration.disconnect()
        } catch {
            suite.fail("external Pi integration E2E test failed: \(error)")
            await integration.disconnect()
        }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw IntegrationTestError.required(message) }
        return value
    }

    private static func commandID(_ json: String) throws -> String {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
            as? [String: Any]
        guard let id = object?["id"] as? String else {
            throw IntegrationTestError.malformedCommand
        }
        return id
    }

    private static func jsonString(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [value])
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    private static func stateJSON(isIdle: Bool, lastEvent: String) -> String {
        """
        {"sessionId":"session-live","sessionName":"Work","cwd":"/tmp/project","isIdle":\(isIdle),"hasPendingMessages":false,"lastEvent":"\(lastEvent)","activeToolCount":0,"modelProvider":"openai-codex","modelId":"gpt-5.4-mini","modelName":"GPT-5.4 mini","thinking":"low"}
        """
    }
}

private enum IntegrationTestError: Error {
    case required(String)
    case malformedCommand
}
