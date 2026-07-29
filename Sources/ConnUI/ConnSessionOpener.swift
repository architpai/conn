import ConnDomain

public enum ConnSessionOpenAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)
}

/// Composition-owned routing for opening a Session in its original Harness.
/// Adapters do not receive an `open` action because opening is an app concern.
public struct AnyConnSessionOpener: Sendable {
    private let availabilityClosure:
        @Sendable (ConnSessionID) -> ConnSessionOpenAvailability
    private let openClosure: @Sendable (ConnSessionID) async -> Bool

    public init(
        availability: @escaping @Sendable (ConnSessionID) -> ConnSessionOpenAvailability,
        open: @escaping @Sendable (ConnSessionID) async -> Bool
    ) {
        availabilityClosure = availability
        openClosure = open
    }

    public func availability(
        for sessionID: ConnSessionID
    ) -> ConnSessionOpenAvailability {
        availabilityClosure(sessionID)
    }

    public func open(_ sessionID: ConnSessionID) async -> Bool {
        guard availability(for: sessionID) == .available else { return false }
        return await openClosure(sessionID)
    }

    public static let unavailable = AnyConnSessionOpener(
        availability: { _ in .unavailable(reason: "No opening route is available") },
        open: { _ in false }
    )
}
