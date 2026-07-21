// Optional Level 3 adapter; never required for hook observation.

public enum ControlTransportKind: String, Equatable, Sendable {
    case direct
    case proxy
}

public protocol ControlTransport: Sendable {
    func connect(to endpoint: ControlEndpoint) async throws
    func send(text: String) async throws
    func receiveText() async throws -> String
    func disconnect() async
    func observations() async -> [ControlTransportObservation]
}
