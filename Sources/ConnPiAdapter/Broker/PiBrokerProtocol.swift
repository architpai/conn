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
    public let reason: String
    public let workspace: String
    public let modelProvider: String
    public let modelID: String
    public let thinkingLevel: String
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
            reason: frame.reason,
            workspace: frame.cwd,
            modelProvider: frame.modelProvider,
            modelID: frame.modelID,
            thinkingLevel: frame.thinking
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
    let reason: String
    let cwd: String
    let modelProvider: String
    let modelID: String
    let thinking: String

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
        case reason
        case cwd
        case modelProvider
        case modelID = "modelId"
        case thinking
    }
}
