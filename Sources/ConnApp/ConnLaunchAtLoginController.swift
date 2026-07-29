import Foundation
import ServiceManagement
import ConnAppCore

@MainActor
final class ConnLaunchAtLoginController {
    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
    }

    var status: ConnLaunchAtLoginStatus {
        switch service.status {
        case .notRegistered:
            .disabled
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .unavailable
        @unknown default:
            .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) -> Result<ConnLaunchAtLoginStatus, Error> {
        do {
            if enabled {
                if service.status == .notRegistered {
                    try service.register()
                }
            } else if service.status == .enabled
                        || service.status == .requiresApproval {
                try service.unregister()
            }
            return .success(status)
        } catch {
            return .failure(error)
        }
    }
}
