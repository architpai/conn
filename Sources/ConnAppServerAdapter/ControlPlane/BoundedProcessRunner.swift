import Darwin
import Foundation

/// Child processes receive the caller's user/Codex context but executable
/// lookup is restricted to immutable system locations. In particular, the
/// packaged app does not inherit a useful login-shell PATH, while Codex's
/// documented daemon commands invoke system tools such as `ps`.
public enum ConnChildProcessEnvironment {
    public static let trustedSystemPATH = "/usr/bin:/bin:/usr/sbin:/sbin"

    public static func withTrustedSystemPATH(
        inheriting environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var value = environment
        value["PATH"] = trustedSystemPATH
        return value
    }
}

/// Runs one executable directly, without a shell, and bounds both time and captured output.
public struct BoundedProcessRunner: Sendable {
    public struct Result: Equatable, Sendable {
        public let terminationStatus: Int32
        public let standardOutput: Data
        public let standardError: Data

        public var standardOutputString: String {
            String(decoding: standardOutput, as: UTF8.self)
        }

        public var standardErrorString: String {
            String(decoding: standardError, as: UTF8.self)
        }
    }

    public enum RunnerError: Error, Equatable, Sendable {
        case invalidTimeout
        case launchFailed(String)
        case timedOut
        case outputLimitExceeded
    }

    public let outputLimit: Int
    public let terminationGrace: Duration

    public init(
        outputLimit: Int = 256 * 1_024,
        terminationGrace: Duration = .milliseconds(250)
    ) {
        self.outputLimit = max(1, outputLimit)
        self.terminationGrace = terminationGrace
    }

    public func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: Duration
    ) async throws -> Result {
        guard timeout > .zero else { throw RunnerError.invalidTimeout }
        try Task.checkCancellation()

        let execution = ProcessExecution(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            outputLimit: outputLimit,
            terminationGrace: terminationGrace
        )

        do {
            try execution.launch()
        } catch {
            throw RunnerError.launchFailed(String(describing: error))
        }

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: RaceResult.self) { group in
                group.addTask {
                    .completed(await execution.waitForCompletion())
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return .timedOut
                }

                guard let first = try await group.next() else {
                    execution.cancel()
                    throw CancellationError()
                }
                group.cancelAll()

                switch first {
                case let .completed(completion):
                    if completion.outputLimitExceeded {
                        throw RunnerError.outputLimitExceeded
                    }
                    return Result(
                        terminationStatus: completion.terminationStatus,
                        standardOutput: completion.standardOutput,
                        standardError: completion.standardError
                    )
                case .timedOut:
                    execution.cancel()
                    _ = await execution.waitForCompletion()
                    throw RunnerError.timedOut
                }
            }
        } onCancel: {
            execution.cancel()
        }
    }
}

private extension BoundedProcessRunner {
    enum RaceResult: Sendable {
        case completed(ProcessCompletion)
        case timedOut
    }
}

private struct ProcessCompletion: Sendable {
    let terminationStatus: Int32
    let standardOutput: Data
    let standardError: Data
    let outputLimitExceeded: Bool
}

/// `Process` and `Pipe` are not Sendable. All access to them and their captured
/// bytes is serialized by `lock`; the unchecked conformance is confined here.
private final class ProcessExecution: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let outputLimit: Int
    private let terminationGrace: Duration

    private var standardOutput = Data()
    private var standardError = Data()
    private var outputLimitExceeded = false
    private var completion: ProcessCompletion?
    private var waiters: [CheckedContinuation<ProcessCompletion, Never>] = []
    private var cancellationRequested = false

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?,
        outputLimit: Int,
        terminationGrace: Duration
    ) {
        self.outputLimit = outputLimit
        self.terminationGrace = terminationGrace
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe
    }

    func launch() throws {
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.capture(handle.availableData, fromStandardError: false)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.capture(handle.availableData, fromStandardError: true)
        }
        process.terminationHandler = { [weak self] process in
            self?.finish(terminationStatus: process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        lock.withLock {
            if cancellationRequested {
                terminateLocked()
            }
        }
    }

    func waitForCompletion() async -> ProcessCompletion {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if let completion {
                    continuation.resume(returning: completion)
                } else {
                    waiters.append(continuation)
                }
            }
        }
    }

    func cancel() {
        let shouldEscalate = lock.withLock {
            cancellationRequested = true
            guard completion == nil else { return false }
            terminateLocked()
            return process.isRunning
        }
        guard shouldEscalate else { return }

        let grace = terminationGrace
        Task.detached { [weak self] in
            try? await Task.sleep(for: grace)
            self?.forceTerminateIfNeeded()
        }
    }

    private func capture(_ data: Data, fromStandardError: Bool) {
        guard !data.isEmpty else { return }
        var mustTerminate = false
        lock.withLock {
            guard completion == nil else { return }
            let capturedCount = standardOutput.count + standardError.count
            let remaining = max(0, outputLimit - capturedCount)
            if remaining > 0 {
                if fromStandardError {
                    standardError.append(data.prefix(remaining))
                } else {
                    standardOutput.append(data.prefix(remaining))
                }
            }
            if data.count > remaining {
                outputLimitExceeded = true
                mustTerminate = true
            }
        }
        if mustTerminate { cancel() }
    }

    private func finish(terminationStatus: Int32) {
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil

        // The process has exited, so these reads only drain bytes already in the pipes.
        capture(outputPipe.fileHandleForReading.readDataToEndOfFile(), fromStandardError: false)
        capture(errorPipe.fileHandleForReading.readDataToEndOfFile(), fromStandardError: true)

        let resumed: ([CheckedContinuation<ProcessCompletion, Never>], ProcessCompletion) = lock.withLock {
            if let completion { return ([], completion) }
            let value = ProcessCompletion(
                terminationStatus: terminationStatus,
                standardOutput: standardOutput,
                standardError: standardError,
                outputLimitExceeded: outputLimitExceeded
            )
            completion = value
            let pending = waiters
            waiters.removeAll(keepingCapacity: false)
            return (pending, value)
        }
        for waiter in resumed.0 {
            waiter.resume(returning: resumed.1)
        }
    }

    private func terminateLocked() {
        if process.isRunning {
            process.terminate()
        }
    }

    private func forceTerminateIfNeeded() {
        let processID: pid_t? = lock.withLock {
            guard completion == nil, process.isRunning else { return nil }
            return process.processIdentifier
        }
        if let processID, processID > 0 {
            _ = Darwin.kill(processID, SIGKILL)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
