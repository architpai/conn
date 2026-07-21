public struct ControlTransportObservation: Equatable, Sendable {
    public enum Event: String, Equatable, Sendable {
        case connectionStarted
        case webSocketUpgrade
        case proxyStarted
        case message
        case cleanClose
        case protocolClose
        case cancelled
        case timeout
        case failure
        case proxyExited
        case streamHalfClosed
        case diagnosticBytes
        case bufferLimitExceeded
    }

    public enum Direction: String, Equatable, Sendable {
        case inbound
        case outbound
    }

    public let transport: ControlTransportKind
    public let event: Event
    public let direction: Direction?
    public let opcode: String?
    public let byteCount: Int?
    public let closeCode: UInt16?
    public let exitStatus: Int32?
    public let isTruncated: Bool

    public init(
        transport: ControlTransportKind,
        event: Event,
        direction: Direction? = nil,
        opcode: String? = nil,
        byteCount: Int? = nil,
        closeCode: UInt16? = nil,
        exitStatus: Int32? = nil,
        isTruncated: Bool = false
    ) {
        self.transport = transport
        self.event = event
        self.direction = direction
        self.opcode = opcode
        self.byteCount = byteCount
        self.closeCode = closeCode
        self.exitStatus = exitStatus
        self.isTruncated = isTruncated
    }
}
