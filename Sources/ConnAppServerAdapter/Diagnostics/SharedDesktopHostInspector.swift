import Darwin
import Foundation

public enum SharedDesktopBundleState: String, Codable, Equatable, Sendable {
    case available
    case missing
    case untrusted
    case malformed
    case unavailable
}

public struct SharedDesktopBundleInspection: Codable, Equatable, Sendable {
    public let state: SharedDesktopBundleState
    public let shortVersion: String?
    public let buildVersion: String?

    public init(
        state: SharedDesktopBundleState,
        shortVersion: String? = nil,
        buildVersion: String? = nil
    ) {
        self.state = state
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
    }
}

public enum SharedDesktopBundledCLIState: String, Codable, Equatable, Sendable {
    case available
    case missing
    case untrusted
    case malformed
    case oversized
    case unavailable
}

public struct SharedDesktopBundledCLIInspection: Codable, Equatable, Sendable {
    public let state: SharedDesktopBundledCLIState
    public let version: String?

    public init(state: SharedDesktopBundledCLIState, version: String? = nil) {
        self.state = state
        self.version = version
    }
}

public enum SharedDesktopGUIEnvironmentInspection: String, Codable, Equatable, Sendable {
    case enabled
    case disabled
    case unexpected
    case unavailable
}

public enum SharedDesktopLaunchConfigurationInspection: String, Codable, Equatable, Sendable {
    case missing
    case connManaged
    case legacyConnManaged
    case foreign
    case untrusted
    case malformed
    case oversized
    case unavailable
}

public enum SharedDesktopProcessState: String, Codable, Equatable, Sendable {
    case notRunning
    case single
    case multiple
    case unavailable
}

public enum SharedDesktopPrivateAppServerChildState: String, Codable, Equatable, Sendable {
    case notApplicable
    case absent
    case single
    case multiple
    case unavailable
}

public struct SharedDesktopProcessTopologyInspection: Codable, Equatable, Sendable {
    public let desktop: SharedDesktopProcessState
    public let privateAppServerChild: SharedDesktopPrivateAppServerChildState

    public init(
        desktop: SharedDesktopProcessState,
        privateAppServerChild: SharedDesktopPrivateAppServerChildState
    ) {
        self.desktop = desktop
        self.privateAppServerChild = privateAppServerChild
    }
}

public enum SharedDesktopDaemonState: String, Codable, Equatable, Sendable {
    case runningSafe
    case stopped
    case incompatible
    case unsafeEndpoint
    case missing
    case malformed
    case unavailable
}

public struct SharedDesktopDaemonInspection: Codable, Equatable, Sendable {
    public let state: SharedDesktopDaemonState
    public let cliVersion: String?
    public let appServerVersion: String?

    public init(
        state: SharedDesktopDaemonState,
        cliVersion: String? = nil,
        appServerVersion: String? = nil
    ) {
        self.state = state
        self.cliVersion = cliVersion
        self.appServerVersion = appServerVersion
    }
}

/// A privacy-closed current-host report for Phase 10 Shared Desktop diagnostics.
/// Paths, process identifiers, command output, environment contents, daemon
/// details, configuration contents, and App Server payloads are structurally
/// absent. The report is evidence only; inspection performs no mutations.
public struct SharedDesktopHostInspection: Codable, Equatable, Sendable {
    public let bundle: SharedDesktopBundleInspection
    public let bundledCLI: SharedDesktopBundledCLIInspection
    public let guiEnvironment: SharedDesktopGUIEnvironmentInspection
    public let launchConfiguration: SharedDesktopLaunchConfigurationInspection
    public let desktopTopology: SharedDesktopProcessTopologyInspection
    public let daemon: SharedDesktopDaemonInspection

    public init(
        bundle: SharedDesktopBundleInspection,
        bundledCLI: SharedDesktopBundledCLIInspection,
        guiEnvironment: SharedDesktopGUIEnvironmentInspection,
        launchConfiguration: SharedDesktopLaunchConfigurationInspection,
        desktopTopology: SharedDesktopProcessTopologyInspection,
        daemon: SharedDesktopDaemonInspection
    ) {
        self.bundle = bundle
        self.bundledCLI = bundledCLI
        self.guiEnvironment = guiEnvironment
        self.launchConfiguration = launchConfiguration
        self.desktopTopology = desktopTopology
        self.daemon = daemon
    }
}

package enum SharedDesktopBoundedDataFact: Equatable, Sendable {
    case value(Data)
    case missing
    case untrusted
    case oversized
    case unavailable
}

package enum SharedDesktopBoundedCommandFact: Equatable, Sendable {
    case value(terminationStatus: Int32, output: Data)
    case missing
    case untrusted
    case oversized
    case unavailable
}

package struct SharedDesktopRawProcess: Equatable, Sendable {
    package let processID: Int32
    package let parentProcessID: Int32
    package let isDesktopExecutable: Bool
    package let isPrivateAppServerChild: Bool

    package init(
        processID: Int32,
        parentProcessID: Int32,
        isDesktopExecutable: Bool,
        isPrivateAppServerChild: Bool
    ) {
        self.processID = processID
        self.parentProcessID = parentProcessID
        self.isDesktopExecutable = isDesktopExecutable
        self.isPrivateAppServerChild = isPrivateAppServerChild
    }
}

package enum SharedDesktopProcessInventoryFact: Equatable, Sendable {
    case value([SharedDesktopRawProcess])
    case unavailable
}

package func sharedDesktopProcessInventoryIsSaturated(
    byteCount: Int32,
    capacity: Int
) -> Bool {
    byteCount >= Int32(capacity * MemoryLayout<pid_t>.stride)
}

package enum SharedDesktopDaemonFact: Equatable, Sendable {
    case value(
        kind: ManagedDaemonStatus.Kind,
        cliVersion: String?,
        appServerVersion: String?
    )
    case missing
    case unavailable
}

package struct SharedDesktopHostInspectorDependencies: Sendable {
    package let bundleMetadata: @Sendable () -> SharedDesktopBoundedDataFact
    package let bundledCLI: @Sendable () async -> SharedDesktopBoundedCommandFact
    package let guiEnvironment: @Sendable () async -> SharedDesktopBoundedCommandFact
    package let launchConfiguration: @Sendable () -> SharedDesktopBoundedDataFact
    package let processInventory: @Sendable () async -> SharedDesktopProcessInventoryFact
    package let daemon: @Sendable () async -> SharedDesktopDaemonFact

    package init(
        bundleMetadata: @escaping @Sendable () -> SharedDesktopBoundedDataFact,
        bundledCLI: @escaping @Sendable () async -> SharedDesktopBoundedCommandFact,
        guiEnvironment: @escaping @Sendable () async -> SharedDesktopBoundedCommandFact,
        launchConfiguration: @escaping @Sendable () -> SharedDesktopBoundedDataFact,
        processInventory: @escaping @Sendable () async -> SharedDesktopProcessInventoryFact,
        daemon: @escaping @Sendable () async -> SharedDesktopDaemonFact
    ) {
        self.bundleMetadata = bundleMetadata
        self.bundledCLI = bundledCLI
        self.guiEnvironment = guiEnvironment
        self.launchConfiguration = launchConfiguration
        self.processInventory = processInventory
        self.daemon = daemon
    }
}

public actor SharedDesktopHostInspector {
    public static let desktopBundleIdentifier = "com.openai.codex"
    public static let guiEnvironmentVariable = "CODEX_APP_SERVER_USE_LOCAL_DAEMON"
    public static let launchAgentLabel = "com.conn.experimental-shared-desktop"
    public static let setupContractMarker = "v2-2026-07-21"
    package static let legacySetupContractMarkers: Set<String> = ["v1-2026-07-20"]

    private let dependencies: SharedDesktopHostInspectorDependencies

    public init() {
        dependencies = .live()
    }

    package init(dependencies: SharedDesktopHostInspectorDependencies) {
        self.dependencies = dependencies
    }

    public func inspect() async -> SharedDesktopHostInspection {
        async let bundledCLI = dependencies.bundledCLI()
        async let guiEnvironment = dependencies.guiEnvironment()
        async let processInventory = dependencies.processInventory()
        async let daemon = dependencies.daemon()

        let bundle = Self.inspectBundle(dependencies.bundleMetadata())
        let launchConfiguration = Self.inspectLaunchConfiguration(
            dependencies.launchConfiguration()
        )
        return await .init(
            bundle: bundle,
            bundledCLI: Self.inspectBundledCLI(bundledCLI),
            guiEnvironment: Self.inspectGUIEnvironment(guiEnvironment),
            launchConfiguration: launchConfiguration,
            desktopTopology: Self.inspectProcessTopology(processInventory),
            daemon: Self.inspectDaemon(daemon)
        )
    }

    private static func inspectBundle(
        _ fact: SharedDesktopBoundedDataFact
    ) -> SharedDesktopBundleInspection {
        switch fact {
        case .missing:
            return .init(state: .missing)
        case .untrusted, .oversized:
            return .init(state: .untrusted)
        case .unavailable:
            return .init(state: .unavailable)
        case let .value(data):
            guard let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let dictionary = object as? [String: Any],
                  dictionary["CFBundleIdentifier"] as? String == desktopBundleIdentifier,
                  let shortVersion = boundedVersion(dictionary["CFBundleShortVersionString"]),
                  let buildVersion = boundedVersion(dictionary["CFBundleVersion"])
            else { return .init(state: .malformed) }
            return .init(
                state: .available,
                shortVersion: shortVersion,
                buildVersion: buildVersion
            )
        }
    }

    private static func inspectBundledCLI(
        _ fact: SharedDesktopBoundedCommandFact
    ) -> SharedDesktopBundledCLIInspection {
        switch fact {
        case .missing:
            return .init(state: .missing)
        case .untrusted:
            return .init(state: .untrusted)
        case .oversized:
            return .init(state: .oversized)
        case .unavailable:
            return .init(state: .unavailable)
        case let .value(status, output):
            guard status == 0,
                  output.count <= 256,
                  let text = String(data: output, encoding: .utf8)
            else { return .init(state: .malformed) }
            let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard token.hasPrefix("codex-cli "),
                  let version = boundedVersion(String(token.dropFirst("codex-cli ".count)))
            else { return .init(state: .malformed) }
            return .init(state: .available, version: version)
        }
    }

    private static func inspectGUIEnvironment(
        _ fact: SharedDesktopBoundedCommandFact
    ) -> SharedDesktopGUIEnvironmentInspection {
        switch fact {
        case .missing:
            return .disabled
        case .untrusted, .oversized, .unavailable:
            return .unavailable
        case let .value(status, output):
            guard status == 0, output.count <= 32,
                  let text = String(data: output, encoding: .utf8)
            else { return .unavailable }
            switch text.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "1": return .enabled
            case "": return .disabled
            default: return .unexpected
            }
        }
    }

    private static func inspectLaunchConfiguration(
        _ fact: SharedDesktopBoundedDataFact
    ) -> SharedDesktopLaunchConfigurationInspection {
        switch fact {
        case .missing: return .missing
        case .untrusted: return .untrusted
        case .oversized: return .oversized
        case .unavailable: return .unavailable
        case let .value(data):
            guard let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let dictionary = object as? [String: Any],
                  let label = dictionary["Label"] as? String,
                  let arguments = dictionary["ProgramArguments"] as? [String]
            else { return .malformed }
            guard label == launchAgentLabel else { return .foreign }
            if isCurrentLaunchConfiguration(dictionary, arguments: arguments) {
                return .connManaged
            }
            if isKnownPreviousConnConfiguration(dictionary, arguments: arguments) {
                return .legacyConnManaged
            }
            if isKnownLegacyLaunchArguments(arguments) { return .legacyConnManaged }
            return .malformed
        }
    }

    package static func inspectLaunchConfigurationData(
        _ data: Data
    ) -> SharedDesktopLaunchConfigurationInspection {
        inspectLaunchConfiguration(.value(data))
    }

    private static func isCurrentLaunchConfiguration(
        _ dictionary: [String: Any],
        arguments: [String]
    ) -> Bool {
        let allowedKeys: Set<String> = [
            "Label",
            "ProgramArguments",
            "EnvironmentVariables",
            "RunAtLoad",
            "ProcessType",
            "LimitLoadToSessionType",
        ]
        guard Set(dictionary.keys) == allowedKeys,
              arguments == [
                  "/bin/launchctl", "setenv", guiEnvironmentVariable, "1",
              ],
              let environment = dictionary["EnvironmentVariables"] as? [String: String],
              environment == ["CONN_SHARED_DESKTOP_SETUP_CONTRACT": setupContractMarker],
              dictionary["RunAtLoad"] as? Bool == true,
              dictionary["ProcessType"] as? String == "Background",
              dictionary["LimitLoadToSessionType"] as? String == "Aqua"
        else { return false }
        return true
    }

    private static func isKnownPreviousConnConfiguration(
        _ dictionary: [String: Any],
        arguments: [String]
    ) -> Bool {
        let allowedKeys: Set<String> = [
            "Label",
            "ProgramArguments",
            "EnvironmentVariables",
            "RunAtLoad",
            "ProcessType",
            "LimitLoadToSessionType",
        ]
        guard Set(dictionary.keys) == allowedKeys,
              arguments == [
                  "/bin/launchctl", "setenv", guiEnvironmentVariable, "1",
              ],
              let environment = dictionary["EnvironmentVariables"] as? [String: String],
              environment.count == 1,
              let marker = environment["CONN_SHARED_DESKTOP_SETUP_CONTRACT"],
              legacySetupContractMarkers.contains(marker),
              dictionary["RunAtLoad"] as? Bool == true,
              dictionary["ProcessType"] as? String == "Background",
              dictionary["LimitLoadToSessionType"] as? String == "Aqua"
        else { return false }
        return true
    }

    private static func isKnownLegacyLaunchArguments(_ arguments: [String]) -> Bool {
        guard arguments.count == 3,
              arguments[0] == "/bin/sh",
              arguments[1] == "-c" else { return false }
        let command = arguments[2]
        guard command.utf8.count <= 1_024,
              !command.contains("\n"),
              !command.contains("\0") else { return false }
        let suffix = " app-server daemon start && /bin/launchctl setenv \(guiEnvironmentVariable) 1"
        guard command.hasSuffix(suffix) else { return false }
        let executable = String(command.dropLast(suffix.count))
        return executable.hasPrefix("/")
            && executable.hasSuffix("/codex")
            && !executable.contains("'")
            && !executable.contains("\"")
            && !executable.contains(";")
            && !executable.contains("|")
            && !executable.contains("&")
    }

    private static func inspectProcessTopology(
        _ fact: SharedDesktopProcessInventoryFact
    ) -> SharedDesktopProcessTopologyInspection {
        guard case let .value(processes) = fact else {
            return .init(desktop: .unavailable, privateAppServerChild: .unavailable)
        }
        let desktopIDs = Set(processes.filter(\.isDesktopExecutable).map(\.processID))
        let desktopState: SharedDesktopProcessState = switch desktopIDs.count {
        case 0: .notRunning
        case 1: .single
        default: .multiple
        }
        guard !desktopIDs.isEmpty else {
            return .init(desktop: desktopState, privateAppServerChild: .notApplicable)
        }
        let childCount = processes.filter {
            $0.isPrivateAppServerChild && desktopIDs.contains($0.parentProcessID)
        }.count
        let childState: SharedDesktopPrivateAppServerChildState = switch childCount {
        case 0: .absent
        case 1: .single
        default: .multiple
        }
        return .init(desktop: desktopState, privateAppServerChild: childState)
    }

    private static func inspectDaemon(
        _ fact: SharedDesktopDaemonFact
    ) -> SharedDesktopDaemonInspection {
        switch fact {
        case .missing:
            return .init(state: .missing)
        case .unavailable:
            return .init(state: .unavailable)
        case let .value(kind, cliVersion, appServerVersion):
            let state: SharedDesktopDaemonState = switch kind {
            case .running: .runningSafe
            case .stopped: .stopped
            case .incompatible: .incompatible
            case .endpointRefused: .unsafeEndpoint
            case .malformed: .malformed
            case .unavailable: .unavailable
            }
            return .init(
                state: state,
                cliVersion: boundedVersion(cliVersion),
                appServerVersion: boundedVersion(appServerVersion)
            )
        }
    }

    private static func boundedVersion(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 64,
              trimmed.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 0x21 && scalar.value <= 0x7E
              }) else { return nil }
        return trimmed
    }
}

private extension SharedDesktopHostInspectorDependencies {
    static let desktopBundleURL = URL(
        fileURLWithPath: "/Applications/ChatGPT.app",
        isDirectory: true
    )
    static let launchAgentURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        .appendingPathComponent("com.conn.experimental-shared-desktop.plist")

    static func live() -> Self {
        let shortRunner = BoundedProcessRunner(outputLimit: 512)
        return .init(
            bundleMetadata: {
                readTrustedFile(
                    at: desktopBundleURL.appendingPathComponent("Contents/Info.plist"),
                    maximumBytes: 64 * 1_024
                )
            },
            bundledCLI: {
                let executable = desktopBundleURL
                    .appendingPathComponent("Contents/Resources/codex")
                switch inspectExecutable(executable) {
                case .missing: return .missing
                case .untrusted: return .untrusted
                case .unavailable: return .unavailable
                case .ready:
                    do {
                        let result = try await shortRunner.run(
                            executableURL: executable,
                            arguments: ["--version"],
                            timeout: .seconds(3)
                        )
                        return .value(
                            terminationStatus: result.terminationStatus,
                            output: result.standardOutput
                        )
                    } catch BoundedProcessRunner.RunnerError.outputLimitExceeded {
                        return .oversized
                    } catch {
                        return .unavailable
                    }
                }
            },
            guiEnvironment: {
                do {
                    let result = try await shortRunner.run(
                        executableURL: URL(fileURLWithPath: "/bin/launchctl"),
                        arguments: ["getenv", SharedDesktopHostInspector.guiEnvironmentVariable],
                        timeout: .seconds(2)
                    )
                    return .value(
                        terminationStatus: result.terminationStatus,
                        output: result.standardOutput
                    )
                } catch BoundedProcessRunner.RunnerError.outputLimitExceeded {
                    return .oversized
                } catch {
                    return .unavailable
                }
            },
            launchConfiguration: {
                readTrustedFile(at: launchAgentURL, maximumBytes: 16 * 1_024)
            },
            processInventory: {
                await readProcessInventory(runner: BoundedProcessRunner(outputLimit: 4_096))
            },
            daemon: {
                switch await CodexExecutableDiscovery().discover() {
                case let .ready(executable):
                    do {
                        let discovery = EndpointDiscovery()
                        let lifecycle = ManagedDaemonLifecycle(
                            executable: executable,
                            codexHome: discovery.defaultCodexHome(),
                            endpointDiscovery: discovery
                        )
                        let status = try await lifecycle.status()
                        return .value(
                            kind: status.kind,
                            cliVersion: status.report?.cliVersion,
                            appServerVersion: status.report?.appServerVersion
                        )
                    } catch {
                        return .unavailable
                    }
                case .missing: return .missing
                case .unsafe, .unsupported, .diagnosticFailure: return .unavailable
                }
            }
        )
    }

    enum ExecutableFact {
        case ready
        case missing
        case untrusted
        case unavailable
    }

    static func inspectExecutable(_ url: URL) -> ExecutableFact {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            return errno == ENOENT ? .missing : .unavailable
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_uid == 0 || metadata.st_uid == getuid(),
              metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0,
              access(url.path, X_OK) == 0 else { return .untrusted }
        return .ready
    }

    static func readTrustedFile(at url: URL, maximumBytes: Int) -> SharedDesktopBoundedDataFact {
        guard maximumBytes >= 0 else { return .unavailable }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            return errno == ENOENT ? .missing : (errno == ELOOP ? .untrusted : .unavailable)
        }
        defer { close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { return .unavailable }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_nlink == 1,
              metadata.st_uid == 0 || metadata.st_uid == getuid(),
              metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0 else {
            return .untrusted
        }
        var parentMetadata = stat()
        let parentPath = url.deletingLastPathComponent().path
        guard lstat(parentPath, &parentMetadata) == 0,
              parentMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              parentMetadata.st_uid == 0 || parentMetadata.st_uid == getuid(),
              parentMetadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0 else {
            return .untrusted
        }
        guard metadata.st_size >= 0, metadata.st_size <= maximumBytes else {
            return .oversized
        }
        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: min(4_096, maximumBytes + 1))
        while data.count <= maximumBytes {
            let allowed = min(buffer.count, maximumBytes + 1 - data.count)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, allowed)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return .unavailable
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= maximumBytes else { return .oversized }
        guard data.count == Int(metadata.st_size) else { return .unavailable }
        var currentMetadata = stat()
        guard lstat(url.path, &currentMetadata) == 0,
              currentMetadata.st_dev == metadata.st_dev,
              currentMetadata.st_ino == metadata.st_ino,
              currentMetadata.st_nlink == 1 else { return .untrusted }
        return .value(data)
    }

    static func readProcessInventory(
        runner: BoundedProcessRunner
    ) async -> SharedDesktopProcessInventoryFact {
        let capacity = 8_192
        var identifiers = [pid_t](repeating: 0, count: capacity)
        let byteCount = proc_listpids(
            UInt32(PROC_ALL_PIDS),
            0,
            &identifiers,
            Int32(MemoryLayout<pid_t>.stride * identifiers.count)
        )
        guard byteCount >= 0 else { return .unavailable }
        guard !sharedDesktopProcessInventoryIsSaturated(
            byteCount: byteCount,
            capacity: identifiers.count
        ) else { return .unavailable }
        let count = min(Int(byteCount) / MemoryLayout<pid_t>.stride, identifiers.count)
        var rows: [SharedDesktopRawProcess] = []
        rows.reserveCapacity(8)
        let desktopPath = desktopBundleURL.appendingPathComponent("Contents/MacOS/ChatGPT").path
        let bundledCodexPath = desktopBundleURL.appendingPathComponent("Contents/Resources/codex").path

        for processID in identifiers.prefix(count) where processID > 0 {
            guard let path = processPath(processID),
                  path == desktopPath || path == bundledCodexPath,
                  let parentID = parentProcessID(processID) else { continue }
            let isDesktop = path == desktopPath
            var isPrivateAppServer = false
            if path == bundledCodexPath {
                do {
                    let result = try await runner.run(
                        executableURL: URL(fileURLWithPath: "/bin/ps"),
                        arguments: ["-p", String(processID), "-o", "command="],
                        timeout: .seconds(1)
                    )
                    guard result.terminationStatus == 0,
                          result.standardOutput.count <= 4_096,
                          let command = String(data: result.standardOutput, encoding: .utf8)
                    else { return .unavailable }
                    isPrivateAppServer = command
                        .split(whereSeparator: \Character.isWhitespace)
                        .contains("app-server")
                } catch {
                    return .unavailable
                }
            }
            rows.append(.init(
                processID: processID,
                parentProcessID: parentID,
                isDesktopExecutable: isDesktop,
                isPrivateAppServerChild: isPrivateAppServer
            ))
        }
        return .value(rows)
    }

    static func processPath(_ processID: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(processID, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func parentProcessID(_ processID: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, pointer, Int32(size))
        }
        guard result == Int32(size) else { return nil }
        return pid_t(info.pbi_ppid)
    }
}
