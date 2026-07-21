import Foundation

/// Deterministically reduces privacy-safe App Server snapshots and deltas.
/// Connection authority and unresolved requests are runtime-only; checkpoints
/// contain a bounded presentation cache that always restores as stale.
public actor AppServerProjectionStore {
    private struct RequestKey: Hashable, Sendable {
        let threadID: AppServerThreadID
        let requestID: AppServerRequestID
    }

    private struct StoredRequest: Equatable, Sendable {
        var value: AppServerProjectedRequest
        var sequence: UInt64
    }

    private struct StoredItem: Equatable, Sendable {
        var value: AppServerProjectedItem
        var sequence: UInt64
        var order: Int
        var terminalConflict: Bool
    }

    private struct PresentationLocation: Hashable, Sendable {
        let threadID: AppServerThreadID
        let turnID: AppServerTurnID
        let itemID: AppServerItemID
    }

    private struct PlanLocation: Hashable, Sendable {
        let threadID: AppServerThreadID
        let turnID: AppServerTurnID
    }

    private struct StoredTurn: Equatable, Sendable {
        var id: AppServerTurnID
        var status: AppServerTurnStatus
        var startedAt: Date?
        var completedAt: Date?
        var itemsView: AppServerTurnItemsView
        var items: [AppServerItemID: StoredItem]
        var plan: AppServerTurnPlan?
        var planSequence: UInt64
        var planConflict: Bool
        var sequence: UInt64
        var terminalConflict: Bool
    }

    private struct StoredThread: Equatable, Sendable {
        var id: AppServerThreadID
        var sessionID: AppServerSessionID?
        var title: String?
        var workingDirectoryName: String?
        var workingDirectoryPath: String?
        var projectRootPath: String?
        var gitBranch: String?
        var source: AppServerThreadSource
        var parentThreadID: AppServerThreadID?
        var forkedFromThreadID: AppServerThreadID?
        var status: AppServerThreadStatus
        var freshness: AppServerProjectionFreshness
        var createdAt: Date?
        var updatedAt: Date
        var lastObservedAt: Date
        var turns: [AppServerTurnID: StoredTurn]
        var requests: [RequestKey: StoredRequest]
        var tokenUsage: AppServerTokenUsage?
        var tokenUsageSequence: UInt64
        var tokenUsageConflict: Bool
        var sequence: UInt64
        var metadataSequence: UInt64
        var statusSequence: UInt64
    }

    private struct State: Equatable, Sendable {
        var currentConnection: AppServerConnectionIdentity?
        var connectionSource: AppServerConnectionSource = .managedDaemon
        var featureSupport = AppServerFeatureSupport()
        var threads: [AppServerThreadID: StoredThread] = [:]
        var threadTombstones: [AppServerThreadID: UInt64] = [:]
        var resolvedRequestTombstones: [RequestKey: UInt64] = [:]
        var lastSnapshotSequence: UInt64?
        var requiresSnapshot = false
        var requiresContentSnapshot = false
        var rejectsDeltasUntilReconnect = false
        var hydrationDeltas: [AppServerDeltaInput] = []
    }

    public let configuration: AppServerProjectionConfiguration
    private var state = State()

    public init(configuration: AppServerProjectionConfiguration = .init()) {
        self.configuration = configuration
    }

    @discardableResult
    public func apply(_ input: AppServerProjectionInput) -> AppServerProjectionApplyResult {
        switch input {
        case let .connectionActivated(identity, source, featureSupport):
            return activate(identity: identity, source: source, featureSupport: featureSupport)
        case let .snapshot(snapshot):
            return apply(snapshot)
        case let .delta(delta):
            return apply(delta)
        case let .connectionLost(identity):
            return loseConnection(identity)
        }
    }

    /// Phase 4.5-compatible transaction: runtime authority, tombstones, and all
    /// reducer state roll back together if the synchronous persistence commit
    /// fails. The persistence adapter receives no runtime-only authority.
    @discardableResult
    public func applyAndPersist(
        _ input: AppServerProjectionInput,
        checkpointedAt date: Date,
        persist: @Sendable (AppServerProjectionCheckpoint) throws -> Void
    ) rethrows -> AppServerProjectionApplyResult {
        let previous = state
        let result = apply(input)
        guard result == .applied || result == .appliedPendingSnapshot else {
            return result
        }
        do {
            try persist(makeCheckpoint(at: date))
            return result
        } catch {
            state = previous
            throw error
        }
    }

    public func snapshot(at now: Date = Date()) -> AppServerProjectionSnapshot {
        let threads = state.threads.values
            .map { project($0, now: now) }
            .sorted(by: projectedThreadComesFirst)
        return AppServerProjectionSnapshot(
            connection: state.currentConnection,
            connectionSource: state.connectionSource,
            connectionSourceLabel: state.connectionSource.presentationLabel,
            featureSupport: state.featureSupport,
            threads: threads
        )
    }

    public func checkpoint(at date: Date = Date()) -> AppServerProjectionCheckpoint {
        makeCheckpoint(at: date)
    }

    /// Replaces state only after the entire checkpoint validates. Restored rows
    /// are always stale, feature support is empty, and requests/connection
    /// authority/tombstones are never reconstructed.
    public func restore(from checkpoint: AppServerProjectionCheckpoint) throws {
        guard checkpoint.schemaVersion == AppServerProjectionCheckpoint.currentSchemaVersion else {
            throw AppServerProjectionCheckpointError.unsupportedSchemaVersion(
                checkpoint.schemaVersion
            )
        }
        guard checkpoint.checkpointKind == .appServerProjection,
              checkpoint.threads.count <= configuration.maximumThreads,
              checkpoint.savedAt.timeIntervalSince1970.isFinite
        else { throw AppServerProjectionCheckpointError.invalidCheckpoint }

        var restored = State()
        // Shared Desktop verification is runtime-only and depends on a live
        // exact-thread proof. A cache may remember rows, but it must never
        // restore that proof or its presentation label.
        restored.connectionSource = .managedDaemon
        restored.featureSupport = AppServerFeatureSupport()

        for cached in checkpoint.threads {
            guard validate(cached) else {
                throw AppServerProjectionCheckpointError.invalidCheckpoint
            }
            guard restored.threads[cached.id] == nil else {
                throw AppServerProjectionCheckpointError.invalidCheckpoint
            }
            var turns: [AppServerTurnID: StoredTurn] = [:]
            for projectedTurn in cached.turns {
                guard turns[projectedTurn.id] == nil else {
                    throw AppServerProjectionCheckpointError.invalidCheckpoint
                }
                var items: [AppServerItemID: StoredItem] = [:]
                for (order, projectedItem) in projectedTurn.items.enumerated() {
                    guard items[projectedItem.id] == nil else {
                        throw AppServerProjectionCheckpointError.invalidCheckpoint
                    }
                    items[projectedItem.id] = StoredItem(
                        value: projectedItem,
                        sequence: 0,
                        order: order,
                        terminalConflict: projectedItem.status == .unknown
                    )
                }
                turns[projectedTurn.id] = StoredTurn(
                    id: projectedTurn.id,
                    status: projectedTurn.status,
                    startedAt: projectedTurn.startedAt,
                    completedAt: projectedTurn.completedAt,
                    itemsView: projectedTurn.itemsView,
                    items: items,
                    plan: nil,
                    planSequence: 0,
                    planConflict: false,
                    sequence: 0,
                    terminalConflict: projectedTurn.status == .unknown
                )
            }
            restored.threads[cached.id] = StoredThread(
                id: cached.id,
                sessionID: cached.sessionID,
                title: cached.title,
                workingDirectoryName: cached.workingDirectoryName,
                workingDirectoryPath: cached.workingDirectoryPath,
                projectRootPath: cached.projectRootPath,
                gitBranch: nil,
                source: cached.source,
                parentThreadID: cached.parentThreadID,
                forkedFromThreadID: cached.forkedFromThreadID,
                status: cached.status,
                freshness: .stale,
                createdAt: cached.createdAt,
                updatedAt: cached.updatedAt,
                lastObservedAt: cached.lastObservedAt,
                turns: turns,
                requests: [:],
                tokenUsage: nil,
                tokenUsageSequence: 0,
                tokenUsageConflict: false,
                sequence: 0,
                metadataSequence: 0,
                statusSequence: 0
            )
        }
        state = restored
    }

    public func storageMetrics() -> AppServerProjectionStorageMetrics {
        AppServerProjectionStorageMetrics(
            threadCount: state.threads.count,
            turnCount: state.threads.values.reduce(0) { $0 + $1.turns.count },
            itemCount: state.threads.values.reduce(0) { total, thread in
                total + thread.turns.values.reduce(0) { $0 + $1.items.count }
            },
            presentationByteCount: state.threads.values.reduce(0) { threadTotal, thread in
                threadTotal + thread.turns.values.reduce(0) { turnTotal, turn in
                    turnTotal + planByteCount(turn.plan) + turn.items.values.reduce(0) {
                        $0 + presentationByteCount($1.value.presentation)
                    }
                }
            },
            unresolvedRequestCount: state.threads.values.reduce(0) { $0 + $1.requests.count },
            threadTombstoneCount: state.threadTombstones.count,
            resolvedRequestTombstoneCount: state.resolvedRequestTombstones.count,
            bufferedDeltaCount: state.hydrationDeltas.count,
            requiresSnapshot: state.requiresSnapshot,
            rejectsDeltasUntilReconnect: state.rejectsDeltasUntilReconnect
        )
    }

    private func activate(
        identity: AppServerConnectionIdentity,
        source: AppServerConnectionSource,
        featureSupport: AppServerFeatureSupport
    ) -> AppServerProjectionApplyResult {
        if state.currentConnection == identity {
            guard state.connectionSource != source || state.featureSupport != featureSupport else {
                return .duplicate
            }
            state.connectionSource = source
            state.featureSupport = featureSupport
            return .applied
        }

        state.currentConnection = identity
        state.connectionSource = source
        state.featureSupport = featureSupport
        state.lastSnapshotSequence = nil
        state.requiresSnapshot = true
        state.requiresContentSnapshot = false
        state.rejectsDeltasUntilReconnect = false
        state.hydrationDeltas.removeAll(keepingCapacity: true)
        state.threadTombstones.removeAll(keepingCapacity: true)
        state.resolvedRequestTombstones.removeAll(keepingCapacity: true)
        for id in state.threads.keys {
            guard var thread = state.threads[id] else { continue }
            thread.freshness = .stale
            thread.sequence = 0
            thread.metadataSequence = 0
            thread.statusSequence = 0
            thread.tokenUsage = nil
            thread.tokenUsageSequence = 0
            thread.tokenUsageConflict = false
            thread.requests.removeAll(keepingCapacity: true)
            thread.turns = thread.turns.mapValues { turn in
                var reset = turn
                reset.sequence = 0
                reset.plan = nil
                reset.planSequence = 0
                reset.planConflict = false
                if reset.status == .inProgress {
                    // An active turn ID from a prior connection is cache only.
                    // It becomes current again only through a structured read or
                    // lifecycle fact on this exact connection generation.
                    reset.status = .unknown
                }
                reset.items = turn.items.mapValues { item in
                    var resetItem = item
                    resetItem.sequence = 0
                    return resetItem
                }
                return reset
            }
            state.threads[id] = thread
        }
        return .applied
    }

    private func loseConnection(
        _ identity: AppServerConnectionIdentity
    ) -> AppServerProjectionApplyResult {
        guard state.currentConnection == identity else { return .rejectedStaleConnection }
        state.currentConnection = nil
        state.featureSupport = AppServerFeatureSupport()
        state.lastSnapshotSequence = nil
        state.requiresSnapshot = false
        state.requiresContentSnapshot = false
        state.rejectsDeltasUntilReconnect = false
        state.hydrationDeltas.removeAll(keepingCapacity: true)
        state.threadTombstones.removeAll(keepingCapacity: true)
        state.resolvedRequestTombstones.removeAll(keepingCapacity: true)
        for id in state.threads.keys {
            guard var thread = state.threads[id] else { continue }
            thread.freshness = .stale
            thread.requests.removeAll(keepingCapacity: true)
            state.threads[id] = thread
        }
        return .applied
    }

    private func apply(
        _ snapshot: AppServerSnapshotInput
    ) -> AppServerProjectionApplyResult {
        guard state.currentConnection == snapshot.cursor.connection else {
            return .rejectedStaleConnection
        }
        guard snapshot.observedAt.timeIntervalSince1970.isFinite else {
            return .ignoredInvalidIdentity
        }
        if let previous = state.lastSnapshotSequence, snapshot.cursor.sequence <= previous {
            return .duplicate
        }

        guard Set(snapshot.threads.map(\.id)).count == snapshot.threads.count else {
            return .ignoredInvalidIdentity
        }
        let incomingIDs = Set(snapshot.threads.map(\.id))
        if let authoritativeThreadIDs = snapshot.authoritativeThreadIDs,
           !incomingIDs.isSubset(of: authoritativeThreadIDs)
                || !authoritativeThreadIDs.allSatisfy(validate) {
            return .ignoredInvalidIdentity
        }

        if snapshot.contentAuthority == .metadataOnly {
            return applyMetadataSnapshot(snapshot, incomingIDs: incomingIDs)
        }

        let before = state
        state.threadTombstones = state.threadTombstones.filter {
            $0.value > snapshot.cursor.sequence
        }
        state.requiresSnapshot = false
        state.requiresContentSnapshot = false
        let bufferedDeltas = state.hydrationDeltas
            .filter {
                $0.cursor.connection == snapshot.cursor.connection
                    && $0.cursor.sequence > snapshot.cursor.sequence
            }
            .sorted { $0.cursor.sequence < $1.cursor.sequence }
        state.hydrationDeltas.removeAll(keepingCapacity: true)
        for unboundedThread in snapshot.threads {
            guard validateUnbounded(unboundedThread) else {
                state = before
                return .ignoredInvalidIdentity
            }
            let thread = truncated(unboundedThread)
            _ = upsertThread(
                thread,
                sequence: snapshot.cursor.sequence,
                observedAt: snapshot.observedAt,
                freshness: snapshot.threadFreshness,
                snapshotAuthority: true
            )
        }

        if snapshot.inventoryAuthority == .authoritative {
            let inventoryIDs = snapshot.authoritativeThreadIDs ?? incomingIDs
            for id in state.threads.keys where !inventoryIDs.contains(id) {
                guard let thread = state.threads[id],
                      thread.sequence <= snapshot.cursor.sequence else {
                    continue
                }
                state.threads.removeValue(forKey: id)
            }
        }
        clearRequests(observedThrough: snapshot.cursor.sequence)
        state.lastSnapshotSequence = max(
            state.lastSnapshotSequence ?? snapshot.cursor.sequence,
            snapshot.cursor.sequence
        )
        for delta in bufferedDeltas {
            _ = apply(delta)
        }
        trimState()
        return state == before ? .duplicate : .applied
    }

    /// A `thread/list` response owns tile metadata and inventory membership,
    /// not the live request/turn/item stream. Do not clear request state,
    /// consume recovery buffers, or advance the complete-snapshot fence here:
    /// notifications can be queued while the paginated request is in flight.
    private func applyMetadataSnapshot(
        _ snapshot: AppServerSnapshotInput,
        incomingIDs: Set<AppServerThreadID>
    ) -> AppServerProjectionApplyResult {
        let before = state
        for unboundedThread in snapshot.threads {
            guard validateUnbounded(unboundedThread) else {
                state = before
                return .ignoredInvalidIdentity
            }
            let thread = truncated(metadataOnly(unboundedThread))
            _ = upsertThread(
                thread,
                sequence: snapshot.cursor.sequence,
                observedAt: snapshot.observedAt,
                freshness: snapshot.threadFreshness,
                snapshotAuthority: true,
                advancesRuntimeSequence: false
            )
        }

        if snapshot.inventoryAuthority == .authoritative {
            let inventoryIDs = snapshot.authoritativeThreadIDs ?? incomingIDs
            for id in state.threads.keys where !inventoryIDs.contains(id) {
                guard let thread = state.threads[id],
                      thread.sequence <= snapshot.cursor.sequence else {
                    continue
                }
                state.threads.removeValue(forKey: id)
            }
            // A complete thread/list owns global membership and tile metadata.
            // It can establish or recover that authority without claiming the
            // detailed turn history is a complete snapshot. Replay deltas that
            // arrived while authority was unavailable after installing the
            // inventory baseline.
            if !state.requiresContentSnapshot && !state.rejectsDeltasUntilReconnect {
                let bufferedDeltas = state.hydrationDeltas
                    .filter { $0.cursor.connection == snapshot.cursor.connection }
                    .sorted { $0.cursor.sequence < $1.cursor.sequence }
                state.hydrationDeltas.removeAll(keepingCapacity: true)
                state.requiresSnapshot = false
                for delta in bufferedDeltas {
                    _ = apply(delta)
                }
            }
        }
        trimState()
        return metadataRefreshHasMeaningfulChange(comparedTo: before)
            ? .applied
            : .duplicate
    }

    /// Metadata polling advances an internal ordering fence and observation
    /// timestamp even when the durable/presented row is otherwise identical.
    /// Those bookkeeping-only changes must not schedule another checkpoint.
    private func metadataRefreshHasMeaningfulChange(comparedTo before: State) -> Bool {
        guard state.currentConnection == before.currentConnection,
              state.connectionSource == before.connectionSource,
              state.featureSupport == before.featureSupport,
              state.threadTombstones == before.threadTombstones,
              state.resolvedRequestTombstones == before.resolvedRequestTombstones,
              state.lastSnapshotSequence == before.lastSnapshotSequence,
              state.requiresSnapshot == before.requiresSnapshot,
              state.requiresContentSnapshot == before.requiresContentSnapshot,
              state.rejectsDeltasUntilReconnect == before.rejectsDeltasUntilReconnect,
              state.hydrationDeltas == before.hydrationDeltas,
              state.threads.keys == before.threads.keys
        else { return true }

        for (id, thread) in state.threads {
            guard let prior = before.threads[id],
                  thread.id == prior.id,
                  thread.sessionID == prior.sessionID,
                  thread.title == prior.title,
                  thread.workingDirectoryName == prior.workingDirectoryName,
                  thread.workingDirectoryPath == prior.workingDirectoryPath,
                  thread.projectRootPath == prior.projectRootPath,
                  thread.gitBranch == prior.gitBranch,
                  thread.source == prior.source,
                  thread.parentThreadID == prior.parentThreadID,
                  thread.forkedFromThreadID == prior.forkedFromThreadID,
                  thread.status == prior.status,
                  thread.freshness == prior.freshness,
                  thread.createdAt == prior.createdAt,
                  thread.updatedAt == prior.updatedAt,
                  thread.turns == prior.turns,
                  thread.requests == prior.requests,
                  thread.tokenUsage == prior.tokenUsage,
                  thread.tokenUsageSequence == prior.tokenUsageSequence,
                  thread.tokenUsageConflict == prior.tokenUsageConflict,
                  thread.sequence == prior.sequence,
                  thread.statusSequence == prior.statusSequence
            else { return true }
            // Intentionally ignored: lastObservedAt and metadataSequence.
        }
        return false
    }

    private func metadataOnly(_ thread: AppServerThreadInput) -> AppServerThreadInput {
        AppServerThreadInput(
            id: thread.id,
            sessionID: thread.sessionID,
            title: thread.title,
            workingDirectoryName: thread.workingDirectoryName,
            workingDirectoryPath: thread.workingDirectoryPath,
            projectRootPath: thread.projectRootPath,
            gitBranch: thread.gitBranch,
            source: thread.source,
            parentThreadID: thread.parentThreadID,
            forkedFromThreadID: thread.forkedFromThreadID,
            status: thread.status,
            createdAt: thread.createdAt,
            updatedAt: thread.updatedAt,
            turnsAreAuthoritative: false,
            turns: []
        )
    }

    private func apply(_ input: AppServerDeltaInput) -> AppServerProjectionApplyResult {
        guard state.currentConnection == input.cursor.connection else {
            return .rejectedStaleConnection
        }
        guard input.observedAt.timeIntervalSince1970.isFinite else {
            return .ignoredInvalidIdentity
        }
        if state.rejectsDeltasUntilReconnect || state.requiresSnapshot {
            guard !state.rejectsDeltasUntilReconnect else { return .ignoredTombstoned }
            if state.hydrationDeltas.contains(where: { $0.cursor.sequence == input.cursor.sequence }) {
                return .duplicate
            }
            guard state.hydrationDeltas.count < configuration.maximumHydrationDeltas else {
                state.hydrationDeltas.removeAll(keepingCapacity: true)
                state.rejectsDeltasUntilReconnect = true
                return .ignoredTombstoned
            }
            state.hydrationDeltas.append(input)
            return .appliedPendingSnapshot
        }
        let result = applyDeltaNow(input)
        if result == .applied, state.requiresSnapshot {
            return .appliedPendingSnapshot
        }
        return result
    }

    private func applyDeltaNow(
        _ input: AppServerDeltaInput
    ) -> AppServerProjectionApplyResult {
        if let snapshotSequence = state.lastSnapshotSequence,
           input.cursor.sequence <= snapshotSequence {
            return .duplicate
        }
        let sequence = input.cursor.sequence
        let result: AppServerProjectionApplyResult

        switch input.delta {
        case let .threadUpsert(unboundedThread):
            guard validateUnbounded(unboundedThread) else { return .ignoredInvalidIdentity }
            let thread = truncated(unboundedThread)
            result = upsertThread(
                thread,
                sequence: sequence,
                observedAt: input.observedAt,
                freshness: .live,
                snapshotAuthority: false
            )
        case let .threadStatus(threadID, status):
            guard validate(threadID) else { return .ignoredInvalidIdentity }
            result = updateThreadStatus(
                threadID: threadID,
                status: status,
                sequence: sequence,
                observedAt: input.observedAt
            )
        case let .threadRemoved(threadID):
            guard validate(threadID) else { return .ignoredInvalidIdentity }
            result = removeThread(threadID, sequence: sequence)
        case let .turnUpsert(threadID, unboundedTurn):
            guard validate(threadID), validateUnbounded(unboundedTurn) else {
                return .ignoredInvalidIdentity
            }
            let turn = truncated(unboundedTurn)
            result = upsertTurn(
                threadID: threadID,
                input: turn,
                sequence: sequence,
                observedAt: input.observedAt
            )
        case let .itemUpsert(threadID, turnID, item):
            guard validate(threadID), validate(turnID), validate(item) else {
                return .ignoredInvalidIdentity
            }
            result = upsertItem(
                threadID: threadID,
                turnID: turnID,
                input: item,
                sequence: sequence,
                observedAt: input.observedAt
            )
        case let .itemPresentationDelta(threadID, turnID, itemID, delta):
            guard validate(threadID), validate(turnID), validate(itemID),
                  validate(delta) else {
                return .ignoredInvalidIdentity
            }
            result = appendItemPresentationDelta(
                threadID: threadID,
                turnID: turnID,
                itemID: itemID,
                delta: delta,
                sequence: sequence,
                observedAt: input.observedAt
            )
        case let .threadTokenUsage(threadID, turnID, usage):
            guard validate(threadID), validate(turnID), validate(usage) else {
                return .ignoredInvalidIdentity
            }
            result = updateTokenUsage(
                threadID: threadID,
                usage: usage,
                sequence: sequence,
                observedAt: input.observedAt
            )
        case let .turnPlanUpdated(threadID, turnID, plan):
            guard validate(threadID), validate(turnID), validate(plan) else {
                return .ignoredInvalidIdentity
            }
            result = updateTurnPlan(
                threadID: threadID,
                turnID: turnID,
                plan: plan,
                sequence: sequence,
                observedAt: input.observedAt
            )
        case let .requestOpened(request):
            guard validate(request) else { return .ignoredInvalidIdentity }
            result = openRequest(request, sequence: sequence, observedAt: input.observedAt)
        case let .requestResolved(threadID, requestID):
            guard validate(threadID), validate(requestID) else { return .ignoredInvalidIdentity }
            result = resolveRequest(threadID: threadID, requestID: requestID, sequence: sequence)
        }

        if result == .applied {
            trimAfterAppliedDelta(input.delta)
        }
        return result
    }

    private func upsertThread(
        _ input: AppServerThreadInput,
        sequence: UInt64,
        observedAt: Date,
        freshness: AppServerProjectionFreshness,
        snapshotAuthority: Bool,
        advancesRuntimeSequence: Bool = true
    ) -> AppServerProjectionApplyResult {
        let previous = state.threads[input.id]
        let runtimeSequence = advancesRuntimeSequence
            ? sequence
            : (state.lastSnapshotSequence ?? 0)
        var removedTombstone = false
        if let tombstone = state.threadTombstones[input.id] {
            guard tombstone < sequence else { return .ignoredTombstoned }
            state.threadTombstones.removeValue(forKey: input.id)
            removedTombstone = true
        }

        var stored = previous ?? StoredThread(
            id: input.id,
            sessionID: input.sessionID,
            title: bounded(input.title),
            workingDirectoryName: bounded(input.workingDirectoryName),
            workingDirectoryPath: bounded(input.workingDirectoryPath),
            projectRootPath: bounded(input.projectRootPath),
            gitBranch: bounded(input.gitBranch),
            source: input.source,
            parentThreadID: input.parentThreadID,
            forkedFromThreadID: input.forkedFromThreadID,
            status: input.status,
            freshness: freshness,
            createdAt: input.createdAt,
            updatedAt: input.updatedAt,
            lastObservedAt: observedAt,
            turns: [:],
            requests: [:],
            tokenUsage: nil,
            tokenUsageSequence: 0,
            tokenUsageConflict: false,
            sequence: runtimeSequence,
            metadataSequence: sequence,
            statusSequence: runtimeSequence
        )

        var hasConflict = false
        let incomingTitle = bounded(input.title)
        let incomingWorkingDirectoryName = bounded(input.workingDirectoryName)
        let incomingWorkingDirectoryPath = bounded(input.workingDirectoryPath)
        let incomingProjectRootPath = bounded(input.projectRootPath)
        let incomingGitBranch = bounded(input.gitBranch)
        let incomingCreatedAt = input.createdAt ?? stored.createdAt
        if sequence > stored.metadataSequence {
            stored.sessionID = input.sessionID
            stored.title = incomingTitle
            stored.workingDirectoryName = incomingWorkingDirectoryName
            stored.workingDirectoryPath = incomingWorkingDirectoryPath
            stored.projectRootPath = incomingProjectRootPath
            stored.gitBranch = incomingGitBranch
            stored.source = input.source
            stored.parentThreadID = input.parentThreadID
            stored.forkedFromThreadID = input.forkedFromThreadID
            stored.createdAt = incomingCreatedAt
            stored.metadataSequence = sequence
        } else if sequence == stored.metadataSequence,
                  stored.sessionID != input.sessionID
                    || stored.title != incomingTitle
                    || stored.workingDirectoryName != incomingWorkingDirectoryName
                    || stored.workingDirectoryPath != incomingWorkingDirectoryPath
                    || stored.projectRootPath != incomingProjectRootPath
                    || stored.gitBranch != incomingGitBranch
                    || stored.source != input.source
                    || stored.parentThreadID != input.parentThreadID
                    || stored.forkedFromThreadID != input.forkedFromThreadID
                    || stored.createdAt != incomingCreatedAt {
            stored.sessionID = nil
            stored.title = nil
            stored.workingDirectoryName = nil
            stored.workingDirectoryPath = nil
            stored.projectRootPath = nil
            stored.gitBranch = nil
            stored.source = .unknown
            stored.parentThreadID = nil
            stored.forkedFromThreadID = nil
            stored.createdAt = nil
            hasConflict = true
        }
        if !advancesRuntimeSequence {
            if input.status != .unknown {
                // Metadata refreshes provide a useful initial/cached status,
                // but never replace current evidence with an unknown scan row.
                // A known value can still repair a missed notification.
                stored.status = input.status
            }
        } else if sequence > stored.statusSequence {
            stored.status = input.status
            stored.statusSequence = sequence
        } else if sequence == stored.statusSequence, stored.status != input.status {
            stored.status = .unknown
            hasConflict = true
        }
        if advancesRuntimeSequence && (stored.sequence <= sequence || stored.freshness != .live) {
            stored.freshness = freshness
        } else if !advancesRuntimeSequence && (previous == nil || stored.freshness != .live) {
            stored.freshness = freshness
        }
        stored.updatedAt = max(stored.updatedAt, input.updatedAt)
        stored.lastObservedAt = max(stored.lastObservedAt, observedAt)
        if advancesRuntimeSequence {
            stored.sequence = max(stored.sequence, sequence)
        }

        let incomingTurnIDs = Set(input.turns.map(\.id))
        for turn in input.turns {
            hasConflict = mergeTurn(
                &stored,
                input: turn,
                sequence: sequence,
                authoritative: input.turnsAreAuthoritative
            ) || hasConflict
        }
        if input.turnsAreAuthoritative {
            stored.turns = stored.turns.filter { id, value in
                incomingTurnIDs.contains(id) || value.sequence > sequence
            }
        }
        trimThread(&stored)
        let newlyRequiresSnapshot = hasConflict
            && !snapshotAuthority
            && !state.requiresSnapshot
        if hasConflict && !snapshotAuthority {
            stored.freshness = .stale
            state.requiresSnapshot = true
            if hasTerminalConflict(stored) {
                state.requiresContentSnapshot = true
            }
        }
        guard stored != previous
                || removedTombstone
                || newlyRequiresSnapshot else {
            return .duplicate
        }
        state.threads[input.id] = stored
        return .applied
    }

    private func updateThreadStatus(
        threadID: AppServerThreadID,
        status: AppServerThreadStatus,
        sequence: UInt64,
        observedAt: Date
    ) -> AppServerProjectionApplyResult {
        if let tombstone = state.threadTombstones[threadID] {
            guard tombstone < sequence else { return .ignoredTombstoned }
            state.threadTombstones.removeValue(forKey: threadID)
        }
        var thread = state.threads[threadID] ?? skeletalThread(
            id: threadID,
            observedAt: observedAt,
            sequence: sequence
        )
        guard sequence >= thread.statusSequence else { return .duplicate }
        if sequence == thread.statusSequence {
            guard thread.status != status else { return .duplicate }
            thread.status = .unknown
            thread.freshness = .stale
            thread.lastObservedAt = max(thread.lastObservedAt, observedAt)
            state.requiresSnapshot = true
            state.threads[threadID] = thread
            return .applied
        }
        thread.status = status
        thread.statusSequence = sequence
        thread.freshness = .live
        thread.lastObservedAt = max(thread.lastObservedAt, observedAt)
        thread.sequence = max(thread.sequence, sequence)
        state.threads[threadID] = thread
        return .applied
    }

    private func removeThread(
        _ threadID: AppServerThreadID,
        sequence: UInt64
    ) -> AppServerProjectionApplyResult {
        if let tombstone = state.threadTombstones[threadID], tombstone >= sequence {
            return .duplicate
        }
        if let thread = state.threads[threadID], thread.sequence > sequence {
            return .duplicate
        }
        state.threadTombstones[threadID] = sequence
        state.threads.removeValue(forKey: threadID)
        trimThreadTombstones()
        return .applied
    }

    private func upsertTurn(
        threadID: AppServerThreadID,
        input: AppServerTurnInput,
        sequence: UInt64,
        observedAt: Date
    ) -> AppServerProjectionApplyResult {
        if let tombstone = state.threadTombstones[threadID] {
            guard tombstone < sequence else { return .ignoredTombstoned }
            state.threadTombstones.removeValue(forKey: threadID)
        }
        var thread = state.threads[threadID] ?? skeletalThread(
            id: threadID,
            observedAt: observedAt,
            sequence: sequence
        )
        let previous = thread.turns[input.id]
        let terminalConflict = mergeTurn(
            &thread,
            input: input,
            sequence: sequence,
            authoritative: false
        )
        guard thread.turns[input.id] != previous else { return .duplicate }
        thread.freshness = terminalConflict ? .stale : .live
        if terminalConflict {
            state.requiresSnapshot = true
            state.requiresContentSnapshot = true
        }
        thread.lastObservedAt = max(thread.lastObservedAt, observedAt)
        thread.sequence = max(thread.sequence, sequence)
        trimThread(&thread)
        state.threads[threadID] = thread
        return .applied
    }

    private func upsertItem(
        threadID: AppServerThreadID,
        turnID: AppServerTurnID,
        input: AppServerItemInput,
        sequence: UInt64,
        observedAt: Date
    ) -> AppServerProjectionApplyResult {
        if let tombstone = state.threadTombstones[threadID] {
            guard tombstone < sequence else { return .ignoredTombstoned }
            state.threadTombstones.removeValue(forKey: threadID)
        }
        var thread = state.threads[threadID] ?? skeletalThread(
            id: threadID,
            observedAt: observedAt,
            sequence: sequence
        )
        var turn = thread.turns[turnID] ?? StoredTurn(
            id: turnID,
            status: .inProgress,
            startedAt: input.startedAt,
            completedAt: nil,
            itemsView: .notLoaded,
            items: [:],
            plan: nil,
            planSequence: 0,
            planConflict: false,
            sequence: sequence,
            terminalConflict: false
        )
        let previous = turn.items[input.id]
        let terminalConflict = mergeItem(
            &turn,
            input: input,
            sequence: sequence,
            authoritative: false
        )
        guard turn.items[input.id] != previous else { return .duplicate }
        turn.sequence = max(turn.sequence, sequence)
        thread.turns[turnID] = turn
        thread.freshness = terminalConflict ? .stale : .live
        if terminalConflict {
            state.requiresSnapshot = true
            state.requiresContentSnapshot = true
        }
        thread.lastObservedAt = max(thread.lastObservedAt, observedAt)
        thread.sequence = max(thread.sequence, sequence)
        trimThread(&thread)
        state.threads[threadID] = thread
        return .applied
    }

    private func appendItemPresentationDelta(
        threadID: AppServerThreadID,
        turnID: AppServerTurnID,
        itemID: AppServerItemID,
        delta: AppServerItemPresentationDelta,
        sequence: UInt64,
        observedAt: Date
    ) -> AppServerProjectionApplyResult {
        guard state.threadTombstones[threadID].map({ $0 < sequence }) ?? true else {
            return .ignoredTombstoned
        }
        guard var thread = state.threads[threadID],
              var turn = thread.turns[turnID],
              var stored = turn.items[itemID]
        else {
            return requireContentSnapshot()
        }
        guard sequence > stored.sequence else { return .duplicate }

        let presentation: AppServerItemPresentationPayload
        switch delta {
        case let .agentText(fragment):
            guard stored.value.kind == .agentMessage else {
                return requireContentSnapshot()
            }
            let existing: String
            let isFinalAnswer: Bool
            switch stored.value.presentation {
            case let .agentText(value):
                existing = value
                isFinalAnswer = false
            case let .agentFinalText(value):
                existing = value
                isFinalAnswer = true
            case nil:
                existing = ""
                isFinalAnswer = false
            default: return requireContentSnapshot()
            }
            let text = boundedPresentationText(existing + fragment)
            presentation = isFinalAnswer ? .agentFinalText(text) : .agentText(text)

        case let .reasoningSummaryPartAdded(index):
            guard stored.value.kind == .reasoning else {
                return requireContentSnapshot()
            }
            var parts: [String]
            switch stored.value.presentation {
            case let .reasoningSummary(value): parts = value
            case nil: parts = []
            default: return requireContentSnapshot()
            }
            while parts.count <= index { parts.append("") }
            presentation = .reasoningSummary(parts)

        case let .reasoningSummaryText(index, fragment):
            guard stored.value.kind == .reasoning else {
                return requireContentSnapshot()
            }
            var parts: [String]
            switch stored.value.presentation {
            case let .reasoningSummary(value): parts = value
            case nil: parts = []
            default: return requireContentSnapshot()
            }
            while parts.count <= index { parts.append("") }
            let otherBytes = parts.enumerated().reduce(0) { total, entry in
                entry.offset == index ? total : total + entry.element.utf8.count
            }
            let otherLines = parts.enumerated().reduce(0) { total, entry in
                entry.offset == index ? total : total + lineCount(entry.element)
            }
            let limits = configuration.itemPresentationLimits
            let remainingBytes = max(0, limits.maximumTextUTF8Bytes - otherBytes)
            let remainingLines = max(0, limits.maximumTextLineCount - otherLines)
            parts[index] = boundedPresentationText(
                parts[index] + fragment,
                maximumBytes: remainingBytes,
                maximumLines: remainingLines
            )
            presentation = .reasoningSummary(parts)
        }

        guard validate(presentation, for: stored.value.kind) else {
            return .ignoredInvalidIdentity
        }

        stored.value = AppServerProjectedItem(input: .init(
            id: stored.value.id,
            kind: stored.value.kind,
            status: stored.value.status,
            startedAt: stored.value.startedAt,
            completedAt: stored.value.completedAt,
            presentation: presentation
        ))
        stored.sequence = sequence
        turn.items[itemID] = stored
        turn.sequence = max(turn.sequence, sequence)
        thread.turns[turnID] = turn
        thread.freshness = .live
        thread.lastObservedAt = max(thread.lastObservedAt, observedAt)
        thread.sequence = max(thread.sequence, sequence)
        trimThread(&thread)
        state.threads[threadID] = thread
        return .applied
    }

    private func requireContentSnapshot() -> AppServerProjectionApplyResult {
        state.requiresSnapshot = true
        state.requiresContentSnapshot = true
        return .applied
    }

    private func updateTokenUsage(
        threadID: AppServerThreadID,
        usage: AppServerTokenUsage,
        sequence: UInt64,
        observedAt: Date
    ) -> AppServerProjectionApplyResult {
        if let tombstone = state.threadTombstones[threadID] {
            guard tombstone < sequence else { return .ignoredTombstoned }
            state.threadTombstones.removeValue(forKey: threadID)
        }
        var thread = state.threads[threadID] ?? skeletalThread(
            id: threadID,
            observedAt: observedAt,
            sequence: sequence
        )
        guard sequence >= thread.tokenUsageSequence else { return .duplicate }
        if sequence == thread.tokenUsageSequence {
            guard !thread.tokenUsageConflict, thread.tokenUsage != usage else {
                return .duplicate
            }
            thread.tokenUsage = nil
            thread.tokenUsageConflict = true
        } else {
            thread.tokenUsage = usage
            thread.tokenUsageSequence = sequence
            thread.tokenUsageConflict = false
        }
        thread.freshness = .live
        thread.lastObservedAt = max(thread.lastObservedAt, observedAt)
        thread.sequence = max(thread.sequence, sequence)
        state.threads[threadID] = thread
        return .applied
    }

    private func updateTurnPlan(
        threadID: AppServerThreadID,
        turnID: AppServerTurnID,
        plan: AppServerTurnPlan,
        sequence: UInt64,
        observedAt: Date
    ) -> AppServerProjectionApplyResult {
        if let tombstone = state.threadTombstones[threadID] {
            guard tombstone < sequence else { return .ignoredTombstoned }
            state.threadTombstones.removeValue(forKey: threadID)
        }
        var thread = state.threads[threadID] ?? skeletalThread(
            id: threadID,
            observedAt: observedAt,
            sequence: sequence
        )
        var turn = thread.turns[turnID] ?? StoredTurn(
            id: turnID,
            status: .inProgress,
            startedAt: nil,
            completedAt: nil,
            itemsView: .notLoaded,
            items: [:],
            plan: nil,
            planSequence: 0,
            planConflict: false,
            sequence: sequence,
            terminalConflict: false
        )
        guard sequence >= turn.planSequence else { return .duplicate }
        if sequence == turn.planSequence {
            guard !turn.planConflict, turn.plan != plan else { return .duplicate }
            turn.plan = nil
            turn.planConflict = true
        } else {
            turn.plan = plan
            turn.planSequence = sequence
            turn.planConflict = false
        }
        turn.sequence = max(turn.sequence, sequence)
        thread.turns[turnID] = turn
        thread.freshness = .live
        thread.lastObservedAt = max(thread.lastObservedAt, observedAt)
        thread.sequence = max(thread.sequence, sequence)
        trimThread(&thread)
        state.threads[threadID] = thread
        return .applied
    }

    private func openRequest(
        _ input: AppServerRequestInput,
        sequence: UInt64,
        observedAt: Date
    ) -> AppServerProjectionApplyResult {
        let key = RequestKey(threadID: input.threadID, requestID: input.requestID)
        if let tombstone = state.resolvedRequestTombstones[key] {
            guard tombstone < sequence else { return .ignoredTombstoned }
            state.resolvedRequestTombstones.removeValue(forKey: key)
        }
        if let tombstone = state.threadTombstones[input.threadID] {
            guard tombstone < sequence else { return .ignoredTombstoned }
            state.threadTombstones.removeValue(forKey: input.threadID)
        }
        var thread = state.threads[input.threadID] ?? skeletalThread(
            id: input.threadID,
            observedAt: observedAt,
            sequence: sequence
        )
        if let existing = thread.requests[key], existing.sequence >= sequence {
            return .duplicate
        }
        guard let connection = state.currentConnection else { return .rejectedStaleConnection }
        thread.requests[key] = StoredRequest(
            value: AppServerProjectedRequest(
                id: .init(connection: connection, requestID: input.requestID),
                threadID: input.threadID,
                turnID: input.turnID,
                itemID: input.itemID,
                kind: input.kind,
                facts: input.facts,
                startedAt: input.startedAt
            ),
            sequence: sequence
        )
        thread.freshness = .live
        thread.lastObservedAt = max(thread.lastObservedAt, observedAt)
        thread.sequence = max(thread.sequence, sequence)
        state.threads[input.threadID] = thread
        return .applied
    }

    private func resolveRequest(
        threadID: AppServerThreadID,
        requestID: AppServerRequestID,
        sequence: UInt64
    ) -> AppServerProjectionApplyResult {
        let key = RequestKey(threadID: threadID, requestID: requestID)
        if let existing = state.resolvedRequestTombstones[key], existing >= sequence {
            return .duplicate
        }
        if let request = state.threads[threadID]?.requests[key], request.sequence > sequence {
            return .duplicate
        }
        state.resolvedRequestTombstones[key] = sequence
        if var thread = state.threads[threadID],
           let request = thread.requests[key],
           request.sequence <= sequence {
            thread.requests.removeValue(forKey: key)
            thread.sequence = max(thread.sequence, sequence)
            state.threads[threadID] = thread
        }
        trimRequestTombstones()
        return .applied
    }

    @discardableResult
    private func mergeTurn(
        _ thread: inout StoredThread,
        input: AppServerTurnInput,
        sequence: UInt64,
        authoritative: Bool
    ) -> Bool {
        var turn = thread.turns[input.id] ?? StoredTurn(
            id: input.id,
            status: input.status,
            startedAt: input.startedAt,
            completedAt: input.completedAt,
            itemsView: input.itemsView,
            items: [:],
            plan: nil,
            planSequence: 0,
            planConflict: false,
            sequence: sequence,
            terminalConflict: input.status == .unknown
        )

        let incomingIsTerminal = input.status.isTerminal
        let existingIsTerminal = turn.status.isTerminal
        if authoritative, sequence >= turn.sequence {
            turn.status = input.status
            turn.terminalConflict = input.status == .unknown
            turn.startedAt = input.startedAt ?? turn.startedAt
            turn.completedAt = input.completedAt ?? turn.completedAt
            turn.itemsView = moreComplete(turn.itemsView, input.itemsView)
        } else if turn.terminalConflict {
            turn.status = .unknown
        } else if existingIsTerminal, incomingIsTerminal, turn.status != input.status {
            turn.status = .unknown
            turn.terminalConflict = true
            turn.completedAt = later(turn.completedAt, input.completedAt)
        } else if sequence >= turn.sequence {
            if !existingIsTerminal || incomingIsTerminal {
                turn.status = input.status
            }
            turn.startedAt = input.startedAt ?? turn.startedAt
            turn.completedAt = input.completedAt ?? turn.completedAt
            turn.itemsView = moreComplete(turn.itemsView, input.itemsView)
        } else if incomingIsTerminal && !existingIsTerminal {
            // A terminal structured Turn dominates a late-arriving nonterminal
            // fact even when reducer application is reversed.
            turn.status = input.status
            turn.completedAt = input.completedAt ?? turn.completedAt
        } else {
            turn.startedAt = turn.startedAt ?? input.startedAt
            if incomingIsTerminal {
                turn.completedAt = turn.completedAt ?? input.completedAt
            }
            turn.itemsView = moreComplete(turn.itemsView, input.itemsView)
        }

        let incomingIDs = Set(input.items.map(\.id))
        for (order, item) in input.items.enumerated() {
            _ = mergeItem(
                &turn,
                input: item,
                sequence: sequence,
                order: order,
                authoritative: authoritative && input.itemsView == .full
            )
        }
        if input.itemsView == .full {
            turn.items = turn.items.filter { id, value in
                incomingIDs.contains(id) || value.sequence > sequence
            }
        }
        turn.sequence = max(turn.sequence, sequence)
        trimTurn(&turn)
        thread.turns[input.id] = turn
        return turn.terminalConflict || turn.items.values.contains(where: \.terminalConflict)
    }

    @discardableResult
    private func mergeItem(
        _ turn: inout StoredTurn,
        input: AppServerItemInput,
        sequence: UInt64,
        order: Int? = nil,
        authoritative: Bool
    ) -> Bool {
        let projected = AppServerProjectedItem(input: input)
        guard var stored = turn.items[input.id] else {
            turn.items[input.id] = StoredItem(
                value: projected,
                sequence: sequence,
                order: order ?? ((turn.items.values.map(\.order).max() ?? -1) + 1),
                terminalConflict: input.status == .unknown
            )
            return input.status == .unknown
        }
        if authoritative, sequence > stored.sequence {
            stored.value = projected
            stored.sequence = sequence
            if let order { stored.order = order }
            stored.terminalConflict = input.status == .unknown
            turn.items[input.id] = stored
            return stored.terminalConflict
        }
        if sequence == stored.sequence {
            let candidate = AppServerProjectedItem(input: .init(
                id: input.id,
                kind: input.kind,
                status: input.status,
                startedAt: input.startedAt ?? stored.value.startedAt,
                completedAt: input.completedAt ?? stored.value.completedAt,
                presentation: input.presentation
            ))
            guard stored.value != candidate else { return stored.terminalConflict }
            stored.value = AppServerProjectedItem(input: .init(
                id: input.id,
                kind: .unknown,
                status: .unknown,
                presentation: nil
            ))
            stored.terminalConflict = true
            turn.items[input.id] = stored
            return true
        }
        if stored.terminalConflict {
            return true
        }
        if stored.value.status.isTerminal,
           input.status.isTerminal,
           stored.value.status != input.status {
            let presentation = sequence >= stored.sequence
                ? input.presentation
                : stored.value.presentation
            stored.value = AppServerProjectedItem(input: .init(
                id: input.id,
                kind: input.kind,
                status: .unknown,
                startedAt: input.startedAt ?? stored.value.startedAt,
                completedAt: later(stored.value.completedAt, input.completedAt),
                presentation: presentation
            ))
            stored.sequence = max(stored.sequence, sequence)
            stored.terminalConflict = true
            turn.items[input.id] = stored
            return true
        }
        if sequence < stored.sequence {
            if input.status.isTerminal, stored.value.status == input.status {
                stored.value = AppServerProjectedItem(input: .init(
                    id: stored.value.id,
                    kind: stored.value.kind,
                    status: stored.value.status,
                    startedAt: stored.value.startedAt ?? input.startedAt,
                    completedAt: stored.value.completedAt ?? input.completedAt,
                    presentation: stored.value.presentation
                ))
                turn.items[input.id] = stored
                return false
            }
            if stored.value.status.isTerminal, !input.status.isTerminal {
                stored.value = AppServerProjectedItem(input: .init(
                    id: stored.value.id,
                    kind: stored.value.kind,
                    status: stored.value.status,
                    startedAt: stored.value.startedAt ?? input.startedAt,
                    completedAt: stored.value.completedAt,
                    presentation: stored.value.presentation
                ))
                turn.items[input.id] = stored
                return false
            }
            guard input.status.isTerminal && !stored.value.status.isTerminal else {
                return false
            }
        } else if stored.value.status.isTerminal && !input.status.isTerminal {
            stored.value = AppServerProjectedItem(input: .init(
                id: stored.value.id,
                kind: stored.value.kind,
                status: stored.value.status,
                startedAt: stored.value.startedAt ?? input.startedAt,
                completedAt: stored.value.completedAt,
                presentation: stored.value.presentation
            ))
            turn.items[input.id] = stored
            return false
        }
        stored.value = AppServerProjectedItem(input: .init(
            id: input.id,
            kind: input.kind,
            status: input.status,
            startedAt: input.startedAt ?? stored.value.startedAt,
            completedAt: input.completedAt ?? stored.value.completedAt,
            presentation: input.presentation
        ))
        stored.sequence = max(stored.sequence, sequence)
        turn.items[input.id] = stored
        return false
    }

    private func skeletalThread(
        id: AppServerThreadID,
        observedAt: Date,
        sequence: UInt64
    ) -> StoredThread {
        StoredThread(
            id: id,
            sessionID: nil,
            title: nil,
            workingDirectoryName: nil,
            workingDirectoryPath: nil,
            projectRootPath: nil,
            gitBranch: nil,
            source: .unknown,
            parentThreadID: nil,
            forkedFromThreadID: nil,
            status: .unknown,
            freshness: .live,
            createdAt: nil,
            updatedAt: observedAt,
            lastObservedAt: observedAt,
            turns: [:],
            requests: [:],
            tokenUsage: nil,
            tokenUsageSequence: 0,
            tokenUsageConflict: false,
            sequence: sequence,
            metadataSequence: 0,
            statusSequence: 0
        )
    }

    private func project(_ thread: StoredThread, now: Date) -> AppServerProjectedThread {
        _ = now
        let freshness: AppServerProjectionFreshness
        if thread.freshness == .stale || hasTerminalConflict(thread) {
            freshness = .stale
        } else {
            freshness = thread.freshness
        }
        let turns = thread.turns.values.map(project).sorted(by: projectedTurnComesFirst)
        let activeTurnIDs = turns.filter { $0.status == .inProgress }.map(\.id).sorted()
        let requests = thread.requests.values.map(\.value).sorted(by: projectedRequestComesFirst)
        let outcome = activeTurnIDs.isEmpty ? latestOutcome(threadID: thread.id, turns: turns) : nil
        return AppServerProjectedThread(
            id: thread.id,
            sessionID: thread.sessionID,
            title: thread.title,
            workingDirectoryName: thread.workingDirectoryName,
            workingDirectoryPath: thread.workingDirectoryPath,
            projectRootPath: thread.projectRootPath,
            gitBranch: thread.gitBranch,
            source: thread.source,
            sourceLabel: thread.source.presentationLabel,
            parentThreadID: thread.parentThreadID,
            forkedFromThreadID: thread.forkedFromThreadID,
            status: thread.status,
            statusFreshness: state.currentConnection == nil ? .stale : thread.freshness,
            freshness: freshness,
            activity: activity(status: thread.status, turns: turns, requests: requests, outcome: outcome),
            createdAt: thread.createdAt,
            updatedAt: thread.updatedAt,
            lastObservedAt: thread.lastObservedAt,
            turns: turns,
            activeTurnIDs: activeTurnIDs,
            requests: requests,
            outcome: outcome,
            tokenUsage: thread.tokenUsage
        )
    }

    private func project(_ turn: StoredTurn) -> AppServerProjectedTurn {
        AppServerProjectedTurn(
            id: turn.id,
            status: turn.status,
            startedAt: turn.startedAt,
            completedAt: turn.completedAt,
            itemsView: turn.itemsView,
            items: turn.items.values.sorted {
                if $0.order != $1.order { return $0.order < $1.order }
                return $0.value.id < $1.value.id
            }.map(\.value),
            plan: turn.plan
        )
    }

    private func latestOutcome(
        threadID: AppServerThreadID,
        turns: [AppServerProjectedTurn]
    ) -> AppServerProjectedOutcome? {
        guard let turn = turns.first(where: { $0.status.isTerminal }) else { return nil }
        let kind: AppServerOutcomeKind
        switch turn.status {
        case .completed: kind = .completed
        case .failed: kind = .failed
        case .interrupted: kind = .interrupted
        default: return nil
        }
        return AppServerProjectedOutcome(
            threadID: threadID,
            turnID: turn.id,
            kind: kind,
            completedAt: turn.completedAt
        )
    }

    private func activity(
        status: AppServerThreadStatus,
        turns: [AppServerProjectedTurn],
        requests: [AppServerProjectedRequest],
        outcome: AppServerProjectedOutcome?
    ) -> AppServerActivityKind {
        if requests.contains(where: { $0.kind == .structuredQuestion || $0.kind == .mcpElicitation }) {
            return .waitingForInput
        }
        if !requests.isEmpty { return .waitingForApproval }
        if case let .active(flags) = status {
            if flags.contains(.waitingOnUserInput) { return .waitingForInput }
            if flags.contains(.waitingOnApproval) { return .waitingForApproval }
        }
        if let activeTurn = turns.first(where: { $0.status == .inProgress }) {
            guard let item = activeTurn.items.first else { return .working }
            switch item.kind {
            case .commandExecution: return .runningCommand
            case .fileChange: return .changingFiles
            case .mcpToolCall, .dynamicToolCall, .webSearch, .imageGeneration: return .usingTool
            default: return .working
            }
        }
        if let outcome {
            switch outcome.kind {
            case .completed: return .completed
            case .failed: return .failed
            case .interrupted: return .interrupted
            }
        }
        if status == .idle || status == .notLoaded { return .idle }
        return .unknown
    }

    private func makeCheckpoint(at date: Date) -> AppServerProjectionCheckpoint {
        let cached = state.threads.values
            .sorted(by: storedThreadComesFirst)
            .prefix(configuration.maximumThreads)
            .map { thread in
                AppServerCachedThread(
                    id: thread.id,
                    sessionID: thread.sessionID,
                    title: thread.title,
                    workingDirectoryName: thread.workingDirectoryName,
                    workingDirectoryPath: thread.workingDirectoryPath,
                    projectRootPath: thread.projectRootPath,
                    source: thread.source,
                    parentThreadID: thread.parentThreadID,
                    forkedFromThreadID: thread.forkedFromThreadID,
                    status: thread.status,
                    createdAt: thread.createdAt,
                    updatedAt: thread.updatedAt,
                    lastObservedAt: thread.lastObservedAt,
                    turns: thread.turns.values
                        .map(projectForCheckpoint)
                        .sorted(by: projectedTurnComesFirst)
                )
            }
        return AppServerProjectionCheckpoint(
            savedAt: date,
            // Never persist runtime-only Shared Desktop qualification. A new
            // process must re-establish every live verification gate.
            connectionSource: .managedDaemon,
            threads: cached
        )
    }

    private func projectForCheckpoint(_ turn: StoredTurn) -> AppServerProjectedTurn {
        let projected = project(turn)
        return AppServerProjectedTurn(
            id: projected.id,
            status: projected.status,
            startedAt: projected.startedAt,
            completedAt: projected.completedAt,
            itemsView: projected.itemsView,
            items: projected.items.map { item in
                AppServerProjectedItem(input: .init(
                    id: item.id,
                    kind: item.kind,
                    status: item.status,
                    startedAt: item.startedAt,
                    completedAt: item.completedAt,
                    presentation: nil
                ))
            }
        )
    }

    private func clearRequests(observedThrough sequence: UInt64) {
        for id in state.threads.keys {
            guard var thread = state.threads[id] else { continue }
            thread.requests = thread.requests.filter { $0.value.sequence > sequence }
            state.threads[id] = thread
        }
    }

    private func trimState() {
        trimThreadsIfNeeded()
        trimUnresolvedRequestsIfNeeded()
        trimRequestTombstones()
        trimThreadTombstones()
        trimPresentationPayloads()
    }

    /// Delta retention work is scoped to bounds the delta can grow. Common
    /// lifecycle/status inputs therefore touch only their target thread rather
    /// than scanning every cached thread, request, and presentation payload.
    private func trimAfterAppliedDelta(_ delta: AppServerProjectionDelta) {
        switch delta {
        case let .threadUpsert(thread):
            trimThreadsIfNeeded()
            if thread.turns.contains(where: { turn in
                turn.items.contains(where: { $0.presentation != nil })
            }) {
                trimPresentationPayloads()
            }
        case .threadStatus:
            trimThreadsIfNeeded()
        case .threadRemoved, .requestResolved:
            break
        case let .turnUpsert(_, turn):
            trimThreadsIfNeeded()
            if turn.items.contains(where: { $0.presentation != nil }) {
                trimPresentationPayloads()
            }
        case let .itemUpsert(_, _, item):
            trimThreadsIfNeeded()
            if item.presentation != nil {
                trimPresentationPayloads()
            }
        case .itemPresentationDelta:
            trimThreadsIfNeeded()
            trimPresentationPayloads()
        case .threadTokenUsage:
            trimThreadsIfNeeded()
        case .turnPlanUpdated:
            trimThreadsIfNeeded()
            trimPresentationPayloads()
        case .requestOpened:
            trimThreadsIfNeeded()
            trimUnresolvedRequestsIfNeeded()
        }
    }

    private func trimThreadsIfNeeded() {
        if state.threads.count > configuration.maximumThreads {
            let keep = Set(state.threads.values
                .sorted(by: storedThreadComesFirst)
                .prefix(configuration.maximumThreads)
                .map(\.id))
            state.threads = state.threads.filter { keep.contains($0.key) }
        }
    }

    private func trimUnresolvedRequestsIfNeeded() {
        let allRequests = state.threads.values
            .flatMap { thread in thread.requests.map { (thread.id, $0.key, $0.value) } }
            .sorted { left, right in
                if left.2.sequence != right.2.sequence { return left.2.sequence > right.2.sequence }
                if left.0 != right.0 { return left.0 < right.0 }
                return left.1.requestID < right.1.requestID
            }
        if allRequests.count > configuration.maximumUnresolvedRequests {
            let keep = Set(allRequests.prefix(configuration.maximumUnresolvedRequests).map(\.1))
            for id in state.threads.keys {
                guard var thread = state.threads[id] else { continue }
                thread.requests = thread.requests.filter { keep.contains($0.key) }
                state.threads[id] = thread
            }
        }
    }

    private func trimPresentationPayloads() {
        guard let maximumBytes = configuration.maximumAggregatePresentationBytes else {
            return
        }
        let entries = state.threads.values.flatMap { thread in
            thread.turns.values.flatMap { turn in
                turn.items.values.compactMap { item -> (
                    location: PresentationLocation,
                    priority: Int,
                    sequence: UInt64,
                    byteCount: Int
                )? in
                    let byteCount = presentationByteCount(item.value.presentation)
                    guard byteCount > 0 else { return nil }
                    return (
                        PresentationLocation(
                            threadID: thread.id,
                            turnID: turn.id,
                            itemID: item.value.id
                        ),
                        presentationRetentionPriority(item.value.presentation),
                        item.sequence,
                        byteCount
                    )
                }
            }
        }.sorted { left, right in
            if left.priority != right.priority { return left.priority < right.priority }
            if left.sequence != right.sequence { return left.sequence > right.sequence }
            if left.location.threadID != right.location.threadID {
                return left.location.threadID < right.location.threadID
            }
            if left.location.turnID != right.location.turnID {
                return left.location.turnID < right.location.turnID
            }
            return left.location.itemID < right.location.itemID
        }

        var retainedBytes = 0
        var retained: Set<PresentationLocation> = []
        for entry in entries where retainedBytes + entry.byteCount <= maximumBytes {
            retained.insert(entry.location)
            retainedBytes += entry.byteCount
        }

        for threadID in state.threads.keys {
            guard var thread = state.threads[threadID] else { continue }
            for turnID in thread.turns.keys {
                guard var turn = thread.turns[turnID] else { continue }
                for itemID in turn.items.keys {
                    let location = PresentationLocation(
                        threadID: threadID,
                        turnID: turnID,
                        itemID: itemID
                    )
                    guard !retained.contains(location),
                          var item = turn.items[itemID],
                          item.value.presentation != nil
                    else { continue }
                    item.value = AppServerProjectedItem(input: .init(
                        id: item.value.id,
                        kind: item.value.kind,
                        status: item.value.status,
                        startedAt: item.value.startedAt,
                        completedAt: item.value.completedAt,
                        presentation: nil
                    ))
                    turn.items[itemID] = item
                }
                thread.turns[turnID] = turn
            }
            state.threads[threadID] = thread
        }

        let retainedItemBytes = state.threads.values.reduce(0) { threadTotal, thread in
            threadTotal + thread.turns.values.reduce(0) { turnTotal, turn in
                turnTotal + turn.items.values.reduce(0) {
                    $0 + presentationByteCount($1.value.presentation)
                }
            }
        }
        var remainingBytes = max(0, maximumBytes - retainedItemBytes)
        let plans = state.threads.values.flatMap { thread in
            thread.turns.values.compactMap { turn -> (
                threadID: AppServerThreadID,
                turnID: AppServerTurnID,
                sequence: UInt64,
                byteCount: Int
            )? in
                let byteCount = planByteCount(turn.plan)
                guard byteCount > 0 else { return nil }
                return (thread.id, turn.id, turn.planSequence, byteCount)
            }
        }.sorted { left, right in
            if left.sequence != right.sequence { return left.sequence > right.sequence }
            if left.threadID != right.threadID { return left.threadID < right.threadID }
            return left.turnID < right.turnID
        }
        var retainedPlans: Set<PlanLocation> = []
        for entry in plans where entry.byteCount <= remainingBytes {
            retainedPlans.insert(.init(threadID: entry.threadID, turnID: entry.turnID))
            remainingBytes -= entry.byteCount
        }
        for threadID in state.threads.keys {
            guard var thread = state.threads[threadID] else { continue }
            for turnID in thread.turns.keys where !retainedPlans.contains(
                .init(threadID: threadID, turnID: turnID)
            ) {
                thread.turns[turnID]?.plan = nil
            }
            state.threads[threadID] = thread
        }
    }

    private func presentationRetentionPriority(
        _ presentation: AppServerItemPresentationPayload?
    ) -> Int {
        switch presentation {
        case .userText, .agentText, .agentFinalText:
            0
        case .planText:
            1
        case .reasoningSummary:
            2
        case .command, .fileChanges, .tool, .none:
            3
        }
    }

    private func presentationByteCount(
        _ presentation: AppServerItemPresentationPayload?
    ) -> Int {
        guard let presentation else { return 0 }
        switch presentation {
        case let .userText(value), let .agentText(value), let .agentFinalText(value),
             let .planText(value), let .command(value):
            return value.utf8.count
        case let .reasoningSummary(parts):
            return parts.reduce(0) { $0 + $1.utf8.count }
        case let .fileChanges(changes):
            return changes.reduce(0) {
                $0 + $1.path.utf8.count + $1.kind.rawValue.utf8.count
            }
        case let .tool(name, server):
            return name.utf8.count + (server?.utf8.count ?? 0)
        }
    }

    private func planByteCount(_ plan: AppServerTurnPlan?) -> Int {
        plan?.steps.reduce(0) {
            $0 + $1.step.utf8.count + $1.status.rawValue.utf8.count
        } ?? 0
    }

    private func trimThread(_ thread: inout StoredThread) {
        if thread.turns.count > configuration.maximumTurnsPerThread {
            let keep = Set(thread.turns.values
                .sorted(by: storedTurnComesFirst)
                .prefix(configuration.maximumTurnsPerThread)
                .map(\.id))
            thread.turns = thread.turns.filter { keep.contains($0.key) }
        }
        for id in thread.turns.keys {
            guard var turn = thread.turns[id] else { continue }
            trimTurn(&turn)
            thread.turns[id] = turn
        }
    }

    private func trimTurn(_ turn: inout StoredTurn) {
        guard turn.items.count > configuration.maximumItemsPerTurn else { return }
        let keep = Set(turn.items.values
            .sorted(by: storedItemComesFirst)
            .prefix(configuration.maximumItemsPerTurn)
            .map(\.value.id))
        turn.items = turn.items.filter { keep.contains($0.key) }
    }

    private func trimRequestTombstones() {
        guard state.resolvedRequestTombstones.count
                > configuration.maximumResolvedRequestTombstones else { return }
        let keep = Set(state.resolvedRequestTombstones
            .sorted { left, right in
                if left.value != right.value { return left.value > right.value }
                if left.key.threadID != right.key.threadID {
                    return left.key.threadID < right.key.threadID
                }
                return left.key.requestID < right.key.requestID
            }
            .prefix(configuration.maximumResolvedRequestTombstones)
            .map(\.key))
        state.resolvedRequestTombstones = state.resolvedRequestTombstones.filter {
            keep.contains($0.key)
        }
        state.rejectsDeltasUntilReconnect = true
    }

    private func trimThreadTombstones() {
        guard state.threadTombstones.count > configuration.maximumThreadTombstones else {
            return
        }
        let keep = Set(state.threadTombstones
            .sorted { left, right in
                if left.value != right.value { return left.value > right.value }
                return left.key < right.key
            }
            .prefix(configuration.maximumThreadTombstones)
            .map(\.key))
        state.threadTombstones = state.threadTombstones.filter { keep.contains($0.key) }
        state.requiresSnapshot = true
    }

    private func hasTerminalConflict(_ thread: StoredThread) -> Bool {
        thread.turns.values.contains { turn in
            turn.terminalConflict || turn.items.values.contains(where: \.terminalConflict)
        }
    }

    /// Reads can contain the complete upstream history, which is intentionally
    /// larger than Conn's projection. Validate the entire input first, then
    /// retain the most recent turns/items from the protocol's ordered arrays.
    private func truncated(_ thread: AppServerThreadInput) -> AppServerThreadInput {
        let turns = thread.turns
            .suffix(configuration.maximumTurnsPerThread)
            .map(truncated)
        return AppServerThreadInput(
            id: thread.id,
            sessionID: thread.sessionID,
            title: thread.title,
            workingDirectoryName: thread.workingDirectoryName,
            workingDirectoryPath: thread.workingDirectoryPath,
            projectRootPath: thread.projectRootPath,
            gitBranch: thread.gitBranch,
            source: thread.source,
            parentThreadID: thread.parentThreadID,
            forkedFromThreadID: thread.forkedFromThreadID,
            status: thread.status,
            createdAt: thread.createdAt,
            updatedAt: thread.updatedAt,
            turnsAreAuthoritative: thread.turnsAreAuthoritative,
            turns: Array(turns)
        )
    }

    private func truncated(_ turn: AppServerTurnInput) -> AppServerTurnInput {
        let items = turn.items
            .suffix(configuration.maximumItemsPerTurn)
        return AppServerTurnInput(
            id: turn.id,
            status: turn.status,
            startedAt: turn.startedAt,
            completedAt: turn.completedAt,
            itemsView: turn.itemsView,
            items: Array(items)
        )
    }

    private func validateUnbounded(_ thread: AppServerThreadInput) -> Bool {
        validate(thread.id)
            && validate(thread.sessionID)
            && (thread.parentThreadID.map(validate) ?? true)
            && (thread.forkedFromThreadID.map(validate) ?? true)
            && bounded(thread.title) == thread.title
            && bounded(thread.workingDirectoryName) == thread.workingDirectoryName
            && bounded(thread.workingDirectoryPath) == thread.workingDirectoryPath
            && bounded(thread.projectRootPath) == thread.projectRootPath
            && bounded(thread.gitBranch) == thread.gitBranch
            && (thread.createdAt.map(validDate) ?? true)
            && validDate(thread.updatedAt)
            && Set(thread.turns.map(\.id)).count == thread.turns.count
            && thread.turns.allSatisfy(validateUnbounded)
    }

    private func validateUnbounded(_ turn: AppServerTurnInput) -> Bool {
        validate(turn.id)
            && (turn.startedAt.map(validDate) ?? true)
            && (turn.completedAt.map(validDate) ?? true)
            && Set(turn.items.map(\.id)).count == turn.items.count
            && turn.items.allSatisfy(validate)
    }

    private func validate(_ thread: AppServerThreadInput) -> Bool {
        validateUnbounded(thread)
            && thread.turns.count <= configuration.maximumTurnsPerThread
            && thread.turns.allSatisfy { $0.items.count <= configuration.maximumItemsPerTurn }
    }

    private func validate(_ cached: AppServerCachedThread) -> Bool {
        validate(cached.id)
            && (cached.sessionID.map(validate) ?? true)
            && (cached.parentThreadID.map(validate) ?? true)
            && (cached.forkedFromThreadID.map(validate) ?? true)
            && bounded(cached.title) == cached.title
            && bounded(cached.workingDirectoryName) == cached.workingDirectoryName
            && bounded(cached.workingDirectoryPath) == cached.workingDirectoryPath
            && bounded(cached.projectRootPath) == cached.projectRootPath
            && (cached.createdAt.map(validDate) ?? true)
            && validDate(cached.updatedAt)
            && validDate(cached.lastObservedAt)
            && cached.turns.count <= configuration.maximumTurnsPerThread
            && Set(cached.turns.map(\.id)).count == cached.turns.count
            && cached.turns.allSatisfy(validate)
    }

    private func validate(_ turn: AppServerTurnInput) -> Bool {
        validateUnbounded(turn)
            && turn.items.count <= configuration.maximumItemsPerTurn
    }

    private func validate(_ turn: AppServerProjectedTurn) -> Bool {
        validate(turn.id)
            && (turn.startedAt.map(validDate) ?? true)
            && (turn.completedAt.map(validDate) ?? true)
            && turn.items.count <= configuration.maximumItemsPerTurn
            && Set(turn.items.map(\.id)).count == turn.items.count
            && turn.items.allSatisfy(validate)
    }

    private func validate(_ item: AppServerItemInput) -> Bool {
        validate(item.id)
            && (item.startedAt.map(validDate) ?? true)
            && (item.completedAt.map(validDate) ?? true)
            && validate(item.presentation, for: item.kind)
    }

    private func validate(_ item: AppServerProjectedItem) -> Bool {
        validate(item.id)
            && (item.startedAt.map(validDate) ?? true)
            && (item.completedAt.map(validDate) ?? true)
            && validate(item.presentation, for: item.kind)
    }

    private func validate(_ delta: AppServerItemPresentationDelta) -> Bool {
        let limits = configuration.itemPresentationLimits
        switch delta {
        case let .agentText(value):
            return value.utf8.count <= limits.maximumTextUTF8Bytes
                && lineCount(value) <= limits.maximumTextLineCount
        case let .reasoningSummaryPartAdded(index):
            return index >= 0
                && index < min(
                    limits.maximumReasoningSummaryParts,
                    limits.maximumTextLineCount
                )
        case let .reasoningSummaryText(index, value):
            return index >= 0
                && index < min(
                    limits.maximumReasoningSummaryParts,
                    limits.maximumTextLineCount
                )
                && value.utf8.count <= limits.maximumTextUTF8Bytes
                && lineCount(value) <= limits.maximumTextLineCount
        }
    }

    private func validate(
        _ presentation: AppServerItemPresentationPayload?,
        for kind: AppServerItemKind
    ) -> Bool {
        guard let presentation else { return true }
        let limits = configuration.itemPresentationLimits

        func boundedText(_ value: String) -> Bool {
            value.utf8.count <= limits.maximumTextUTF8Bytes
                && lineCount(value) <= limits.maximumTextLineCount
        }

        func boundedSingleLine(_ value: String, maximumBytes: Int) -> Bool {
            !value.isEmpty
                && value.utf8.count <= maximumBytes
                && lineCount(value) == 1
        }

        switch presentation {
        case let .userText(value):
            return kind == .userMessage && boundedText(value)
        case let .agentText(value), let .agentFinalText(value):
            return kind == .agentMessage && boundedText(value)
        case let .planText(value):
            return kind == .plan && boundedText(value)
        case let .reasoningSummary(parts):
            return kind == .reasoning
                && parts.count <= limits.maximumReasoningSummaryParts
                && parts.reduce(0) { $0 + $1.utf8.count } <= limits.maximumTextUTF8Bytes
                && parts.reduce(0) { $0 + lineCount($1) } <= limits.maximumTextLineCount
        case let .command(value):
            return kind == .commandExecution && boundedText(value)
        case let .fileChanges(changes):
            return kind == .fileChange
                && changes.count <= limits.maximumFileChanges
                && changes.allSatisfy {
                    boundedSingleLine(
                        $0.path,
                        maximumBytes: limits.maximumPathUTF8Bytes
                    )
                }
        case let .tool(name, server):
            return [.mcpToolCall, .dynamicToolCall, .collabAgentToolCall].contains(kind)
                && boundedSingleLine(name, maximumBytes: limits.maximumNameUTF8Bytes)
                && (server.map {
                    boundedSingleLine($0, maximumBytes: limits.maximumNameUTF8Bytes)
                } ?? true)
        }
    }

    private func validate(_ usage: AppServerTokenUsage) -> Bool {
        usage.usedTokens >= 0
            && (usage.contextWindow.map { $0 > 0 } ?? true)
    }

    private func validate(_ plan: AppServerTurnPlan) -> Bool {
        let limits = configuration.itemPresentationLimits
        return validDate(plan.updatedAt)
            && plan.steps.count <= limits.maximumPlanSteps
            && plan.steps.allSatisfy {
                $0.step.utf8.count <= limits.maximumPlanStepUTF8Bytes
                    && lineCount($0.step) == 1
            }
    }

    private func lineCount(_ value: String) -> Int {
        var count = 1
        var previousWasCarriageReturn = false
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x0A:
                if !previousWasCarriageReturn { count += 1 }
                previousWasCarriageReturn = false
            case 0x0D:
                count += 1
                previousWasCarriageReturn = true
            case 0x85, 0x2028, 0x2029:
                count += 1
                previousWasCarriageReturn = false
            default:
                previousWasCarriageReturn = false
            }
        }
        return count
    }

    private func boundedPresentationText(_ value: String) -> String {
        let limits = configuration.itemPresentationLimits
        return boundedPresentationText(
            value,
            maximumBytes: limits.maximumTextUTF8Bytes,
            maximumLines: limits.maximumTextLineCount
        )
    }

    private func boundedPresentationText(
        _ value: String,
        maximumBytes: Int,
        maximumLines: Int
    ) -> String {
        var result = ""
        var byteCount = 0
        var lines = 1
        for character in value {
            let fragment = String(character)
            let nextLines = lineCount(fragment) - 1
            guard lines + nextLines <= maximumLines else { break }
            let bytes = fragment.utf8.count
            guard byteCount + bytes <= maximumBytes else { break }
            result.append(character)
            byteCount += bytes
            lines += nextLines
        }
        return result
    }

    private func validate(_ request: AppServerRequestInput) -> Bool {
        validate(request.requestID)
            && validate(request.threadID)
            && (request.turnID.map(validate) ?? true)
            && (request.itemID.map(validate) ?? true)
            && validDate(request.startedAt)
    }

    private func validate(_ id: AppServerThreadID) -> Bool { validate(id.rawValue) }
    private func validate(_ id: AppServerSessionID) -> Bool { validate(id.rawValue) }
    private func validate(_ id: AppServerTurnID) -> Bool { validate(id.rawValue) }
    private func validate(_ id: AppServerItemID) -> Bool { validate(id.rawValue) }
    private func validate(_ id: AppServerRequestID) -> Bool {
        switch id {
        case .integer: true
        case let .string(value): validate(value)
        }
    }

    private func validate(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= configuration.maximumStringBytes
    }

    private func validDate(_ date: Date) -> Bool { date.timeIntervalSince1970.isFinite }

    private func later(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (left?, right?): max(left, right)
        case let (left?, nil): left
        case let (nil, right?): right
        case (nil, nil): nil
        }
    }

    private func bounded(_ value: String?) -> String? {
        guard let value else { return nil }
        return value.utf8.count <= configuration.maximumStringBytes ? value : nil
    }

    private func moreComplete(
        _ lhs: AppServerTurnItemsView,
        _ rhs: AppServerTurnItemsView
    ) -> AppServerTurnItemsView {
        func rank(_ value: AppServerTurnItemsView) -> Int {
            switch value {
            case .notLoaded: 0
            case .summary: 1
            case .full: 2
            }
        }
        return rank(rhs) >= rank(lhs) ? rhs : lhs
    }

    private func storedThreadComesFirst(_ lhs: StoredThread, _ rhs: StoredThread) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id < rhs.id
    }

    private func storedTurnComesFirst(_ lhs: StoredTurn, _ rhs: StoredTurn) -> Bool {
        let left = lhs.completedAt ?? lhs.startedAt ?? .distantPast
        let right = rhs.completedAt ?? rhs.startedAt ?? .distantPast
        if left != right { return left > right }
        return lhs.id < rhs.id
    }

    private func storedItemComesFirst(_ lhs: StoredItem, _ rhs: StoredItem) -> Bool {
        // Authoritative arrays are chronological and live deltas append the
        // next ordinal. Item timestamps are commonly absent, so trimming by
        // opaque IDs can discard the newest commentary/final answer while
        // retaining older call-* and exec-* activity.
        if lhs.order != rhs.order { return lhs.order > rhs.order }
        if lhs.sequence != rhs.sequence { return lhs.sequence > rhs.sequence }
        return lhs.value.id < rhs.value.id
    }

    private func projectedThreadComesFirst(
        _ lhs: AppServerProjectedThread,
        _ rhs: AppServerProjectedThread
    ) -> Bool {
        // Thread.updatedAt is the daemon's authoritative activity order.
        // Local selection/read observations must never promote an older row.
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id < rhs.id
    }

    private func projectedTurnComesFirst(
        _ lhs: AppServerProjectedTurn,
        _ rhs: AppServerProjectedTurn
    ) -> Bool {
        let left = lhs.completedAt ?? lhs.startedAt ?? .distantPast
        let right = rhs.completedAt ?? rhs.startedAt ?? .distantPast
        if left != right { return left > right }
        return lhs.id < rhs.id
    }

    private func projectedItemComesFirst(
        _ lhs: AppServerProjectedItem,
        _ rhs: AppServerProjectedItem
    ) -> Bool {
        let left = lhs.completedAt ?? lhs.startedAt ?? .distantPast
        let right = rhs.completedAt ?? rhs.startedAt ?? .distantPast
        if left != right { return left > right }
        return lhs.id < rhs.id
    }

    private func projectedRequestComesFirst(
        _ lhs: AppServerProjectedRequest,
        _ rhs: AppServerProjectedRequest
    ) -> Bool {
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
        return lhs.id.requestID < rhs.id.requestID
    }
}
