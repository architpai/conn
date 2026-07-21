import Foundation
import ConnDomain

/// Conn-local review identity. It contains only upstream IDs and is kept
/// separate from the disposable App Server projection checkpoint.
public struct AppServerOutcomeIdentity: Codable, Equatable, Hashable, Sendable {
    public let threadID: AppServerThreadID
    public let turnID: AppServerTurnID

    public init(threadID: AppServerThreadID, turnID: AppServerTurnID) {
        self.threadID = threadID
        self.turnID = turnID
    }
}

public enum AppServerOutcomeReviewDisposition: String, Codable, Equatable, Sendable {
    case reviewed
    case unreviewed
}

public struct AppServerOutcomeReviewMarker: Codable, Equatable, Sendable {
    public let identity: AppServerOutcomeIdentity
    public let disposition: AppServerOutcomeReviewDisposition
    public let observedAt: Date
    public let reviewedAt: Date?

    public init(
        identity: AppServerOutcomeIdentity,
        disposition: AppServerOutcomeReviewDisposition,
        observedAt: Date,
        reviewedAt: Date? = nil
    ) {
        self.identity = identity
        self.disposition = disposition
        self.observedAt = observedAt
        self.reviewedAt = reviewedAt
    }
}

/// Bounded durable local-UX state. A baseline timestamp prevents an upgrade
/// from presenting historical terminal turns as hundreds of new completions.
public struct AppServerOutcomeReviewLedger: Codable, Equatable, Sendable {
    public static let maximumMarkers = 1_000
    public static let maximumIdentityUTF8Bytes = 512

    public let baselineAt: Date
    private var hasEstablishedAuthoritativeBaseline: Bool
    private var observedActiveTurnByThreadID: [String: AppServerOutcomeIdentity]
    private var markersByThreadID: [String: AppServerOutcomeReviewMarker]

    public init(baselineAt: Date = Date()) {
        self.baselineAt = baselineAt
        hasEstablishedAuthoritativeBaseline = false
        observedActiveTurnByThreadID = [:]
        markersByThreadID = [:]
    }

    public var markers: [AppServerOutcomeReviewMarker] {
        markersByThreadID.values.sorted(by: Self.markerComesBefore)
    }

    public var unreviewedOutcomeIDs: Set<AppServerOutcomeIdentity> {
        Set(markersByThreadID.values.compactMap {
            $0.disposition == .unreviewed ? $0.identity : nil
        })
    }

    public var reviewedOutcomeIDs: Set<AppServerOutcomeIdentity> {
        Set(markersByThreadID.values.compactMap {
            $0.disposition == .reviewed ? $0.identity : nil
        })
    }

    @discardableResult
    public mutating func reconcile(
        with snapshot: AppServerProjectionSnapshot,
        hasCurrentAuthority: Bool,
        observedAt: Date = Date()
    ) -> Bool {
        guard hasCurrentAuthority else { return false }
        let isBaselinePass = !hasEstablishedAuthoritativeBaseline
        var changed = isBaselinePass
        for thread in snapshot.threads where thread.freshness == .live {
            if thread.activeTurnIDs.count == 1,
               let activeTurnID = thread.activeTurnIDs.first {
                let activeIdentity = AppServerOutcomeIdentity(
                    threadID: thread.id,
                    turnID: activeTurnID
                )
                if Self.isValid(activeIdentity),
                   observedActiveTurnByThreadID[thread.id.rawValue] != activeIdentity {
                    observedActiveTurnByThreadID[thread.id.rawValue] = activeIdentity
                    changed = true
                }
            }
            guard let outcome = thread.outcome else { continue }
            let identity = AppServerOutcomeIdentity(
                threadID: outcome.threadID,
                turnID: outcome.turnID
            )
            guard Self.isValid(identity) else { continue }
            let wasObservedActive = observedActiveTurnByThreadID[thread.id.rawValue] == identity
            if wasObservedActive {
                observedActiveTurnByThreadID.removeValue(forKey: thread.id.rawValue)
            }
            if markersByThreadID[thread.id.rawValue]?.identity == identity { continue }
            let isProvenNew = !isBaselinePass
                && (outcome.completedAt.map { $0 > baselineAt } ?? wasObservedActive)
            markersByThreadID[thread.id.rawValue] = .init(
                identity: identity,
                disposition: isProvenNew ? .unreviewed : .reviewed,
                observedAt: outcome.completedAt ?? observedAt,
                reviewedAt: isProvenNew ? nil : baselineAt
            )
            changed = true
        }
        hasEstablishedAuthoritativeBaseline = true
        if trimActiveTurnsToBound() { changed = true }
        if trimToBound() { changed = true }
        return changed
    }

    /// Reviews only the exact latest marker for one thread. If a newer turn
    /// raced the user's click, the captured older identity is a no-op.
    @discardableResult
    public mutating func markReviewed(
        _ identity: AppServerOutcomeIdentity,
        at date: Date = Date()
    ) -> Bool {
        guard date.timeIntervalSince1970.isFinite,
              var marker = markersByThreadID[identity.threadID.rawValue],
              marker.identity == identity,
              marker.disposition == .unreviewed else { return false }
        marker = .init(
            identity: marker.identity,
            disposition: .reviewed,
            observedAt: marker.observedAt,
            reviewedAt: date
        )
        markersByThreadID[identity.threadID.rawValue] = marker
        return true
    }

    public func isValid() -> Bool {
        baselineAt.timeIntervalSince1970.isFinite
            && observedActiveTurnByThreadID.count <= Self.maximumMarkers
            && observedActiveTurnByThreadID.allSatisfy { key, identity in
                key == identity.threadID.rawValue && Self.isValid(identity)
            }
            && markersByThreadID.count <= Self.maximumMarkers
            && markersByThreadID.allSatisfy { key, marker in
                key == marker.identity.threadID.rawValue
                    && Self.isValid(marker.identity)
                    && marker.observedAt.timeIntervalSince1970.isFinite
                    && (marker.reviewedAt?.timeIntervalSince1970.isFinite ?? true)
                    && (marker.disposition == .reviewed) == (marker.reviewedAt != nil)
            }
    }

    private mutating func trimToBound() -> Bool {
        guard markersByThreadID.count > Self.maximumMarkers else { return false }
        let retained = markers.prefix(Self.maximumMarkers)
        markersByThreadID = Dictionary(uniqueKeysWithValues: retained.map {
            ($0.identity.threadID.rawValue, $0)
        })
        return true
    }

    private mutating func trimActiveTurnsToBound() -> Bool {
        guard observedActiveTurnByThreadID.count > Self.maximumMarkers else { return false }
        let retained = observedActiveTurnByThreadID.values
            .sorted {
                if $0.threadID != $1.threadID { return $0.threadID < $1.threadID }
                return $0.turnID < $1.turnID
            }
            .prefix(Self.maximumMarkers)
        observedActiveTurnByThreadID = Dictionary(uniqueKeysWithValues: retained.map {
            ($0.threadID.rawValue, $0)
        })
        return true
    }

    private static func markerComesBefore(
        _ lhs: AppServerOutcomeReviewMarker,
        _ rhs: AppServerOutcomeReviewMarker
    ) -> Bool {
        if lhs.disposition != rhs.disposition {
            return lhs.disposition == .unreviewed
        }
        if lhs.observedAt != rhs.observedAt { return lhs.observedAt > rhs.observedAt }
        if lhs.identity.threadID != rhs.identity.threadID {
            return lhs.identity.threadID < rhs.identity.threadID
        }
        return lhs.identity.turnID < rhs.identity.turnID
    }

    private static func isValid(_ identity: AppServerOutcomeIdentity) -> Bool {
        !identity.threadID.rawValue.isEmpty
            && !identity.turnID.rawValue.isEmpty
            && identity.threadID.rawValue.utf8.count <= maximumIdentityUTF8Bytes
            && identity.turnID.rawValue.utf8.count <= maximumIdentityUTF8Bytes
    }
}

/// Versioned UserDefaults adapter for the bounded review ledger. Conversation
/// content is structurally absent; corrupt or oversized data starts a fresh
/// baseline instead of inventing unread outcomes.
public struct AppServerOutcomeReviewPreferenceStore {
    private struct Wrapper: Codable {
        static let currentVersion = 1
        let version: Int
        let ledger: AppServerOutcomeReviewLedger
    }

    public static let defaultKey = "appServerOutcomeReviewLedger.v1"
    public static let maximumEncodedBytes = 2 * 1_024 * 1_024

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load(orBaselineAt date: Date = Date()) -> AppServerOutcomeReviewLedger {
        guard let data = defaults.data(forKey: key),
              data.count <= Self.maximumEncodedBytes,
              let wrapper = try? JSONDecoder().decode(Wrapper.self, from: data),
              wrapper.version == Wrapper.currentVersion,
              wrapper.ledger.isValid() else {
            return .init(baselineAt: date)
        }
        return wrapper.ledger
    }

    @discardableResult
    public func save(_ ledger: AppServerOutcomeReviewLedger) -> Bool {
        guard ledger.isValid(),
              let data = try? JSONEncoder().encode(Wrapper(
                  version: Wrapper.currentVersion,
                  ledger: ledger
              )),
              data.count <= Self.maximumEncodedBytes else { return false }
        defaults.set(data, forKey: key)
        return true
    }
}
