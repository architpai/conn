import Foundation

public enum ConnConnectionOperation: String, Equatable, Sendable {
    case connect
    case send
    case receive
    case request
}

public enum ConnAppServerConnectionError: Error, Equatable, Sendable {
    case notConnected
    case connectionAlreadyActive
    case initializationAlreadyAttempted
    case unsupportedVersion(String)
    case unsupportedMethod(method: String, version: String, experimentalAPIEnabled: Bool)
    case timedOut(ConnConnectionOperation)
    case transportFailure(ConnConnectionOperation)
    case invalidResponse(method: String)
    case server(method: String, code: Int64)
    case staleConnection
    case inboundQueueOverflow
    case unknownServerRequest(RequestID)
}

public enum ConnAppServerConnectionState: Equatable, Sendable {
    case disconnected
    case disconnecting(generation: UInt64)
    case connecting(generation: UInt64)
    case ready(generation: UInt64, version: SupportedAppServerVersion)
    case failed(generation: UInt64)
}

public enum ConnAppServerInboundMessage: Equatable, Sendable {
    case request(JSONRPCRequest)
    case notification(JSONRPCNotification)

    fileprivate var byteCount: Int {
        let message: JSONRPCWireMessage
        switch self {
        case let .request(value): message = .request(value)
        case let .notification(value): message = .notification(value)
        }
        return (try? JSONEncoder().encode(message).count) ?? 0
    }

    fileprivate var isSheddable: Bool {
        guard case let .notification(notification) = self else { return false }
        return notification.method.hasSuffix("Delta")
            || notification.method.hasSuffix("/delta")
            || notification.method == "thread/tokenUsage/updated"
            || notification.method == "thread/goal/cleared"
    }
}

/// Runtime-only authority for inbound facts. The random instance component
/// prevents generation counters from colliding when a connection actor is
/// replaced after reconnect or app-core reconstruction.
public struct ConnAppServerConnectionIdentity: Equatable, Hashable, Sendable {
    public let instanceID: UUID
    public let generation: UInt64

    public init(instanceID: UUID, generation: UInt64) {
        self.instanceID = instanceID
        self.generation = generation
    }
}

/// One inbound message at its original monotonic receive position.
public struct ConnAppServerInboundEnvelope: Equatable, Sendable {
    public let connection: ConnAppServerConnectionIdentity
    public let sequence: UInt64
    public let message: ConnAppServerInboundMessage

    public init(
        connection: ConnAppServerConnectionIdentity,
        sequence: UInt64,
        message: ConnAppServerInboundMessage
    ) {
        self.connection = connection
        self.sequence = sequence
        self.message = message
    }

    fileprivate var byteCount: Int { message.byteCount }
    fileprivate var isSheddable: Bool {
        message.isSheddable
    }
}

/// One correlated result at its exact position in the connection's shared
/// receive order. Snapshot reducers must use this authority instead of
/// synthesizing a cursor from whichever notifications happened to be drained.
public struct ConnAppServerResponseEnvelope: Equatable, Sendable {
    public let connection: ConnAppServerConnectionIdentity
    public let sequence: UInt64
    public let result: JSONValue

    public init(
        connection: ConnAppServerConnectionIdentity,
        sequence: UInt64,
        result: JSONValue
    ) {
        self.connection = connection
        self.sequence = sequence
        self.result = result
    }
}

public struct ConnAppServerConnectionConfiguration: Sendable {
    public var connectTimeout: Duration
    public var sendTimeout: Duration
    public var receiveTimeout: Duration?
    public var requestTimeout: Duration
    public var maximumInboundMessages: Int
    public var maximumInboundBytes: Int
    public var maximumTraceEntries: Int

    public init(
        connectTimeout: Duration = .seconds(5),
        sendTimeout: Duration = .seconds(5),
        receiveTimeout: Duration? = nil,
        requestTimeout: Duration = .seconds(30),
        maximumInboundMessages: Int = 512,
        maximumInboundBytes: Int = 64 * 1_024 * 1_024,
        maximumTraceEntries: Int = 256
    ) {
        self.connectTimeout = connectTimeout
        self.sendTimeout = sendTimeout
        self.receiveTimeout = receiveTimeout
        self.requestTimeout = requestTimeout
        self.maximumInboundMessages = max(1, maximumInboundMessages)
        self.maximumInboundBytes = max(1, maximumInboundBytes)
        self.maximumTraceEntries = max(1, maximumTraceEntries)
    }
}

/// Production JSON-RPC connection over the Phase 5 selected transport.
///
/// The actor never retries a request. Replacement increments the generation,
/// uses a fresh correlation store, and retains globally unique request IDs so a
/// reply from an old transport session cannot resolve a newer request.
public actor ConnAppServerConnection {
    public static let reasoningTextDeltaMethod = "item/reasoning/textDelta"
    public static let optOutNotificationMethods = [reasoningTextDeltaMethod]

    private let transport: any ControlTransport
    private let configuration: ConnAppServerConnectionConfiguration
    private let clientInfo: InitializeClientInfo
    private let instanceID = UUID()

    private var connectionState: ConnAppServerConnectionState = .disconnected
    private var generation: UInt64 = 0
    private var nextRequestNumber: Int64 = 0
    private var receiveTask: Task<Void, Never>?
    private var correlation: RequestCorrelationStore?
    private var pendingRequestIDs: Set<RequestID> = []
    private var initializeAttemptedGeneration: UInt64?
    private var compatibility: AppServerCompatibilityPolicy?

    private var inbound: [ConnAppServerInboundEnvelope] = []
    private var inboundBytes = 0
    private var nextInboundSequence: UInt64 = 0
    private var responsePositions: [RequestID: (ConnAppServerConnectionIdentity, UInt64)] = [:]
    /// Exact request method retained with each active server-request ID. A
    /// future/unsupported request may still be observed, but cannot be
    /// answered unless the version-pinned response policy authorizes its
    /// method.
    private var unresolvedServerRequests: [RequestID: String] = [:]
    private var trace: ConnConnectionTraceBuffer

    public init(
        transport: any ControlTransport,
        configuration: ConnAppServerConnectionConfiguration = .init(),
        clientInfo: InitializeClientInfo = .init(
            name: "conn",
            title: "Conn",
            version: "0.1.0"
        )
    ) {
        self.transport = transport
        self.configuration = configuration
        self.clientInfo = clientInfo
        trace = .init(limit: configuration.maximumTraceEntries)
    }

    public var state: ConnAppServerConnectionState { connectionState }

    public var activeIdentity: ConnAppServerConnectionIdentity? {
        switch connectionState {
        case let .connecting(generation), let .ready(generation, _):
            ConnAppServerConnectionIdentity(instanceID: instanceID, generation: generation)
        case .disconnected, .disconnecting, .failed:
            nil
        }
    }

    public var pendingRequestCount: Int { pendingRequestIDs.count }

    public var queuedInboundCount: Int { inbound.count }

    public func traceEntries() -> [ConnConnectionTraceEntry] { trace.entries }

    @discardableResult
    public func connect(
        to endpoint: ControlEndpoint,
        serverVersion: SupportedAppServerVersion,
        mode: AppServerCapabilityMode = .stable
    ) async throws -> InitializeResponse {
        guard case .disconnected = connectionState else {
            throw ConnAppServerConnectionError.connectionAlreadyActive
        }

        generation &+= 1
        let activeGeneration = generation
        connectionState = .connecting(generation: activeGeneration)
        compatibility = .init(version: serverVersion, mode: mode)
        let store = RequestCorrelationStore(
            historyLimit: configuration.maximumTraceEntries,
            uniquenessPolicy: .monotonicallyIncreasingIntegers
        )
        correlation = store
        initializeAttemptedGeneration = nil
        inbound.removeAll(keepingCapacity: true)
        inboundBytes = 0
        nextInboundSequence = 0
        responsePositions.removeAll(keepingCapacity: true)
        unresolvedServerRequests.removeAll(keepingCapacity: true)

        do {
            let selectedTransport = transport
            try await withConnTimeout(configuration.connectTimeout, operation: .connect) {
                try await selectedTransport.connect(to: endpoint)
            }
            try requireGeneration(activeGeneration)
            trace.recordLocal(generation: activeGeneration, envelope: .transport, method: "connected")

            receiveTask = Task { [weak self] in
                await self?.runReceiveLoop(generation: activeGeneration, transport: selectedTransport)
            }

            let initialized = try await initialize(generation: activeGeneration, mode: mode)
            try requireGeneration(activeGeneration)
            connectionState = .ready(generation: activeGeneration, version: serverVersion)
            return initialized
        } catch {
            await failAndDisconnect(generation: activeGeneration)
            throw Self.publicError(error, operation: .connect)
        }
    }

    @discardableResult
    public func reconnect(
        to endpoint: ControlEndpoint,
        serverVersion: SupportedAppServerVersion,
        mode: AppServerCapabilityMode = .stable
    ) async throws -> InitializeResponse {
        await disconnect()
        return try await connect(to: endpoint, serverVersion: serverVersion, mode: mode)
    }

    public func disconnect() async {
        switch connectionState {
        case .disconnected, .disconnecting:
            return
        case .connecting, .ready, .failed:
            break
        }
        let invalidatedGeneration = generation
        generation &+= 1
        let disconnectGeneration = generation
        connectionState = .disconnecting(generation: disconnectGeneration)
        compatibility = nil
        initializeAttemptedGeneration = nil
        let oldReceiveTask = receiveTask
        receiveTask = nil
        oldReceiveTask?.cancel()

        if let store = correlation {
            for id in pendingRequestIDs { _ = await store.cancel(id) }
        }
        correlation = nil
        pendingRequestIDs.removeAll(keepingCapacity: true)
        inbound.removeAll(keepingCapacity: true)
        inboundBytes = 0
        responsePositions.removeAll(keepingCapacity: true)
        unresolvedServerRequests.removeAll(keepingCapacity: true)
        trace.recordLocal(generation: invalidatedGeneration, envelope: .transport, method: "disconnected")
        await transport.disconnect()
        if generation == disconnectGeneration {
            connectionState = .disconnected
        }
    }

    /// Sends one request exactly once. Timeout and caller cancellation remove
    /// local correlation state; neither condition causes automatic replay.
    public func request(
        method: String,
        params: JSONValue? = nil,
        timeout: Duration? = nil
    ) async throws -> JSONValue {
        try await requestEnvelope(method: method, params: params, timeout: timeout).result
    }

    /// Sends one request and returns the response's exact position relative to
    /// notifications and server requests received on the same generation.
    public func requestEnvelope(
        method: String,
        params: JSONValue? = nil,
        timeout: Duration? = nil
    ) async throws -> ConnAppServerResponseEnvelope {
        guard case let .ready(activeGeneration, _) = connectionState,
              let policy = compatibility,
              let store = correlation
        else { throw ConnAppServerConnectionError.notConnected }

        try policy.requireSupport(for: method)
        return try await requestOnce(
            method: method,
            params: params,
            generation: activeGeneration,
            store: store,
            timeout: timeout
        )
    }

    /// Answers only a server request observed in the active generation.
    public func respond(to requestID: RequestID, result: JSONValue) async throws {
        guard case let .ready(activeGeneration, _) = connectionState,
              let policy = compatibility else {
            throw ConnAppServerConnectionError.notConnected
        }
        guard let method = unresolvedServerRequests[requestID] else {
            throw ConnAppServerConnectionError.unknownServerRequest(requestID)
        }
        try policy.requireServerResponseSupport(for: method)
        try await send(
            .response(.init(id: requestID, result: result)),
            generation: activeGeneration
        )
        try requireGeneration(activeGeneration)
        unresolvedServerRequests.removeValue(forKey: requestID)
    }

    public func drainInboundMessages() -> [ConnAppServerInboundMessage] {
        let values = inbound.map(\.message)
        inbound.removeAll(keepingCapacity: true)
        inboundBytes = 0
        return values
    }

    /// Preferred Phase 7 drain API. It retains exact connection-instance and
    /// receive-order authority for deterministic projection and stale gating.
    public func drainInboundEnvelopes() -> [ConnAppServerInboundEnvelope] {
        let values = inbound
        inbound.removeAll(keepingCapacity: true)
        inboundBytes = 0
        return values
    }

    private func initialize(
        generation activeGeneration: UInt64,
        mode: AppServerCapabilityMode
    ) async throws -> InitializeResponse {
        guard initializeAttemptedGeneration != activeGeneration else {
            throw ConnAppServerConnectionError.initializationAlreadyAttempted
        }
        guard let store = correlation else { throw ConnAppServerConnectionError.notConnected }
        initializeAttemptedGeneration = activeGeneration

        let capabilities = InitializeCapabilities(
            experimentalAPI: mode.enablesExperimentalAPI ? true : nil,
            optOutNotificationMethods: Self.optOutNotificationMethods
        )
        let params = InitializeParams(clientInfo: clientInfo, capabilities: capabilities)
        let paramsValue = try JSONValue.decode(from: JSONEncoder().encode(params))
        let result = try await requestOnce(
            method: "initialize",
            params: paramsValue,
            generation: activeGeneration,
            store: store
        ).result
        let response: InitializeResponse
        do {
            response = try JSONDecoder().decode(InitializeResponse.self, from: result.encodedData())
        } catch {
            throw ConnAppServerConnectionError.invalidResponse(method: "initialize")
        }

        try await send(
            .notification(.init(method: "initialized")),
            generation: activeGeneration
        )
        return response
    }

    private func requestOnce(
        method: String,
        params: JSONValue?,
        generation activeGeneration: UInt64,
        store: RequestCorrelationStore,
        timeout: Duration? = nil
    ) async throws -> ConnAppServerResponseEnvelope {
        try requireGeneration(activeGeneration)
        let requestID = nextRequestID()
        try await store.register(requestID)
        pendingRequestIDs.insert(requestID)

        do {
            try await send(
                .request(.init(id: requestID, method: method, params: params)),
                generation: activeGeneration
            )
            let response = try await withConnTimeout(
                timeout ?? configuration.requestTimeout,
                operation: .request
            ) {
                try await store.response(for: requestID)
            }
            try requireGeneration(activeGeneration)
            pendingRequestIDs.remove(requestID)

            guard let position = responsePositions.removeValue(forKey: requestID) else {
                throw ConnAppServerConnectionError.invalidResponse(method: method)
            }

            switch response {
            case let .success(value):
                return ConnAppServerResponseEnvelope(
                    connection: position.0,
                    sequence: position.1,
                    result: value.result
                )
            case let .failure(value):
                throw ConnAppServerConnectionError.server(method: method, code: value.error.code)
            }
        } catch {
            _ = await store.cancel(requestID)
            pendingRequestIDs.remove(requestID)
            responsePositions.removeValue(forKey: requestID)
            throw error
        }
    }

    private func send(_ message: JSONRPCWireMessage, generation activeGeneration: UInt64) async throws {
        try requireGeneration(activeGeneration)
        let text = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
        let selectedTransport = transport
        do {
            try await withConnTimeout(configuration.sendTimeout, operation: .send) {
                try await selectedTransport.send(text: text)
            }
        } catch {
            throw Self.publicError(error, operation: .send)
        }
        try requireGeneration(activeGeneration)
        trace.record(message, generation: activeGeneration, direction: .outbound)
    }

    private func runReceiveLoop(
        generation activeGeneration: UInt64,
        transport selectedTransport: any ControlTransport
    ) async {
        while !Task.isCancelled {
            do {
                let text: String
                if let receiveTimeout = configuration.receiveTimeout {
                    text = try await withConnTimeout(receiveTimeout, operation: .receive) {
                        try await selectedTransport.receiveText()
                    }
                } else {
                    // Silence is healthy. EOF/transport failure is the default
                    // liveness signal; diagnostic callers may opt into a bound.
                    text = try await selectedTransport.receiveText()
                }
                guard activeGeneration == generation else { return }

                let message: JSONRPCWireMessage
                do {
                    message = try JSONRPCWireMessage(data: Data(text.utf8))
                } catch {
                    trace.recordLocal(generation: activeGeneration, envelope: .unknown)
                    continue
                }
                try await dispatch(message, generation: activeGeneration)
            } catch is CancellationError {
                return
            } catch {
                await failAndDisconnect(generation: activeGeneration)
                return
            }
        }
    }

    private func dispatch(_ message: JSONRPCWireMessage, generation activeGeneration: UInt64) async throws {
        try requireGeneration(activeGeneration)

        if case let .notification(notification) = message,
           notification.method == Self.reasoningTextDeltaMethod
        {
            trace.recordLocal(
                generation: activeGeneration,
                envelope: .dropped,
                method: Self.reasoningTextDeltaMethod
            )
            return
        }

        trace.record(message, generation: activeGeneration, direction: .inbound)
        switch message {
        case .response, .error:
            if let correlation {
                let responseID: RequestID
                switch message {
                case let .response(response): responseID = response.id
                case let .error(response): responseID = response.id
                default: preconditionFailure("response branch received a non-response")
                }
                let position = try nextReceivePosition(generation: activeGeneration)
                let recordedPosition: Bool
                if pendingRequestIDs.contains(responseID), responsePositions[responseID] == nil {
                    // Record before resolving: resolve may resume the waiting
                    // request, which can then re-enter this connection actor.
                    responsePositions[responseID] = (position.connection, position.sequence)
                    recordedPosition = true
                } else {
                    recordedPosition = false
                }
                let disposition = await correlation.resolve(message)
                try requireGeneration(activeGeneration)
                switch disposition {
                case .stored, .resumedWaiter:
                    break
                case .recorded, .ignoredNonResponse:
                    if recordedPosition,
                       responsePositions[responseID]?.1 == position.sequence {
                        responsePositions.removeValue(forKey: responseID)
                    }
                }
            }
        case let .request(request):
            guard unresolvedServerRequests.count < configuration.maximumInboundMessages,
                  unresolvedServerRequests[request.id] == nil
            else { throw ConnAppServerConnectionError.inboundQueueOverflow }
            unresolvedServerRequests[request.id] = request.method
            try enqueue(.request(request), generation: activeGeneration)
        case let .notification(notification):
            if notification.method == "serverRequest/resolved",
               let requestValue = notification.params?.objectValue?["requestId"],
               let requestID = RequestID(jsonValue: requestValue) {
                unresolvedServerRequests.removeValue(forKey: requestID)
            }
            try enqueue(.notification(notification), generation: activeGeneration)
        case .unknown:
            break
        }
    }

    private func enqueue(
        _ message: ConnAppServerInboundMessage,
        generation activeGeneration: UInt64
    ) throws {
        let position = try nextReceivePosition(generation: activeGeneration)
        let envelope = ConnAppServerInboundEnvelope(
            connection: position.connection,
            sequence: position.sequence,
            message: message
        )
        let bytes = envelope.byteCount
        guard bytes <= configuration.maximumInboundBytes else {
            if envelope.isSheddable { return }
            throw ConnAppServerConnectionError.inboundQueueOverflow
        }

        while inbound.count >= configuration.maximumInboundMessages
            || inboundBytes + bytes > configuration.maximumInboundBytes
        {
            guard let notificationIndex = inbound.firstIndex(where: \.isSheddable) else {
                // A sheddable incoming notification is less authoritative than
                // every required fact already queued. Drop it rather than
                // turning healthy resume noise into a reconnect.
                if envelope.isSheddable { return }
                throw ConnAppServerConnectionError.inboundQueueOverflow
            }
            inboundBytes -= inbound.remove(at: notificationIndex).byteCount
        }
        inbound.append(envelope)
        inboundBytes += bytes
    }

    private func nextReceivePosition(
        generation activeGeneration: UInt64
    ) throws -> (connection: ConnAppServerConnectionIdentity, sequence: UInt64) {
        try requireGeneration(activeGeneration)
        guard nextInboundSequence < UInt64.max else {
            throw ConnAppServerConnectionError.inboundQueueOverflow
        }
        nextInboundSequence += 1
        return (
            ConnAppServerConnectionIdentity(
                instanceID: instanceID,
                generation: activeGeneration
            ),
            nextInboundSequence
        )
    }

    private func failAndDisconnect(generation activeGeneration: UInt64) async {
        guard activeGeneration == generation else { return }
        generation &+= 1
        connectionState = .failed(generation: activeGeneration)
        receiveTask?.cancel()
        receiveTask = nil
        if let store = correlation {
            for id in pendingRequestIDs { _ = await store.cancel(id) }
        }
        correlation = nil
        pendingRequestIDs.removeAll(keepingCapacity: true)
        compatibility = nil
        inbound.removeAll(keepingCapacity: true)
        inboundBytes = 0
        responsePositions.removeAll(keepingCapacity: true)
        unresolvedServerRequests.removeAll(keepingCapacity: true)
        await transport.disconnect()
    }

    private func requireGeneration(_ expected: UInt64) throws {
        guard expected == generation else { throw ConnAppServerConnectionError.staleConnection }
    }

    private func nextRequestID() -> RequestID {
        nextRequestNumber &+= 1
        return .integer(nextRequestNumber)
    }

    private static func publicError(
        _ error: any Error,
        operation: ConnConnectionOperation
    ) -> any Error {
        if error is CancellationError { return CancellationError() }
        if let error = error as? ConnAppServerConnectionError { return error }
        return ConnAppServerConnectionError.transportFailure(operation)
    }
}

private func withConnTimeout<T: Sendable>(
    _ duration: Duration,
    operation: ConnConnectionOperation,
    body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw ConnAppServerConnectionError.timedOut(operation)
        }
        guard let result = try await group.next() else {
            throw CancellationError()
        }
        group.cancelAll()
        return result
    }
}
