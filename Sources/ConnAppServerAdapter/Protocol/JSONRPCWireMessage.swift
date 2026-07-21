import Foundation

// Optional Level 3 adapter; never required for hook observation.

public struct JSONRPCSuccessResponse: Sendable, Equatable, Codable {
    public let id: RequestID
    public let result: JSONValue
    public let additionalFields: [String: JSONValue]

    public init(
        id: RequestID,
        result: JSONValue,
        additionalFields: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.result = result
        self.additionalFields = additionalFields.removing(keys: ["id", "result"])
    }

    public init(from decoder: any Decoder) throws {
        let object = try JSONValue(from: decoder).requiredObject(codingPath: decoder.codingPath)
        id = try object.requiredRequestID(for: "id", codingPath: decoder.codingPath)
        result = try object.requiredValue(for: "result", codingPath: decoder.codingPath)
        additionalFields = object.removing(keys: ["id", "result"])
    }

    public func encode(to encoder: any Encoder) throws {
        var object = additionalFields
        object["id"] = id.jsonValue
        object["result"] = result
        try JSONValue.object(object).encode(to: encoder)
    }
}

public struct JSONRPCErrorDetail: Sendable, Equatable, Codable {
    public let code: Int64
    public let message: String
    public let data: JSONValue?
    public let additionalFields: [String: JSONValue]

    public init(
        code: Int64,
        message: String,
        data: JSONValue? = nil,
        additionalFields: [String: JSONValue] = [:]
    ) {
        self.code = code
        self.message = message
        self.data = data
        self.additionalFields = additionalFields.removing(keys: ["code", "message", "data"])
    }

    public init(from decoder: any Decoder) throws {
        let object = try JSONValue(from: decoder).requiredObject(codingPath: decoder.codingPath)
        code = try object.requiredInteger(for: "code", codingPath: decoder.codingPath)
        message = try object.requiredString(for: "message", codingPath: decoder.codingPath)
        data = object["data"]
        additionalFields = object.removing(keys: ["code", "message", "data"])
    }

    public func encode(to encoder: any Encoder) throws {
        var object = additionalFields
        object["code"] = .integer(code)
        object["message"] = .string(message)
        if let data { object["data"] = data }
        try JSONValue.object(object).encode(to: encoder)
    }

    init?(object: [String: JSONValue]) {
        guard
            let code = object["code"]?.integerValue,
            let message = object["message"]?.stringValue
        else { return nil }

        self.init(
            code: code,
            message: message,
            data: object["data"],
            additionalFields: object
        )
    }

    var jsonValue: JSONValue {
        var object = additionalFields
        object["code"] = .integer(code)
        object["message"] = .string(message)
        if let data { object["data"] = data }
        return .object(object)
    }
}

public struct JSONRPCErrorResponse: Sendable, Equatable, Codable {
    public let id: RequestID
    public let error: JSONRPCErrorDetail
    public let additionalFields: [String: JSONValue]

    public init(
        id: RequestID,
        error: JSONRPCErrorDetail,
        additionalFields: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.error = error
        self.additionalFields = additionalFields.removing(keys: ["id", "error"])
    }

    public init(from decoder: any Decoder) throws {
        let object = try JSONValue(from: decoder).requiredObject(codingPath: decoder.codingPath)
        id = try object.requiredRequestID(for: "id", codingPath: decoder.codingPath)
        guard
            let errorObject = object["error"]?.objectValue,
            let error = JSONRPCErrorDetail(object: errorObject)
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Missing or invalid error object")
            )
        }
        self.error = error
        additionalFields = object.removing(keys: ["id", "error"])
    }

    public func encode(to encoder: any Encoder) throws {
        var object = additionalFields
        object["id"] = id.jsonValue
        object["error"] = error.jsonValue
        try JSONValue.object(object).encode(to: encoder)
    }
}

/// A JSON-RPC request. Direction is supplied by the connection that observed it;
/// the envelope itself cannot distinguish a client request from a server request.
public struct JSONRPCRequest: Sendable, Equatable, Codable {
    public let id: RequestID
    public let method: String
    public let params: JSONValue?
    public let additionalFields: [String: JSONValue]

    public init(
        id: RequestID,
        method: String,
        params: JSONValue? = nil,
        additionalFields: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.method = method
        self.params = params
        self.additionalFields = additionalFields.removing(keys: ["id", "method", "params"])
    }

    public init(from decoder: any Decoder) throws {
        let object = try JSONValue(from: decoder).requiredObject(codingPath: decoder.codingPath)
        id = try object.requiredRequestID(for: "id", codingPath: decoder.codingPath)
        method = try object.requiredString(for: "method", codingPath: decoder.codingPath)
        params = object["params"]
        additionalFields = object.removing(keys: ["id", "method", "params"])
    }

    public func encode(to encoder: any Encoder) throws {
        var object = additionalFields
        object["id"] = id.jsonValue
        object["method"] = .string(method)
        if let params { object["params"] = params }
        try JSONValue.object(object).encode(to: encoder)
    }
}

public struct JSONRPCNotification: Sendable, Equatable, Codable {
    public let method: String
    public let params: JSONValue?
    public let additionalFields: [String: JSONValue]

    public init(
        method: String,
        params: JSONValue? = nil,
        additionalFields: [String: JSONValue] = [:]
    ) {
        self.method = method
        self.params = params
        self.additionalFields = additionalFields.removing(keys: ["method", "params"])
    }

    public init(from decoder: any Decoder) throws {
        let object = try JSONValue(from: decoder).requiredObject(codingPath: decoder.codingPath)
        method = try object.requiredString(for: "method", codingPath: decoder.codingPath)
        params = object["params"]
        additionalFields = object.removing(keys: ["method", "params"])
    }

    public func encode(to encoder: any Encoder) throws {
        var object = additionalFields
        object["method"] = .string(method)
        if let params { object["params"] = params }
        try JSONValue.object(object).encode(to: encoder)
    }
}

/// Classification of one complete App Server JSON-RPC wire object.
///
/// Unknown or malformed messages remain inspectable rather than making the
/// event loop fail. Known methods are deliberately not enumerated here.
public enum JSONRPCWireMessage: Sendable, Equatable, Codable {
    case response(JSONRPCSuccessResponse)
    case error(JSONRPCErrorResponse)
    case request(JSONRPCRequest)
    case notification(JSONRPCNotification)
    case unknown(JSONValue)

    public init(from decoder: any Decoder) throws {
        self = Self.classify(try JSONValue(from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .response(response): try response.encode(to: encoder)
        case let .error(error): try error.encode(to: encoder)
        case let .request(request): try request.encode(to: encoder)
        case let .notification(notification): try notification.encode(to: encoder)
        case let .unknown(value): try value.encode(to: encoder)
        }
    }

    public init(data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
    }

    public var rawValue: JSONValue {
        switch self {
        case let .response(value):
            var object = value.additionalFields
            object["id"] = value.id.jsonValue
            object["result"] = value.result
            return .object(object)
        case let .error(value):
            var object = value.additionalFields
            object["id"] = value.id.jsonValue
            object["error"] = value.error.jsonValue
            return .object(object)
        case let .request(value):
            var object = value.additionalFields
            object["id"] = value.id.jsonValue
            object["method"] = .string(value.method)
            if let params = value.params { object["params"] = params }
            return .object(object)
        case let .notification(value):
            var object = value.additionalFields
            object["method"] = .string(value.method)
            if let params = value.params { object["params"] = params }
            return .object(object)
        case let .unknown(value):
            return value
        }
    }

    private static func classify(_ rawValue: JSONValue) -> Self {
        guard case let .object(object) = rawValue else { return .unknown(rawValue) }

        // These keys select mutually exclusive JSON-RPC envelope shapes. Treat
        // conflicting selectors as unknown instead of guessing by precedence.
        let discriminatorCount = ["result", "error", "method"].reduce(into: 0) { count, key in
            if object[key] != nil { count += 1 }
        }
        guard discriminatorCount == 1 else { return .unknown(rawValue) }

        if
            let idValue = object["id"],
            let id = RequestID(jsonValue: idValue),
            let result = object["result"]
        {
            return .response(.init(id: id, result: result, additionalFields: object))
        }

        if
            let idValue = object["id"],
            let id = RequestID(jsonValue: idValue),
            let errorObject = object["error"]?.objectValue,
            let error = JSONRPCErrorDetail(object: errorObject)
        {
            return .error(.init(id: id, error: error, additionalFields: object))
        }

        if
            let idValue = object["id"],
            let id = RequestID(jsonValue: idValue),
            let method = object["method"]?.stringValue
        {
            return .request(
                .init(id: id, method: method, params: object["params"], additionalFields: object)
            )
        }

        if object["id"] == nil, let method = object["method"]?.stringValue {
            return .notification(
                .init(method: method, params: object["params"], additionalFields: object)
            )
        }

        return .unknown(rawValue)
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    func removing(keys: Set<String>) -> Self {
        filter { !keys.contains($0.key) }
    }

    func requiredValue(for key: String, codingPath: [any CodingKey]) throws -> JSONValue {
        guard let value = self[key] else {
            throw DecodingError.keyNotFound(
                DynamicCodingKey(key),
                .init(codingPath: codingPath, debugDescription: "Missing required field \(key)")
            )
        }
        return value
    }

    func requiredString(for key: String, codingPath: [any CodingKey]) throws -> String {
        guard let value = self[key]?.stringValue else {
            throw DecodingError.typeMismatch(
                String.self,
                .init(codingPath: codingPath, debugDescription: "Field \(key) must be a string")
            )
        }
        return value
    }

    func requiredInteger(for key: String, codingPath: [any CodingKey]) throws -> Int64 {
        guard let value = self[key]?.integerValue else {
            throw DecodingError.typeMismatch(
                Int64.self,
                .init(codingPath: codingPath, debugDescription: "Field \(key) must be an integer")
            )
        }
        return value
    }

    func requiredRequestID(for key: String, codingPath: [any CodingKey]) throws -> RequestID {
        guard let rawValue = self[key], let value = RequestID(jsonValue: rawValue) else {
            throw DecodingError.typeMismatch(
                RequestID.self,
                .init(codingPath: codingPath, debugDescription: "Field \(key) must be a request id")
            )
        }
        return value
    }
}

extension JSONValue {
    func requiredObject(codingPath: [any CodingKey]) throws -> [String: JSONValue] {
        guard case let .object(value) = self else {
            throw DecodingError.typeMismatch(
                [String: JSONValue].self,
                .init(codingPath: codingPath, debugDescription: "Expected a JSON object")
            )
        }
        return value
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        return nil
    }
}
