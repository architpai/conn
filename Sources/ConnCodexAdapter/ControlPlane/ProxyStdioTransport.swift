import CryptoKit
import Darwin
import Foundation

private final class ProxyChunkSequencer: @unchecked Sendable {
    private let lock = NSLock()
    private var nextValue: UInt64 = 0

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let value = nextValue
        nextValue &+= 1
        return value
    }
}

package struct ProxyStdioTestCommand: Sendable {
    package let executableURL: URL
    package let arguments: [String]
    package let webSocketKey: String
    package let maskingKeys: [[UInt8]]

    package init(
        executableURL: URL,
        arguments: [String],
        webSocketKey: String = "dGhlIHNhbXBsZSBub25jZQ==",
        maskingKeys: [[UInt8]] = [[1, 2, 3, 4]]
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.webSocketKey = webSocketKey
        self.maskingKeys = maskingKeys
    }
}

/// A WebSocket client over Codex's documented raw-byte stdio proxy.
///
/// This actor owns only its disposable proxy child. The proxy's exit is a
/// connection loss and never a daemon, thread, or turn outcome.
public actor ProxyStdioTransport: ControlTransport {
    private enum Command: Sendable {
        case codex(URL)
        case testCodex(URL, webSocketKey: String, maskingKeys: [[UInt8]])
        case test(ProxyStdioTestCommand)
    }

    private struct Session {
        let id: UUID
        let process: Process
        let standardInput: FileHandle
        let standardOutput: FileHandle
        let standardError: FileHandle
    }

    private enum State {
        case disconnected
        case connecting(Session)
        case connected(Session)
    }

    private static let handshakeLimit = 16 * 1_024
    private static let webSocketMagic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    private static let terminationGrace: Duration = .milliseconds(250)

    private let command: Command
    private let maximumMessageBytes: Int
    private let maximumBufferedBytes: Int
    private let maximumQueuedMessages: Int
    private let maximumDiagnosticBytes: Int
    private let connectionTimeout: Duration

    private var state: State = .disconnected
    private var handshakeBuffer = Data()
    private var frameBuffer = Data()
    private var fragmentedMessage = Data()
    private var isReadingFragmentedText = false
    private var queuedMessages: [Data] = []
    private var queuedMessageBytes = 0
    private var pendingConnect: CheckedContinuation<Void, Error>?
    private var pendingReceive: CheckedContinuation<String, Error>?
    private var recordedDiagnosticBytes = 0
    private var didRecordDiagnosticTruncation = false
    private var testMaskingKeyIndex = 0
    private var recordedObservations: [ControlTransportObservation] = []
    private var pendingStdoutChunks: [UInt64: Data] = [:]
    private var nextStdoutChunkSequence: UInt64 = 0

    public init(
        codexExecutableURL: URL,
        maximumMessageBytes: Int = 64 * 1_024 * 1_024,
        maximumBufferedBytes: Int = 64 * 1_024 * 1_024,
        maximumQueuedMessages: Int = 1_024,
        maximumDiagnosticBytes: Int = 64 * 1_024,
        connectionTimeout: Duration = .seconds(5)
    ) {
        command = .codex(codexExecutableURL)
        self.maximumMessageBytes = max(1, maximumMessageBytes)
        self.maximumBufferedBytes = max(1, maximumBufferedBytes)
        self.maximumQueuedMessages = max(1, maximumQueuedMessages)
        self.maximumDiagnosticBytes = max(0, maximumDiagnosticBytes)
        self.connectionTimeout = connectionTimeout
    }

    package init(
        testCommand: ProxyStdioTestCommand,
        maximumMessageBytes: Int = 64 * 1_024 * 1_024,
        maximumBufferedBytes: Int = 64 * 1_024 * 1_024,
        maximumQueuedMessages: Int = 1_024,
        maximumDiagnosticBytes: Int = 64 * 1_024,
        connectionTimeout: Duration = .seconds(1)
    ) {
        command = .test(testCommand)
        self.maximumMessageBytes = max(1, maximumMessageBytes)
        self.maximumBufferedBytes = max(1, maximumBufferedBytes)
        self.maximumQueuedMessages = max(1, maximumQueuedMessages)
        self.maximumDiagnosticBytes = max(0, maximumDiagnosticBytes)
        self.connectionTimeout = connectionTimeout
    }

    package init(
        testCodexExecutableURL: URL,
        webSocketKey: String = "dGhlIHNhbXBsZSBub25jZQ==",
        maskingKeys: [[UInt8]] = [[1, 2, 3, 4]],
        connectionTimeout: Duration = .seconds(1)
    ) {
        command = .testCodex(
            testCodexExecutableURL,
            webSocketKey: webSocketKey,
            maskingKeys: maskingKeys
        )
        maximumMessageBytes = 64 * 1_024 * 1_024
        maximumBufferedBytes = 64 * 1_024 * 1_024
        maximumQueuedMessages = 1_024
        maximumDiagnosticBytes = 64 * 1_024
        self.connectionTimeout = connectionTimeout
    }

    public func connect(to endpoint: ControlEndpoint) async throws {
        switch state {
        case .connected:
            return
        case .connecting:
            throw ControlTransportError.connectionInProgress
        case .disconnected:
            break
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let webSocketKey: String

        switch command {
        case let .codex(executableURL):
            process.executableURL = executableURL
            process.arguments = ["app-server", "proxy", "--sock", endpoint.socketURL.path]
            process.environment = ConnChildProcessEnvironment.withTrustedSystemPATH()
            webSocketKey = Self.randomWebSocketKey()
        case let .testCodex(executableURL, fixedWebSocketKey, _):
            process.executableURL = executableURL
            process.arguments = ["app-server", "proxy", "--sock", endpoint.socketURL.path]
            process.environment = ConnChildProcessEnvironment.withTrustedSystemPATH()
            webSocketKey = fixedWebSocketKey
        case let .test(testCommand):
            process.executableURL = testCommand.executableURL
            process.arguments = testCommand.arguments
            webSocketKey = testCommand.webSocketKey
        }

        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let session = Session(
            id: UUID(),
            process: process,
            standardInput: inputPipe.fileHandleForWriting,
            standardOutput: outputPipe.fileHandleForReading,
            standardError: errorPipe.fileHandleForReading
        )
        resetBuffers()
        state = .connecting(session)
        record(.init(transport: .proxy, event: .connectionStarted))

        // FileHandle emits chunks in stream order, but independent Tasks are
        // not guaranteed to enter this actor in creation order. Stamp each
        // chunk synchronously and reorder at the actor boundary.
        let stdoutSequencer = ProxyChunkSequencer()
        session.standardOutput.readabilityHandler = { [weak self] handle in
            let sequence = stdoutSequencer.next()
            let data = handle.availableData
            Task {
                await self?.consumeStdout(
                    data,
                    sequence: sequence,
                    sessionID: session.id,
                    webSocketKey: webSocketKey
                )
            }
        }
        session.standardError.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.consumeStderr(data, sessionID: session.id) }
        }
        process.terminationHandler = { [weak self] terminated in
            let status = terminated.terminationStatus
            Task { await self?.proxyDidExit(sessionID: session.id, status: status) }
        }

        do {
            try process.run()
            record(.init(transport: .proxy, event: .proxyStarted))
            try session.standardInput.write(contentsOf: Self.upgradeRequest(key: webSocketKey))

            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    pendingConnect = continuation
                    Task {
                        try? await Task.sleep(for: connectionTimeout)
                        self.connectionTimedOut(sessionID: session.id)
                    }
                }
            } onCancel: {
                Task { await self.cancelConnection(sessionID: session.id) }
            }
            guard case let .connected(active) = state, active.id == session.id else {
                throw ControlTransportError.connectionClosed
            }
        } catch {
            if activeSession(id: session.id) != nil {
                state = .disconnected
                tearDown(session, terminate: true)
            }
            if !(error is CancellationError), !Self.isTimeout(error) {
                record(.init(transport: .proxy, event: .failure))
            }
            throw error
        }
    }

    public func send(text: String) async throws {
        guard case let .connected(session) = state else {
            throw ControlTransportError.notConnected
        }
        let payload = Data(text.utf8)
        guard payload.count <= maximumMessageBytes else {
            recordLimitExceeded(direction: .outbound, byteCount: payload.count)
            throw ControlTransportError.messageTooLarge
        }

        do {
            try writeFrame(opcode: 0x1, payload: payload, to: session)
            record(.init(
                transport: .proxy,
                event: .message,
                direction: .outbound,
                opcode: "text",
                byteCount: payload.count
            ))
        } catch let error as ControlTransportError {
            failSession(session.id, error: error)
            throw error
        } catch {
            let transportError = ControlTransportError.connectionFailed(String(describing: error))
            failSession(session.id, error: transportError)
            throw transportError
        }
    }

    public func receiveText() async throws -> String {
        guard case .connected = state else {
            throw ControlTransportError.notConnected
        }
        if let message = popQueuedMessage() {
            return try decode(message)
        }
        guard pendingReceive == nil else {
            throw ControlTransportError.receiveInProgress
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingReceive = continuation
                if Task.isCancelled { cancelPendingReceive() }
            }
        } onCancel: {
            Task { await self.cancelPendingReceive() }
        }
    }

    public func disconnect() {
        guard let session = activeSession else { return }
        if case .connected = state {
            try? writeFrame(
                opcode: 0x8,
                payload: Data([0x03, 0xE8]),
                to: session
            )
        }
        state = .disconnected
        tearDown(session, terminate: true)
        pendingConnect?.resume(throwing: ControlTransportError.connectionClosed)
        pendingConnect = nil
        pendingReceive?.resume(throwing: ControlTransportError.connectionClosed)
        pendingReceive = nil
        record(.init(transport: .proxy, event: .cancelled))
    }

    public func observations() -> [ControlTransportObservation] {
        recordedObservations
    }

    private func consumeStdout(
        _ data: Data,
        sequence: UInt64,
        sessionID: UUID,
        webSocketKey: String
    ) {
        guard activeSession(id: sessionID) != nil else { return }
        pendingStdoutChunks[sequence] = data
        while let next = pendingStdoutChunks.removeValue(forKey: nextStdoutChunkSequence) {
            nextStdoutChunkSequence &+= 1
            consumeStdoutInOrder(next, sessionID: sessionID, webSocketKey: webSocketKey)
            guard activeSession(id: sessionID) != nil else { return }
        }
    }

    private func consumeStdoutInOrder(_ data: Data, sessionID: UUID, webSocketKey: String) {
        if data.isEmpty {
            record(.init(
                transport: .proxy,
                event: .streamHalfClosed,
                direction: .inbound
            ))
            failSession(sessionID, error: .connectionClosed)
            return
        }

        switch state {
        case let .connecting(session) where session.id == sessionID:
            consumeHandshakeBytes(data, session: session, webSocketKey: webSocketKey)
        case let .connected(session) where session.id == sessionID:
            frameBuffer.append(data)
            parseFrames(session: session)
        case .disconnected, .connecting, .connected:
            break
        }
    }

    private func consumeHandshakeBytes(_ data: Data, session: Session, webSocketKey: String) {
        handshakeBuffer.append(data)
        guard handshakeBuffer.count <= Self.handshakeLimit else {
            recordLimitExceeded(direction: .inbound, byteCount: handshakeBuffer.count)
            failSession(session.id, error: .messageTooLarge)
            return
        }

        let delimiter = Data("\r\n\r\n".utf8)
        guard let range = handshakeBuffer.range(of: delimiter) else { return }
        let headerData = Data(handshakeBuffer[..<range.lowerBound])
        let remainder = Data(handshakeBuffer[range.upperBound...])
        handshakeBuffer.removeAll(keepingCapacity: false)

        guard Self.isValidUpgrade(headerData, key: webSocketKey) else {
            record(.init(transport: .proxy, event: .failure))
            failSession(session.id, error: .connectionFailed("The proxy returned an invalid WebSocket upgrade."))
            return
        }

        state = .connected(session)
        record(.init(transport: .proxy, event: .webSocketUpgrade))
        pendingConnect?.resume()
        pendingConnect = nil
        if !remainder.isEmpty {
            frameBuffer.append(remainder)
            parseFrames(session: session)
        }
    }

    private func parseFrames(session: Session) {
        while activeSession(id: session.id) != nil {
            guard frameBuffer.count >= 2 else { return }
            let first = frameBuffer[frameBuffer.startIndex]
            let second = frameBuffer[frameBuffer.index(after: frameBuffer.startIndex)]
            let isFinal = first & 0x80 != 0
            let reservedBits = first & 0x70
            let opcode = first & 0x0F
            let isMasked = second & 0x80 != 0
            var payloadLength = UInt64(second & 0x7F)
            var headerLength = 2

            if payloadLength == 126 {
                guard frameBuffer.count >= 4 else { return }
                payloadLength = UInt64(frameBuffer[2]) << 8 | UInt64(frameBuffer[3])
                headerLength = 4
            } else if payloadLength == 127 {
                guard frameBuffer.count >= 10 else { return }
                guard frameBuffer[2] & 0x80 == 0 else {
                    protocolFailure(sessionID: session.id)
                    return
                }
                payloadLength = 0
                for byte in frameBuffer[2..<10] {
                    payloadLength = payloadLength << 8 | UInt64(byte)
                }
                headerLength = 10
            }

            guard reservedBits == 0, !isMasked,
                  payloadLength <= UInt64(maximumMessageBytes),
                  payloadLength <= UInt64(Int.max),
                  headerLength + Int(payloadLength) <= maximumBufferedBytes
            else {
                if payloadLength > UInt64(maximumMessageBytes) {
                    recordLimitExceeded(direction: .inbound, byteCount: Int(clamping: payloadLength))
                    failSession(session.id, error: .messageTooLarge)
                } else {
                    protocolFailure(sessionID: session.id)
                }
                return
            }

            let frameLength = headerLength + Int(payloadLength)
            guard frameBuffer.count >= frameLength else {
                if frameBuffer.count > maximumBufferedBytes {
                    recordLimitExceeded(direction: .inbound, byteCount: frameBuffer.count)
                    failSession(session.id, error: .messageTooLarge)
                }
                return
            }
            let payload = Data(frameBuffer[headerLength..<frameLength])
            frameBuffer.removeSubrange(..<frameLength)

            guard handleFrame(opcode: opcode, isFinal: isFinal, payload: payload, session: session) else {
                return
            }
        }
    }

    private func handleFrame(opcode: UInt8, isFinal: Bool, payload: Data, session: Session) -> Bool {
        if opcode >= 0x8, (!isFinal || payload.count > 125) {
            protocolFailure(sessionID: session.id)
            return false
        }

        switch opcode {
        case 0x0:
            guard isReadingFragmentedText else {
                protocolFailure(sessionID: session.id)
                return false
            }
            guard fragmentedMessage.count + payload.count <= maximumMessageBytes else {
                recordLimitExceeded(
                    direction: .inbound,
                    byteCount: fragmentedMessage.count + payload.count
                )
                failSession(session.id, error: .messageTooLarge)
                return false
            }
            fragmentedMessage.append(payload)
            if isFinal {
                isReadingFragmentedText = false
                let complete = fragmentedMessage
                fragmentedMessage.removeAll(keepingCapacity: true)
                deliverOrQueue(complete, sessionID: session.id)
            }
        case 0x1:
            guard !isReadingFragmentedText else {
                protocolFailure(sessionID: session.id)
                return false
            }
            if isFinal {
                deliverOrQueue(payload, sessionID: session.id)
            } else {
                isReadingFragmentedText = true
                fragmentedMessage = payload
            }
        case 0x2:
            // `codex app-server proxy` may carry UTF-8 JSON-RPC in a binary
            // WebSocket frame for larger responses. Preserve the same message
            // and UTF-8 bounds as text frames; JSON parsing remains mandatory
            // at the connection boundary.
            guard !isReadingFragmentedText else {
                protocolFailure(sessionID: session.id)
                return false
            }
            if isFinal {
                deliverOrQueue(payload, sessionID: session.id)
            } else {
                isReadingFragmentedText = true
                fragmentedMessage = payload
            }
        case 0x8:
            let closeCode = payload.count >= 2
                ? UInt16(payload[0]) << 8 | UInt16(payload[1])
                : nil
            record(.init(
                transport: .proxy,
                event: closeCode == 1_000 ? .cleanClose : .protocolClose,
                direction: .inbound,
                opcode: "close",
                byteCount: payload.count,
                closeCode: closeCode
            ))
            try? writeFrame(opcode: 0x8, payload: payload, to: session)
            failSession(session.id, error: .connectionClosed)
            return false
        case 0x9:
            record(.init(
                transport: .proxy,
                event: .message,
                direction: .inbound,
                opcode: "ping",
                byteCount: payload.count
            ))
            do {
                try writeFrame(opcode: 0xA, payload: payload, to: session)
                record(.init(
                    transport: .proxy,
                    event: .message,
                    direction: .outbound,
                    opcode: "pong",
                    byteCount: payload.count
                ))
            } catch {
                failSession(session.id, error: .connectionFailed(String(describing: error)))
                return false
            }
        case 0xA:
            record(.init(
                transport: .proxy,
                event: .message,
                direction: .inbound,
                opcode: "pong",
                byteCount: payload.count
            ))
        default:
            protocolFailure(sessionID: session.id)
            return false
        }
        return activeSession(id: session.id) != nil
    }

    private func writeFrame(opcode: UInt8, payload: Data, to session: Session) throws {
        guard payload.count <= maximumMessageBytes else {
            throw ControlTransportError.messageTooLarge
        }
        let maskingKey = nextMaskingKey()
        var frame = Data([0x80 | opcode])
        if payload.count <= 125 {
            frame.append(0x80 | UInt8(payload.count))
        } else if payload.count <= Int(UInt16.max) {
            frame.append(0x80 | 126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(0x80 | 127)
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((length >> UInt64(shift)) & 0xFF))
            }
        }
        frame.append(contentsOf: maskingKey)
        for (index, byte) in payload.enumerated() {
            frame.append(byte ^ maskingKey[index % 4])
        }
        try session.standardInput.write(contentsOf: frame)
    }

    private func nextMaskingKey() -> [UInt8] {
        let testKeys: [[UInt8]]?
        switch command {
        case .codex:
            testKeys = nil
        case let .testCodex(_, _, maskingKeys):
            testKeys = maskingKeys
        case let .test(testCommand):
            testKeys = testCommand.maskingKeys
        }
        if let testKeys, !testKeys.isEmpty {
            let key = testKeys[min(testMaskingKeyIndex, testKeys.count - 1)]
            testMaskingKeyIndex += 1
            if key.count == 4 { return key }
        }
        var generator = SystemRandomNumberGenerator()
        return (0..<4).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }

    private func consumeStderr(_ data: Data, sessionID: UUID) {
        guard activeSession(id: sessionID) != nil, !data.isEmpty else { return }
        let remaining = max(0, maximumDiagnosticBytes - recordedDiagnosticBytes)
        let accepted = min(remaining, data.count)
        if accepted > 0 {
            recordedDiagnosticBytes += accepted
            record(.init(
                transport: .proxy,
                event: .diagnosticBytes,
                direction: .inbound,
                byteCount: accepted,
                isTruncated: accepted < data.count
            ))
        }
        if accepted < data.count, !didRecordDiagnosticTruncation {
            didRecordDiagnosticTruncation = true
            if accepted == 0 {
                record(.init(
                    transport: .proxy,
                    event: .diagnosticBytes,
                    direction: .inbound,
                    byteCount: 0,
                    isTruncated: true
                ))
            }
        }
    }

    private func deliverOrQueue(_ message: Data, sessionID: UUID) {
        guard activeSession(id: sessionID) != nil else { return }
        guard String(data: message, encoding: .utf8) != nil else {
            failSession(sessionID, error: .invalidUTF8)
            return
        }
        if let continuation = pendingReceive {
            pendingReceive = nil
            recordMessage(message)
            continuation.resume(returning: String(decoding: message, as: UTF8.self))
            return
        }
        guard queuedMessages.count < maximumQueuedMessages,
              queuedMessageBytes + message.count <= maximumBufferedBytes
        else {
            recordLimitExceeded(direction: .inbound, byteCount: queuedMessageBytes + message.count)
            failSession(sessionID, error: .messageTooLarge)
            return
        }
        queuedMessages.append(message)
        queuedMessageBytes += message.count
    }

    private func popQueuedMessage() -> Data? {
        guard !queuedMessages.isEmpty else { return nil }
        let message = queuedMessages.removeFirst()
        queuedMessageBytes -= message.count
        recordMessage(message)
        return message
    }

    private func recordMessage(_ message: Data) {
        record(.init(
            transport: .proxy,
            event: .message,
            direction: .inbound,
            opcode: "text",
            byteCount: message.count
        ))
    }

    private func decode(_ message: Data) throws -> String {
        guard let text = String(data: message, encoding: .utf8) else {
            throw ControlTransportError.invalidUTF8
        }
        return text
    }

    private func protocolFailure(sessionID: UUID) {
        if let session = activeSession(id: sessionID) {
            try? writeFrame(opcode: 0x8, payload: Data([0x03, 0xEA]), to: session)
        }
        record(.init(
            transport: .proxy,
            event: .protocolClose,
            direction: .inbound,
            opcode: "close",
            closeCode: 1_002
        ))
        failSession(sessionID, error: .unexpectedMessageType)
    }

    private func cancelPendingReceive() {
        guard let continuation = pendingReceive else { return }
        pendingReceive = nil
        continuation.resume(throwing: CancellationError())
        if let session = activeSession {
            state = .disconnected
            tearDown(session, terminate: true)
        }
        record(.init(transport: .proxy, event: .cancelled))
    }

    private func cancelConnection(sessionID: UUID) {
        guard let session = activeSession(id: sessionID) else { return }
        state = .disconnected
        tearDown(session, terminate: true)
        pendingConnect?.resume(throwing: CancellationError())
        pendingConnect = nil
        record(.init(transport: .proxy, event: .cancelled))
    }

    private func connectionTimedOut(sessionID: UUID) {
        guard case let .connecting(session) = state, session.id == sessionID else { return }
        state = .disconnected
        tearDown(session, terminate: true)
        pendingConnect?.resume(throwing: ControlTransportError.connectionTimedOut)
        pendingConnect = nil
        record(.init(transport: .proxy, event: .timeout))
    }

    private func proxyDidExit(sessionID: UUID, status: Int32) {
        record(.init(transport: .proxy, event: .proxyExited, exitStatus: status))
        guard let session = activeSession(id: sessionID) else { return }
        state = .disconnected
        tearDown(session, terminate: false)
        pendingConnect?.resume(throwing: ControlTransportError.connectionClosed)
        pendingConnect = nil
        pendingReceive?.resume(throwing: ControlTransportError.connectionClosed)
        pendingReceive = nil
    }

    private func failSession(_ sessionID: UUID, error: ControlTransportError) {
        guard let session = activeSession(id: sessionID) else { return }
        state = .disconnected
        tearDown(session, terminate: true)
        pendingConnect?.resume(throwing: error)
        pendingConnect = nil
        pendingReceive?.resume(throwing: error)
        pendingReceive = nil
    }

    private func tearDown(_ session: Session, terminate: Bool) {
        session.standardOutput.readabilityHandler = nil
        session.standardError.readabilityHandler = nil
        try? session.standardInput.close()
        if terminate, session.process.isRunning {
            ProxyChildTerminator(process: session.process).terminate(after: Self.terminationGrace)
        }
    }

    private var activeSession: Session? {
        switch state {
        case .disconnected: nil
        case let .connecting(session), let .connected(session): session
        }
    }

    private func activeSession(id: UUID) -> Session? {
        guard let session = activeSession, session.id == id else { return nil }
        return session
    }

    private func resetBuffers() {
        handshakeBuffer.removeAll(keepingCapacity: true)
        frameBuffer.removeAll(keepingCapacity: true)
        fragmentedMessage.removeAll(keepingCapacity: true)
        isReadingFragmentedText = false
        queuedMessages.removeAll(keepingCapacity: true)
        queuedMessageBytes = 0
        pendingConnect = nil
        pendingReceive = nil
        recordedDiagnosticBytes = 0
        didRecordDiagnosticTruncation = false
        testMaskingKeyIndex = 0
        pendingStdoutChunks.removeAll(keepingCapacity: true)
        nextStdoutChunkSequence = 0
    }

    private func recordLimitExceeded(direction: ControlTransportObservation.Direction, byteCount: Int) {
        record(.init(
            transport: .proxy,
            event: .bufferLimitExceeded,
            direction: direction,
            byteCount: byteCount
        ))
    }

    private func record(_ observation: ControlTransportObservation) {
        recordedObservations.append(observation)
    }

    private static func randomWebSocketKey() -> String {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
            .base64EncodedString()
    }

    private static func upgradeRequest(key: String) -> Data {
        Data("""
        GET / HTTP/1.1\r
        Host: localhost\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Key: \(key)\r
        Sec-WebSocket-Version: 13\r
        \r

        """.utf8)
    }

    private static func isValidUpgrade(_ data: Data, key: String) -> Bool {
        guard let header = String(data: data, encoding: .utf8) else { return false }
        let lines = header.components(separatedBy: "\r\n")
        guard let status = lines.first,
              status.split(separator: " ").dropFirst().first == "101"
        else { return false }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let expected = Data(Insecure.SHA1.hash(data: Data((key + webSocketMagic).utf8)))
            .base64EncodedString()
        let upgradeTokens = headers["upgrade"]?.lowercased()
        let connectionTokens = headers["connection"]?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return upgradeTokens == "websocket"
            && connectionTokens?.contains("upgrade") == true
            && headers["sec-websocket-accept"] == expected
    }

    private static func isTimeout(_ error: Error) -> Bool {
        guard let transportError = error as? ControlTransportError else { return false }
        if case .connectionTimedOut = transportError { return true }
        return false
    }
}

/// `Process` is not Sendable. This wrapper owns only one exact proxy child and
/// confines the unchecked crossing to bounded termination of that same PID.
private final class ProxyChildTerminator: @unchecked Sendable {
    private let process: Process
    private let processID: pid_t

    init(process: Process) {
        self.process = process
        processID = process.processIdentifier
    }

    func terminate(after grace: Duration) {
        process.terminate()
        Task.detached { [self] in
            try? await Task.sleep(for: grace)
            guard process.isRunning, process.processIdentifier == processID, processID > 0 else { return }
            _ = Darwin.kill(processID, SIGKILL)
        }
    }
}
