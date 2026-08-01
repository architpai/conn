import Foundation
import ConnDomain
import ConnPiAdapter

enum PiProductionLiveProbe {
    private enum Stage {
        case waitingForRegistration
        case waitingForIdleReply
        case waitingForSteerTool
        case waitingForSteerReply
        case waitingForInterruptTool
        case waitingForInterruptSettlement
    }

    static func run() async {
        guard let agentArgument = argument(after: "--agent-dir"),
              let runtimeArgument = argument(after: "--runtime-dir"),
              let socketArgument = argument(after: "--socket") else {
            fail("live probe requires --agent-dir, --runtime-dir, and --socket")
        }
        let agentDirectory = URL(fileURLWithPath: agentArgument, isDirectory: true)
        let installer = PiExtensionInstaller(
            agentDirectory: agentDirectory,
            sourceURL: PiExtensionResource.bundledSourceURL,
            releaseVersion: "0.2.1",
            trashDirectory: agentDirectory.appendingPathComponent("trash", isDirectory: true)
        )
        do {
            _ = try installer.install()
        } catch {
            fail("isolated production extension install failed: \(error)")
        }
        let broker = PiLocalBroker(
            runtimeStore: .init(
                directory: URL(fileURLWithPath: runtimeArgument, isDirectory: true)
            ),
            socketURL: URL(fileURLWithPath: socketArgument)
        )
        let integration = PiExternalIntegration(broker: broker, enabled: true)
        do {
            let feed = try await integration.establishFeed()
            emit("LIVE_PROBE_READY")
            var stage = Stage.waitingForRegistration
            for await update in feed.updates {
                guard case let .sessionUpsert(session) = update.update else { continue }
                let summary = session.activities.last?.summary ?? ""
                switch stage {
                case .waitingForRegistration:
                    let result = await followUp(
                        "Reply with exactly PRODUCTION_IDLE_FOLLOWUP_OK",
                        session: session,
                        integration: integration
                    )
                    emit("IDLE_FOLLOWUP_\(result.kind.rawValue)")
                    guard result.kind == .accepted else {
                        fail("idle follow-up was not accepted")
                    }
                    stage = .waitingForIdleReply

                case .waitingForIdleReply
                    where summary.contains("PRODUCTION_IDLE_FOLLOWUP_OK"):
                    let result = await followUp(
                        "Use bash to run sleep 5. When it completes, obey any steering message.",
                        session: session,
                        integration: integration
                    )
                    emit("BUSY_PROMPT_\(result.kind.rawValue)")
                    guard result.kind == .accepted else {
                        fail("busy prompt was not accepted")
                    }
                    stage = .waitingForSteerTool

                case .waitingForSteerTool
                    where session.activities.last?.kind == .toolCall
                        && session.status == .working:
                    guard let run = session.runs.first else {
                        fail("busy Pi state did not project an active Run")
                    }
                    let result = await integration.perform(.steer(
                        sessionID: session.id,
                        runID: run.id,
                        text: try ConnActionText(
                            "After the tool completes, reply exactly PRODUCTION_STEER_OK"
                        )
                    ))
                    emit("STEER_\(result.kind.rawValue)")
                    guard result.kind == .accepted else {
                        fail("steer was not accepted")
                    }
                    stage = .waitingForSteerReply

                case .waitingForSteerReply
                    where summary.contains("PRODUCTION_STEER_OK"):
                    let result = await followUp(
                        "Use bash to run sleep 20, then reply SHOULD_NOT_APPEAR",
                        session: session,
                        integration: integration
                    )
                    emit("INTERRUPT_PROMPT_\(result.kind.rawValue)")
                    guard result.kind == .accepted else {
                        fail("interrupt prompt was not accepted")
                    }
                    stage = .waitingForInterruptTool

                case .waitingForInterruptTool
                    where session.activities.last?.kind == .toolCall
                        && session.status == .working:
                    guard let run = session.runs.first else {
                        fail("interrupt target did not project an active Run")
                    }
                    let result = await integration.perform(.interrupt(
                        sessionID: session.id,
                        runID: run.id
                    ))
                    emit("INTERRUPT_\(result.kind.rawValue)")
                    guard result.kind == .accepted else {
                        fail("interrupt was not accepted")
                    }
                    stage = .waitingForInterruptSettlement

                case .waitingForInterruptSettlement where session.status == .idle:
                    emit("PRODUCTION_PI_E2E_PASS")
                    await integration.disconnect()
                    Foundation.exit(EXIT_SUCCESS)

                default:
                    break
                }
            }
            fail("live Pi feed ended before parity completed")
        } catch {
            fail("live Pi probe failed: \(error)")
        }
    }

    private static func followUp(
        _ value: String,
        session: ConnSession,
        integration: PiExternalIntegration
    ) async -> ConnActionOutcome {
        do {
            return await integration.perform(.followUp(
                sessionID: session.id,
                text: try ConnActionText(value)
            ))
        } catch {
            return .init(
                integrationID: PiExternalIntegrationIdentity.integrationID,
                action: .followUp,
                kind: .rejected,
                evidence: String(describing: error)
            )
        }
    }

    private static func argument(after name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name),
              CommandLine.arguments.indices.contains(index + 1) else {
            return nil
        }
        return CommandLine.arguments[index + 1]
    }

    private static func emit(_ value: String) {
        print(value)
        fflush(stdout)
    }

    private static func fail(_ value: String) -> Never {
        fputs("LIVE_PROBE_FAIL: \(value)\n", stderr)
        fflush(stderr)
        Foundation.exit(EXIT_FAILURE)
    }
}
