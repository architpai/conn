import Darwin
import Foundation
import ConnPiAdapter

enum PiLocalBrokerTestCases {
    static func run(into suite: inout TestSuite) async {
        let suffix = UUID().uuidString.prefix(8)
        let root = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("conn-pi-broker-\(suffix)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PiRuntimeDescriptorStore(
            directory: root.appendingPathComponent("runtime", isDirectory: true)
        )
        let socketURL = root.appendingPathComponent("broker.sock")
        let broker = PiLocalBroker(
            runtimeStore: store,
            socketURL: socketURL,
            features: .init(questionsEnabled: false, approvalsEnabled: false)
        )
        do {
            let descriptor = try await broker.start(timeToLive: 30)
            let client = try openRegisteredClient(
                socketURL: socketURL,
                descriptor: descriptor
            )
            suite.check(
                client.response.contains(#""type":"registered""#),
                "authenticated extension receives registration acknowledgement"
            )
            let registrations = await broker.registrations()
            suite.check(registrations.count == 1, "broker owns one live registration")
            suite.check(
                registrations.first?.handshake.sessionID == "session-live",
                "broker indexes the stable Pi Session identity"
            )
            let commandTask = Task {
                await broker.send(
                    .followUp(id: "control-1", message: "continue"),
                    to: "session-live",
                    timeout: .seconds(2)
                )
            }
            let command = try readLine(from: client.descriptor)
            let commandObject = try JSONSerialization.jsonObject(
                with: Data(command.utf8)
            ) as? [String: Any]
            suite.check(
                commandObject?["type"] as? String == "follow_up",
                "broker sends the closed follow-up command to the original Pi process"
            )
            try writeLine(
                """
                {"type":"response","id":"control-1","success":true,"state":{"sessionId":"session-live","sessionName":"Work","cwd":"/tmp/project","isIdle":true,"hasPendingMessages":true,"lastEvent":"turn_end","activeToolCount":0,"modelProvider":"openai-codex","modelId":"gpt-5.4-mini","modelName":"GPT-5.4 mini","thinking":"low"}}
                """,
                to: client.descriptor
            )
            guard case let .accepted(state) = await commandTask.value else {
                suite.fail("correlated Pi control acknowledgement must be accepted exactly once")
                Darwin.close(client.descriptor)
                await broker.stop()
                return
            }
            suite.check(
                state.hasPendingMessages,
                "control acknowledgement carries Pi's effective post-command state"
            )
            Darwin.close(client.descriptor)
            await broker.stop()
            suite.check(
                !FileManager.default.fileExists(atPath: socketURL.path),
                "broker stop removes its exact Unix socket"
            )
            suite.check(
                store.load() == nil,
                "broker stop invalidates the runtime lease"
            )
        } catch {
            suite.fail("live broker registration failed: \(error)")
            await broker.stop()
        }
    }

    static func openRegisteredClient(
        socketURL: URL,
        descriptor: PiBrokerRuntimeDescriptor
    ) throws -> (descriptor: Int32, response: String) {
        let socketDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { throw BrokerTestError.socket }

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketURL.path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) {
            $0.copyBytes(from: pathBytes)
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    socketDescriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard connected == 0 else { throw BrokerTestError.connect }
        let frame = """
        {"type":"register","protocol":1,"generation":"\(descriptor.generation.uuidString)","secret":"\(descriptor.authenticationSecret)","extensionVersion":"0.2.1","piVersion":"0.82.1","instanceId":"instance-live","pid":42,"sessionId":"session-live","reason":"startup","cwd":"/tmp/project","modelProvider":"openai-codex","modelId":"gpt-5.4-mini","thinking":"low"}
        """
        try writeLine(frame, to: socketDescriptor)
        return (socketDescriptor, try readLine(from: socketDescriptor))
    }

    static func writeLine(_ value: String, to descriptor: Int32) throws {
        let line = value.hasSuffix("\n") ? value : value + "\n"
        let written = line.withCString {
            Darwin.write(descriptor, $0, line.utf8.count)
        }
        guard written == line.utf8.count else { throw BrokerTestError.write }
    }

    static func readLine(from descriptor: Int32) throws -> String {
        var result = Data()
        var byte: UInt8 = 0
        while result.count <= PiBrokerProtocolBounds.maximumFrameBytes {
            let count = Darwin.read(descriptor, &byte, 1)
            guard count > 0 else { throw BrokerTestError.read }
            if byte == 0x0A { return String(decoding: result, as: UTF8.self) }
            result.append(byte)
        }
        throw BrokerTestError.read
    }
}

private enum BrokerTestError: Error {
    case socket
    case connect
    case write
    case read
}
