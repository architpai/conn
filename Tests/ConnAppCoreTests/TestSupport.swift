import Darwin
import Foundation
import ConnDomain

struct TestSuite {
    private(set) var assertions = 0
    private(set) var failures: [String] = []

    mutating func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { failures.append(message) }
    }

    mutating func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        check(actual == expected, "\(message) (actual: \(actual), expected: \(expected))")
    }

    mutating func recordUnexpected(_ error: Error, context: String) {
        assertions += 1
        failures.append("\(context): \(error)")
    }
}

enum Phase3TestScaffolding {
    static func temporaryApplicationSupport(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "conn-app-core-tests-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

}
