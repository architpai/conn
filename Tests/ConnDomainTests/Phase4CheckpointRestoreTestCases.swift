import Foundation
import ConnDomain

enum Phase4CheckpointRestoreTestCases {
    static func run(into suite: inout TestSuite) throws {
        let integrationID = IntegrationID(rawValue: "restore-fixture")
        let sessionID = ConnSessionID(
            integrationID: integrationID,
            upstreamID: .init(rawValue: "session")
        )
        let persisted = PersistedIntegrationProjection(
            descriptor: .init(
                id: integrationID,
                harnessID: .init(rawValue: "synthetic"),
                displayName: "Synthetic"
            ),
            inventoryAuthority: .complete,
            sessions: [.init(
                id: sessionID,
                status: .idle,
                updatedAt: Date(timeIntervalSince1970: 1_860_000_000)
            )],
            checkpointedAt: Date(timeIntervalSince1970: 1_860_000_001)
        )
        var projection = IntegrationProjection()
        suite.check(
            projection.restore(persisted) == .restored,
            "valid presentation-only checkpoint restores"
        )
        suite.check(
            projection.freshness == .rehydrated,
            "restored projection is explicitly rehydrated"
        )
        suite.check(
            projection.generation == nil
                && !projection.capabilities.canMonitor
                && projection.capabilities.actions.isEmpty,
            "restore cannot recreate runtime generation or capability proof"
        )
        suite.check(
            !projection.hasCurrentAuthority(for: sessionID),
            "restored Session is never actionable"
        )
        suite.check(
            projection.sessionsByID[sessionID] != nil
                && projection.attentionRequests.isEmpty,
            "bounded Session presentation restores without Attention authority"
        )

        let checkpoint = ConnProjectionCheckpoint(integrations: [persisted])
        try checkpoint.validate()
        suite.check(
            checkpoint.format == ConnProjectionCheckpoint.formatDiscriminator,
            "neutral checkpoint carries the v0.2 format discriminator"
        )
        do {
            try ConnProjectionCheckpoint(
                format: "app-server-projection",
                integrations: [persisted]
            ).validate()
            suite.check(false, "provider-shaped checkpoint root is rejected")
        } catch {
            suite.check(
                error as? ConnProjectionCheckpointError
                    == .unsupportedFormat("app-server-projection"),
                "format mismatch fails closed before restore"
            )
        }

        projection.markStale()
        suite.check(
            projection.freshness == .stale
                && projection.generation == nil
                && projection.attentionRequests.isEmpty,
            "marking stale revokes all runtime-only authority"
        )
    }
}
