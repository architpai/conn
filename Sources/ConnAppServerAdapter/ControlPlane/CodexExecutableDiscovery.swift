import Darwin
import Foundation

public struct CodexCLIVersion: RawRepresentable, Equatable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var supportedAppServerVersion: SupportedAppServerVersion? {
        SupportedAppServerVersion(rawValue: rawValue)
    }

    public var isSupported: Bool { supportedAppServerVersion != nil }
}

public struct CodexExecutable: Equatable, Sendable {
    public let url: URL
    public let version: CodexCLIVersion

    public init(url: URL, version: CodexCLIVersion) {
        self.url = url
        self.version = version
    }
}

public enum CodexExecutableInspection: Equatable, Sendable {
    case ready(CodexExecutable)
    case missing(URL)
    case unsafe(URL, detail: String)
    case unsupported(URL, reportedVersion: String?)
    case diagnosticFailure(URL)
}

/// Validates explicit candidates in caller-supplied priority order. It does not
/// search arbitrary writable PATH entries or silently fall back after an unsafe
/// candidate is selected.
public struct CodexExecutableDiscovery: Sendable {
    private let runner: BoundedProcessRunner
    private let currentUserID: uid_t
    private let diagnosticTimeout: Duration

    public init(
        runner: BoundedProcessRunner = BoundedProcessRunner(outputLimit: 4_096),
        currentUserID: uid_t = getuid(),
        diagnosticTimeout: Duration = .seconds(3)
    ) {
        self.runner = runner
        self.currentUserID = currentUserID
        self.diagnosticTimeout = diagnosticTimeout
    }

    public func inspect(_ candidateURL: URL) async -> CodexExecutableInspection {
        guard candidateURL.isFileURL, candidateURL.path.hasPrefix("/") else {
            return .unsafe(candidateURL, detail: "Codex executable path must be absolute.")
        }
        let resolved = candidateURL.resolvingSymlinksInPath().standardizedFileURL
        var metadata = stat()
        guard stat(resolved.path, &metadata) == 0 else {
            return errno == ENOENT ? .missing(resolved) : .unsafe(
                resolved,
                detail: "Codex executable metadata could not be inspected."
            )
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            return .unsafe(resolved, detail: "Codex executable must be a regular file.")
        }
        guard metadata.st_uid == currentUserID || metadata.st_uid == 0 else {
            return .unsafe(resolved, detail: "Codex executable has an unexpected owner.")
        }
        guard metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0,
              access(resolved.path, X_OK) == 0
        else {
            return .unsafe(
                resolved,
                detail: "Codex executable must be executable and not group/world writable."
            )
        }
        var parentMetadata = stat()
        let parentPath = resolved.deletingLastPathComponent().path
        guard stat(parentPath, &parentMetadata) == 0,
              parentMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              (parentMetadata.st_uid == currentUserID || parentMetadata.st_uid == 0),
              parentMetadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
        else {
            return .unsafe(
                resolved,
                detail: "Codex executable parent must be trusted and not group/world writable."
            )
        }

        do {
            let result = try await runner.run(
                executableURL: resolved,
                arguments: ["--version"],
                timeout: diagnosticTimeout
            )
            guard result.terminationStatus == 0,
                  let output = String(data: result.standardOutput, encoding: .utf8)
            else { return .diagnosticFailure(resolved) }
            let token = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard token.hasPrefix("codex-cli ") else {
                return .unsupported(resolved, reportedVersion: nil)
            }
            let rawVersion = String(token.dropFirst("codex-cli ".count))
            let version = CodexCLIVersion(rawValue: rawVersion)
            guard version.isSupported else {
                return .unsupported(resolved, reportedVersion: rawVersion)
            }
            return .ready(.init(url: resolved, version: version))
        } catch {
            return .diagnosticFailure(resolved)
        }
    }

    /// Returns only documented or explicitly configured locations. Conn does
    /// not execute the first arbitrary `codex` found on a mutable PATH.
    public func supportedCandidates(
        configuredURL: URL? = nil,
        codexHome: URL? = nil
    ) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let resolvedCodexHome = (codexHome ?? EndpointDiscovery().defaultCodexHome())
            .standardizedFileURL
        var candidates: [URL] = []
        if let configuredURL { candidates.append(configuredURL.standardizedFileURL) }
        candidates.append(
            resolvedCodexHome.appendingPathComponent("packages/standalone/current/codex")
        )
        candidates.append(home.appendingPathComponent(".local/bin/codex"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/codex"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/codex"))
        return candidates
    }

    public func discover(
        configuredURL: URL? = nil,
        codexHome: URL? = nil
    ) async -> CodexExecutableInspection {
        await discover(in: supportedCandidates(configuredURL: configuredURL, codexHome: codexHome))
    }

    public func discover(in candidates: [URL]) async -> CodexExecutableInspection {
        guard let first = candidates.first else {
            return .missing(URL(fileURLWithPath: "/", isDirectory: true))
        }
        for candidate in candidates {
            let inspection = await inspect(candidate)
            if case .missing = inspection { continue }
            return inspection
        }
        return .missing(first.standardizedFileURL)
    }
}
