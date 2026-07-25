import Foundation

@MainActor
package final class ConnCompactNotificationLifetimeController {
    package typealias Sleep = @MainActor (TimeInterval) async throws -> Void

    private let sleep: Sleep
    private var task: Task<Void, Never>?
    private var presentedID: String?

    package init(
        sleep: @escaping Sleep = { duration in
            try await Task.sleep(for: .seconds(duration))
        }
    ) {
        self.sleep = sleep
    }

    deinit {
        task?.cancel()
    }

    @discardableResult
    package func present(
        id: String,
        duration: TimeInterval,
        onExpire: @escaping @MainActor (String) -> Void
    ) -> Bool {
        guard presentedID != id else { return false }
        task?.cancel()
        presentedID = id
        task = Task { @MainActor [weak self, sleep] in
            do {
                try await sleep(duration)
            } catch {
                return
            }
            guard let self, self.presentedID == id else { return }
            self.presentedID = nil
            self.task = nil
            onExpire(id)
        }
        return true
    }

    package func dismiss() {
        task?.cancel()
        task = nil
        presentedID = nil
    }
}
