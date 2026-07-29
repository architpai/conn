import Foundation
import ConnDomain

public struct ConnUserFacingNotification: Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionID: ConnSessionID
    public let sessionTitle: String
    public let text: String
    public let observedAt: Date
    public let isFinal: Bool
}

public struct ConnUserFacingNotificationBatch: Equatable, Identifiable, Sendable {
    public let notifications: [ConnUserFacingNotification]
    public let duration: TimeInterval

    public var id: String { notifications.map(\.id).joined(separator: "|") }
}

private struct ConnNotificationRunIdentity: Hashable, Sendable {
    let sessionID: ConnSessionID
    let runID: RunID
}

private struct ConnNotificationCandidate: Sendable {
    let notification: ConnUserFacingNotification
    let runID: RunID?
}

public struct ConnUserFacingNotificationLedger: Sendable {
    private var seenActivityIDs: Set<String> = []
    private var activeRunIDs: Set<ConnNotificationRunIdentity> = []
    private var activeSessionIDs: Set<ConnSessionID> = []
    private var hasSeeded = false

    public init() {}

    public mutating func collect(
        from presentation: ConnDomainPresentation
    ) -> [ConnUserFacingNotification] {
        let candidates = presentation.sessions.flatMap { session in
            session.activities.compactMap { item -> ConnNotificationCandidate? in
                guard item.activity.kind == .agentMessage,
                      item.activity.status == .completed,
                      let text = item.detail?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                      ),
                      !text.isEmpty else { return nil }
                let id = "\(session.id.integrationID.rawValue)|"
                    + "\(session.id.upstreamID.rawValue)|\(item.id.rawValue)"
                return ConnNotificationCandidate(
                    notification: .init(
                        id: id,
                        sessionID: session.id,
                        sessionTitle: session.title,
                        text: text,
                        observedAt: item.activity.observedAt,
                        isFinal: session.visualState == .completed
                    ),
                    runID: item.activity.runID
                )
            }
        }.sorted {
            if $0.notification.observedAt != $1.notification.observedAt {
                return $0.notification.observedAt < $1.notification.observedAt
            }
            return $0.notification.id < $1.notification.id
        }
        let currentActiveRunIDs = Set(presentation.sessions.flatMap { session in
            session.runs.compactMap { run in
                run.run.status == .inProgress
                    ? ConnNotificationRunIdentity(
                        sessionID: session.id,
                        runID: run.id
                    )
                    : nil
            }
        })
        let currentActiveSessionIDs = Set(
            presentation.sessions.filter(\.isActive).map(\.id)
        )
        defer {
            activeRunIDs = currentActiveRunIDs
            activeSessionIDs = currentActiveSessionIDs
        }
        if !hasSeeded {
            seenActivityIDs.formUnion(candidates.map(\.notification.id))
            hasSeeded = true
            return []
        }
        let unseen = candidates.filter {
            !seenActivityIDs.contains($0.notification.id)
        }
        seenActivityIDs.formUnion(unseen.map(\.notification.id))
        let observedActiveRunIDs = activeRunIDs.union(currentActiveRunIDs)
        let observedActiveSessionIDs = activeSessionIDs.union(
            currentActiveSessionIDs
        )
        return unseen.compactMap { candidate in
            if let runID = candidate.runID {
                let identity = ConnNotificationRunIdentity(
                    sessionID: candidate.notification.sessionID,
                    runID: runID
                )
                if observedActiveRunIDs.contains(identity) {
                    return candidate.notification
                }
                return nil
            }
            return observedActiveSessionIDs.contains(
                candidate.notification.sessionID
            ) ? candidate.notification : nil
        }
    }

    public mutating func reset() {
        seenActivityIDs.removeAll()
        activeRunIDs.removeAll()
        activeSessionIDs.removeAll()
        hasSeeded = false
    }
}

public enum ConnUserFacingNotificationPolicy {
    public static let maximumMessagesPerBatch = 2
    public static let minimumDuration: TimeInterval = 5
    public static let maximumDuration: TimeInterval = 10

    public static func batch(
        _ notifications: [ConnUserFacingNotification]
    ) -> ConnUserFacingNotificationBatch? {
        let selected = Array(notifications.suffix(maximumMessagesPerBatch))
        guard !selected.isEmpty else { return nil }
        let characters = selected.reduce(0) { $0 + $1.text.count }
        return .init(
            notifications: selected,
            duration: min(
                max(minimumDuration + Double(characters) / 80, minimumDuration),
                maximumDuration
            )
        )
    }

    public static func reconcileFinality(
        of batch: ConnUserFacingNotificationBatch,
        with presentation: ConnDomainPresentation
    ) -> ConnUserFacingNotificationBatch {
        let completedSessionIDs = Set(
            presentation.sessions.compactMap {
                $0.visualState == .completed ? $0.id : nil
            }
        )
        let reconciled = batch.notifications.map { notification in
            guard !notification.isFinal,
                  completedSessionIDs.contains(notification.sessionID) else {
                return notification
            }
            return ConnUserFacingNotification(
                id: notification.id,
                sessionID: notification.sessionID,
                sessionTitle: notification.sessionTitle,
                text: notification.text,
                observedAt: notification.observedAt,
                isFinal: true
            )
        }
        return .init(
            notifications: reconciled,
            duration: batch.duration
        )
    }
}
