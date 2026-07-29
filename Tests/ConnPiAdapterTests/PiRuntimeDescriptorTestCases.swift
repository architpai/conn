import Darwin
import Foundation
import ConnPiAdapter

enum PiRuntimeDescriptorTestCases {
    static func run(into suite: inout TestSuite) {
        do {
            try publishesLoadsExpiresAndInvalidates(into: &suite)
        } catch {
            suite.fail("runtime descriptor test failed: \(error)")
        }
    }

    private static func publishesLoadsExpiresAndInvalidates(
        into suite: inout TestSuite
    ) throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(
            "conn-pi-runtime-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PiRuntimeDescriptorStore(directory: root)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let socket = root.appendingPathComponent("broker.sock")

        let descriptor = try store.publish(
            socketURL: socket,
            now: now,
            timeToLive: 30
        )
        suite.check(
            descriptor.protocolVersion == PiBrokerProtocolBounds.currentVersion,
            "runtime descriptor pins the broker protocol"
        )
        suite.check(
            !descriptor.authenticationSecret.isEmpty,
            "every broker generation receives an authentication secret"
        )
        suite.check(
            descriptor.description.contains(descriptor.authenticationSecret) == false,
            "runtime descriptor descriptions redact authentication secrets"
        )
        suite.check(
            store.load(now: now.addingTimeInterval(1)) == descriptor,
            "fresh owner-only runtime descriptor loads exactly"
        )
        let permissions = try FileManager.default.attributesOfItem(
            atPath: store.descriptorURL.path
        )[.posixPermissions] as? NSNumber
        suite.check(
            permissions?.intValue == 0o600,
            "runtime descriptor is owner-readable and owner-writable only"
        )
        suite.check(
            store.load(now: now.addingTimeInterval(31)) == nil,
            "expired broker authority is treated as absent"
        )
        let refreshed = try store.refresh(
            descriptor,
            now: now.addingTimeInterval(20),
            timeToLive: 30
        )
        suite.check(
            refreshed.generation == descriptor.generation
                && refreshed.authenticationSecret == descriptor.authenticationSecret,
            "lease refresh preserves the live broker authority identity"
        )
        suite.check(
            store.load(now: now.addingTimeInterval(40)) == refreshed,
            "refreshed broker lease extends only its expiry"
        )
        try store.invalidate()
        suite.check(
            !FileManager.default.fileExists(atPath: store.descriptorURL.path),
            "broker shutdown removes the exact runtime descriptor"
        )
    }
}
