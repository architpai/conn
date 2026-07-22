import Foundation
import ConnDomain

public struct ShellUserFacingNotification: Equatable, Sendable, Identifiable {
    public let id: String
    public let threadID: AppServerThreadID
    public let threadTitle: String
    public let itemID: String
    public let text: String
    public let observedAt: Date
    public let sourceOrder: Int
    public let isFinalAnswer: Bool

    public init(
        id: String,
        threadID: AppServerThreadID,
        threadTitle: String,
        itemID: String,
        text: String,
        observedAt: Date,
        sourceOrder: Int = 0,
        isFinalAnswer: Bool
    ) {
        self.id = id
        self.threadID = threadID
        self.threadTitle = threadTitle
        self.itemID = itemID
        self.text = text
        self.observedAt = observedAt
        self.sourceOrder = sourceOrder
        self.isFinalAnswer = isFinalAnswer
    }
}

public struct ShellUserFacingNotificationGroup: Equatable, Sendable, Identifiable {
    public let threadID: AppServerThreadID
    public let threadTitle: String
    public let messages: [ShellUserFacingNotification]

    public var id: String { threadID.rawValue }
}

public struct ShellUserFacingNotificationBatch: Equatable, Sendable, Identifiable {
    public let groups: [ShellUserFacingNotificationGroup]
    public let duration: TimeInterval

    public var id: String {
        groups.flatMap(\.messages).map(\.id).joined(separator: "|")
    }

    public var primaryThreadID: AppServerThreadID {
        groups[0].threadID
    }

    public var showsCompletionIndicator: Bool {
        groups.flatMap(\.messages).last?.isFinalAnswer == true
    }

    public var preferredHeight: CGFloat {
        let messageCount = groups.reduce(0) { $0 + $1.messages.count }
        let headingCount = groups.count
        return min(112, CGFloat(24 + messageCount * 28 + headingCount * 14))
    }
}

public struct ShellUserFacingNotificationSeedLedger: Sendable {
    private var seededThreadIDs: Set<AppServerThreadID> = []

    public init() {}

    public mutating func consume(
        _ threads: [AppServerProjectedThread]
    ) -> Set<String> {
        let unseededThreads = threads.filter {
            !$0.turns.isEmpty && !seededThreadIDs.contains($0.id)
        }
        seededThreadIDs.formUnion(unseededThreads.map(\.id))
        return ShellUserFacingNotificationPolicy.silentSeedIDs(from: unseededThreads)
    }

    public mutating func reset() {
        seededThreadIDs.removeAll(keepingCapacity: false)
    }
}

public enum ShellUserFacingNotificationPolicy {
    public static let maximumMessagesPerBatch = 2
    public static let minimumDuration: TimeInterval = 5
    public static let maximumDuration: TimeInterval = 10

    public static func isEligible(
        category: AppServerTimelineCategory,
        statusLabel: String,
        text: String?
    ) -> Bool {
        guard statusLabel == "Completed",
              category == .agentOutput || category == .finalAnswer,
              let text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return true
    }

    public static func shouldSeedFirstHydration(
        wasHydrated: Bool,
        visualState: AppServerThreadVisualState
    ) -> Bool {
        _ = visualState
        // A first detailed read has no receive watermark that can distinguish
        // current prose from older history. Seed it silently in every state;
        // subsequent live item completions are the first honest notifications.
        return !wasHydrated
    }

    /// Only assistant-authored text that Codex exposes to the user qualifies.
    /// Commands, tools, file reads, reasoning, plans, and lifecycle events are
    /// deliberately excluded even when they are the newest timeline item.
    public static func collect(
        from threads: [AppServerThreadPresentation]
    ) -> [ShellUserFacingNotification] {
        threads.flatMap { thread in
            thread.timeline.compactMap { item in
                guard isEligible(
                    category: item.category,
                    statusLabel: item.statusLabel,
                    text: item.detail
                ),
                      let text = item.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
                else { return nil }
                return ShellUserFacingNotification(
                    id: AppServerPresentationIdentity.notification(
                        threadID: thread.threadID,
                        timelineItemID: item.id
                    ),
                    threadID: thread.threadID,
                    threadTitle: thread.title,
                    itemID: item.id,
                    text: text,
                    observedAt: item.observedAt,
                    sourceOrder: item.sourceOrder,
                    isFinalAnswer: item.category == .finalAnswer
                )
            }
        }.sorted(by: chronological)
    }

    /// Completed assistant items can be restored from a privacy-bounded
    /// checkpoint before their runtime-only text is materialized again. Seed
    /// those stable identities silently so a later resume cannot replay the
    /// historical completion as a new notification.
    public static func silentSeedIDs(
        from threads: [AppServerProjectedThread]
    ) -> Set<String> {
        Set(threads.flatMap { thread in
            thread.turns.flatMap { turn in
                turn.items.compactMap { item in
                    guard item.kind == .agentMessage,
                          item.status == .completed,
                          item.presentation == nil
                    else { return nil }
                    return AppServerPresentationIdentity.notification(
                        threadID: thread.id,
                        timelineItemID: AppServerPresentationIdentity.timelineItem(
                            turnID: turn.id,
                            itemID: item.id
                        )
                    )
                }
            }
        })
    }

    public static func unseen(
        _ notifications: [ShellUserFacingNotification],
        excluding seenIDs: Set<String>
    ) -> [ShellUserFacingNotification] {
        notifications.filter { !seenIDs.contains($0.id) }
    }

    public static func batch(
        _ notifications: [ShellUserFacingNotification]
    ) -> ShellUserFacingNotificationBatch? {
        // When commentary arrives faster than the shelf lifetime, mirror the
        // transcript's newest user-facing text instead of showing a stale
        // queue head. The selected suffix remains chronological on screen.
        let selected = Array(
            notifications.sorted(by: chronological).suffix(maximumMessagesPerBatch)
        )
        guard !selected.isEmpty else { return nil }

        var order: [AppServerThreadID] = []
        var messagesByThread: [AppServerThreadID: [ShellUserFacingNotification]] = [:]
        var titleByThread: [AppServerThreadID: String] = [:]
        for notification in selected {
            if messagesByThread[notification.threadID] == nil { order.append(notification.threadID) }
            messagesByThread[notification.threadID, default: []].append(notification)
            titleByThread[notification.threadID] = notification.threadTitle
        }
        let groups = order.map { threadID in
            ShellUserFacingNotificationGroup(
                threadID: threadID,
                threadTitle: titleByThread[threadID] ?? "Thread",
                messages: messagesByThread[threadID] ?? []
            )
        }
        let characterCount = selected.reduce(0) { $0 + $1.text.count }
        let readingDuration = minimumDuration + Double(characterCount) / 80
        return .init(
            groups: groups,
            duration: min(max(readingDuration, minimumDuration), maximumDuration)
        )
    }

    private static func chronological(
        _ lhs: ShellUserFacingNotification,
        _ rhs: ShellUserFacingNotification
    ) -> Bool {
        if lhs.observedAt != rhs.observedAt { return lhs.observedAt < rhs.observedAt }
        if lhs.threadID == rhs.threadID, lhs.sourceOrder != rhs.sourceOrder {
            return lhs.sourceOrder < rhs.sourceOrder
        }
        return lhs.id < rhs.id
    }
}
