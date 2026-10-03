import Foundation
import os

/// Runs a child process to completion off the cooperative pool: writes `stdin`, closes it,
/// collects stdout/stderr fully, and terminates the child on timeout or task cancellation.
enum ProcessRunner {
    struct Output: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: Data
        var timedOut: Bool
    }

    private final class State: Sendable {
        let process: Process
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        init(process: Process) { self.process = process }

        func terminate(timeout: Bool) {
            if timeout { timedOut.withLock { $0 = true } }
            if process.isRunning { process.terminate() }
        }
    }

    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        stdin: Data,
        timeout: TimeInterval
    ) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // A child that exits before reading stdin must surface as EPIPE, not kill us with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let state = State(process: process)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
                let group = DispatchGroup()
                let stdoutData = OSAllocatedUnfairLock(initialState: Data())
                let stderrData = OSAllocatedUnfairLock(initialState: Data())
                group.enter()
                process.terminationHandler = { _ in group.leave() }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                for (pipe, sink) in [(output, stdoutData), (errors, stderrData)] {
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        sink.withLock { $0 = data }
                        group.leave()
                    }
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    // A child that exits without reading stdin raises EPIPE; ignore it.
                    try? input.fileHandleForWriting.write(contentsOf: stdin)
                    try? input.fileHandleForWriting.close()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    state.terminate(timeout: true)
                }
                group.notify(queue: .global()) {
                    continuation.resume(
                        returning: Output(
                            status: process.terminationStatus,
                            stdout: stdoutData.withLock { $0 },
                            stderr: stderrData.withLock { $0 },
                            timedOut: state.timedOut.withLock { $0 }
                        ))
                }
            }
        } onCancel: {
            state.terminate(timeout: false)
        }
    }
}
