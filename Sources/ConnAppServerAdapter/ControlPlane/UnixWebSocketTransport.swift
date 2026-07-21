import Foundation
import Network

// Optional Level 3 adapter; never required for hook observation.

public enum ControlTransportError: Error, CustomStringConvertible, Sendable {
    case notConnected
    case connectionInProgress
    case connectionFailed(String)
    case connectionClosed
    case connectionTimedOut
    case unexpectedMessageType
    case invalidUTF8
    case receiveInProgress
    case messageTooLarge

    public var description: String {
        switch self {
        case .notConnected:
            "The App Server control transport is not connected."
        case .connectionInProgress:
            "An App Server control connection is already in progress."
        case let .connectionFailed(message):
            "The App Server control transport failed: \(message)"
        case .connectionClosed:
            "The App Server closed the control transport."
        case .connectionTimedOut:
            "The App Server control connection timed out."
        case .unexpectedMessageType:
            "The App Server sent a non-text WebSocket message."
        case .invalidUTF8:
            "The App Server sent a text message that was not valid UTF-8."
        case .receiveInProgress:
            "An App Server control receive is already in progress."
        case .messageTooLarge:
            "The App Server control message exceeded the transport bound."
        }
    }
}

private final class ConnectionAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func finish(with result: Result<Void, Error>) -> Bool {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return false
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
        return true
    }
}

/// A WebSocket client over the documented local App Server Unix socket.
///
/// This transport only accepts endpoints created by ``EndpointDiscovery``. It
/// never launches or owns an App Server process.
public actor UnixWebSocketTransport: ControlTransport {
    // Large thread/read responses can exceed 16 MiB once tool output is
    // included. Keep a finite ceiling while accommodating real local tasks.
    private static let maximumMessageBytes = 64 * 1_024 * 1_024

    private enum State {
        case disconnected
        case connecting(NWConnection)
        case connected(NWConnection)
    }

    private var state: State = .disconnected
    private let queue = DispatchQueue(label: "dev.conn.control-plane")
    private let connectionTimeout: Duration
    private var recordedObservations: [ControlTransportObservation] = []

    public init(connectionTimeout: Duration = .seconds(5)) {
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

        let webSocket = NWProtocolWebSocket.Options(.version13)
        webSocket.autoReplyPing = true
        webSocket.maximumMessageSize = Self.maximumMessageBytes
        webSocket.setAdditionalHeaders([(name: "Host", value: "localhost")])

        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)

        let candidate = NWConnection(to: .unix(path: endpoint.socketURL.path), using: parameters)
        state = .connecting(candidate)
        record(.init(transport: .direct, event: .connectionStarted))

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let attempt = ConnectionAttempt(continuation: continuation)
                    candidate.stateUpdateHandler = { connectionState in
                        switch connectionState {
                        case .ready:
                            Task { await self.recordUpgrade(for: candidate) }
                            candidate.stateUpdateHandler = { [weak self, weak candidate] terminalState in
                                guard let self, let candidate else { return }
                                switch terminalState {
                                case let .failed(error):
                                    Task { await self.connectionDidTerminate(candidate, failure: error.debugDescription) }
                                case .cancelled:
                                    Task { await self.connectionDidTerminate(candidate, failure: nil) }
                                default:
                                    break
                                }
                            }
                            attempt.finish(with: .success(()))
                        case let .waiting(error), let .failed(error):
                            attempt.finish(
                                with: .failure(
                                    ControlTransportError.connectionFailed(error.debugDescription)
                                )
                            )
                        case .cancelled:
                            attempt.finish(with: .failure(ControlTransportError.connectionClosed))
                        default:
                            break
                        }
                    }

                    Task {
                        try? await Task.sleep(for: connectionTimeout)
                        if attempt.finish(with: .failure(ControlTransportError.connectionTimedOut)) {
                            self.record(.init(transport: .direct, event: .timeout))
                            candidate.cancel()
                        }
                    }
                    candidate.start(queue: queue)
                }
            } onCancel: {
                candidate.cancel()
                Task { await self.record(.init(transport: .direct, event: .cancelled)) }
            }

            try Task.checkCancellation()
            guard case let .connecting(active) = state, active === candidate else {
                candidate.cancel()
                throw ControlTransportError.connectionClosed
            }
            state = .connected(candidate)
        } catch {
            if case let .connecting(active) = state, active === candidate {
                state = .disconnected
            }
            candidate.stateUpdateHandler = nil
            candidate.cancel()
            if !(error is CancellationError),
               !Self.isTimeout(error)
            {
                record(.init(transport: .direct, event: .failure))
            }
            throw error
        }
    }

    public func send(text: String) async throws {
        guard case let .connected(connection) = state else {
            throw ControlTransportError.notConnected
        }
        let byteCount = text.utf8.count
        guard byteCount <= Self.maximumMessageBytes else {
            record(.init(
                transport: .direct,
                event: .bufferLimitExceeded,
                direction: .outbound,
                byteCount: byteCount
            ))
            throw ControlTransportError.messageTooLarge
        }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: UUID().uuidString,
            metadata: [metadata]
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: Data(text.utf8),
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(
                            throwing: ControlTransportError.connectionFailed(error.debugDescription)
                        )
                    } else {
                        Task {
                            await self.record(.init(
                                transport: .direct,
                                event: .message,
                                direction: .outbound,
                                opcode: "text",
                                byteCount: byteCount
                            ))
                        }
                        continuation.resume()
                    }
                }
            )
        }
    }

    public func receiveText() async throws -> String {
        guard case let .connected(connection) = state else {
            throw ControlTransportError.notConnected
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection.receiveMessage { data, context, _, error in
                    if let error {
                        Task { await self.record(.init(transport: .direct, event: .failure)) }
                        continuation.resume(
                            throwing: ControlTransportError.connectionFailed(error.debugDescription)
                        )
                        return
                    }
                    guard let metadata = context?.protocolMetadata(
                        definition: NWProtocolWebSocket.definition
                    ) as? NWProtocolWebSocket.Metadata
                    else {
                        continuation.resume(throwing: ControlTransportError.unexpectedMessageType)
                        return
                    }
                    if metadata.opcode == .close {
                        let closeCode = Self.closeCode(metadata.closeCode)
                        let isClean = closeCode == 1_000
                        Task {
                            await self.record(.init(
                                transport: .direct,
                                event: isClean ? .cleanClose : .protocolClose,
                                direction: .inbound,
                                opcode: "close",
                                byteCount: data?.count,
                                closeCode: closeCode
                            ))
                        }
                        continuation.resume(throwing: ControlTransportError.connectionClosed)
                        return
                    }
                    guard metadata.opcode == .text || metadata.opcode == .binary else {
                        Task {
                            await self.record(.init(
                                transport: .direct,
                                event: .message,
                                direction: .inbound,
                                opcode: Self.opcodeName(metadata.opcode),
                                byteCount: data?.count
                            ))
                        }
                        continuation.resume(throwing: ControlTransportError.unexpectedMessageType)
                        return
                    }
                    guard let data else {
                        continuation.resume(throwing: ControlTransportError.connectionClosed)
                        return
                    }
                    guard let text = String(data: data, encoding: .utf8) else {
                        continuation.resume(throwing: ControlTransportError.invalidUTF8)
                        return
                    }
                    Task {
                        await self.record(.init(
                            transport: .direct,
                            event: .message,
                            direction: .inbound,
                            opcode: Self.opcodeName(metadata.opcode),
                            byteCount: data.count
                        ))
                    }
                    continuation.resume(returning: text)
                }
            }
        } onCancel: {
            // Network.framework cannot cancel an individual receive. Closing the
            // Conn subscription prevents a cancelled reader from silently
            // consuming the next App Server frame.
            connection.cancel()
            Task { await self.record(.init(transport: .direct, event: .cancelled)) }
        }
    }

    public func disconnect() {
        switch state {
        case .disconnected:
            return
        case let .connecting(connection):
            state = .disconnected
            // Keep the setup handler installed so cancellation resumes the
            // in-flight connect continuation.
            connection.cancel()
            record(.init(transport: .direct, event: .cancelled))
        case let .connected(connection):
            state = .disconnected
            connection.stateUpdateHandler = nil
            connection.cancel()
            record(.init(transport: .direct, event: .cancelled))
        }
    }

    public func observations() -> [ControlTransportObservation] {
        recordedObservations
    }

    private func record(_ observation: ControlTransportObservation) {
        recordedObservations.append(observation)
    }

    private func recordUpgrade(for connection: NWConnection) {
        switch state {
        case let .connecting(active) where active === connection:
            record(.init(transport: .direct, event: .webSocketUpgrade))
        case let .connected(active) where active === connection:
            record(.init(transport: .direct, event: .webSocketUpgrade))
        case .disconnected, .connecting, .connected:
            break
        }
    }

    private func connectionDidTerminate(_ connection: NWConnection, failure: String?) {
        var wasActive = false
        switch state {
        case let .connecting(active) where active === connection:
            state = .disconnected
            connection.stateUpdateHandler = nil
            wasActive = true
        case let .connected(active) where active === connection:
            state = .disconnected
            connection.stateUpdateHandler = nil
            wasActive = true
        case .disconnected, .connecting, .connected:
            break
        }
        if wasActive, failure != nil {
            record(.init(transport: .direct, event: .failure))
        }
    }

    private static func opcodeName(_ opcode: NWProtocolWebSocket.Opcode) -> String {
        switch opcode {
        case .cont: "continuation"
        case .text: "text"
        case .binary: "binary"
        case .close: "close"
        case .ping: "ping"
        case .pong: "pong"
        @unknown default: "unknown"
        }
    }

    private static func closeCode(_ code: NWProtocolWebSocket.CloseCode) -> UInt16? {
        switch code {
        case let .protocolCode(value): value.rawValue
        case let .applicationCode(value), let .privateCode(value): value
        @unknown default: nil
        }
    }

    private static func isTimeout(_ error: Error) -> Bool {
        guard let transportError = error as? ControlTransportError else { return false }
        if case .connectionTimedOut = transportError { return true }
        return false
    }
}
