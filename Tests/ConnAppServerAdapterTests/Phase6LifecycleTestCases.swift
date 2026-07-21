import Darwin
import Foundation
import ConnAppServerAdapter

enum Phase6LifecycleTestCases {
    static func run(in suite: inout TestSuite) async {
        await discoversOnlySafeSupportedExecutables(in: &suite)
        await boundsAndCancelsCommands(in: &suite)
        await startsOnlyAConfirmedStoppedDaemon(in: &suite)
        await refusesMalformedAndUnsafeDaemonState(in: &suite)
    }

    private static func discoversOnlySafeSupportedExecutables(in suite: inout TestSuite) async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let supported = root.appendingPathComponent("supported-codex")
            try writeExecutable("#!/bin/sh\nprintf 'codex-cli 0.144.5\\n'\n", to: supported)

            let discovery = CodexExecutableDiscovery(diagnosticTimeout: .seconds(1))
            let candidates = discovery.supportedCandidates(configuredURL: supported, codexHome: root)
            suite.check(candidates.first == supported, "explicit executable is checked before documented defaults")
            suite.check(
                !candidates.contains { $0.path.contains(".nvm") },
                "discovery never scans or copies arbitrary mutable PATH entries"
            )
            let inspected = await discovery.inspect(supported)
            if case let .ready(executable) = inspected {
                suite.check(executable.version.rawValue == "0.144.5", "discovery reports an exact supported version")
                suite.check(executable.url == supported.resolvingSymlinksInPath(), "discovery returns the validated executable")
            } else {
                suite.fail("safe supported executable was not discovered: \(inspected)")
            }

            guard chmod(supported.path, mode_t(0o722)) == 0 else {
                suite.fail("could not make the discovery fixture unsafe")
                return
            }
            if case .unsafe = await discovery.inspect(supported) {
                suite.check(true, "group/world-writable executable is refused")
            } else {
                suite.fail("unsafe executable was accepted")
            }

            let unsupported = root.appendingPathComponent("unsupported-codex")
            try writeExecutable("#!/bin/sh\nprintf 'codex-cli 9.9.9\\n'\n", to: unsupported)
            if case let .unsupported(_, version) = await discovery.inspect(unsupported) {
                suite.check(version == "9.9.9", "unsupported executable reports its exact version")
            } else {
                suite.fail("unsupported version was not refused")
            }
        } catch {
            suite.fail("executable discovery fixture failed: \(error)")
        }
    }

    private static func boundsAndCancelsCommands(in suite: inout TestSuite) async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let executable = root.appendingPathComponent("slow-command")
            try writeExecutable("#!/bin/sh\nsleep 5\n", to: executable)
            let runner = BoundedProcessRunner(terminationGrace: .milliseconds(20))

            do {
                _ = try await runner.run(
                    executableURL: executable,
                    arguments: [],
                    timeout: .milliseconds(40)
                )
                suite.fail("bounded runner should time out")
            } catch BoundedProcessRunner.RunnerError.timedOut {
                suite.check(true, "bounded runner times out and terminates only its command")
            } catch {
                suite.fail("bounded runner returned the wrong timeout error: \(error)")
            }

            let task = Task {
                try await runner.run(
                    executableURL: executable,
                    arguments: [],
                    timeout: .seconds(2)
                )
            }
            try await Task.sleep(for: .milliseconds(30))
            task.cancel()
            do {
                _ = try await task.value
                suite.fail("cancelled command should not complete")
            } catch is CancellationError {
                suite.check(true, "caller cancellation terminates the command")
            } catch {
                suite.fail("cancelled command returned the wrong error: \(error)")
            }
        } catch {
            suite.fail("bounded command fixture failed: \(error)")
        }
    }

    private static func startsOnlyAConfirmedStoppedDaemon(in suite: inout TestSuite) async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let controlDirectory = root.appendingPathComponent(
                EndpointDiscovery.controlDirectoryName,
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true)
            guard chmod(controlDirectory.path, mode_t(0o700)) == 0 else {
                suite.fail("could not secure lifecycle control directory")
                return
            }
            let socket = controlDirectory.appendingPathComponent(EndpointDiscovery.controlSocketName)
            let descriptor = try makeListeningUnixSocket(at: socket)
            defer { close(descriptor) }
            guard chmod(socket.path, mode_t(0o600)) == 0 else {
                suite.fail("could not secure lifecycle socket")
                return
            }

            let state = root.appendingPathComponent("daemon-running")
            let log = root.appendingPathComponent("arguments.log")
            let pathLog = root.appendingPathComponent("path.log")
            let executableURL = root.appendingPathComponent("fake-codex")
            let script = """
            #!/bin/sh
            printf '%s\\n' "$*" >> '\(log.path)'
            printf '%s\\n' "$PATH" >> '\(pathLog.path)'
            if [ "$1 $2 $3" = "app-server daemon version" ]; then
              if [ -f '\(state.path)' ]; then
                printf '%s\\n' '{"status":"running","backend":"pid","socketPath":"\(socket.path)","cliVersion":"0.144.5","appServerVersion":"0.144.6"}'
              else
                printf '%s\\n' '{"status":"stopped","cliVersion":"0.144.5"}'
              fi
              exit 0
            fi
            if [ "$1 $2 $3" = "app-server daemon start" ]; then
              touch '\(state.path)'
              exit 0
            fi
            exit 91
            """
            try writeExecutable(script, to: executableURL)
            let lifecycle = ManagedDaemonLifecycle(
                executable: .init(url: executableURL, version: .init(rawValue: "0.144.5")),
                codexHome: root
            )
            let result = try await lifecycle.ensureRunning(
                probeTimeout: .seconds(1),
                startTimeout: .seconds(1)
            )
            suite.check(result.startAttempted, "a confirmed stopped daemon is started once")
            suite.check(result.status.kind == .running, "post-start status validates the running daemon")
            suite.check(result.status.report?.appServerVersion == "0.144.6", "supported launcher/daemon version skew is explicit")
            suite.check(result.status.endpoint?.socketURL == socket, "only the documented secure endpoint is returned")

            let arguments = try String(contentsOf: log, encoding: .utf8)
                .split(separator: "\n").map(String.init)
            suite.check(
                arguments == [
                    "app-server daemon version",
                    "app-server daemon start",
                    "app-server daemon version",
                ],
                "lifecycle uses only the exact documented status/start commands"
            )
            suite.check(!arguments.contains(where: { $0.contains("stop") || $0.contains("restart") }), "lifecycle never stops or restarts the daemon")

            let paths = try String(contentsOf: pathLog, encoding: .utf8)
                .split(separator: "\n").map(String.init)
            suite.check(
                paths == Array(
                    repeating: ConnChildProcessEnvironment.trustedSystemPATH,
                    count: arguments.count
                ),
                "daemon version/start receive only the trusted system PATH"
            )

            let alreadyRunning = try await lifecycle.ensureRunning()
            suite.check(!alreadyRunning.startAttempted, "an already-running daemon is not restarted")
        } catch {
            suite.fail("managed daemon start fixture failed: \(error)")
        }
    }

    private static func refusesMalformedAndUnsafeDaemonState(in suite: inout TestSuite) async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let executableURL = root.appendingPathComponent("fake-codex")
            try writeExecutable("#!/bin/sh\nprintf 'not-json\\n'\n", to: executableURL)
            let lifecycle = ManagedDaemonLifecycle(
                executable: .init(url: executableURL, version: .init(rawValue: "0.144.5")),
                codexHome: root
            )
            let malformed = try await lifecycle.ensureRunning()
            suite.check(malformed.status.kind == .malformed, "malformed status fails closed")
            suite.check(!malformed.startAttempted, "malformed status cannot trigger daemon start")

            let outside = root.deletingLastPathComponent().appendingPathComponent("unexpected.sock")
            let runningScript = """
            #!/bin/sh
            printf '%s\\n' '{"status":"running","socketPath":"\(outside.path)","cliVersion":"0.144.5","appServerVersion":"0.144.5"}'
            """
            try writeExecutable(runningScript, to: executableURL)
            let refused = try await lifecycle.ensureRunning()
            suite.check(refused.status.kind == .endpointRefused, "unexpected endpoint is refused honestly")
            suite.check(!refused.startAttempted, "unsafe endpoint cannot trigger daemon mutation")
        } catch {
            suite.fail("malformed daemon fixture failed: \(error)")
        }
    }

    private static func writeExecutable(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        guard chmod(url.path, mode_t(0o700)) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    private static func temporaryRoot() -> URL {
        URL(fileURLWithPath: "/tmp/cn6-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    private static func makeListeningUnixSocket(at url: URL) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(url.path.utf8CString)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= pathCapacity else {
            close(descriptor)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            for index in pathBytes.indices { bytes[index] = UInt8(bitPattern: pathBytes[index]) }
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, length)
            }
        }
        guard result == 0, listen(descriptor, 1) == 0 else {
            let captured = errno
            close(descriptor)
            throw POSIXError(.init(rawValue: captured) ?? .EIO)
        }
        return descriptor
    }
}
