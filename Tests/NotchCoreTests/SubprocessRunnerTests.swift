import Foundation
import Testing
@testable import NotchCore

@Suite("SubprocessRunnerTests")
struct SubprocessRunnerTests {
    @Test func largeOutputDoesNotDeadlock() async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return }

        let result = try await SubprocessRunner.run(
            executableURL: python,
            arguments: ["-c", "import sys; sys.stdout.write('A' * 1_048_576)"],
            timeout: 5.0
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout.count == 1_048_576)
    }

    @Test func hangingProcessTimesOut() async throws {
        let sleepBin = URL(fileURLWithPath: "/bin/sleep")
        guard FileManager.default.isExecutableFile(atPath: sleepBin.path) else { return }

        let start = Date()
        await #expect(throws: SubprocessError.self) {
            _ = try await SubprocessRunner.run(
                executableURL: sleepBin,
                arguments: ["10"],
                timeout: 0.3
            )
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 2.0)
    }

    @Test func nonZeroExitReported() async throws {
        let sh = URL(fileURLWithPath: "/bin/sh")
        let result = try await SubprocessRunner.run(
            executableURL: sh,
            arguments: ["-c", "exit 42"],
            timeout: 2.0
        )
        #expect(result.exitCode == 42)
    }

    @Test func launchFailureReported() async throws {
        let invalidURL = URL(fileURLWithPath: "/nonexistent/binary/path")
        await #expect(throws: SubprocessError.self) {
            _ = try await SubprocessRunner.run(
                executableURL: invalidURL,
                arguments: [],
                timeout: 1.0
            )
        }
    }

    @Test func taskCancellationTerminatesProcess() async throws {
        let sleepBin = URL(fileURLWithPath: "/bin/sleep")
        guard FileManager.default.isExecutableFile(atPath: sleepBin.path) else { return }

        let task = Task {
            try await SubprocessRunner.run(
                executableURL: sleepBin,
                arguments: ["10"],
                timeout: 5.0
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let start = Date()
        switch await task.result {
        case .success: Issue.record("Cancelled process returned success")
        case .failure(let error): #expect(error as? SubprocessError == .cancelled)
        }
        #expect(Date().timeIntervalSince(start) < 0.5)
    }
    @Test func descendantHeldPipeHonorsDeadline() async throws {
        let start = Date()
        do {
            _ = try await SubprocessRunner.run(executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 0.6 & exit 0"], timeout: 0.15)
            Issue.record("Descendant-held pipe returned success")
        } catch { #expect(error as? SubprocessError == .timedOut(0.15)) }
        #expect(Date().timeIntervalSince(start) < 0.5)
        // Allow the intentionally short-lived descendant to exit before the test finishes.
        try await Task.sleep(for: .milliseconds(650))
    }

    @Test func bothStreamsAreDrainedWithBoundedCapture() async throws {
        let result = try await SubprocessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", "import sys; sys.stdout.write('a'*1048576); sys.stderr.write('b'*1048576)"],
            timeout: 5, maxOutputBytes: 1024)
        #expect(result.exitCode == 0)
        #expect(result.stdout.count == 1024)
        #expect(result.stderr.count == 1024)
    }

}
