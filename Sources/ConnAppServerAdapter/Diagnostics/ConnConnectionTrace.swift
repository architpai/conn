import Foundation

public enum ConnTraceDirection: String, Codable, Sendable {
    case outbound
    case inbound
    case local
}

public enum ConnTraceEnvelope: String, Codable, Sendable {
    case request
    case response
    case error
    case notification
    case unknown
    case transport
    case dropped
}

/// Sanitized metadata only. Parameters, results, content, request identifiers,
/// and error text are structurally absent from this type.
public struct ConnConnectionTraceEntry: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let generation: UInt64
    public let direction: ConnTraceDirection
    public let envelope: ConnTraceEnvelope
    public let method: String?
    public let correlation: UInt64?
    public let errorCode: Int64?

    public init(
        sequence: UInt64,
        generation: UInt64,
        direction: ConnTraceDirection,
        envelope: ConnTraceEnvelope,
        method: String? = nil,
        correlation: UInt64? = nil,
        errorCode: Int64? = nil
    ) {
        self.sequence = sequence
        self.generation = generation
        self.direction = direction
        self.envelope = envelope
        self.method = method
        self.correlation = correlation
        self.errorCode = errorCode
    }
}

struct ConnConnectionTraceBuffer: Sendable {
    private(set) var entries: [ConnConnectionTraceEntry] = []
    private var sequence: UInt64 = 0
    private var nextCorrelation: UInt64 = 0
    private var correlations: [RequestID: UInt64] = [:]
    private var correlationOrder: [RequestID] = []
    private var requestMethods: [RequestID: String] = [:]
    private let limit: Int

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    mutating func record(
        _ message: JSONRPCWireMessage,
        generation: UInt64,
        direction: ConnTraceDirection
    ) {
        switch message {
        case let .request(request):
            requestMethods[request.id] = Self.safeMethod(request.method)
            append(
                generation: generation,
                direction: direction,
                envelope: .request,
                method: request.method,
                requestID: request.id
            )
        case let .response(response):
            append(
                generation: generation,
                direction: direction,
                envelope: .response,
                method: requestMethods[response.id],
                requestID: response.id
            )
        case let .error(response):
            append(
                generation: generation,
                direction: direction,
                envelope: .error,
                method: requestMethods[response.id],
                requestID: response.id,
                errorCode: response.error.code
            )
        case let .notification(notification):
            append(
                generation: generation,
                direction: direction,
                envelope: .notification,
                method: notification.method
            )
        case .unknown:
            append(generation: generation, direction: direction, envelope: .unknown)
        }
    }

    mutating func recordLocal(
        generation: UInt64,
        envelope: ConnTraceEnvelope,
        method: String? = nil
    ) {
        append(
            generation: generation,
            direction: .local,
            envelope: envelope,
            method: method
        )
    }

    private mutating func append(
        generation: UInt64,
        direction: ConnTraceDirection,
        envelope: ConnTraceEnvelope,
        method: String? = nil,
        requestID: RequestID? = nil,
        errorCode: Int64? = nil
    ) {
        sequence &+= 1
        entries.append(.init(
            sequence: sequence,
            generation: generation,
            direction: direction,
            envelope: envelope,
            method: method.flatMap(Self.safeMethod),
            correlation: requestID.map { correlation(for: $0) },
            errorCode: errorCode
        ))
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
    }

    private mutating func correlation(for requestID: RequestID) -> UInt64 {
        if let value = correlations[requestID] { return value }
        nextCorrelation &+= 1
        correlations[requestID] = nextCorrelation
        correlationOrder.append(requestID)
        if correlationOrder.count > limit {
            let evicted = correlationOrder.removeFirst()
            correlations.removeValue(forKey: evicted)
            requestMethods.removeValue(forKey: evicted)
        }
        return nextCorrelation
    }

    private static func safeMethod(_ value: String) -> String? {
        recognizedMethods.contains(value) ? value : nil
    }

    /// Closed metadata allowlist. Unknown method strings may contain arbitrary
    /// peer-controlled text, so their envelopes are traced without the label.
    private static let recognizedMethods: Set<String> = [
        "connected", "disconnected", "initialize", "initialized",
        "thread/list", "thread/read", "thread/resume", "thread/unsubscribe",
        "thread/loaded/list",
        "thread/started", "thread/status/changed", "thread/closed",
        "thread/archived", "thread/unarchived", "thread/deleted",
        "turn/started",
        "turn/completed", "turn/plan/updated", "turn/diff/updated",
        "item/started", "item/completed", "item/agentMessage/delta",
        "item/plan/delta", "item/reasoning/summaryPartAdded",
        "item/reasoning/summaryTextDelta", "item/reasoning/textDelta",
        "item/commandExecution/outputDelta", "item/fileChange/outputDelta",
        "item/fileChange/patchUpdated", "serverRequest/resolved",
        "hook/started", "hook/completed",
        "item/commandExecution/requestApproval", "item/fileChange/requestApproval",
        "item/tool/requestUserInput", "account/rateLimits/read", "account/read",
        "account/usage/read", "app/list", "config/read", "hooks/list",
        "model/list", "plugin/list", "plugin/uninstall",
        "collaborationMode/list", "thread/search",
    ]
}
