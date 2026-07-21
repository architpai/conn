import Foundation

struct TestSuite {
    private(set) var assertions = 0
    private(set) var failures: [String] = []

    mutating func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() {
            failures.append(message)
        }
    }

    mutating func require<T>(_ value: T?, _ message: String) throws -> T {
        assertions += 1
        guard let value else {
            failures.append(message)
            throw TestFailure.requiredValueMissing(message)
        }
        return value
    }

    mutating func recordUnexpected(_ error: Error, context: String) {
        assertions += 1
        failures.append("\(context): \(error)")
    }
}

enum TestFailure: Error {
    case requiredValueMissing(String)
}

final class LockedArray<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    func append(_ value: Element) {
        lock.withLock {
            storage.append(value)
        }
    }

    var values: [Element] {
        lock.withLock { storage }
    }
}
