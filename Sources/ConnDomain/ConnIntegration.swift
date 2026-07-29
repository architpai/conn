import Foundation

public struct IntegrationDescriptor: Codable, Equatable, Sendable {
    public let id: IntegrationID
    public let harnessID: HarnessID
    public let displayName: String

    public init(
        id: IntegrationID,
        harnessID: HarnessID,
        displayName: String,
        bounds: ConnDomainBounds = .default
    ) {
        self.id = id
        self.harnessID = harnessID
        self.displayName = ConnDomainBounds.boundedSingleLine(
            displayName,
            maximumUTF8Bytes: bounds.maximumTitleUTF8Bytes
        )
    }
}

public struct IntegrationSnapshot: Equatable, Sendable {
    public let integration: IntegrationDescriptor
    public let generation: IntegrationConnectionGeneration
    public let throughSequence: UInt64
    public let inventoryAuthority: InventoryAuthority
    public let capabilities: IntegrationCapabilities
    public let sessions: [ConnSession]
    public let attentionRequests: [AttentionRequest]
    public let observedAt: Date

    public init(
        integration: IntegrationDescriptor,
        generation: IntegrationConnectionGeneration,
        throughSequence: UInt64,
        inventoryAuthority: InventoryAuthority,
        capabilities: IntegrationCapabilities,
        sessions: [ConnSession],
        attentionRequests: [AttentionRequest] = [],
        observedAt: Date
    ) {
        self.integration = integration
        self.generation = generation
        self.throughSequence = throughSequence
        self.inventoryAuthority = inventoryAuthority
        self.capabilities = capabilities
        self.sessions = sessions
        self.attentionRequests = attentionRequests
        self.observedAt = observedAt
    }
}

public enum IntegrationSemanticUpdate: Equatable, Sendable {
    case sessionUpsert(ConnSession)
    case sessionRemoved(ConnSessionID)
    case activityUpsert(sessionID: ConnSessionID, activity: ConnActivity)
    case attentionUpsert(AttentionRequest)
    case attentionRemoved(sessionID: ConnSessionID, requestID: AttentionRequestID)
    case inventoryAuthorityChanged(InventoryAuthority)
    case authorityLost
}

public struct IntegrationUpdate: Equatable, Sendable {
    public let integrationID: IntegrationID
    public let cursor: IntegrationUpdateCursor
    public let observedAt: Date
    public let update: IntegrationSemanticUpdate

    public init(
        integrationID: IntegrationID,
        cursor: IntegrationUpdateCursor,
        observedAt: Date,
        update: IntegrationSemanticUpdate
    ) {
        self.integrationID = integrationID
        self.cursor = cursor
        self.observedAt = observedAt
        self.update = update
    }
}

public enum ConnIntegrationError: Error, Equatable, Sendable {
    case unavailable
    case qualificationFailed
    case connectionInvalidated
}

public struct ConnIntegrationFeed: Sendable {
    public let snapshot: IntegrationSnapshot
    /// Ending the stream invalidates current authority. Implementations emit
    /// `.authorityLost` when it can be delivered safely; consumers must still
    /// fail stale on termination because unsafe overflow may prevent delivery.
    public let updates: AsyncStream<IntegrationUpdate>

    public init(
        snapshot: IntegrationSnapshot,
        updates: AsyncStream<IntegrationUpdate>
    ) {
        self.snapshot = snapshot
        self.updates = updates
    }
}

/// Provider-neutral asynchronous port. Implementations serialize feed
/// publication, connection generation, and action authority internally.
public protocol ConnIntegration: Sendable {
    var descriptor: IntegrationDescriptor { get }
    func establishFeed() async throws(ConnIntegrationError) -> ConnIntegrationFeed
    func sessionModels(
        for sessionID: ConnSessionID?
    ) async -> ConnSessionModelCatalogResult
    func perform(_ action: ConnAction) async -> ConnActionOutcome
    func disconnect() async
}

public extension ConnIntegration {
    func sessionModels(
        for sessionID: ConnSessionID?
    ) async -> ConnSessionModelCatalogResult {
        .init(outcome: .unavailable)
    }

    func disconnect() async {}
}
