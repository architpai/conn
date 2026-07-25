import Foundation

// Optional Level 3 adapter; never required for hook observation.

public enum CorrelatedResponse: Sendable, Equatable {
    case success(JSONRPCSuccessResponse)
    case failure(JSONRPCErrorResponse)

    public var id: RequestID {
        switch self {
        case let .success(response): response.id
        case let .failure(response): response.id
        }
    }
}

public enum RequestCorrelationError: Error, Sendable, Equatable {
    case duplicateRequestID(RequestID)
    case requestIDDoesNotMatchPolicy(RequestID)
    case unknownRequestID(RequestID)
    case responseAlreadyAwaited(RequestID)
}

public enum RequestIDUniquenessPolicy: Sendable, Equatable {
    /// General-purpose behavior retained for callers that use arbitrary IDs.
    case strictHistory
    /// Constant-memory policy for Conn's globally increasing integer IDs.
    case monotonicallyIncreasingIntegers
}

public enum UnmatchedResponseReason: Sendable, Equatable {
    /// No request with this identifier was registered by this store.
    case unknownRequest
    /// The request was already completed or cancelled when this response arrived.
    case lateResponse
    /// A response was already stored for the request and has not yet been consumed.
    case duplicateResponse
}

public struct UnmatchedResponseRecord: Sendable, Equatable {
    public let response: CorrelatedResponse
    public let reason: UnmatchedResponseReason

    public init(response: CorrelatedResponse, reason: UnmatchedResponseReason) {
        self.response = response
        self.reason = reason
    }
}

public enum CorrelationDisposition: Sendable, Equatable {
    case stored(RequestID)
    case resumedWaiter(RequestID)
    case recorded(RequestID, reason: UnmatchedResponseReason)
    case ignoredNonResponse
}

/// Actor-isolated request/response correlation for the JSON-RPC connection.
///
/// Register before writing a request to the transport. This closes the race in
/// which a response arrives before the caller begins awaiting it.
public actor RequestCorrelationStore {
    private enum PendingRequest {
        case registered
        case waiting(CheckedContinuation<CorrelatedResponse, any Error>)
        case resolved(CorrelatedResponse)
    }

    private var pending: [RequestID: PendingRequest] = [:]
    // General-purpose callers retain strict arbitrary-ID history. Production
    // Conn connections use the constant-memory monotonic-integer policy.
    private var issued: Set<RequestID> = []
    private var highestIssuedInteger: Int64?
    private var unmatched: [UnmatchedResponseRecord] = []
    private let historyLimit: Int
    private let uniquenessPolicy: RequestIDUniquenessPolicy

    public init(
        historyLimit: Int = 128,
        uniquenessPolicy: RequestIDUniquenessPolicy = .strictHistory
    ) {
        self.historyLimit = max(1, historyLimit)
        self.uniquenessPolicy = uniquenessPolicy
    }

    public var pendingCount: Int {
        pending.count
    }

    public var unmatchedResponses: [UnmatchedResponseRecord] {
        unmatched
    }

    /// Reserves an identifier before the corresponding request is sent.
    public func register(_ id: RequestID) throws {
        switch uniquenessPolicy {
        case .strictHistory:
            guard issued.insert(id).inserted else {
                throw RequestCorrelationError.duplicateRequestID(id)
            }
        case .monotonicallyIncreasingIntegers:
            guard case let .integer(value) = id else {
                throw RequestCorrelationError.requestIDDoesNotMatchPolicy(id)
            }
            if let highestIssuedInteger, value <= highestIssuedInteger {
                throw RequestCorrelationError.duplicateRequestID(id)
            }
            highestIssuedInteger = value
        }

        pending[id] = .registered
    }

    /// Waits for the response associated with an already registered identifier.
    public func response(for id: RequestID) async throws -> CorrelatedResponse {
        guard let request = pending[id] else {
            throw RequestCorrelationError.unknownRequestID(id)
        }

        switch request {
        case .registered:
            if Task.isCancelled {
                _ = cancel(id)
                throw CancellationError()
            }

            let response = try await withTaskCancellationHandler {
                // Cancellation may race with installing the handler. Check
                // again before creating a continuation so an already-cancelled
                // task cannot leave a waiter behind.
                if Task.isCancelled {
                    _ = cancel(id)
                    throw CancellationError()
                }

                return try await withCheckedThrowingContinuation { continuation in
                    pending[id] = .waiting(continuation)
                }
            } onCancel: {
                // This only cancels local correlation state. Protocol-level
                // cancellation remains an explicit concern of the caller.
                Task {
                    _ = await self.cancel(id)
                }
            }

            if Task.isCancelled {
                record(response, reason: .lateResponse)
                throw CancellationError()
            }
            return response
        case let .resolved(response):
            pending.removeValue(forKey: id)
            if Task.isCancelled {
                record(response, reason: .lateResponse)
                throw CancellationError()
            }
            return response
        case .waiting:
            throw RequestCorrelationError.responseAlreadyAwaited(id)
        }
    }

    /// Correlates success and error responses. Other wire messages are ignored.
    @discardableResult
    public func resolve(_ message: JSONRPCWireMessage) -> CorrelationDisposition {
        let response: CorrelatedResponse
        switch message {
        case let .response(value): response = .success(value)
        case let .error(value): response = .failure(value)
        case .request, .notification, .unknown: return .ignoredNonResponse
        }

        let id = response.id
        guard let request = pending[id] else {
            let wasIssued: Bool
            switch uniquenessPolicy {
            case .strictHistory:
                wasIssued = issued.contains(id)
            case .monotonicallyIncreasingIntegers:
                if case let .integer(value) = id, let highestIssuedInteger {
                    wasIssued = value <= highestIssuedInteger
                } else {
                    wasIssued = false
                }
            }
            let reason: UnmatchedResponseReason = wasIssued ? .lateResponse : .unknownRequest
            record(response, reason: reason)
            return .recorded(id, reason: reason)
        }

        switch request {
        case .registered:
            pending[id] = .resolved(response)
            return .stored(id)
        case let .waiting(continuation):
            pending.removeValue(forKey: id)
            continuation.resume(returning: response)
            return .resumedWaiter(id)
        case .resolved:
            record(response, reason: .duplicateResponse)
            return .recorded(id, reason: .duplicateResponse)
        }
    }

    /// Cancels local waiting only; it does not send a protocol-level cancel.
    @discardableResult
    public func cancel(_ id: RequestID) -> Bool {
        guard let request = pending.removeValue(forKey: id) else { return false }

        if case let .waiting(continuation) = request {
            continuation.resume(throwing: CancellationError())
        }
        return true
    }

    public func clearUnmatchedResponses() {
        unmatched.removeAll(keepingCapacity: true)
    }

    private func record(_ response: CorrelatedResponse, reason: UnmatchedResponseReason) {
        unmatched.append(.init(response: response, reason: reason))
        if unmatched.count > historyLimit {
            unmatched.removeFirst(unmatched.count - historyLimit)
        }
    }

}
