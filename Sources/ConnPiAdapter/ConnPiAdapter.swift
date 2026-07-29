import Foundation
import ConnDomain

public enum PiExternalIntegrationIdentity {
    public static let harnessID = HarnessID(rawValue: "pi")
    public static let integrationID = IntegrationID(rawValue: "pi.external")
    public static let descriptor = IntegrationDescriptor(
        id: integrationID,
        harnessID: harnessID,
        displayName: "Pi"
    )
}

public actor PiExternalIntegration: ConnIntegration {
    public nonisolated let descriptor = PiExternalIntegrationIdentity.descriptor

    public init() {}

    public func establishFeed() async throws(ConnIntegrationError) -> ConnIntegrationFeed {
        throw .unavailable
    }

    public func perform(_ action: ConnAction) async -> ConnActionOutcome {
        .init(
            integrationID: descriptor.id,
            action: action.kind,
            kind: .unavailable,
            evidence: "External Pi is not connected"
        )
    }

    public func disconnect() async {}
}
