import Foundation

struct TestSuite {
    private(set) var assertions = 0
    private(set) var failures: [String] = []

    mutating func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { failures.append(message) }
    }

    mutating func checkEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ message: String
    ) {
        check(actual == expected, "\(message) (actual: \(actual), expected: \(expected))")
    }

    mutating func recordUnexpected(_ error: Error, context: String) {
        assertions += 1
        failures.append("\(context): \(error)")
    }
}
