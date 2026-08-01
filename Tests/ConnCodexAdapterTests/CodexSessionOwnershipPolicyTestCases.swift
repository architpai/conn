import Foundation
import ConnCodexAdapter

enum CodexSessionOwnershipPolicyTestCases {
    static func run(into suite: inout TestSuite) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "conn-codex-ownership-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let sessions = root.appendingPathComponent("sessions/2026/07/30", isDirectory: true)
        let archived = root.appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)

        let desktop = "10000000-0000-4000-8000-000000000001"
        let cli = "10000000-0000-4000-8000-000000000002"
        let conn = "10000000-0000-4000-8000-000000000003"
        let t3 = "10000000-0000-4000-8000-000000000004"
        let vscode = "10000000-0000-4000-8000-000000000005"
        let missing = "10000000-0000-4000-8000-000000000006"
        try writeRollout(id: desktop, originator: "Codex Desktop", under: sessions)
        try writeRollout(id: cli, originator: "codex-tui", under: sessions)
        try writeRollout(id: conn, originator: "conn", under: sessions)
        try writeRollout(id: t3, originator: "t3code_desktop", under: sessions)
        try writeRollout(id: vscode, originator: "codex_vscode", under: archived)

        let candidates = Set([desktop, cli, conn, t3, vscode, missing].map {
            AppServerThreadID(rawValue: $0)
        })
        let included = await CodexSessionOwnershipPolicy(
            codexHomeURL: root
        ).includedThreadIDs(from: candidates)

        suite.checkEqual(
            included.map(\.rawValue).sorted(),
            [cli, conn, desktop].sorted(),
            "Codex inventory admits only CLI, Desktop, and Conn-originated Sessions"
        )
    }

    private static func writeRollout(
        id: String,
        originator: String,
        under directory: URL
    ) throws {
        let payload: [String: Any] = [
            "type": "session_meta",
            "payload": [
                "id": id,
                "originator": originator,
                "source": "vscode",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.appendingNewline().write(
            to: directory.appendingPathComponent("rollout-\(id).jsonl")
        )
    }
}

private extension Data {
    func appendingNewline() -> Data {
        var result = self
        result.append(0x0A)
        return result
    }
}
