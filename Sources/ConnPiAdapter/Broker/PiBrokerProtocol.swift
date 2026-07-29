import Foundation

public enum PiBrokerProtocolBounds {
    public static let currentVersion = 1
    public static let maximumFrameBytes = 64 * 1024
    public static let maximumIdentifierUTF8Bytes = 512
    public static let maximumPathUTF8Bytes = 4 * 1024
}

public enum PiBrokerProtocolError: Error, Equatable, Sendable {
    case frameTooLarge
    case malformedFrame
    case unsupportedMessage
    case unsupportedProtocol
    case staleGeneration
    case authenticationFailed
    case invalidField
}

public struct PiBridgeHandshake: Equatable, Sendable {
    public let extensionVersion: String
    public let piVersion: String
    public let instanceID: String
    public let processID: Int32
    public let sessionID: String
    public let sessionName: String?
    public let reason: String
    public let workspace: String
    public let modelProvider: String
    public let modelID: String
    public let thinkingLevel: String
    public let isIdle: Bool?
}

public enum PiBrokerHandshakeDecoder {
    public static func decode(
        _ data: Data,
        expectedGeneration: UUID,
        expectedSecret: String
    ) throws(PiBrokerProtocolError) -> PiBridgeHandshake {
        guard data.count <= PiBrokerProtocolBounds.maximumFrameBytes else {
            throw .frameTooLarge
        }
        let messageType: String
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else {
                throw PiBrokerProtocolError.malformedFrame
            }
            messageType = type
        } catch let error as PiBrokerProtocolError {
            throw error
        } catch {
            throw .malformedFrame
        }
        guard messageType == "register" else { throw .unsupportedMessage }
        let frame: WireHandshake
        do {
            frame = try JSONDecoder().decode(WireHandshake.self, from: data)
        } catch {
            throw .malformedFrame
        }
        guard frame.protocolVersion == PiBrokerProtocolBounds.currentVersion else {
            throw .unsupportedProtocol
        }
        guard frame.generation == expectedGeneration else {
            throw .staleGeneration
        }
        guard constantTimeEqual(frame.secret, expectedSecret) else {
            throw .authenticationFailed
        }
        guard frame.pid > 0, frame.pid <= Int(Int32.max),
              validIdentifier(frame.extensionVersion),
              validIdentifier(frame.piVersion),
              validIdentifier(frame.instanceID),
              validIdentifier(frame.sessionID),
              validIdentifier(frame.reason),
              validPath(frame.cwd),
              validIdentifier(frame.modelProvider),
              validIdentifier(frame.modelID),
              validIdentifier(frame.thinking)
        else {
            throw .invalidField
        }
        return PiBridgeHandshake(
            extensionVersion: frame.extensionVersion,
            piVersion: frame.piVersion,
            instanceID: frame.instanceID,
            processID: Int32(frame.pid),
            sessionID: frame.sessionID,
            sessionName: frame.sessionName,
            reason: frame.reason,
            workspace: frame.cwd,
            modelProvider: frame.modelProvider,
            modelID: frame.modelID,
            thinkingLevel: frame.thinking,
            isIdle: frame.isIdle
        )
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= PiBrokerProtocolBounds.maximumIdentifierUTF8Bytes
            && !value.contains(where: \.isNewline)
    }

    private static func validPath(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= PiBrokerProtocolBounds.maximumPathUTF8Bytes
            && !value.contains("\0")
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        var difference = UInt(lhsBytes.count ^ rhsBytes.count)
        let count = max(lhsBytes.count, rhsBytes.count)
        for index in 0..<count {
            let left = index < lhsBytes.count ? lhsBytes[index] : 0
            let right = index < rhsBytes.count ? rhsBytes[index] : 0
            difference |= UInt(left ^ right)
        }
        return difference == 0
    }
}

private struct WireHandshake: Decodable {
    let type: String
    let protocolVersion: Int
    let generation: UUID
    let secret: String
    let extensionVersion: String
    let piVersion: String
    let instanceID: String
    let pid: Int
    let sessionID: String
    let sessionName: String?
    let reason: String
    let cwd: String
    let modelProvider: String
    let modelID: String
    let thinking: String
    let isIdle: Bool?

    private enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion = "protocol"
        case generation
        case secret
        case extensionVersion
        case piVersion
        case instanceID = "instanceId"
        case pid
        case sessionID = "sessionId"
        case sessionName
        case reason
        case cwd
        case modelProvider
        case modelID = "modelId"
        case thinking
        case isIdle
    }
}

public struct PiBridgeState: Codable, Equatable, Sendable {
    public let sessionID: String
    public let sessionName: String?
    public let workspace: String
    public let isIdle: Bool
    public let hasPendingMessages: Bool
    public let lastEvent: String
    public let activeToolCount: Int
    public let modelProvider: String
    public let modelID: String
    public let modelName: String?
    public let thinkingLevel: String

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case sessionName
        case workspace = "cwd"
        case isIdle
        case hasPendingMessages
        case lastEvent
        case activeToolCount
        case modelProvider
        case modelID = "modelId"
        case modelName
        case thinkingLevel = "thinking"
    }

    fileprivate var isValid: Bool {
        !sessionID.isEmpty
            && sessionID.utf8.count <= PiBrokerProtocolBounds.maximumIdentifierUTF8Bytes
            && workspace.hasPrefix("/")
            && workspace.utf8.count <= PiBrokerProtocolBounds.maximumPathUTF8Bytes
            && activeToolCount >= 0
            && activeToolCount <= 1_024
            && !modelProvider.isEmpty
            && !modelID.isEmpty
            && modelProvider.utf8.count
                <= PiBrokerProtocolBounds.maximumIdentifierUTF8Bytes
            && modelID.utf8.count <= PiBrokerProtocolBounds.maximumIdentifierUTF8Bytes
            && thinkingLevel.utf8.count
                <= PiBrokerProtocolBounds.maximumIdentifierUTF8Bytes
    }
}

public struct PiBridgeEventFrame: Equatable, Sendable {
    public let event: String
    public let state: PiBridgeState
    public let activity: PiBridgeActivity?
}

public struct PiBridgeActivity: Codable, Equatable, Sendable {
    public let id: String
    public let kind: String
    public let text: String

    fileprivate var isValid: Bool {
        !id.isEmpty
            && id.utf8.count <= PiBrokerProtocolBounds.maximumIdentifierUTF8Bytes
            && ["userMessage", "agentMessage", "toolCall"].contains(kind)
            && text.utf8.count <= 32 * 1_024
    }
}

public struct PiBridgeResponseFrame: Equatable, Sendable {
    public let id: String
    public let success: Bool
    public let error: String?
    public let state: PiBridgeState
}

public struct PiBridgeAttentionRequest: Codable, Equatable, Sendable {
    public let id: String
    public let kind: String
    public let questionID: String?
    public let header: String?
    public let prompt: String
    public let choices: [String]
    public let permitsOther: Bool?
    public let toolName: String?

    fileprivate var isValid: Bool {
        !id.isEmpty
            && id.utf8.count <= PiBrokerProtocolBounds.maximumIdentifierUTF8Bytes
            && ["question", "approval"].contains(kind)
            && prompt.utf8.count <= 2_048
            && choices.count <= 8
            && choices.allSatisfy {
                !$0.isEmpty && $0.utf8.count <= 512
            }
            && (kind != "question" || (
                questionID?.isEmpty == false
                    && header?.isEmpty == false
            ))
            && (kind != "approval" || toolName?.isEmpty == false)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case questionID = "questionId"
        case header
        case prompt
        case choices
        case permitsOther
        case toolName
    }
}

public struct PiBridgeAttentionFrame: Equatable, Sendable {
    public let request: PiBridgeAttentionRequest
    public let state: PiBridgeState
}

public struct PiBridgeAttentionResolvedFrame: Equatable, Sendable {
    public let requestID: String
    public let state: PiBridgeState
}

public enum PiBrokerMessage: Equatable, Sendable {
    case event(PiBridgeEventFrame)
    case response(PiBridgeResponseFrame)
    case attention(PiBridgeAttentionFrame)
    case attentionResolved(PiBridgeAttentionResolvedFrame)
}

public enum PiBrokerMessageDecoder {
    public static func decode(
        _ data: Data
    ) throws(PiBrokerProtocolError) -> PiBrokerMessage {
        guard data.count <= PiBrokerProtocolBounds.maximumFrameBytes else {
            throw .frameTooLarge
        }
        let type: String
        do {
            guard let object = try JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  let candidate = object["type"] as? String else {
                throw PiBrokerProtocolError.malformedFrame
            }
            type = candidate
        } catch let error as PiBrokerProtocolError {
            throw error
        } catch {
            throw .malformedFrame
        }
        let decoder = JSONDecoder()
        do {
            switch type {
            case "event":
                let wire = try decoder.decode(WireEvent.self, from: data)
                guard wire.state.isValid,
                      !wire.event.isEmpty,
                      wire.event.utf8.count
                        <= PiBrokerProtocolBounds.maximumIdentifierUTF8Bytes,
                      wire.activity?.isValid != false
                else { throw PiBrokerProtocolError.invalidField }
                return .event(.init(
                    event: wire.event,
                    state: wire.state,
                    activity: wire.activity
                ))
            case "response":
                let wire = try decoder.decode(WireResponse.self, from: data)
                guard wire.state.isValid,
                      !wire.id.isEmpty,
                      wire.id.utf8.count
                        <= PiBrokerProtocolBounds.maximumIdentifierUTF8Bytes,
                      wire.error?.utf8.count ?? 0 <= 2_048
                else { throw PiBrokerProtocolError.invalidField }
                return .response(.init(
                    id: wire.id,
                    success: wire.success,
                    error: wire.error,
                    state: wire.state
                ))
            case "attention":
                let wire = try decoder.decode(WireAttention.self, from: data)
                guard wire.state.isValid, wire.request.isValid else {
                    throw PiBrokerProtocolError.invalidField
                }
                return .attention(.init(
                    request: wire.request,
                    state: wire.state
                ))
            case "attention_resolved":
                let wire = try decoder.decode(WireAttentionResolved.self, from: data)
                guard wire.state.isValid,
                      !wire.requestID.isEmpty,
                      wire.requestID.utf8.count
                        <= PiBrokerProtocolBounds.maximumIdentifierUTF8Bytes
                else { throw PiBrokerProtocolError.invalidField }
                return .attentionResolved(.init(
                    requestID: wire.requestID,
                    state: wire.state
                ))
            default:
                throw PiBrokerProtocolError.unsupportedMessage
            }
        } catch let error as PiBrokerProtocolError {
            throw error
        } catch {
            throw .malformedFrame
        }
    }
}

public enum PiBrokerCommand: Equatable, Sendable {
    case followUp(id: String, message: String)
    case steer(id: String, message: String)
    case interrupt(id: String)
    case setModel(id: String, provider: String, modelID: String)
    case setThinking(id: String, level: String)
    case answer(id: String, requestID: String, answer: String)
    case decide(id: String, requestID: String, approve: Bool)

    public var id: String {
        switch self {
        case let .followUp(id, _),
             let .steer(id, _),
             let .interrupt(id),
             let .setModel(id, _, _),
             let .setThinking(id, _),
             let .answer(id, _, _),
             let .decide(id, _, _):
            id
        }
    }
}

public enum PiBrokerCommandEncoder {
    public static func encode(
        _ command: PiBrokerCommand
    ) throws(PiBrokerProtocolError) -> Data {
        var object: [String: Any] = ["id": command.id]
        switch command {
        case let .followUp(_, message):
            guard validMessage(message) else { throw .invalidField }
            object["type"] = "follow_up"
            object["message"] = message
        case let .steer(_, message):
            guard validMessage(message) else { throw .invalidField }
            object["type"] = "steer"
            object["message"] = message
        case .interrupt:
            object["type"] = "interrupt"
        case let .setModel(_, provider, modelID):
            guard validIdentifier(provider), validIdentifier(modelID) else {
                throw .invalidField
            }
            object["type"] = "set_model"
            object["provider"] = provider
            object["modelId"] = modelID
        case let .setThinking(_, level):
            guard validIdentifier(level) else { throw .invalidField }
            object["type"] = "set_thinking"
            object["level"] = level
        case let .answer(_, requestID, answer):
            guard validIdentifier(requestID), validMessage(answer) else {
                throw .invalidField
            }
            object["type"] = "answer"
            object["requestId"] = requestID
            object["answer"] = answer
        case let .decide(_, requestID, approve):
            guard validIdentifier(requestID) else { throw .invalidField }
            object["type"] = "decide"
            object["requestId"] = requestID
            object["decision"] = approve ? "approve" : "deny"
        }
        do {
            var data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            data.append(0x0A)
            guard data.count <= PiBrokerProtocolBounds.maximumFrameBytes else {
                throw PiBrokerProtocolError.frameTooLarge
            }
            return data
        } catch let error as PiBrokerProtocolError {
            throw error
        } catch {
            throw .malformedFrame
        }
    }

    private static func validMessage(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 32 * 1_024
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= PiBrokerProtocolBounds.maximumIdentifierUTF8Bytes
            && !value.contains(where: \.isNewline)
    }
}

private struct WireEvent: Decodable {
    let event: String
    let state: PiBridgeState
    let activity: PiBridgeActivity?
}

private struct WireResponse: Decodable {
    let id: String
    let success: Bool
    let error: String?
    let state: PiBridgeState
}

private struct WireAttention: Decodable {
    let request: PiBridgeAttentionRequest
    let state: PiBridgeState
}

private struct WireAttentionResolved: Decodable {
    let requestID: String
    let state: PiBridgeState

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case state
    }
}
