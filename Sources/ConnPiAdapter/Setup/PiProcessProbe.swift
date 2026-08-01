import Darwin
import Foundation

struct PiProcessProbe: Sendable {
    struct Result: Sendable {
        let status: Int32
        let output: Data
    }

    enum ProbeError: Error {
        case launchFailed
        case timedOut
        case outputLimitExceeded
    }

    let outputLimit: Int

    init(outputLimit: Int = 8 * 1_024) {
        self.outputLimit = max(1, outputLimit)
    }

    func run(
        executableURL: URL,
        arguments: [String],
        timeout: Duration
    ) async throws -> Result {
        let execution = PiProbeExecution(
            executableURL: executableURL,
            arguments: arguments,
            outputLimit: outputLimit
        )
        do {
            try execution.launch()
        } catch {
            throw ProbeError.launchFailed
        }
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: PiProbeRace.self) { group in
                group.addTask { .completed(await execution.wait()) }
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
                    guard !completion.exceeded else {
                        throw ProbeError.outputLimitExceeded
                    }
                    return .init(
                        status: completion.status,
                        output: completion.output
                    )
                case .timedOut:
                    execution.cancel()
                    _ = await execution.wait()
                    throw ProbeError.timedOut
                }
            }
        } onCancel: {
            execution.cancel()
        }
    }
}

private enum PiProbeRace: Sendable {
    case completed(PiProbeCompletion)
    case timedOut
}

private struct PiProbeCompletion: Sendable {
    let status: Int32
    let output: Data
    let exceeded: Bool
}

private final class PiProbeExecution: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let outputLimit: Int
    private var output = Data()
    private var exceeded = false
    private var completion: PiProbeCompletion?
    private var waiters: [CheckedContinuation<PiProbeCompletion, Never>] = []

    init(executableURL: URL, arguments: [String], outputLimit: Int) {
        self.outputLimit = outputLimit
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
    }

    func launch() throws {
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] in
            self?.capture($0.availableData)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] in
            self?.capture($0.availableData)
        }
        process.terminationHandler = { [weak self] process in
            self?.finish(status: process.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
    }

    func wait() async -> PiProbeCompletion {
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
        let processID = lock.withLock { () -> pid_t? in
            guard completion == nil, process.isRunning else { return nil }
            process.terminate()
            return process.processIdentifier
        }
        guard let processID else { return }
        Task.detached {
            try? await Task.sleep(for: .milliseconds(250))
            if Darwin.kill(processID, 0) == 0 {
                _ = Darwin.kill(processID, SIGKILL)
            }
        }
    }

    private func capture(_ data: Data) {
        guard !data.isEmpty else { return }
        var cancelProcess = false
        lock.withLock {
            guard completion == nil else { return }
            let remaining = max(0, outputLimit - output.count)
            output.append(data.prefix(remaining))
            if data.count > remaining {
                exceeded = true
                cancelProcess = true
            }
        }
        if cancelProcess { cancel() }
    }

    private func finish(status: Int32) {
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        let result: (
            [CheckedContinuation<PiProbeCompletion, Never>],
            PiProbeCompletion
        ) = lock.withLock {
            if let completion { return ([], completion) }
            let completion = PiProbeCompletion(
                status: status,
                output: output,
                exceeded: exceeded
            )
            self.completion = completion
            let pending = waiters
            waiters.removeAll()
            return (pending, completion)
        }
        result.0.forEach { $0.resume(returning: result.1) }
    }
}
