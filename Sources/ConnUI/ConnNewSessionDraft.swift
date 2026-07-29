import ConnDomain

/// Conn-owned state before a Harness Session exists. The draft has no Session
/// identity and never appears in provider inventory or the sidebar.
public struct ConnNewSessionDraft: Equatable, Sendable {
    public private(set) var isPresented = false
    public private(set) var integrationID: IntegrationID?
    public var workspace = ""
    public var message = ""
    public var modelID: ConnSessionModelID?
    public var reasoningEffortID: ConnReasoningEffortID?
    public private(set) var pendingSessionID: ConnSessionID?

    public init() {}

    public var isAwaitingCreatedSession: Bool {
        pendingSessionID != nil
    }

    public var requiresDefaultWorkspace: Bool {
        workspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public mutating func present(
        integrationID: IntegrationID,
        defaultWorkspace: String
    ) {
        if self.integrationID == nil {
            self.integrationID = integrationID
        }
        applyDefaultWorkspaceIfNeeded(defaultWorkspace)
        isPresented = true
    }

    public mutating func hide() {
        guard pendingSessionID == nil else { return }
        isPresented = false
    }

    public mutating func applyDefaultWorkspaceIfNeeded(
        _ defaultWorkspace: String
    ) {
        guard requiresDefaultWorkspace else { return }
        workspace = defaultWorkspace
    }

    public mutating func markCreationAccepted(
        _ sessionID: ConnSessionID
    ) {
        guard sessionID.integrationID == integrationID else { return }
        pendingSessionID = sessionID
        isPresented = true
    }

    @discardableResult
    public mutating func reconcile(
        availableSessionIDs: Set<ConnSessionID>
    ) -> ConnSessionID? {
        guard let pendingSessionID,
              availableSessionIDs.contains(pendingSessionID) else {
            return nil
        }
        self = .init()
        return pendingSessionID
    }

    @discardableResult
    public mutating func reconcile(
        availableSessionIDs: [ConnSessionID]
    ) -> ConnSessionID? {
        reconcile(availableSessionIDs: Set(availableSessionIDs))
    }
}
