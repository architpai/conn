import Foundation
import ConnDomain

/// Serializes App Server projection mutation with its bounded durable cache.
/// The domain actor owns rollback so runtime-only request authority is restored
/// exactly when a checkpoint write fails.
public actor AppServerDomainCoordinator {
    private let domain: AppServerProjectionStore
    private let checkpointStore: AppServerDomainCheckpointFileStore?
    private let persistenceDebounce: Duration
    private var persistenceTask: Task<Void, Never>?
    private var pendingCheckpointDate: Date?
    private var lastPersistenceDiagnostic: String?

    public init(
        domain: AppServerProjectionStore,
        checkpointStore: AppServerDomainCheckpointFileStore,
        persistenceDebounce: Duration = .milliseconds(250)
    ) {
        self.domain = domain
        self.checkpointStore = checkpointStore
        self.persistenceDebounce = persistenceDebounce
    }

    /// Live monitoring can continue without a durable cache when the disposable
    /// cache cannot be repaired. App Server remains authoritative.
    public init(domain: AppServerProjectionStore) {
        self.domain = domain
        checkpointStore = nil
        persistenceDebounce = .milliseconds(250)
        lastPersistenceDiagnostic = "The private App Server cache is unavailable; monitoring remains live without durable rows."
    }

    /// Restores only the separately discriminated App Server cache. The domain
    /// store guarantees every restored row is stale and non-actionable.
    @discardableResult
    public func restoreCheckpoint() async throws -> Bool {
        guard let checkpointStore,
              let checkpoint = try checkpointStore.load() else { return false }
        try await domain.restore(from: checkpoint)
        return true
    }

    /// Actor-isolated mutate -> checkpoint -> durable save with full rollback.
    /// Consequential action replay is intentionally outside this coordinator.
    @discardableResult
    public func applyAndPersist(
        _ input: AppServerProjectionInput,
        checkpointedAt date: Date = Date()
    ) async throws -> AppServerProjectionApplyResult {
        let result = await domain.apply(input)
        if result == .applied || result == .appliedPendingSnapshot {
            schedulePersistence(checkpointedAt: date)
        }
        return result
    }

    public func snapshot(at date: Date = Date()) async -> AppServerProjectionSnapshot {
        await domain.snapshot(at: date)
    }

    public func storageMetrics() async -> AppServerProjectionStorageMetrics {
        await domain.storageMetrics()
    }

    public func persistenceDiagnostic() -> String? {
        lastPersistenceDiagnostic
    }

    /// Deterministic test/shutdown seam. Ordinary inputs are debounced so a
    /// notification burst does not encode and fsync once per fact.
    public func flushPersistence() async {
        persistenceTask?.cancel()
        persistenceTask = nil
        await persistPendingCheckpoint()
    }

    private func schedulePersistence(checkpointedAt date: Date) {
        guard checkpointStore != nil else { return }
        pendingCheckpointDate = date
        persistenceTask?.cancel()
        let delay = persistenceDebounce
        persistenceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await self?.persistPendingCheckpoint()
        }
    }

    private func persistPendingCheckpoint() async {
        guard let checkpointStore,
              let checkpointedAt = pendingCheckpointDate else { return }
        pendingCheckpointDate = nil
        let checkpoint = await domain.checkpoint(at: checkpointedAt)
        do {
            _ = try checkpointStore.save(checkpoint)
            lastPersistenceDiagnostic = nil
        } catch {
            // The cache is disposable. A persistence wall must never roll back
            // live projection state or turn a healthy daemon session into a
            // reconnect loop.
            lastPersistenceDiagnostic = "Conn could not update its private App Server cache; live monitoring continues."
        }
    }
}

/// Pre-commit authority for actions captured from one exact App Server
/// connection and coordinator. Runtime identity is never persisted.
public struct AppServerDomainCommitIdentity: Equatable, Sendable {
    public let connection: AppServerConnectionIdentity
    private let coordinatorIdentifier: ObjectIdentifier

    public init(
        connection: AppServerConnectionIdentity,
        coordinator: AppServerDomainCoordinator
    ) {
        self.connection = connection
        coordinatorIdentifier = ObjectIdentifier(coordinator)
    }
}

/// Phase 4.5's generation/commit protection applied to App Server authority.
/// This is a pre-commit check; it does not claim transactional revocation after
/// the commit closure has begun.
public enum AppServerDomainCommitGate {
    @discardableResult
    public static func performIfCurrent<Result: Sendable>(
        isolation: isolated (any Actor)? = #isolation,
        captured: AppServerDomainCommitIdentity,
        current: () -> AppServerDomainCommitIdentity?,
        commit: () async throws -> Result
    ) async rethrows -> Result? {
        _ = isolation
        guard captured == current() else { return nil }
        return try await commit()
    }
}
