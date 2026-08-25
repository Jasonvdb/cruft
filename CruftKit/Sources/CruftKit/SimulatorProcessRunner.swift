import Darwin
import Dispatch
import Foundation

struct DirectProcessResult: Sendable, Equatable {
    let status: Int32
    let standardOutput: Data
    let standardError: Data
    let outputWasTruncated: Bool
}

enum DirectProcessError: Error, Sendable, Equatable {
    case timedOut(executable: String, seconds: TimeInterval)
}

protocol DirectProcessRunning: Sendable {
    func run(executable: URL, arguments: [String]) throws -> DirectProcessResult
}

/// Runs one executable directly, drains both output pipes concurrently, and
/// stops the child after a finite deadline. Output beyond the configured cap
/// is drained but not retained, so a noisy child cannot deadlock or exhaust
/// memory.
struct BoundedDirectProcessRunner: DirectProcessRunning {
    static let defaultTimeout: TimeInterval = 5
    static let defaultMaximumOutputBytes = 4 * 1024 * 1024

    let timeout: TimeInterval
    let maximumOutputBytes: Int

    init(
        timeout: TimeInterval = Self.defaultTimeout,
        maximumOutputBytes: Int = Self.defaultMaximumOutputBytes
    ) {
        self.timeout = timeout.isFinite && timeout > 0 ? timeout : Self.defaultTimeout
        self.maximumOutputBytes = max(0, maximumOutputBytes)
    }

    func run(executable: URL, arguments: [String]) throws -> DirectProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let stdoutCapture = PipeCapture(
            handle: stdout.fileHandleForReading, maximumBytes: maximumOutputBytes)
        let stderrCapture = PipeCapture(
            handle: stderr.fileHandleForReading, maximumBytes: maximumOutputBytes)
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutCapture.drain()
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrCapture.drain()
            readers.leave()
        }

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        do {
            try process.run()
        } catch {
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            readers.wait()
            throw error
        }

        guard terminated.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if terminated.wait(timeout: .now() + 0.25) == .timedOut {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            readers.wait()
            throw DirectProcessError.timedOut(
                executable: executable.path(percentEncoded: false), seconds: timeout)
        }

        process.waitUntilExit()
        readers.wait()
        let capturedStdout = stdoutCapture.result()
        let capturedStderr = stderrCapture.result()
        return DirectProcessResult(
            status: process.terminationStatus,
            standardOutput: capturedStdout.data,
            standardError: capturedStderr.data,
            outputWasTruncated: capturedStdout.wasTruncated || capturedStderr.wasTruncated)
    }
}

private final class PipeCapture: @unchecked Sendable {
    private let handle: FileHandle
    private let maximumBytes: Int
    private let lock = NSLock()
    private var data = Data()
    private var wasTruncated = false

    init(handle: FileHandle, maximumBytes: Int) {
        self.handle = handle
        self.maximumBytes = maximumBytes
    }

    func drain() {
        while true {
            let chunk = handle.readData(ofLength: 64 * 1024)
            guard !chunk.isEmpty else { return }
            lock.withLock {
                let remaining = max(0, maximumBytes - data.count)
                data.append(contentsOf: chunk.prefix(remaining))
                wasTruncated = wasTruncated || chunk.count > remaining
            }
        }
    }

    func result() -> (data: Data, wasTruncated: Bool) {
        lock.withLock { (data, wasTruncated) }
    }
}
