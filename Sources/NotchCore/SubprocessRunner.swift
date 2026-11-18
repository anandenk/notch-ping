import Foundation
import Darwin

public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var stdoutString: String {
        String(decoding: stdout, as: UTF8.self)
    }

    public var stderrString: String {
        String(decoding: stderr, as: UTF8.self)
    }
}

public enum SubprocessError: Error, LocalizedError, Equatable {
    case launchFailed(String)
    case timedOut(Double)
    case cancelled
}


private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

public enum SubprocessRunner {
    public static func run(
        executableURL: URL, arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 2.0, maxOutputBytes: Int = 2 * 1024 * 1024
    ) async throws -> ProcessResult {
        try Task.checkCancellation()
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = executableURL
                    process.arguments = arguments
                    if let environment { process.environment = environment }
                    let pipes = [Pipe(), Pipe()]
                    process.standardOutput = pipes[0]
                    process.standardError = pipes[1]
                    defer {
                        for pipe in pipes {
                            try? pipe.fileHandleForReading.close()
                            try? pipe.fileHandleForWriting.close()
                        }
                    }
                    do { try process.run() }
                    catch {
                        continuation.resume(throwing: SubprocessError.launchFailed(error.localizedDescription))
                        return
                    }
                    // Parent writers must close so EOF means all child writers closed.
                    for pipe in pipes { try? pipe.fileHandleForWriting.close() }
                    let descriptors = pipes.map { $0.fileHandleForReading.fileDescriptor }
                    for fd in descriptors { _ = fcntl(fd, F_SETFL, O_NONBLOCK) }
                    var output = [Data(), Data()]
                    var eof = [false, false]
                    let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
                    var bytes = [UInt8](repeating: 0, count: 16384)
                    while true {
                        // Cancellation wins over an exit induced by cancellation.
                        let cancelled = cancellation.cancelled
                        if cancelled || ProcessInfo.processInfo.systemUptime >= deadline {
                            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                            continuation.resume(throwing: cancelled ? SubprocessError.cancelled : .timedOut(timeout))
                            return
                        }
                        for index in 0..<2 where !eof[index] {
                            let count = read(descriptors[index], &bytes, bytes.count)
                            if count > 0 {
                                output[index].append(contentsOf: bytes.prefix(min(count, max(0, maxOutputBytes - output[index].count))))
                            } else if count == 0 { eof[index] = true }
                        }
                        if !process.isRunning && eof.allSatisfy({ $0 }) {
                            continuation.resume(returning: ProcessResult(exitCode: process.terminationStatus,
                                stdout: output[0], stderr: output[1]))
                            return
                        }
                        // Poll only while this short-lived operation is outstanding.
                        var fds = descriptors.enumerated().map {
                            pollfd(fd: eof[$0.offset] ? -1 : $0.element, events: Int16(POLLIN), revents: 0)
                        }
                        _ = poll(&fds, 2, 5)
                    }
                }
            }
        } onCancel: { cancellation.cancel() }
    }
}
