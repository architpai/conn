import Darwin
import Foundation
import ConnAppServerAdapter

enum TransportTestCases {
    private static let shellUpgradeResponse = "printf 'HTTP/1.1 101 Switching Protocols\\r\\nUpgrade: websocket\\r\\nConnection: Upgrade\\r\\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\\r\\n\\r\\n'"
    private static let shellDrainUpgradeRequest = "while IFS= read -r line; do [ \"$line\" = \"$(printf '\\r')\" ] && break; done"

    static func run(in suite: inout TestSuite) async {
        transportKindsAndConformance(in: &suite)
        await rejectsOperationsWhileDisconnected(in: &suite)
        await cancelsInProgressConnection(in: &suite)
        await proxyUsesExactCodexArguments(in: &suite)
        await proxyRoundTripsBoundedLinesAndDiagnostics(in: &suite)
        await proxyAcceptsUTF8BinaryJSON(in: &suite)
        await proxyPreservesLargeFrameChunkOrder(in: &suite)
        await proxyBoundsOutgoingAndIncomingLines(in: &suite)
        await proxyChildExitIsOnlyConnectionLoss(in: &suite)
        await proxyCancellationClosesOnlyTheConnection(in: &suite)
        await proxyHalfCloseIsConnectionLoss(in: &suite)
        await proxyDistinguishesCleanAndProtocolClose(in: &suite)
        await proxyHandshakeTimeoutIsDistinct(in: &suite)
        await proxyEscalatesAStuckChildOnly(in: &suite)
    }

    private static func transportKindsAndConformance(in suite: inout TestSuite) {
        suite.check(ControlTransportKind.direct.rawValue == "direct", "direct transport has stable raw value")
        suite.check(ControlTransportKind.proxy.rawValue == "proxy", "proxy transport has stable raw value")

        func acceptsTransport<T: ControlTransport>(_: T) {}
        acceptsTransport(UnixWebSocketTransport())
        acceptsTransport(ProxyStdioTransport(codexExecutableURL: URL(fileURLWithPath: "/usr/bin/false")))
        suite.check(true, "both transport implementations conform to the shared interface")
    }

    private static func rejectsOperationsWhileDisconnected(in suite: inout TestSuite) async {
        let transport = UnixWebSocketTransport(connectionTimeout: .milliseconds(50))

        do {
            try await transport.send(text: "{}")
            suite.fail("send should fail before connection")
        } catch ControlTransportError.notConnected {
            suite.check(true, "send rejected disconnected state")
        } catch {
            suite.fail("disconnected send returned the wrong error: \(error)")
        }

        do {
            _ = try await transport.receiveText()
            suite.fail("receive should fail before connection")
        } catch ControlTransportError.notConnected {
            suite.check(true, "receive rejected disconnected state")
        } catch {
            suite.fail("disconnected receive returned the wrong error: \(error)")
        }
    }

    private static func cancelsInProgressConnection(in suite: inout TestSuite) async {
        let temporaryRoot = URL(
            fileURLWithPath: "/tmp/conn-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        let controlDirectory = temporaryRoot.appendingPathComponent(
            EndpointDiscovery.controlDirectoryName,
            isDirectory: true
        )

        do {
            try FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporaryRoot) }
            let socketURL = controlDirectory.appendingPathComponent(EndpointDiscovery.controlSocketName)
            let descriptor = try makeListeningUnixSocket(at: socketURL)
            defer { close(descriptor) }
            guard chmod(socketURL.path, mode_t(0o600)) == 0 else {
                suite.fail("transport test could not secure its mock socket")
                return
            }
            let inspection = EndpointDiscovery(currentUserID: getuid()).inspect(codexHome: temporaryRoot)
            guard let endpoint = inspection.endpoint else {
                suite.fail("transport test endpoint did not pass discovery: \(inspection.status)")
                return
            }

            let transport = UnixWebSocketTransport(connectionTimeout: .milliseconds(100))
            let connectTask = Task { try await transport.connect(to: endpoint) }
            try await Task.sleep(for: .milliseconds(10))
            await transport.disconnect()

            do {
                try await connectTask.value
                suite.fail("disconnect should cancel an in-progress WebSocket handshake")
            } catch {
                suite.check(true, "in-progress connection completed with cancellation or closure")
            }

            do {
                try await transport.send(text: "{}")
                suite.fail("transport should remain disconnected after cancelling setup")
            } catch ControlTransportError.notConnected {
                suite.check(true, "cancelled setup returned to disconnected state")
            } catch {
                suite.fail("post-cancel send returned the wrong error: \(error)")
            }

            do {
                try await transport.connect(to: endpoint)
                suite.fail("mock server should not complete the WebSocket handshake")
            } catch ControlTransportError.connectionTimedOut {
                suite.check(true, "a second connection attempt was allowed and timed out cleanly")
            } catch {
                // Network.framework may reject the deliberately incomplete mock
                // handshake before the explicit timeout, which is also valid.
                suite.check(true, "a second connection attempt was allowed and failed cleanly")
            }
        } catch {
            suite.fail("transport lifecycle test setup failed: \(error)")
        }
    }

    private static func proxyUsesExactCodexArguments(in suite: inout TestSuite) async {
        var setupSuite = TestSuite()
        await withDiscoveredEndpoint(in: &setupSuite) { endpoint, temporaryRoot in
            let executableURL = temporaryRoot.appendingPathComponent("fake-codex")
            let script = """
            #!/bin/sh
            \(shellDrainUpgradeRequest)
            \(shellUpgradeResponse)
            if [ "$1" = "app-server" ] && [ "$2" = "proxy" ] && [ "$3" = "--sock" ] && [ "$4" = "\(endpoint.socketURL.path)" ] && [ "$#" -eq 4 ] && [ "$PATH" = "\(ConnChildProcessEnvironment.trustedSystemPATH)" ]; then
                printf '\\201\\002ok'
            else
                printf '\\201\\003bad'
            fi
            IFS= read -r ignored
            """
            do {
                try script.write(to: executableURL, atomically: true, encoding: .utf8)
                guard chmod(executableURL.path, mode_t(0o700)) == 0 else {
                    suite.fail("could not make the fake Codex executable runnable")
                    return
                }

                let transport = ProxyStdioTransport(testCodexExecutableURL: executableURL)
                try await transport.connect(to: endpoint)
                let result = try await transport.receiveText()
                suite.check(
                    result == "ok",
                    "proxy launches only the configured Codex executable with documented arguments and trusted system PATH"
                )
                await transport.disconnect()
            } catch {
                suite.fail("exact proxy command test failed: \(error)")
            }
        }
        setupSuite.failures.forEach { suite.fail($0) }
    }

    private static func proxyRoundTripsBoundedLinesAndDiagnostics(in suite: inout TestSuite) async {
        var setupSuite = TestSuite()
        await withDiscoveredEndpoint(in: &setupSuite) { endpoint, _ in
            let transport = ProxyStdioTransport(
                testCommand: .init(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: [
                        "-c",
                        "\(shellDrainUpgradeRequest); \(shellUpgradeResponse); bytes=$(dd bs=1 count=14 2>/dev/null | od -An -tx1 | tr -d ' \\n'); [ \"$bytes\" = '8188010203047a206a6023383279' ] || exit 9; printf '\\201\\010{\"id\":1}'; printf 'diagnostic\\n' >&2; IFS= read -r ignored"
                    ]
                ),
                maximumMessageBytes: 128,
                maximumBufferedBytes: 128,
                maximumDiagnosticBytes: 4
            )
            do {
                try await transport.connect(to: endpoint)
                try await transport.send(text: "{\"id\":1}")
                let reply = try await transport.receiveText()
                suite.check(reply == "{\"id\":1}", "proxy exchanges masked RFC 6455 text frames")
                await waitForObservation(transport) { $0.event == .diagnosticBytes }

                let observations = await transport.observations()
                suite.check(
                    observations.contains { $0.event == .proxyStarted },
                    "proxy records child startup metadata"
                )
                suite.check(
                    observations.contains {
                        $0.event == .message && $0.direction == .outbound
                            && $0.opcode == "text" && $0.byteCount == 8
                    },
                    "proxy records masked outbound frame metadata without a body"
                )
                suite.check(
                    observations.contains {
                        $0.event == .message && $0.direction == .inbound
                            && $0.opcode == "text" && $0.byteCount == 8
                    },
                    "proxy records inbound frame metadata without a body"
                )
                suite.check(
                    observations.contains {
                        $0.event == .diagnosticBytes && $0.byteCount == 4 && $0.isTruncated
                    },
                    "proxy bounds stderr diagnostics and records truncation metadata"
                )
                await transport.disconnect()
            } catch {
                suite.fail("proxy round-trip test failed: \(error)")
            }
        }
        setupSuite.failures.forEach { suite.fail($0) }
    }

    private static func proxyBoundsOutgoingAndIncomingLines(in suite: inout TestSuite) async {
        var setupSuite = TestSuite()
        await withDiscoveredEndpoint(in: &setupSuite) { endpoint, _ in
            let outgoing = ProxyStdioTransport(
                testCommand: .init(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "\(shellDrainUpgradeRequest); \(shellUpgradeResponse); IFS= read -r ignored"]
                ),
                maximumMessageBytes: 4,
                maximumBufferedBytes: 8
            )
            do {
                try await outgoing.connect(to: endpoint)
                do {
                    try await outgoing.send(text: "12345")
                    suite.fail("proxy should reject an oversized outbound line")
                } catch ControlTransportError.messageTooLarge {
                    suite.check(true, "proxy rejects oversized outbound lines")
                } catch {
                    suite.fail("oversized outbound line returned the wrong error: \(error)")
                }
                await outgoing.disconnect()
            } catch {
                suite.fail("outbound bound setup failed: \(error)")
            }

            let incoming = ProxyStdioTransport(
                testCommand: .init(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "\(shellDrainUpgradeRequest); \(shellUpgradeResponse); sleep 0.03; printf '\\201\\00512345'; IFS= read -r ignored"]
                ),
                maximumMessageBytes: 4,
                maximumBufferedBytes: 8
            )
            do {
                try await incoming.connect(to: endpoint)
                await waitForObservation(incoming) { $0.event == .bufferLimitExceeded }
                let observations = await incoming.observations()
                suite.check(
                    observations.contains {
                        $0.event == .bufferLimitExceeded && $0.direction == .inbound
                    },
                    "proxy records and closes on oversized inbound frames"
                )
                do {
                    _ = try await incoming.receiveText()
                    suite.fail("proxy should be disconnected after an oversized inbound frame")
                } catch ControlTransportError.notConnected {
                    suite.check(true, "oversized inbound frame closes the proxy connection")
                } catch {
                    suite.fail("oversized inbound connection returned the wrong error: \(error)")
                }
            } catch {
                suite.fail("inbound bound setup failed: \(error)")
            }

            let zeroLengthFlood = ProxyStdioTransport(
                testCommand: .init(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: [
                        "-c",
                        "\(shellDrainUpgradeRequest); \(shellUpgradeResponse); sleep 0.03; printf '\\201\\000\\201\\000\\201\\000'; IFS= read -r ignored"
                    ]
                ),
                maximumMessageBytes: 4,
                maximumBufferedBytes: 8,
                maximumQueuedMessages: 2
            )
            do {
                try await zeroLengthFlood.connect(to: endpoint)
                await waitForObservation(zeroLengthFlood) { $0.event == .bufferLimitExceeded }
                let observations = await zeroLengthFlood.observations()
                suite.check(
                    observations.contains { $0.event == .bufferLimitExceeded },
                    "proxy bounds queued message count even when payload byte count is zero"
                )
            } catch {
                suite.fail("zero-length queue bound setup failed: \(error)")
            }
        }
        setupSuite.failures.forEach { suite.fail($0) }
    }

    private static func proxyAcceptsUTF8BinaryJSON(in suite: inout TestSuite) async {
        var setupSuite = TestSuite()
        await withDiscoveredEndpoint(in: &setupSuite) { endpoint, _ in
            let transport = ProxyStdioTransport(testCommand: .init(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "\(shellDrainUpgradeRequest); \(shellUpgradeResponse); printf '\\202\\010{\"id\":1}'; IFS= read -r ignored"
                ]
            ))
            do {
                try await transport.connect(to: endpoint)
                let reply = try await transport.receiveText()
                suite.check(
                    reply == "{\"id\":1}",
                    "proxy accepts bounded UTF-8 JSON carried in a binary WebSocket frame"
                )
                await transport.disconnect()
            } catch {
                suite.fail("UTF-8 binary proxy frame failed: \(error)")
            }
        }
        setupSuite.failures.forEach { suite.fail($0) }
    }

    private static func proxyPreservesLargeFrameChunkOrder(in suite: inout TestSuite) async {
        var setupSuite = TestSuite()
        await withDiscoveredEndpoint(in: &setupSuite) { endpoint, _ in
            let transport = ProxyStdioTransport(testCommand: .init(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "\(shellDrainUpgradeRequest); \(shellUpgradeResponse); "
                        + "printf '\\201\\177\\000\\000\\000\\000\\000\\040\\000\\000'; "
                        + "dd if=/dev/zero bs=8192 count=256 2>/dev/null | LC_ALL=C tr '\\000' 'a'; "
                        + "IFS= read -r ignored"
                ]
            ))
            do {
                try await transport.connect(to: endpoint)
                let reply = try await transport.receiveText()
                suite.check(
                    reply.utf8.count == 2 * 1_024 * 1_024
                        && reply.utf8.allSatisfy { $0 == 97 },
                    "proxy preserves byte order across a rapidly chunked large frame"
                )
                await transport.disconnect()
            } catch {
                suite.fail("large chunked proxy frame failed: \(error)")
            }
        }
        setupSuite.failures.forEach { suite.fail($0) }
    }

    private static func proxyChildExitIsOnlyConnectionLoss(in suite: inout TestSuite) async {
        var setupSuite = TestSuite()
        await withDiscoveredEndpoint(in: &setupSuite) { endpoint, _ in
            let transport = ProxyStdioTransport(testCommand: .init(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "\(shellDrainUpgradeRequest); \(shellUpgradeResponse); sleep 0.05; exit 7"]
            ))
            do {
                try await transport.connect(to: endpoint)
                await waitForObservation(transport) { $0.event == .proxyExited }
                let observations = await transport.observations()
                suite.check(
                    observations.contains { $0.event == .proxyExited && $0.exitStatus == 7 },
                    "proxy child exit is recorded only as connection metadata"
                )
                suite.check(
                    !observations.contains { $0.event == .cleanClose || $0.event == .protocolClose },
                    "proxy exit is not presented as a protocol or daemon outcome"
                )
                do {
                    try await transport.send(text: "{}")
                    suite.fail("exited proxy should not remain connected")
                } catch ControlTransportError.notConnected {
                    suite.check(true, "proxy child exit becomes connection loss")
                } catch {
                    suite.fail("proxy exit returned the wrong connection error: \(error)")
                }
            } catch {
                suite.fail("proxy exit test failed: \(error)")
            }
        }
        setupSuite.failures.forEach { suite.fail($0) }
    }

    private static func proxyCancellationClosesOnlyTheConnection(in suite: inout TestSuite) async {
        var setupSuite = TestSuite()
        await withDiscoveredEndpoint(in: &setupSuite) { endpoint, _ in
            let transport = ProxyStdioTransport(testCommand: .init(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "\(shellDrainUpgradeRequest); \(shellUpgradeResponse); IFS= read -r ignored"]
            ))
            do {
                try await transport.connect(to: endpoint)
                let receive = Task { try await transport.receiveText() }
                try await Task.sleep(for: .milliseconds(10))
                receive.cancel()
                do {
                    _ = try await receive.value
                    suite.fail("cancelled proxy receive should not complete")
                } catch is CancellationError {
                    suite.check(true, "proxy receive cancellation is surfaced as cancellation")
                } catch {
                    suite.fail("cancelled proxy receive returned the wrong error: \(error)")
                }
                let observations = await transport.observations()
                suite.check(
                    observations.contains { $0.event == .cancelled },
                    "proxy records cancellation distinctly"
                )
                do {
                    try await transport.send(text: "{}")
                    suite.fail("cancelled receive should close its disposable proxy")
                } catch ControlTransportError.notConnected {
                    suite.check(true, "cancellation closes only the proxy connection")
                } catch {
                    suite.fail("post-cancellation send returned the wrong error: \(error)")
                }
            } catch {
                suite.fail("proxy cancellation test failed: \(error)")
            }
        }
        setupSuite.failures.forEach { suite.fail($0) }
    }

    private static func proxyHalfCloseIsConnectionLoss(in suite: inout TestSuite) async {
        var setupSuite = TestSuite()
        await withDiscoveredEndpoint(in: &setupSuite) { endpoint, _ in
            let transport = ProxyStdioTransport(testCommand: .init(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "\(shellDrainUpgradeRequest); \(shellUpgradeResponse); sleep 0.03; exec 1>&-; IFS= read -r ignored"]
            ))
            do {
                try await transport.connect(to: endpoint)
                await waitForObservation(transport) { $0.event == .streamHalfClosed }
                let observations = await transport.observations()
                suite.check(
                    observations.contains {
                        $0.event == .streamHalfClosed && $0.direction == .inbound
                    },
                    "proxy records stdout half-close distinctly"
                )
                do {
                    try await transport.send(text: "{}")
                    suite.fail("stdout half-close should end the proxy connection")
                } catch ControlTransportError.notConnected {
                    suite.check(true, "stdout half-close is connection loss only")
                } catch {
                    suite.fail("half-close returned the wrong error: \(error)")
                }
            } catch {
                suite.fail("proxy half-close test failed: \(error)")
            }
        }
        setupSuite.failures.forEach { suite.fail($0) }
    }

    private static func proxyDistinguishesCleanAndProtocolClose(in suite: inout TestSuite) async {
        var setupSuite = TestSuite()
        await withDiscoveredEndpoint(in: &setupSuite) { endpoint, _ in
            let clean = ProxyStdioTransport(testCommand: .init(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "\(shellDrainUpgradeRequest); \(shellUpgradeResponse); sleep 0.03; printf '\\210\\002\\003\\350'; IFS= read -r ignored"
                ]
            ))
            do {
                try await clean.connect(to: endpoint)
                await waitForObservation(clean) { $0.event == .cleanClose }
                let observations = await clean.observations()
                suite.check(
                    observations.contains { $0.event == .cleanClose && $0.closeCode == 1_000 },
                    "proxy records a normal RFC 6455 close distinctly"
                )
            } catch {
                suite.fail("clean proxy close test failed: \(error)")
            }

            let protocolClose = ProxyStdioTransport(testCommand: .init(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "\(shellDrainUpgradeRequest); \(shellUpgradeResponse); sleep 0.03; printf '\\210\\002\\003\\352'; IFS= read -r ignored"
                ]
            ))
            do {
                try await protocolClose.connect(to: endpoint)
                await waitForObservation(protocolClose) { $0.event == .protocolClose }
                let observations = await protocolClose.observations()
                suite.check(
                    observations.contains { $0.event == .protocolClose && $0.closeCode == 1_002 },
                    "proxy records a protocol RFC 6455 close distinctly"
                )
            } catch {
                suite.fail("protocol proxy close test failed: \(error)")
            }
        }
        setupSuite.failures.forEach { suite.fail($0) }
    }

    private static func proxyHandshakeTimeoutIsDistinct(in suite: inout TestSuite) async {
        var setupSuite = TestSuite()
        await withDiscoveredEndpoint(in: &setupSuite) { endpoint, _ in
            let transport = ProxyStdioTransport(
                testCommand: .init(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "\(shellDrainUpgradeRequest); IFS= read -r ignored"]
                ),
                connectionTimeout: .milliseconds(30)
            )
            do {
                try await transport.connect(to: endpoint)
                suite.fail("proxy should time out without a WebSocket upgrade response")
            } catch ControlTransportError.connectionTimedOut {
                let observations = await transport.observations()
                suite.check(
                    observations.contains { $0.event == .timeout },
                    "proxy records handshake timeout distinctly"
                )
            } catch {
                suite.fail("proxy handshake timeout returned the wrong error: \(error)")
            }
        }
        setupSuite.failures.forEach { suite.fail($0) }
    }

    private static func proxyEscalatesAStuckChildOnly(in suite: inout TestSuite) async {
        var setupSuite = TestSuite()
        await withDiscoveredEndpoint(in: &setupSuite) { endpoint, _ in
            let transport = ProxyStdioTransport(testCommand: .init(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "\(shellDrainUpgradeRequest); \(shellUpgradeResponse); trap '' TERM; while :; do :; done"
                ]
            ))
            do {
                try await transport.connect(to: endpoint)
                await transport.disconnect()
                try await Task.sleep(for: .milliseconds(400))
                let observations = await transport.observations()
                suite.check(
                    observations.contains { $0.event == .proxyExited && $0.exitStatus != 0 },
                    "stuck disposable proxy is escalated to bounded exact-child termination"
                )
                suite.check(
                    !observations.contains { $0.event == .cleanClose || $0.event == .protocolClose },
                    "proxy escalation is never presented as daemon or turn state"
                )
            } catch {
                suite.fail("stuck proxy termination test failed: \(error)")
            }
        }
        setupSuite.failures.forEach { suite.fail($0) }
    }

    private static func withDiscoveredEndpoint(
        in suite: inout TestSuite,
        body: (ControlEndpoint, URL) async -> Void
    ) async {
        let temporaryRoot = URL(
            fileURLWithPath: "/tmp/conn-transport-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        let controlDirectory = temporaryRoot.appendingPathComponent(
            EndpointDiscovery.controlDirectoryName,
            isDirectory: true
        )

        do {
            try FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporaryRoot) }
            let socketURL = controlDirectory.appendingPathComponent(EndpointDiscovery.controlSocketName)
            let descriptor = try makeListeningUnixSocket(at: socketURL)
            defer { close(descriptor) }
            guard chmod(socketURL.path, mode_t(0o600)) == 0 else {
                suite.fail("proxy test could not secure its mock socket")
                return
            }
            let inspection = EndpointDiscovery(currentUserID: getuid()).inspect(codexHome: temporaryRoot)
            guard let endpoint = inspection.endpoint else {
                suite.fail("proxy test endpoint did not pass discovery: \(inspection.status)")
                return
            }
            await body(endpoint, temporaryRoot)
        } catch {
            suite.fail("proxy endpoint setup failed: \(error)")
        }
    }

    private static func waitForObservation(
        _ transport: ProxyStdioTransport,
        matching predicate: @Sendable (ControlTransportObservation) -> Bool
    ) async {
        for _ in 0..<100 {
            if await transport.observations().contains(where: predicate) { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func makeListeningUnixSocket(at url: URL) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(url.path.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(descriptor)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            buffer.copyBytes(from: pathBytes)
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(descriptor, 1) == 0 else {
            let capturedError = errno
            close(descriptor)
            throw POSIXError(.init(rawValue: capturedError) ?? .EIO)
        }
        return descriptor
    }
}
