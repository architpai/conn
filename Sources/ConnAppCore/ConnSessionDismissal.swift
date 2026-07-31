import Foundation
import ConnDomain

public struct ConnSessionDismissalLedger: Codable, Equatable, Sendable {
    public static let maximumRecords = 1_000

    private struct Record: Codable, Equatable, Sendable {
        let dismissedAt: Date
        let messageActivityIDs: Set<ActivityID>
        let attentionRequestIDs: Set<AttentionRequestID>
    }

    private var recordsBySessionID: [ConnSessionID: Record] = [:]

    public init() {}

    public var dismissedSessionIDs: Set<ConnSessionID> {
        Set(recordsBySessionID.keys)
    }

    @discardableResult
    public mutating func dismiss(
        _ session: ConnSessionPresentation,
        at date: Date = Date()
    ) -> Bool {
        guard date.timeIntervalSince1970.isFinite else { return false }
        let replacement = Record(
            dismissedAt: date,
            messageActivityIDs: Self.messageActivityIDs(in: session),
            attentionRequestIDs: Set(session.attention.map(\.id))
        )
        guard recordsBySessionID[session.id] != replacement else {
            return false
        }
        recordsBySessionID[session.id] = replacement
        trim()
        return true
    }

    @discardableResult
    public mutating func reconcile(
        with sessions: [ConnSessionPresentation]
    ) -> Bool {
        var restoredSessionIDs: [ConnSessionID] = []
        for session in sessions {
            guard let record = recordsBySessionID[session.id] else {
                continue
            }
            let hasNewMessage = !Self.messageActivityIDs(in: session)
                .isSubset(of: record.messageActivityIDs)
            let hasNewAttention = !Set(session.attention.map(\.id))
                .isSubset(of: record.attentionRequestIDs)
            if hasNewMessage || hasNewAttention {
                restoredSessionIDs.append(session.id)
            }
        }
        for sessionID in restoredSessionIDs {
            recordsBySessionID.removeValue(forKey: sessionID)
        }
        return !restoredSessionIDs.isEmpty
    }

    @discardableResult
    public mutating func restore(_ sessionID: ConnSessionID) -> Bool {
        recordsBySessionID.removeValue(forKey: sessionID) != nil
    }

    public func isValid() -> Bool {
        recordsBySessionID.count <= Self.maximumRecords
            && recordsBySessionID.values.allSatisfy {
                $0.dismissedAt.timeIntervalSince1970.isFinite
            }
    }

    private mutating func trim() {
        guard recordsBySessionID.count > Self.maximumRecords else {
            return
        }
        let retained = recordsBySessionID.sorted {
            if $0.value.dismissedAt != $1.value.dismissedAt {
                return $0.value.dismissedAt > $1.value.dismissedAt
            }
            return $0.key < $1.key
        }.prefix(Self.maximumRecords)
        recordsBySessionID = Dictionary(
            uniqueKeysWithValues: retained.map { ($0.key, $0.value) }
        )
    }

    private static func messageActivityIDs(
        in session: ConnSessionPresentation
    ) -> Set<ActivityID> {
        Set(session.activities.compactMap { activity in
            switch activity.activity.kind {
            case .userMessage, .agentMessage: activity.id
            case .plan, .reasoning, .command, .fileChange, .toolCall,
                 .subagent, .webSearch, .image, .compaction, .unknown:
                nil
            }
        })
    }
}

public struct ConnSessionDismissalPreferenceStore {
    private struct Wrapper: Codable {
        static let version = 1
        let version: Int
        let ledger: ConnSessionDismissalLedger
    }

    public static let defaultKey = "connSessionDismissals.v1"
    public static let maximumEncodedBytes = 2 * 1_024 * 1_024

    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = defaultKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> ConnSessionDismissalLedger {
        guard let data = defaults.data(forKey: key),
              data.count <= Self.maximumEncodedBytes,
              let wrapper = try? JSONDecoder().decode(Wrapper.self, from: data),
              wrapper.version == Wrapper.version,
              wrapper.ledger.isValid() else {
            return .init()
        }
        return wrapper.ledger
    }

    @discardableResult
    public func save(_ ledger: ConnSessionDismissalLedger) -> Bool {
        guard ledger.isValid(),
              let data = try? JSONEncoder().encode(Wrapper(
                version: Wrapper.version,
                ledger: ledger
              )),
              data.count <= Self.maximumEncodedBytes else {
            return false
        }
        defaults.set(data, forKey: key)
        return true
    }
}
