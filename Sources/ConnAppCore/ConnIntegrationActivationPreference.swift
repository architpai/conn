import Foundation

/// A small, provider-neutral adapter for one persisted Integration choice.
/// Absence is resolved exactly once so callers can distinguish a fresh install
/// from an upgrade without overriding a later explicit user decision.
public struct ConnIntegrationActivationPreference: @unchecked Sendable {
    private let defaults: UserDefaults
    public let key: String

    public init(defaults: UserDefaults = .standard, key: String) {
        self.defaults = defaults
        self.key = key
    }

    @discardableResult
    public func resolve(defaultWhenAbsent: Bool) -> Bool {
        if let stored = defaults.object(forKey: key) as? Bool {
            return stored
        }
        defaults.set(defaultWhenAbsent, forKey: key)
        return defaultWhenAbsent
    }

    public func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: key)
    }
}
