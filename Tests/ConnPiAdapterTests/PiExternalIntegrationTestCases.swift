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
            socketURL: socketURL,
            features: .init(questionsEnabled: true, approvalsEnabled: true)
        )
        let integration = PiExternalIntegration(broker: broker, enabled: true)
        do {
            let feed = try await integration.establishFeed()
            suite.check(feed.snapshot.sessions.isEmpty, "external feed begins with honest empty inventory")
            suite.check(
                feed.snapshot.capabilities.actions
                    == [.followUp, .steer, .interrupt, .answer, .resolveApproval],
                "optional attention capabilities appear only in their enabled generation"
            )
            let runtime = try require(
                store.load(),
                "live integration publishes its runtime descriptor"
            )
            let client = try PiLocalBrokerTestCases.openRegisteredClient(
                socketURL: socketURL,
                descriptor: runtime
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
                    && session.origin == .external,
                "Pi Session identity and external ownership map neutrally"
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
                firstActivitySession.activities.count == 1
                    && secondActivitySession.activities.map(\.id.rawValue)
                        == ["activity-1", "activity-2"],
                "successive Pi state updates retain bounded Session activity history"
            )

            try PiLocalBrokerTestCases.writeLine(
                """
                {"type":"attention","request":{"id":"attention-1","kind":"question","questionId":"question-1","header":"Choice","prompt":"Choose one","choices":["A","B"],"permitsOther":false},"state":\(stateJSON(isIdle: false, lastEvent: "tool_call"))}
                """,
                to: client.descriptor
            )
            guard let attentionUpdate = await iterator.next(),
                  case let .attentionUpsert(request) = attentionUpdate.update else {
                suite.fail("question frame must become one neutral Attention Request")
                Darwin.close(client.descriptor)
                await integration.disconnect()
                return
            }
            suite.check(
                request.kind == .structuredQuestion,
                "question Attention kind remains provider-neutral"
            )
            let answers = try ConnStructuredAnswers(
                valuesByQuestionID: ["question-1": ["A"]]
            )
            let answerAction = ConnAction.answer(
                sessionID: session.id,
                authority: .init(
                    requestID: request.id,
                    generation: feed.snapshot.generation
                ),
                answers: answers
            )
            let answerTask = Task { await integration.perform(answerAction) }
            let answerCommand = try PiLocalBrokerTestCases.readLine(
                from: client.descriptor
            )
            suite.check(
                answerCommand.contains(#""type":"answer""#)
                    && answerCommand.contains(#""requestId":"attention-1""#),
                "answer targets one exact live question request"
            )
            try PiLocalBrokerTestCases.writeLine(
                """
                {"type":"response","id":\(jsonString(commandID(answerCommand))),"success":true,"state":\(stateJSON(isIdle: false, lastEvent: "tool_call"))}
                """,
                to: client.descriptor
            )
            let answerOutcome = await answerTask.value
            suite.check(
                answerOutcome.kind == .accepted,
                "exact question answer acknowledgement is accepted"
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
