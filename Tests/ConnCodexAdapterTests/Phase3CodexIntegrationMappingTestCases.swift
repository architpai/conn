import Darwin
import Foundation
import ConnCodexAdapter
import ConnDomain

enum Phase3CodexIntegrationMappingTestCases {
    private static let baseDate = Date(timeIntervalSince1970: 1_850_000_000)
    private static let connection = AppServerConnectionIdentity(
        instanceID: UUID(uuidString: "33000000-0000-4000-8000-000000000001")!,
        generation: 3
    )
    private static let threadID = AppServerThreadID(rawValue: "codex-thread")
    private static let turnID = AppServerTurnID(rawValue: "codex-turn")

    static func run(into suite: inout TestSuite) async throws {
        try await mapsQualifiedCodexStateToNeutralSemantics(into: &suite)
        identityAndRuntimeAuthorityStayOpaque(into: &suite)
        try await inheritedOutputDescriptorsDoNotDefeatProcessBounds(into: &suite)
    }

    private static func mapsQualifiedCodexStateToNeutralSemantics(
        into suite: inout TestSuite
    ) async throws {
        let store = AppServerProjectionStore()
        _ = await store.apply(.connectionActivated(
            identity: connection,
            source: .managedDaemon,
            featureSupport: .init(features: [
                .monitor,
                .openInCodex,
                .createThread,
                .followUp,
                .steer,
                .stopTurn,
                .answer,
                .resolveApproval,
            ])
        ))
        _ = await store.apply(.snapshot(.init(
            cursor: cursor(1),
            observedAt: at(1),
            threads: [.init(
                id: threadID,
                sessionID: .init(rawValue: "provider-session-canary"),
                title: "Codex mapping",
                workingDirectoryName: "conn",
                workingDirectoryPath: "/tmp/conn",
                projectRootPath: "/tmp/conn",
                gitBranch: "feature/provider-neutral",
                source: .cli,
                status: .active([.waitingOnApproval]),
                createdAt: at(0),
                updatedAt: at(2),
                turnsAreAuthoritative: true,
                turns: [.init(
                    id: turnID,
                    status: .inProgress,
                    startedAt: at(1),
                    items: [
                        .init(
                            id: .init(rawValue: "command-item"),
                            kind: .commandExecution,
                            status: .completed,
                            startedAt: at(1),
                            completedAt: at(2),
                            presentation: .command("swift build")
                        ),
                        .init(
                            id: .init(rawValue: "unknown-item"),
                            kind: .unknown,
                            status: .unknown,
                            startedAt: at(2)
                        ),
                    ]
                )]
            )],
            threadFreshness: .live
        )))
        _ = await store.apply(.delta(.init(
            cursor: cursor(2),
            observedAt: at(2),
            delta: .requestOpened(.init(
                requestID: .string("RAW-RESPONSE-TOKEN-CANARY"),
                threadID: threadID,
                turnID: turnID,
                itemID: .init(rawValue: "command-item"),
                kind: .commandApproval,
                facts: .commandApproval(.init(
                    command: "swift build",
                    workingDirectory: "/tmp/conn",
                    reason: "Build needs approval"
                )),
                startedAt: at(2)
            ))
        )))

        let source = await store.snapshot(at: at(3))
        let generation = IntegrationConnectionGeneration(
            instanceID: UUID(uuidString: "33000000-0000-4000-8000-000000000002")!,
            ordinal: 1
        )
        let mapping = CodexProjectionMapper.map(
            source,
            generation: generation,
            throughSequence: 7,
            inventoryAuthority: .complete,
            connOriginatedThreadIDs: [threadID],
            attentionID: { _ in .init(rawValue: "neutral-attention") },
            observedAt: at(3)
        )
        let snapshot = mapping.snapshot
        let session = snapshot.sessions.first

        suite.check(
            snapshot.integration == CodexIntegrationIdentity.descriptor
                && snapshot.integration.harnessID == .init(rawValue: "openai"),
            "Codex mapping carries stable OpenAI Harness attribution"
        )
        suite.check(
            snapshot.generation == generation && snapshot.throughSequence == 7,
            "neutral snapshot preserves only Conn runtime ordering authority"
        )
        suite.check(
            snapshot.inventoryAuthority == .complete,
            "completed Codex pagination maps to complete inventory authority"
        )
        suite.check(
            snapshot.capabilities.canMonitor
                && snapshot.capabilities.actions == [
                    .createSession, .followUp, .steer, .interrupt,
                    .answer, .resolveApproval,
                ],
            "only semantic actions executed by the Adapter are advertised"
        )
        suite.check(
            session?.id == .init(
                integrationID: CodexIntegrationIdentity.integrationID,
                upstreamID: .init(rawValue: threadID.rawValue)
            ),
            "Codex Thread identity becomes Integration-scoped Session identity"
        )
        suite.check(
            session?.origin == .conn
                && session?.ownership == .harness
                && session?.retention == .ephemeral,
            "New Chat remains Conn-originated, Codex-owned, and ephemeral"
        )
        suite.check(
            session?.workspace?.canonicalPath == "/tmp/conn",
            "proven project root maps to neutral Workspace evidence"
        )
        suite.check(
            session?.status == .waitingForAttention,
            "response-bearing Codex request maps to waiting-for-Attention status"
        )
        suite.check(
            session?.runs == [.init(
                id: .init(rawValue: turnID.rawValue),
                status: .inProgress,
                startedAt: at(1)
            )],
            "evidence-backed Codex Turn maps to an optional Conn Run"
        )
        suite.check(
            session?.activities.map(\.kind) == [.command, .unknown],
            "supported and unknown Codex Items map to bounded semantic Activities"
        )
        suite.check(
            session?.activities.first?.summary == "swift build"
                && session?.activities.last?.summary == nil,
            "only reviewed bounded presentation crosses the mapping seam"
        )
        suite.check(
            snapshot.attentionRequests.first?.id == .init(rawValue: "neutral-attention")
                && snapshot.attentionRequests.first?.kind == .approval,
            "provider request becomes a Conn-owned opaque Attention identity"
        )
        suite.check(
            mapping.providerRequestsByID.count == 1,
            "adapter retains exact provider request authority internally"
        )
        let reflectedSnapshot = String(reflecting: snapshot)
        suite.check(
            !reflectedSnapshot.contains("RAW-RESPONSE-TOKEN-CANARY")
                && !reflectedSnapshot.contains("provider-session-canary"),
            "provider response and session tokens do not cross the neutral port"
        )
    }

    private static func identityAndRuntimeAuthorityStayOpaque(
        into suite: inout TestSuite
    ) {
        suite.check(
            CodexIntegrationIdentity.integrationID.rawValue == "builtin-codex",
            "v0.2 Codex Integration uses its reserved stable Conn identity"
        )
        let responseAuthority = AttentionResponseAuthority(
            requestID: .init(rawValue: "neutral"),
            generation: .init(
                instanceID: UUID(uuidString: "33000000-0000-4000-8000-000000000003")!,
                ordinal: 2
            )
        )
        suite.check(
            !String(reflecting: responseAuthority).contains("responseToken"),
            "neutral response authority contains generation evidence, never a provider token"
        )
    }

    private static func inheritedOutputDescriptorsDoNotDefeatProcessBounds(
        into suite: inout TestSuite
    ) async throws {
        let pidFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("conn-inherited-pipe-\(UUID().uuidString).pid")
        var childPID: Int32?
        defer {
            if let childPID {
                _ = Darwin.kill(childPID, SIGTERM)
            }
            try? FileManager.default.removeItem(at: pidFileURL)
        }

        let clock = ContinuousClock()
        let startedAt = clock.now
        let result = try await BoundedProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "sleep 2 & printf '%s\\n' \"$!\" > \"$1\"",
                "conn-inherited-pipe-test",
                pidFileURL.path,
            ],
            timeout: .seconds(3)
        )
        if let pidText = try? String(contentsOf: pidFileURL, encoding: .utf8) {
            childPID = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        suite.check(
            result.terminationStatus == 0
                && childPID != nil
                && startedAt.duration(to: clock.now) < .milliseconds(1_500),
            "a grandchild inheriting output pipes cannot hold process completion open"
        )
    }

    private static func cursor(_ sequence: UInt64) -> AppServerObservationCursor {
        .init(connection: connection, sequence: sequence)
    }

    private static func at(_ seconds: TimeInterval) -> Date {
        baseDate.addingTimeInterval(seconds)
    }
}
