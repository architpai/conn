import Darwin
import Foundation

public struct PiToolchain: Equatable, Sendable {
    public let nodeURL: URL
    public let piEntryURL: URL
    public let nodeVersion: String
    public let piVersion: String

    public init(
        nodeURL: URL,
        piEntryURL: URL,
        nodeVersion: String,
        piVersion: String
    ) {
        self.nodeURL = nodeURL
        self.piEntryURL = piEntryURL
        self.nodeVersion = nodeVersion
        self.piVersion = piVersion
    }
}

public enum PiToolchainInspection: Equatable, Sendable {
    case ready(PiToolchain)
    case missing
    case unsafe(detail: String)
    case unsupported(reportedVersion: String?)
    case diagnosticFailure
}

/// Resolves the actual Node executable and Pi package entry point instead of
/// relying on the environment inherited by a Finder-launched application.
public struct PiToolchainDiscovery: Sendable {
    public static let supportedPiVersion = "0.82.1"

    private let homeDirectory: URL
    private let shellURL: URL?
    private let probe: PiProcessProbe
    private let currentUserID: uid_t
    private let timeout: Duration
    private let cache: PiToolchainCache

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        shellURL: URL? = ProcessInfo.processInfo.environment["SHELL"].map {
            URL(fileURLWithPath: $0)
        },
        currentUserID: uid_t = getuid(),
        timeout: Duration = .seconds(3)
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.shellURL = shellURL?.standardizedFileURL
        self.probe = PiProcessProbe(outputLimit: 8 * 1_024)
        self.currentUserID = currentUserID
        self.timeout = timeout
        self.cache = PiToolchainCache()
    }

    public func discover() async -> PiToolchainInspection {
        if let cached = await cache.value {
            let inspection = await inspect(
                nodeURL: cached.nodeURL,
                piLauncherURL: cached.piEntryURL
            )
            if case .ready = inspection { return inspection }
            await cache.clear()
        }

        var candidates = await loginShellCandidates()
        candidates.append(contentsOf: knownCandidates())
        var seen = Set<String>()
        candidates = candidates.filter {
            seen.insert("\($0.node.path)\n\($0.pi.path)").inserted
        }

        for candidate in candidates {
            let inspection = await inspect(
                nodeURL: candidate.node,
                piLauncherURL: candidate.pi
            )
            switch inspection {
            case let .ready(toolchain):
                await cache.store(toolchain)
                return inspection
            case .missing:
                continue
            case .unsafe, .unsupported, .diagnosticFailure:
                return inspection
            }
        }
        return .missing
    }

    public func inspect(
        nodeURL: URL,
        piLauncherURL: URL
    ) async -> PiToolchainInspection {
        guard let node = validatedRegularFile(
            nodeURL,
            requiresExecutable: true
        ) else {
            return fileExists(nodeURL)
                ? .unsafe(detail: "Node must be a trusted executable that is not group/world writable.")
                : .missing
        }
        guard let entry = validatedRegularFile(
            piLauncherURL.resolvingSymlinksInPath(),
            requiresExecutable: false
        ) else {
            return fileExists(piLauncherURL)
                ? .unsafe(detail: "Pi's resolved package entry must be a trusted regular file.")
                : .missing
        }

        do {
            let nodeResult = try await probe.run(
                executableURL: node,
                arguments: ["--version"],
                timeout: timeout
            )
            guard nodeResult.status == 0,
                  let nodeVersion = singleLine(nodeResult.output),
                  nodeVersion.hasPrefix("v")
            else {
                return .diagnosticFailure
            }

            let piResult = try await probe.run(
                executableURL: node,
                arguments: [entry.path, "--version"],
                timeout: timeout
            )
            guard piResult.status == 0,
                  let piVersion = reportedPiVersion(piResult.output)
            else {
                return .diagnosticFailure
            }
            guard piVersion == Self.supportedPiVersion else {
                return .unsupported(reportedVersion: piVersion)
            }
            return .ready(
                PiToolchain(
                    nodeURL: node,
                    piEntryURL: entry,
                    nodeVersion: nodeVersion,
                    piVersion: piVersion
                )
            )
        } catch {
            return .diagnosticFailure
        }
    }

    private func loginShellCandidates() async -> [PiCandidate] {
        guard let shellURL,
              let shell = validatedRegularFile(shellURL, requiresExecutable: true)
        else {
            return []
        }
        do {
            let result = try await probe.run(
                executableURL: shell,
                arguments: [
                    "-lc",
                    "command -v pi 2>/dev/null || true; command -v node 2>/dev/null || true",
                ],
                timeout: timeout
            )
            guard result.status == 0 else { return [] }
            let lines = String(decoding: result.output, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter { $0.hasPrefix("/") }
            guard lines.count == 2 else { return [] }
            return [
                .init(
                    node: URL(fileURLWithPath: lines[1]),
                    pi: URL(fileURLWithPath: lines[0])
                )
            ]
        } catch {
            return []
        }
    }

    private func knownCandidates() -> [PiCandidate] {
        var binDirectories = [
            homeDirectory.appendingPathComponent(".local/bin", isDirectory: true),
            homeDirectory.appendingPathComponent(".bun/bin", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
        ]
        let nvmVersions = homeDirectory.appendingPathComponent(
            ".nvm/versions/node",
            isDirectory: true
        )
        if let versions = try? FileManager.default.contentsOfDirectory(
            at: nvmVersions,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            binDirectories.append(
                contentsOf: versions
                    .sorted { $0.lastPathComponent > $1.lastPathComponent }
                    .map { $0.appendingPathComponent("bin", isDirectory: true) }
            )
        }
        return binDirectories.map {
            .init(
                node: $0.appendingPathComponent("node"),
                pi: $0.appendingPathComponent("pi")
            )
        }
    }

    private func validatedRegularFile(
        _ candidate: URL,
        requiresExecutable: Bool
    ) -> URL? {
        guard candidate.isFileURL, candidate.path.hasPrefix("/") else { return nil }
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        var metadata = stat()
        guard stat(resolved.path, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_uid == currentUserID || metadata.st_uid == 0,
              metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0,
              !requiresExecutable || access(resolved.path, X_OK) == 0
        else {
            return nil
        }
        return resolved
    }

    private func fileExists(_ url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0
    }

    private func singleLine(_ data: Data) -> String? {
        let value = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value.contains("\n") ? nil : value
    }

    private func reportedPiVersion(_ data: Data) -> String? {
        guard let line = singleLine(data) else { return nil }
        if line == Self.supportedPiVersion { return line }
        let tokens = line.split(separator: " ")
        return tokens.last.map(String.init)
    }
}

private struct PiCandidate: Sendable {
    let node: URL
    let pi: URL
}

private actor PiToolchainCache {
    var value: PiToolchain?

    func store(_ value: PiToolchain) {
        self.value = value
    }

    func clear() {
        value = nil
    }
}
