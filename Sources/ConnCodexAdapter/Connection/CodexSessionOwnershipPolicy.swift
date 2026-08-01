import Foundation

/// Qualifies the local Codex rollouts that belong to Conn's Codex CLI/Desktop
/// Integration. Third-party App Server clients remain available to their own
/// Integrations instead of being projected as Codex Desktop Sessions.
public actor CodexSessionOwnershipPolicy {
    private static let admittedOriginators: Set<String> = [
        "Codex Desktop",
        "codex-tui",
        "codex_cli_rs",
        "conn",
    ]

    private let codexHomeURL: URL

    public init(
        codexHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    ) {
        self.codexHomeURL = codexHomeURL
    }

    public func includedThreadIDs(
        from candidates: Set<AppServerThreadID>
    ) -> Set<AppServerThreadID> {
        guard !candidates.isEmpty else { return [] }
        let candidatesByRawValue = Dictionary(
            uniqueKeysWithValues: candidates.map { ($0.rawValue, $0) }
        )
        // Codex persists UUID Session IDs. Preserve protocol-forward-compatible
        // synthetic/non-persisted identifiers rather than applying a local-file
        // claim that cannot be proven for them.
        var included = Set(candidates.filter { UUID(uuidString: $0.rawValue) == nil })

        for directoryName in ["sessions", "archived_sessions"] {
            let directory = codexHomeURL.appendingPathComponent(
                directoryName,
                isDirectory: true
            )
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
                guard let metadata = Self.sessionMetadata(at: fileURL),
                      let candidate = candidatesByRawValue[metadata.id],
                      Self.admittedOriginators.contains(metadata.originator) else {
                    continue
                }
                included.insert(candidate)
                if included.count == candidates.count { return included }
            }
        }
        return included
    }

    private static func sessionMetadata(
        at fileURL: URL
    ) -> (id: String, originator: String)? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256 * 1024),
              let newline = data.firstIndex(of: 0x0A) else { return nil }
        let firstLine = data[..<newline]
        guard let object = try? JSONSerialization.jsonObject(with: firstLine) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let id = (payload["id"] ?? payload["session_id"]) as? String,
              let originator = payload["originator"] as? String else { return nil }
        return (id, originator)
    }
}
