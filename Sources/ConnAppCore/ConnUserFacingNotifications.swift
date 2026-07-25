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

public struct ConnUserFacingNotificationLedger: Sendable {
    private var seenActivityIDs: Set<String> = []
    private var hasSeeded = false

    public init() {}

    public mutating func collect(
        from presentation: ConnDomainPresentation
    ) -> [ConnUserFacingNotification] {
        let eligible = presentation.sessions.flatMap { session in
            session.activities.compactMap { item -> ConnUserFacingNotification? in
                guard item.activity.kind == .agentMessage,
                      item.activity.status == .completed,
                      let text = item.detail?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                      ),
                      !text.isEmpty else { return nil }
                let id = "\(session.id.integrationID.rawValue)|"
                    + "\(session.id.upstreamID.rawValue)|\(item.id.rawValue)"
                return .init(
                    id: id,
                    sessionID: session.id,
                    sessionTitle: session.title,
                    text: text,
                    observedAt: item.activity.observedAt,
                    isFinal: session.visualState == .completed
                )
            }
        }.sorted {
            if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
            return $0.id < $1.id
        }
        if !hasSeeded {
            seenActivityIDs.formUnion(eligible.map(\.id))
            hasSeeded = true
            return []
        }
        let unseen = eligible.filter { !seenActivityIDs.contains($0.id) }
        seenActivityIDs.formUnion(unseen.map(\.id))
        return unseen
    }

    public mutating func reset() {
        seenActivityIDs.removeAll()
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
}
