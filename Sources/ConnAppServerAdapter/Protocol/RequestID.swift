import Foundation

// Optional Level 3 adapter; never required for hook observation.

/// The request identifier shape emitted by the official Codex App Server.
/// JSON-RPC `null` and floating-point identifiers are intentionally rejected.
public enum RequestID: Sendable, Hashable, Codable, CustomStringConvertible {
    case string(String)
    case integer(Int64)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "A request id must be a string or signed 64-bit integer"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        }
    }

    public var description: String {
        switch self {
        case let .string(value): value
        case let .integer(value): String(value)
        }
    }

    init?(jsonValue: JSONValue) {
        switch jsonValue {
        case let .string(value): self = .string(value)
        case let .integer(value): self = .integer(value)
        default: return nil
        }
    }

    var jsonValue: JSONValue {
        switch self {
        case let .string(value): .string(value)
        case let .integer(value): .integer(value)
        }
    }
}
