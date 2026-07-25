import Foundation

// Optional Level 3 adapter; never required for hook observation.

/// Identity supplied by the client during `initialize`.
public struct InitializeClientInfo: Sendable, Equatable, Codable {
    public let name: String
    public let title: String?
    public let version: String
    public let additionalFields: [String: JSONValue]

    public init(
        name: String,
        title: String? = nil,
        version: String,
        additionalFields: [String: JSONValue] = [:]
    ) {
        self.name = name
        self.title = title
        self.version = version
        self.additionalFields = additionalFields.removing(keys: ["name", "title", "version"])
    }

    public init(from decoder: any Decoder) throws {
        let object = try JSONValue(from: decoder).requiredObject(codingPath: decoder.codingPath)
        name = try object.requiredString(for: "name", codingPath: decoder.codingPath)
        version = try object.requiredString(for: "version", codingPath: decoder.codingPath)

        if let rawTitle = object["title"] {
            switch rawTitle {
            case .null: title = nil
            case let .string(value): title = value
            default:
                throw DecodingError.typeMismatch(
                    String.self,
                    .init(codingPath: decoder.codingPath, debugDescription: "Field title must be a string or null")
                )
            }
        } else {
            title = nil
        }

        additionalFields = object.removing(keys: ["name", "title", "version"])
    }

    public func encode(to encoder: any Encoder) throws {
        var object = additionalFields
        object["name"] = .string(name)
        object["version"] = .string(version)
        if let title { object["title"] = .string(title) }
        try JSONValue.object(object).encode(to: encoder)
    }

    var jsonValue: JSONValue {
        var object = additionalFields
        object["name"] = .string(name)
        object["version"] = .string(version)
        if let title { object["title"] = .string(title) }
        return .object(object)
    }
}
/// Client-declared capabilities defined by the installed official schema.
///
/// This is intentionally not an action-support matrix. The initialize response
/// does not currently document per-action capability flags.
public struct InitializeCapabilities: Sendable, Equatable, Codable {
    public let experimentalAPI: Bool?
    public let mcpServerOpenAIFormElicitation: Bool?
    public let optOutNotificationMethods: [String]?
    public let requestAttestation: Bool?
    public let additionalFields: [String: JSONValue]

    public init(
        experimentalAPI: Bool? = nil,
        mcpServerOpenAIFormElicitation: Bool? = nil,
        optOutNotificationMethods: [String]? = nil,
        requestAttestation: Bool? = nil,
        additionalFields: [String: JSONValue] = [:]
    ) {
        self.experimentalAPI = experimentalAPI
        self.mcpServerOpenAIFormElicitation = mcpServerOpenAIFormElicitation
        self.optOutNotificationMethods = optOutNotificationMethods
        self.requestAttestation = requestAttestation
        self.additionalFields = additionalFields.removing(
            keys: [
                "experimentalApi",
                "mcpServerOpenaiFormElicitation",
                "optOutNotificationMethods",
                "requestAttestation",
            ]
        )
    }

    public init(from decoder: any Decoder) throws {
        let object = try JSONValue(from: decoder).requiredObject(codingPath: decoder.codingPath)
        experimentalAPI = try object.optionalBool(for: "experimentalApi", codingPath: decoder.codingPath)
        mcpServerOpenAIFormElicitation = try object.optionalBool(
            for: "mcpServerOpenaiFormElicitation",
            codingPath: decoder.codingPath
        )
        optOutNotificationMethods = try object.optionalStringArray(
            for: "optOutNotificationMethods",
            codingPath: decoder.codingPath
        )
        requestAttestation = try object.optionalBool(
            for: "requestAttestation",
            codingPath: decoder.codingPath
        )
        additionalFields = object.removing(
            keys: [
                "experimentalApi",
                "mcpServerOpenaiFormElicitation",
                "optOutNotificationMethods",
                "requestAttestation",
            ]
        )
    }

    public func encode(to encoder: any Encoder) throws {
        try jsonValue.encode(to: encoder)
    }

    var jsonValue: JSONValue {
        var object = additionalFields
        if let experimentalAPI { object["experimentalApi"] = .bool(experimentalAPI) }
        if let mcpServerOpenAIFormElicitation {
            object["mcpServerOpenaiFormElicitation"] = .bool(mcpServerOpenAIFormElicitation)
        }
        if let optOutNotificationMethods {
            object["optOutNotificationMethods"] = .array(optOutNotificationMethods.map(JSONValue.string))
        }
        if let requestAttestation { object["requestAttestation"] = .bool(requestAttestation) }
        return .object(object)
    }
}

public struct InitializeParams: Sendable, Equatable, Codable {
    public let clientInfo: InitializeClientInfo
    public let capabilities: InitializeCapabilities?
    public let additionalFields: [String: JSONValue]

    public init(
        clientInfo: InitializeClientInfo,
        capabilities: InitializeCapabilities? = nil,
        additionalFields: [String: JSONValue] = [:]
    ) {
        self.clientInfo = clientInfo
        self.capabilities = capabilities
        self.additionalFields = additionalFields.removing(keys: ["clientInfo", "capabilities"])
    }

    public init(from decoder: any Decoder) throws {
        let object = try JSONValue(from: decoder).requiredObject(codingPath: decoder.codingPath)
        clientInfo = try object.decodeRequired(
            InitializeClientInfo.self,
            for: "clientInfo",
            codingPath: decoder.codingPath
        )
        capabilities = try object.decodeOptional(
            InitializeCapabilities.self,
            for: "capabilities",
            codingPath: decoder.codingPath
        )
        additionalFields = object.removing(keys: ["clientInfo", "capabilities"])
    }

    public func encode(to encoder: any Encoder) throws {
        var object = additionalFields
        object["clientInfo"] = clientInfo.jsonValue
        if let capabilities { object["capabilities"] = capabilities.jsonValue }
        try JSONValue.object(object).encode(to: encoder)
    }
}

/// The official `initialize` result. Unknown future response capabilities remain
/// available in `additionalFields` until they are documented and modeled.
public struct InitializeResponse: Sendable, Equatable, Codable {
    public let codexHome: String
    public let platformFamily: String
    public let platformOS: String
    public let userAgent: String
    public let additionalFields: [String: JSONValue]

    public init(
        codexHome: String,
        platformFamily: String,
        platformOS: String,
        userAgent: String,
        additionalFields: [String: JSONValue] = [:]
    ) {
        self.codexHome = codexHome
        self.platformFamily = platformFamily
        self.platformOS = platformOS
        self.userAgent = userAgent
        self.additionalFields = additionalFields.removing(
            keys: ["codexHome", "platformFamily", "platformOs", "userAgent"]
        )
    }

    public init(from decoder: any Decoder) throws {
        let object = try JSONValue(from: decoder).requiredObject(codingPath: decoder.codingPath)
        codexHome = try object.requiredString(for: "codexHome", codingPath: decoder.codingPath)
        platformFamily = try object.requiredString(for: "platformFamily", codingPath: decoder.codingPath)
        platformOS = try object.requiredString(for: "platformOs", codingPath: decoder.codingPath)
        userAgent = try object.requiredString(for: "userAgent", codingPath: decoder.codingPath)
        additionalFields = object.removing(
            keys: ["codexHome", "platformFamily", "platformOs", "userAgent"]
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var object = additionalFields
        object["codexHome"] = .string(codexHome)
        object["platformFamily"] = .string(platformFamily)
        object["platformOs"] = .string(platformOS)
        object["userAgent"] = .string(userAgent)
        try JSONValue.object(object).encode(to: encoder)
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func optionalBool(for key: String, codingPath: [any CodingKey]) throws -> Bool? {
        guard let rawValue = self[key] else { return nil }
        if case .null = rawValue { return nil }
        guard let value = rawValue.boolValue else {
            throw DecodingError.typeMismatch(
                Bool.self,
                .init(codingPath: codingPath, debugDescription: "Field \(key) must be a boolean")
            )
        }
        return value
    }

    func optionalStringArray(for key: String, codingPath: [any CodingKey]) throws -> [String]? {
        guard let rawValue = self[key] else { return nil }
        if case .null = rawValue { return nil }
        guard case let .array(values) = rawValue else {
            throw DecodingError.typeMismatch(
                [String].self,
                .init(codingPath: codingPath, debugDescription: "Field \(key) must be an array")
            )
        }
        return try values.map { value in
            guard let string = value.stringValue else {
                throw DecodingError.typeMismatch(
                    String.self,
                    .init(codingPath: codingPath, debugDescription: "Field \(key) must contain only strings")
                )
            }
            return string
        }
    }

    func decodeRequired<T: Decodable>(
        _ type: T.Type,
        for key: String,
        codingPath: [any CodingKey]
    ) throws -> T {
        let rawValue = try requiredValue(for: key, codingPath: codingPath)
        return try decode(type, from: rawValue)
    }

    func decodeOptional<T: Decodable>(
        _ type: T.Type,
        for key: String,
        codingPath: [any CodingKey]
    ) throws -> T? {
        guard let rawValue = self[key] else { return nil }
        if case .null = rawValue { return nil }
        return try decode(type, from: rawValue)
    }

    func decode<T: Decodable>(_ type: T.Type, from rawValue: JSONValue) throws -> T {
        let data = try JSONEncoder().encode(rawValue)
        return try JSONDecoder().decode(type, from: data)
    }
}
