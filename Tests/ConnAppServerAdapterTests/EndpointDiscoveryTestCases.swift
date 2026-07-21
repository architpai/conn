import Darwin
import Foundation
import ConnAppServerAdapter

enum EndpointDiscoveryTestCases {
    static func run(in suite: inout TestSuite) {
        resolvesConfiguredCodexHome(in: &suite)
        reportsMissingEndpoint(in: &suite)
        rejectsUnsafeParentDirectory(in: &suite)
        rejectsRegularFile(in: &suite)
        validatesSocketPermissions(in: &suite)
    }

    private static func resolvesConfiguredCodexHome(in suite: inout TestSuite) {
        let discovery = EndpointDiscovery(currentUserID: getuid())
        let home = discovery.defaultCodexHome(environment: ["CODEX_HOME": "/tmp/conn-codex-home"])

        suite.check(home.path == "/tmp/conn-codex-home", "CODEX_HOME should override the default")
        suite.check(
            discovery.expectedSocketURL(codexHome: home).path
                == "/tmp/conn-codex-home/app-server-control/app-server-control.sock",
            "default socket path should follow the documented App Server layout"
        )
    }

    private static func reportsMissingEndpoint(in suite: inout TestSuite) {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let inspection = EndpointDiscovery(currentUserID: getuid()).inspect(codexHome: temporaryRoot)

        suite.check(inspection.status == .missing, "an absent control directory should report missing")
        suite.check(inspection.endpoint == nil, "a missing endpoint must not be connectable")
        suite.check(
            !FileManager.default.fileExists(atPath: temporaryRoot.path),
            "inspection must not create the Codex home or control directory"
        )
    }

    private static func rejectsUnsafeParentDirectory(in suite: inout TestSuite) {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let controlDirectory = temporaryRoot.appendingPathComponent(
            EndpointDiscovery.controlDirectoryName,
            isDirectory: true
        )

        do {
            try FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporaryRoot) }
            guard chmod(controlDirectory.path, mode_t(0o770)) == 0 else {
                suite.fail("test setup could not make the control directory group-writable")
                return
            }

            let inspection = EndpointDiscovery(currentUserID: getuid()).inspect(codexHome: temporaryRoot)
            suite.check(
                inspection.status == .unsafeParentDirectory,
                "group-writable control directories must be refused"
            )
            suite.check(inspection.endpoint == nil, "an unsafe endpoint must not be connectable")
        } catch {
            suite.fail("unsafe-parent test setup failed: \(error)")
        }
    }

    private static func rejectsRegularFile(in suite: inout TestSuite) {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let controlDirectory = temporaryRoot.appendingPathComponent(
            EndpointDiscovery.controlDirectoryName,
            isDirectory: true
        )

        do {
            try FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporaryRoot) }
            let socketURL = controlDirectory.appendingPathComponent(EndpointDiscovery.controlSocketName)
            guard FileManager.default.createFile(atPath: socketURL.path, contents: Data()) else {
                suite.fail("test setup could not create a regular endpoint file")
                return
            }

            let inspection = EndpointDiscovery(currentUserID: getuid()).inspect(codexHome: temporaryRoot)
            suite.check(inspection.status == .notSocket, "a regular file must not pass socket validation")
            suite.check(inspection.endpoint == nil, "a regular file must not be connectable")
        } catch {
            suite.fail("regular-file test setup failed: \(error)")
        }
    }

    private static func validatesSocketPermissions(in suite: inout TestSuite) {
        let temporaryRoot = shortTemporaryRoot()
        let controlDirectory = temporaryRoot.appendingPathComponent(
            EndpointDiscovery.controlDirectoryName,
            isDirectory: true
        )

        do {
            try FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporaryRoot) }
            let socketURL = controlDirectory.appendingPathComponent(EndpointDiscovery.controlSocketName)
            let descriptor = try makeListeningUnixSocket(at: socketURL)
            defer { close(descriptor) }

            guard chmod(socketURL.path, mode_t(0o620)) == 0 else {
                suite.fail("test setup could not make the socket group-writable")
                return
            }
            let unsafe = EndpointDiscovery(currentUserID: getuid()).inspect(codexHome: temporaryRoot)
            suite.check(
                unsafe.status == .unsafeSocketPermissions,
                "a group-writable socket must be refused"
            )

            guard chmod(socketURL.path, mode_t(0o640)) == 0 else {
                suite.fail("test setup could not make the socket group-readable")
                return
            }
            let groupReadable = EndpointDiscovery(currentUserID: getuid()).inspect(
                codexHome: temporaryRoot
            )
            suite.check(
                groupReadable.status == .unsafeSocketPermissions,
                "a group-readable socket must be refused because the contract requires exact 0600"
            )

            guard chmod(socketURL.path, mode_t(0o600)) == 0 else {
                suite.fail("test setup could not restore private socket permissions")
                return
            }
            let ready = EndpointDiscovery(currentUserID: getuid()).inspect(codexHome: temporaryRoot)
            suite.check(ready.status == .ready, "a private current-user socket should be eligible")
            suite.check(ready.endpoint != nil, "a validated socket should produce a connection endpoint")
        } catch {
            suite.fail("Unix-socket test setup failed: \(error)")
        }
    }

    private static func makeListeningUnixSocket(at url: URL) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(url.path.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(descriptor)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            buffer.copyBytes(from: pathBytes)
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(descriptor, 1) == 0 else {
            let capturedError = errno
            close(descriptor)
            throw POSIXError(.init(rawValue: capturedError) ?? .EIO)
        }
        return descriptor
    }

    private static func shortTemporaryRoot() -> URL {
        URL(
            fileURLWithPath: "/tmp/conn-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
    }
}
