import Foundation

public struct ManagedDaemonVersionReport: Codable, Equatable, Sendable {
    public let status: String
    public let backend: String?
    public let managedCodexPath: String?
    public let managedCodexVersion: String?
    public let socketPath: String?
    public let cliVersion: String?
    public let appServerVersion: String?
}

public struct ManagedDaemonStatus: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case running
        case stopped
        case unavailable
        case malformed
        case incompatible
        case endpointRefused
    }

    public let kind: Kind
    public let report: ManagedDaemonVersionReport?
    public let endpointInspection: EndpointInspection?
    public let detail: String

    public var endpoint: ControlEndpoint? {
        guard kind == .running else { return nil }
        return endpointInspection?.endpoint
    }
}

public struct ManagedDaemonStartResult: Equatable, Sendable {
    public let status: ManagedDaemonStatus
    public let startAttempted: Bool
    public let startTerminationStatus: Int32?
}

/// Coordinates only Codex's documented daemon version and start commands.
/// It intentionally has no stop, restart, or remote-control operation.
public actor ManagedDaemonLifecycle {
    public static let versionArguments = ["app-server", "daemon", "version"]
    public static let startArguments = ["app-server", "daemon", "start"]

    private let executable: CodexExecutable
    private let codexHome: URL
    private let runner: BoundedProcessRunner
    private let endpointDiscovery: EndpointDiscovery

    public init(
        executable: CodexExecutable,
        codexHome: URL,
        runner: BoundedProcessRunner = BoundedProcessRunner(),
        endpointDiscovery: EndpointDiscovery = EndpointDiscovery()
    ) {
        self.executable = executable
        self.codexHome = codexHome.standardizedFileURL
        self.runner = runner
        self.endpointDiscovery = endpointDiscovery
    }

    public func status(timeout: Duration = .seconds(2)) async throws -> ManagedDaemonStatus {
        let result: BoundedProcessRunner.Result
        do {
            result = try await runner.run(
                executableURL: executable.url,
                arguments: Self.versionArguments,
                environment: ConnChildProcessEnvironment.withTrustedSystemPATH(),
                timeout: timeout
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ManagedDaemonStatus(
                kind: .unavailable,
                report: nil,
                endpointInspection: nil,
                detail: "Managed daemon version probe did not complete safely within its configured bound."
            )
        }

        if result.terminationStatus != 0,
           let missingEndpoint = confirmedMissingControlSocket(from: result)
        {
            return ManagedDaemonStatus(
                kind: .stopped,
                report: nil,
                endpointInspection: missingEndpoint,
                detail: "The Codex-managed daemon is absent and its documented control socket is missing."
            )
        }

        guard result.terminationStatus == 0 else {
            return ManagedDaemonStatus(
                kind: .unavailable,
                report: nil,
                endpointInspection: nil,
                detail: "Managed daemon version probe exited with status \(result.terminationStatus)."
            )
        }

        let report: ManagedDaemonVersionReport
        do {
            report = try JSONDecoder().decode(
                ManagedDaemonVersionReport.self,
                from: result.standardOutput
            )
        } catch {
            return ManagedDaemonStatus(
                kind: .malformed,
                report: nil,
                endpointInspection: nil,
                detail: "Managed daemon version output was not valid expected JSON."
            )
        }

        switch report.status {
        case "stopped":
            return ManagedDaemonStatus(
                kind: .stopped,
                report: report,
                endpointInspection: nil,
                detail: "The Codex-managed daemon reports that it is stopped."
            )
        case "running":
            return inspectRunning(report)
        default:
            return ManagedDaemonStatus(
                kind: .malformed,
                report: report,
                endpointInspection: nil,
                detail: "Managed daemon returned unknown status '\(report.status)'."
            )
        }
    }

    private func confirmedMissingControlSocket(
        from result: BoundedProcessRunner.Result
    ) -> EndpointInspection? {
        guard result.standardOutput.isEmpty else { return nil }
        let expectedSocket = endpointDiscovery.expectedSocketURL(codexHome: codexHome)
            .standardizedFileURL
        let standardError = result.standardErrorString
        guard standardError.contains(expectedSocket.path),
              standardError.contains("No such file or directory (os error 2)")
        else { return nil }

        let inspection = endpointDiscovery.inspect(socketURL: expectedSocket)
        guard inspection.status == .missing else { return nil }
        return inspection
    }

    /// Returns immediately when already running. Only a confirmed stopped state can
    /// trigger `daemon start`; every other failure is reported without mutation.
    public func ensureRunning(
        probeTimeout: Duration = .seconds(2),
        startTimeout: Duration = .seconds(5)
    ) async throws -> ManagedDaemonStartResult {
        let initial = try await status(timeout: probeTimeout)
        guard initial.kind == .stopped else {
            return ManagedDaemonStartResult(
                status: initial,
                startAttempted: false,
                startTerminationStatus: nil
            )
        }

        let startResult: BoundedProcessRunner.Result
        do {
            startResult = try await runner.run(
                executableURL: executable.url,
                arguments: Self.startArguments,
                environment: ConnChildProcessEnvironment.withTrustedSystemPATH(),
                timeout: startTimeout
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ManagedDaemonStartResult(
                status: ManagedDaemonStatus(
                    kind: .unavailable,
                    report: initial.report,
                    endpointInspection: nil,
                    detail: "Managed daemon start did not complete safely within its configured bound."
                ),
                startAttempted: true,
                startTerminationStatus: nil
            )
        }

        guard startResult.terminationStatus == 0 else {
            return ManagedDaemonStartResult(
                status: ManagedDaemonStatus(
                    kind: .unavailable,
                    report: initial.report,
                    endpointInspection: nil,
                    detail: "Managed daemon start exited with status \(startResult.terminationStatus)."
                ),
                startAttempted: true,
                startTerminationStatus: startResult.terminationStatus
            )
        }

        return ManagedDaemonStartResult(
            status: try await status(timeout: probeTimeout),
            startAttempted: true,
            startTerminationStatus: startResult.terminationStatus
        )
    }

    private func inspectRunning(_ report: ManagedDaemonVersionReport) -> ManagedDaemonStatus {
        guard let reportedCLI = report.cliVersion else {
            return incompatible(report, "Managed daemon omitted its CLI version.")
        }
        guard reportedCLI == executable.version.rawValue else {
            return incompatible(
                report,
                "Version probe was executed by CLI \(executable.version.rawValue), but daemon JSON reported CLI \(reportedCLI)."
            )
        }
        guard let appServerRaw = report.appServerVersion else {
            return incompatible(report, "Managed daemon omitted its App Server version.")
        }
        let appServerVersion = CodexCLIVersion(rawValue: appServerRaw)
        guard appServerVersion.isSupported else {
            return incompatible(
                report,
                "App Server \(appServerRaw) is not supported; this Conn release supports exactly 0.144.5 and 0.144.6."
            )
        }
        guard let socketPath = report.socketPath,
              socketPath.hasPrefix("/"),
              !socketPath.contains("\0")
        else {
            return ManagedDaemonStatus(
                kind: .endpointRefused,
                report: report,
                endpointInspection: nil,
                detail: "Running daemon did not report a safe absolute local socket path."
            )
        }

        let inspection = endpointDiscovery.inspect(
            socketURL: URL(fileURLWithPath: socketPath, isDirectory: false)
        )
        let expectedSocketURL = endpointDiscovery.expectedSocketURL(codexHome: codexHome)
            .standardizedFileURL
        guard inspection.expectedSocketURL == expectedSocketURL else {
            return ManagedDaemonStatus(
                kind: .endpointRefused,
                report: report,
                endpointInspection: inspection,
                detail: "Running daemon reported a socket outside the documented Codex control endpoint."
            )
        }
        guard inspection.status == .ready else {
            return ManagedDaemonStatus(
                kind: .endpointRefused,
                report: report,
                endpointInspection: inspection,
                detail: "Running daemon endpoint was refused: \(inspection.detail)"
            )
        }
        return ManagedDaemonStatus(
            kind: .running,
            report: report,
            endpointInspection: inspection,
            detail: "Codex-managed App Server \(appServerRaw) is running on a validated current-user socket."
        )
    }

    private func incompatible(
        _ report: ManagedDaemonVersionReport,
        _ detail: String
    ) -> ManagedDaemonStatus {
        ManagedDaemonStatus(
            kind: .incompatible,
            report: report,
            endpointInspection: nil,
            detail: detail
        )
    }
}
