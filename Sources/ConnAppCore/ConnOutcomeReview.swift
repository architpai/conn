import Foundation
import ConnDomain

public struct ConnOutcomeIdentity: Codable, Equatable, Hashable, Sendable {
    public let sessionID: ConnSessionID
    public let runID: RunID

    public init(sessionID: ConnSessionID, runID: RunID) {
        self.sessionID = sessionID
        self.runID = runID
    }
}

public enum ConnOutcomeReviewDisposition: String, Codable, Equatable, Sendable {
    case reviewed
    case unreviewed
}

public struct ConnOutcomeReviewMarker: Codable, Equatable, Sendable {
    public let identity: ConnOutcomeIdentity
    public let disposition: ConnOutcomeReviewDisposition
    public let observedAt: Date
    public let reviewedAt: Date?
}

/// A fresh v0.2 review baseline. It never decodes the provider-shaped v0.1
/// ledger, so historical completions cannot appear as newly completed Runs.
public struct ConnOutcomeReviewLedger: Codable, Equatable, Sendable {
    public static let maximumMarkers = 1_000

    public let baselineAt: Date
    private var baselineEstablished = false
    private var activeRunBySessionID: [ConnSessionID: RunID] = [:]
    private var markersBySessionID: [ConnSessionID: ConnOutcomeReviewMarker] = [:]

    public init(baselineAt: Date = Date()) {
        self.baselineAt = baselineAt
    }

    public var markers: [ConnOutcomeReviewMarker] {
        markersBySessionID.values.sorted {
            if $0.disposition != $1.disposition {
                return $0.disposition == .unreviewed
            }
            if $0.observedAt != $1.observedAt {
                return $0.observedAt > $1.observedAt
            }
            return $0.identity.sessionID < $1.identity.sessionID
        }
    }

    public var unreviewedOutcomeIDs: Set<ConnOutcomeIdentity> {
        Set(markers.compactMap {
            $0.disposition == .unreviewed ? $0.identity : nil
        })
    }

    public var reviewedOutcomeIDs: Set<ConnOutcomeIdentity> {
        Set(markers.compactMap {
            $0.disposition == .reviewed ? $0.identity : nil
        })
    }

    @discardableResult
    public mutating func reconcile(
        with snapshot: ConnAggregateSnapshot,
        observedAt: Date = Date()
    ) -> Bool {
        let isBaselinePass = !baselineEstablished
        var changed = isBaselinePass
        for state in snapshot.sessions where state.freshness == .live {
            let session = state.session
            if let active = session.runs.last(where: { $0.status == .inProgress }) {
                if activeRunBySessionID[session.id] != active.id {
                    activeRunBySessionID[session.id] = active.id
                    changed = true
                }
            }
            guard let terminal = session.runs.last(where: {
                $0.status == .completed || $0.status == .failed || $0.status == .interrupted
            }) else { continue }
            let identity = ConnOutcomeIdentity(sessionID: session.id, runID: terminal.id)
            guard markersBySessionID[session.id]?.identity != identity else { continue }
            let wasActive = activeRunBySessionID.removeValue(forKey: session.id) == terminal.id
            let completedAt = terminal.completedAt ?? observedAt
            let isNew = !isBaselinePass && (wasActive || completedAt > baselineAt)
            markersBySessionID[session.id] = .init(
                identity: identity,
                disposition: isNew ? .unreviewed : .reviewed,
                observedAt: completedAt,
                reviewedAt: isNew ? nil : baselineAt
            )
            changed = true
        }
        baselineEstablished = true
        trim()
        return changed
    }

    @discardableResult
    public mutating func markReviewed(
        _ identity: ConnOutcomeIdentity,
        at date: Date = Date()
    ) -> Bool {
        guard var marker = markersBySessionID[identity.sessionID],
              marker.identity == identity,
              marker.disposition == .unreviewed,
              date.timeIntervalSince1970.isFinite else { return false }
        marker = .init(
            identity: identity,
            disposition: .reviewed,
            observedAt: marker.observedAt,
            reviewedAt: date
        )
        markersBySessionID[identity.sessionID] = marker
        return true
    }

    public func isValid() -> Bool {
        baselineAt.timeIntervalSince1970.isFinite
            && activeRunBySessionID.count <= Self.maximumMarkers
            && markersBySessionID.count <= Self.maximumMarkers
            && markers.allSatisfy {
                $0.observedAt.timeIntervalSince1970.isFinite
                    && ($0.reviewedAt?.timeIntervalSince1970.isFinite ?? true)
                    && ($0.disposition == .reviewed) == ($0.reviewedAt != nil)
            }
    }

    private mutating func trim() {
        if markersBySessionID.count > Self.maximumMarkers {
            markersBySessionID = Dictionary(
                uniqueKeysWithValues: markers.prefix(Self.maximumMarkers).map {
                    ($0.identity.sessionID, $0)
                }
            )
        }
        if activeRunBySessionID.count > Self.maximumMarkers {
            activeRunBySessionID = Dictionary(
                uniqueKeysWithValues: activeRunBySessionID.keys.sorted()
                    .prefix(Self.maximumMarkers)
                    .compactMap { sessionID in
                        activeRunBySessionID[sessionID].map { (sessionID, $0) }
                    }
            )
        }
    }
}

public struct ConnOutcomeReviewPreferenceStore {
    private struct Wrapper: Codable {
        static let version = 1
        let version: Int
        let ledger: ConnOutcomeReviewLedger
    }

    public static let defaultKey = "connOutcomeReviewLedger.v2"
    public static let maximumEncodedBytes = 2 * 1_024 * 1_024

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load(orBaselineAt date: Date = Date()) -> ConnOutcomeReviewLedger {
        guard let data = defaults.data(forKey: key),
              data.count <= Self.maximumEncodedBytes,
              let wrapper = try? JSONDecoder().decode(Wrapper.self, from: data),
              wrapper.version == Wrapper.version,
              wrapper.ledger.isValid() else {
            return .init(baselineAt: date)
        }
        return wrapper.ledger
    }

    @discardableResult
    public func save(_ ledger: ConnOutcomeReviewLedger) -> Bool {
        guard ledger.isValid(),
              let data = try? JSONEncoder().encode(Wrapper(
                version: Wrapper.version,
                ledger: ledger
              )),
              data.count <= Self.maximumEncodedBytes else { return false }
        defaults.set(data, forKey: key)
        return true
    }
}
