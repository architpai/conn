import Foundation

public enum ConnLaunchAtLoginStatus: Equatable, Sendable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable
}

public enum ConnLaunchAtLoginPolicy {
    public static func isOn(_ status: ConnLaunchAtLoginStatus) -> Bool {
        status == .enabled || status == .requiresApproval
    }

    public static func isConfirmedEnabled(
        _ status: ConnLaunchAtLoginStatus
    ) -> Bool {
        status == .enabled
    }

    public static func canChange(_ status: ConnLaunchAtLoginStatus) -> Bool {
        status != .unavailable
    }

    public static func detail(_ status: ConnLaunchAtLoginStatus) -> String {
        switch status {
        case .disabled:
            "Conn will not open automatically after login."
        case .enabled:
            "Conn will open automatically after login."
        case .requiresApproval:
            "Allow Conn in System Settings → General → Login Items."
        case .unavailable:
            "Launch at login is unavailable from this copy of Conn."
        }
    }
}
