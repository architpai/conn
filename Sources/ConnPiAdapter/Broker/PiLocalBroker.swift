import Darwin
import Foundation

public enum PiLocalBrokerError: Error, Equatable, Sendable {
    case alreadyRunning
    case socketPathTooLong
    case unsafeSocketDirectory
    case socketSetupFailed
    case runtimeDescriptorFailed
}

public struct PiLiveRegistration: Equatable, Sendable {
    public let handshake: PiBridgeHandshake
    public let connectedAt: Date
}

public enum PiLocalBrokerEvent: Equatable, Sendable {
    case registered(PiLiveRegistration)
    case stateChanged(
        sessionID: String,
        state: PiBridgeState,
        event: String,
        activity: PiBridgeActivity?
    )
    case attentionOpened(
        sessionID: String,
        state: PiBridgeState,
        request: PiBridgeAttentionRequest
    )
    case attentionClosed(sessionID: String, requestID: String)
    case disconnected(sessionID: String, instanceID: String)
}

public enum PiBrokerCommandResult: Equatable, Sendable {
    case accepted(PiBridgeState)
    case rejected(error: String, state: PiBridgeState)
    case acknowledgementUncertain
}

public struct PiLocalBrokerFeed: Sendable {
    public let registrations: [PiLiveRegistration]
    public let events: AsyncStream<PiLocalBrokerEvent>
}

public struct PiEffectiveModelState: Equatable, Sendable {
    public let provider: String
    public let modelID: String
    public let thinkingLevel: String
}

public actor PiLocalBroker {
    private let runtimeStore: PiRuntimeDescriptorStore
    private let socketURL: URL
    private var features: PiBrokerOptionalFeatures
    private var server: PiUnixSocketServer?
    private var descriptor: PiBrokerRuntimeDescriptor?
    private var leaseTask: Task<Void, Never>?
    private var clients: [UUID: PiBrokerClient] = [:]
    private var registrationsByClient: [UUID: PiLiveRegistration] = [:]
    private var latestStateByClient: [UUID: PiBridgeState] = [:]
    private var pendingCommands: [String: PendingPiCommand] = [:]
    private var attentionByID: [String: PiBridgeAttentionRequest] = [:]
    private var observers:
        [UUID: AsyncStream<PiLocalBrokerEvent>.Continuation] = [:]

    public init(
        runtimeStore: PiRuntimeDescriptorStore,
        socketURL: URL,
        features: PiBrokerOptionalFeatures
    ) {
        self.runtimeStore = runtimeStore
        self.socketURL = socketURL.standardizedFileURL
        self.features = features
    }

    public func start(
        now: Date = Date(),
        timeToLive: TimeInterval = 30
    ) throws(PiLocalBrokerError) -> PiBrokerRuntimeDescriptor {
        guard server == nil else { throw .alreadyRunning }
        let server: PiUnixSocketServer
        do {
            server = try PiUnixSocketServer(
                socketURL: socketURL,
                onAccept: { [weak self] client in
                    Task { await self?.accepted(client) }
                },
                onFrame: { [weak self] clientID, data in
                    Task { await self?.received(data, from: clientID) }
                },
                onClose: { [weak self] clientID in
                    Task { await self?.closed(clientID) }
                }
            )
        } catch PiUnixSocketServerError.pathTooLong {
            throw .socketPathTooLong
        } catch PiUnixSocketServerError.unsafeParent {
            throw .unsafeSocketDirectory
        } catch {
            throw .socketSetupFailed
        }
        do {
            let descriptor = try runtimeStore.publish(
                socketURL: socketURL,
                features: features,
                now: now,
                timeToLive: timeToLive
            )
            self.server = server
            self.descriptor = descriptor
            server.resume()
            leaseTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled else { return }
                    await self?.refreshLease()
                }
            }
            return descriptor
        } catch {
            server.stop()
            throw .runtimeDescriptorFailed
        }
    }

    public func stop() {
        leaseTask?.cancel()
        leaseTask = nil
        descriptor = nil
        registrationsByClient.removeAll()
        latestStateByClient.removeAll()
        pendingCommands.values.forEach {
            $0.continuation.resume(returning: .acknowledgementUncertain)
        }
        pendingCommands.removeAll()
        attentionByID.removeAll()
        observers.values.forEach { $0.finish() }
        observers.removeAll()
        let activeClients = clients.values
        clients.removeAll()
        activeClients.forEach { $0.close() }
        server?.stop()
        server = nil
        try? runtimeStore.invalidate()
    }

    public func registrations() -> [PiLiveRegistration] {
        registrationsByClient.values.sorted {
            $0.handshake.sessionID < $1.handshake.sessionID
        }
    }

    public func optionalFeatures() -> PiBrokerOptionalFeatures {
        features
    }

    public func attentionRequest(
        id: String
    ) -> PiBridgeAttentionRequest? {
        attentionByID[id]
    }

    public func effectiveModelState(
        for sessionID: String
    ) -> PiEffectiveModelState? {
        if let state = latestStateByClient.values.first(where: {
            $0.sessionID == sessionID
        }) {
            return .init(
                provider: state.modelProvider,
                modelID: state.modelID,
                thinkingLevel: state.thinkingLevel
            )
        }
        guard let handshake = registrationsByClient.values.first(where: {
            $0.handshake.sessionID == sessionID
        })?.handshake else {
            return nil
        }
        return .init(
            provider: handshake.modelProvider,
            modelID: handshake.modelID,
            thinkingLevel: handshake.thinkingLevel
        )
    }

    public func updateFeatures(_ value: PiBrokerOptionalFeatures) {
        if descriptor != nil {
            stop()
        }
        features = value
    }

    public func feed() -> PiLocalBrokerFeed {
        let observerID = UUID()
        let events = AsyncStream<PiLocalBrokerEvent>(
            bufferingPolicy: .bufferingNewest(128)
        ) { continuation in
            observers[observerID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(observerID) }
            }
        }
        return .init(registrations: registrations(), events: events)
    }

    public func send(
        _ command: PiBrokerCommand,
        to sessionID: String,
        timeout: Duration = .seconds(5)
    ) async -> PiBrokerCommandResult {
        guard timeout > .zero,
              pendingCommands[command.id] == nil,
              let clientID = registrationsByClient.keys.first(where: {
                  (
                      latestStateByClient[$0]?.sessionID
                          ?? registrationsByClient[$0]?.handshake.sessionID
                  ) == sessionID
              }),
              let client = clients[clientID],
              let data = try? PiBrokerCommandEncoder.encode(command)
        else {
            return .acknowledgementUncertain
        }
        return await withCheckedContinuation { continuation in
            pendingCommands[command.id] = .init(
                clientID: clientID,
                continuation: continuation
            )
            guard client.send(data) else {
                resolveCommand(command.id, with: .acknowledgementUncertain)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.expireCommand(command.id)
            }
        }
    }

    private func accepted(_ client: PiBrokerClient) {
        clients[client.id] = client
    }

    private func refreshLease() {
        guard let descriptor else { return }
        do {
            self.descriptor = try runtimeStore.refresh(
                descriptor,
                timeToLive: 30
            )
        } catch {
            stop()
        }
    }

    private func received(_ data: Data, from clientID: UUID) {
        guard let client = clients[clientID] else { return }
        if registrationsByClient[clientID] != nil {
            do {
                switch try PiBrokerMessageDecoder.decode(data) {
                case let .event(event):
                    latestStateByClient[clientID] = event.state
                    publish(.stateChanged(
                        sessionID: event.state.sessionID,
                        state: event.state,
                        event: event.event,
                        activity: event.activity
                    ))
                case let .response(response):
                    latestStateByClient[clientID] = response.state
                    resolveCommand(
                        response.id,
                        with: response.success
                            ? .accepted(response.state)
                            : .rejected(
                                error: response.error ?? "Pi rejected the command",
                                state: response.state
                            )
                    )
                case let .attention(attention):
                    guard (
                        attention.request.kind == "question"
                            && features.questionsEnabled
                    ) || (
                        attention.request.kind == "approval"
                            && features.approvalsEnabled
                    ) else {
                        client.close()
                        return
                    }
                    latestStateByClient[clientID] = attention.state
                    attentionByID[attention.request.id] = attention.request
                    publish(.attentionOpened(
                        sessionID: attention.state.sessionID,
                        state: attention.state,
                        request: attention.request
                    ))
                case let .attentionResolved(resolved):
                    latestStateByClient[clientID] = resolved.state
                    attentionByID.removeValue(forKey: resolved.requestID)
                    publish(.attentionClosed(
                        sessionID: resolved.state.sessionID,
                        requestID: resolved.requestID
                    ))
                }
            } catch {
                client.close()
            }
            return
        }
        guard let descriptor else {
            clients[clientID]?.close()
            return
        }
        do {
            let handshake = try PiBrokerHandshakeDecoder.decode(
                data,
                expectedGeneration: descriptor.generation,
                expectedSecret: descriptor.authenticationSecret
            )
            guard handshake.piVersion == CONN_PI_SUPPORTED_VERSION_SWIFT,
                  handshake.extensionVersion == "0.2.1" else {
                client.close()
                return
            }
            registrationsByClient[clientID] = .init(
                handshake: handshake,
                connectedAt: Date()
            )
            if let registration = registrationsByClient[clientID] {
                publish(.registered(registration))
            }
            _ = client.send(
                Data(
                    #"{"type":"registered","protocol":1}"#.utf8
                ) + Data([0x0A])
            )
        } catch {
            client.close()
        }
    }

    private func closed(_ clientID: UUID) {
        clients.removeValue(forKey: clientID)
        latestStateByClient.removeValue(forKey: clientID)
        let commandIDs = pendingCommands.compactMap {
            $0.value.clientID == clientID ? $0.key : nil
        }
        commandIDs.forEach {
            resolveCommand($0, with: .acknowledgementUncertain)
        }
        // Any bridge loss invalidates the current Integration generation, so
        // no attention token survives to a later registration.
        attentionByID.removeAll()
        if let registration = registrationsByClient.removeValue(forKey: clientID) {
            publish(.disconnected(
                sessionID: registration.handshake.sessionID,
                instanceID: registration.handshake.instanceID
            ))
        }
    }

    private func publish(_ event: PiLocalBrokerEvent) {
        observers.values.forEach { $0.yield(event) }
    }

    private func removeObserver(_ observerID: UUID) {
        observers.removeValue(forKey: observerID)
    }

    private func expireCommand(_ commandID: String) {
        resolveCommand(commandID, with: .acknowledgementUncertain)
    }

    private func resolveCommand(
        _ commandID: String,
        with result: PiBrokerCommandResult
    ) {
        pendingCommands.removeValue(forKey: commandID)?
            .continuation.resume(returning: result)
    }
}

private struct PendingPiCommand {
    let clientID: UUID
    let continuation: CheckedContinuation<PiBrokerCommandResult, Never>
}

private let CONN_PI_SUPPORTED_VERSION_SWIFT = "0.82.1"

private enum PiUnixSocketServerError: Error {
    case pathTooLong
    case unsafeParent
    case setupFailed
}

private final class PiUnixSocketServer: @unchecked Sendable {
    private let socketURL: URL
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "dev.conn.pi-broker.accept")
    private let onAccept: @Sendable (PiBrokerClient) -> Void
    private let onFrame: @Sendable (UUID, Data) -> Void
    private let onClose: @Sendable (UUID) -> Void
    private let lock = NSLock()
    private var stopped = false

    init(
        socketURL: URL,
        onAccept: @escaping @Sendable (PiBrokerClient) -> Void,
        onFrame: @escaping @Sendable (UUID, Data) -> Void,
        onClose: @escaping @Sendable (UUID) -> Void
    ) throws {
        self.socketURL = socketURL
        self.onAccept = onAccept
        self.onFrame = onFrame
        self.onClose = onClose
        guard socketURL.path.utf8.count < MemoryLayout.size(
            ofValue: sockaddr_un().sun_path
        ) else {
            throw PiUnixSocketServerError.pathTooLong
        }
        let parent = socketURL.deletingLastPathComponent()
        do {
            if brokerFileKind(parent) == .absent {
                try FileManager.default.createDirectory(
                    at: parent,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
        } catch {
            throw PiUnixSocketServerError.unsafeParent
        }
        guard brokerSafeDirectory(parent) else {
            throw PiUnixSocketServerError.unsafeParent
        }
        switch brokerFileKind(socketURL) {
        case .absent:
            break
        case .socket:
            guard brokerOwnedByCurrentUser(socketURL) else {
                throw PiUnixSocketServerError.setupFailed
            }
            try? FileManager.default.removeItem(at: socketURL)
        case .regular, .directory, .other:
            throw PiUnixSocketServerError.setupFailed
        }

        let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { throw PiUnixSocketServerError.setupFailed }
        descriptor = fileDescriptor
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketURL.path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: pathBytes)
        }
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    fileDescriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard bindResult == 0, Darwin.listen(fileDescriptor, 16) == 0,
              Darwin.chmod(socketURL.path, 0o600) == 0 else {
            Darwin.close(fileDescriptor)
            try? FileManager.default.removeItem(at: socketURL)
            throw PiUnixSocketServerError.setupFailed
        }
    }

    func resume() {
        queue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        let shouldStop = lock.withLock {
            guard !stopped else { return false }
            stopped = true
            return true
        }
        guard shouldStop else { return }
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
        try? FileManager.default.removeItem(at: socketURL)
    }

    private func acceptLoop() {
        while !lock.withLock({ stopped }) {
            let clientDescriptor = Darwin.accept(descriptor, nil, nil)
            if clientDescriptor < 0 {
                if lock.withLock({ stopped }) { return }
                continue
            }
            guard brokerPeerUserID(clientDescriptor) == getuid() else {
                Darwin.close(clientDescriptor)
                continue
            }
            var noSignal: Int32 = 1
            guard setsockopt(
                clientDescriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSignal,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else {
                Darwin.close(clientDescriptor)
                continue
            }
            let client = PiBrokerClient(
                descriptor: clientDescriptor,
                onFrame: onFrame,
                onClose: onClose
            )
            onAccept(client)
            client.resume()
        }
    }
}

private final class PiBrokerClient: @unchecked Sendable {
    let id = UUID()
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "dev.conn.pi-broker.client")
    private let onFrame: @Sendable (UUID, Data) -> Void
    private let onClose: @Sendable (UUID) -> Void
    private let lock = NSLock()
    private var closed = false

    init(
        descriptor: Int32,
        onFrame: @escaping @Sendable (UUID, Data) -> Void,
        onClose: @escaping @Sendable (UUID) -> Void
    ) {
        self.descriptor = descriptor
        self.onFrame = onFrame
        self.onClose = onClose
    }

    func resume() {
        queue.async { [weak self] in self?.readLoop() }
    }

    func send(_ data: Data) -> Bool {
        let success = lock.withLock {
            guard !closed else { return false }
            var written = 0
            return data.withUnsafeBytes { bytes -> Bool in
                while written < bytes.count {
                    let result = Darwin.write(
                        descriptor,
                        bytes.baseAddress?.advanced(by: written),
                        bytes.count - written
                    )
                    guard result > 0 else { return false }
                    written += result
                }
                return true
            }
        }
        if !success { close() }
        return success
    }

    func close() {
        let shouldClose = lock.withLock {
            guard !closed else { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
        onClose(id)
    }

    private func readLoop() {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8 * 1024)
        while !lock.withLock({ closed }) {
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            guard count > 0 else {
                close()
                return
            }
            buffer.append(contentsOf: chunk.prefix(count))
            guard buffer.count <= PiBrokerProtocolBounds.maximumFrameBytes else {
                close()
                return
            }
            while let newline = buffer.firstIndex(of: 0x0A) {
                let frame = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard !frame.isEmpty else { continue }
                onFrame(id, frame)
            }
        }
    }
}

private enum BrokerFileKind {
    case absent
    case regular
    case directory
    case socket
    case other
}

private func brokerFileKind(_ url: URL) -> BrokerFileKind {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
        return errno == ENOENT ? .absent : .other
    }
    switch metadata.st_mode & mode_t(S_IFMT) {
    case mode_t(S_IFREG): return .regular
    case mode_t(S_IFDIR): return .directory
    case mode_t(S_IFSOCK): return .socket
    default: return .other
    }
}

private func brokerSafeDirectory(_ url: URL) -> Bool {
    var metadata = stat()
    return lstat(url.path, &metadata) == 0
        && metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        && metadata.st_uid == getuid()
        && metadata.st_mode & mode_t(S_IRWXG | S_IRWXO) == 0
}

private func brokerOwnedByCurrentUser(_ url: URL) -> Bool {
    var metadata = stat()
    return lstat(url.path, &metadata) == 0 && metadata.st_uid == getuid()
}

private func brokerPeerUserID(_ descriptor: Int32) -> uid_t? {
    var credentials = xucred()
    var length = socklen_t(MemoryLayout<xucred>.size)
    let result = withUnsafeMutablePointer(to: &credentials) {
        getsockopt(
            descriptor,
            SOL_LOCAL,
            LOCAL_PEERCRED,
            $0,
            &length
        )
    }
    return result == 0 ? credentials.cr_uid : nil
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
