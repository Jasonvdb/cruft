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

/// Runs one executable directly in an isolated process group. Both output
/// pipes are drained without blocking and retained only up to the configured
/// cap. A timeout signals the full group, so a helper process cannot outlive
/// the command or keep an inherited output pipe open forever.
struct BoundedDirectProcessRunner: DirectProcessRunning {
    static let defaultTimeout: TimeInterval = 5
    static let defaultMaximumOutputBytes = 4 * 1024 * 1024

    private static let terminationGrace: TimeInterval = 0.25
    private static let killGrace: TimeInterval = 0.25
    private static let pollMicroseconds: useconds_t = 2_000

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
        var stdoutPipe = try PipeDescriptors()
        defer { stdoutPipe.closeAll() }
        var stderrPipe = try PipeDescriptors()
        defer { stderrPipe.closeAll() }
        try stdoutPipe.makeReadEndNonblocking()
        try stderrPipe.makeReadEndNonblocking()

        let nullInput = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard nullInput >= 0 else { throw Self.currentPOSIXError() }
        defer { Darwin.close(nullInput) }

        var actions: posix_spawn_file_actions_t?
        try Self.check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try Self.check(posix_spawn_file_actions_adddup2(&actions, nullInput, STDIN_FILENO))
        try Self.check(posix_spawn_file_actions_adddup2(
            &actions, stdoutPipe.writeDescriptor, STDOUT_FILENO))
        try Self.check(posix_spawn_file_actions_adddup2(
            &actions, stderrPipe.writeDescriptor, STDERR_FILENO))
        for descriptor in [
            stdoutPipe.readDescriptor, stdoutPipe.writeDescriptor,
            stderrPipe.readDescriptor, stderrPipe.writeDescriptor, nullInput,
        ] where descriptor > STDERR_FILENO {
            try Self.check(posix_spawn_file_actions_addclose(&actions, descriptor))
        }

        var attributes: posix_spawnattr_t?
        try Self.check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = Int16(POSIX_SPAWN_SETPGROUP)
        try Self.check(posix_spawnattr_setflags(&attributes, flags))
        // A pgroup of zero makes the spawned PID the new process-group ID.
        try Self.check(posix_spawnattr_setpgroup(&attributes, 0))

        var processID: pid_t = 0
        let executablePath = executable.path(percentEncoded: false)
        let spawnStatus = Self.withMutableCStringArray(
            [executablePath] + arguments
        ) { argv in
            executablePath.withCString { path in
                posix_spawn(
                    &processID,
                    path,
                    &actions,
                    &attributes,
                    argv,
                    environ)
            }
        }
        try Self.check(spawnStatus)

        // The child owns the write ends now. Closing the parent's copies makes
        // EOF reflect only processes in the isolated child group.
        stdoutPipe.closeWriteEnd()
        stderrPipe.closeWriteEnd()

        var stdoutCapture = OutputCapture(maximumBytes: maximumOutputBytes)
        var stderrCapture = OutputCapture(maximumBytes: maximumOutputBytes)
        var waitStatus: Int32 = 0
        var directChildExited = false
        let deadline = Self.deadline(after: timeout)

        while true {
            stdoutCapture.drain(from: stdoutPipe.readDescriptor)
            stderrCapture.drain(from: stderrPipe.readDescriptor)
            Self.reap(processID, status: &waitStatus, exited: &directChildExited)

            if directChildExited && !Self.processGroupExists(processID) {
                // No writers remain. One last drain collects bytes that were
                // already buffered when the final process exited.
                stdoutCapture.drain(from: stdoutPipe.readDescriptor)
                stderrCapture.drain(from: stderrPipe.readDescriptor)
                return DirectProcessResult(
                    status: Self.terminationStatus(waitStatus),
                    standardOutput: stdoutCapture.data,
                    standardError: stderrCapture.data,
                    outputWasTruncated:
                        stdoutCapture.wasTruncated || stderrCapture.wasTruncated)
            }

            if DispatchTime.now().uptimeNanoseconds >= deadline {
                break
            }
            Darwin.usleep(Self.pollMicroseconds)
        }

        // First ask the full group to stop. If any member remains after the
        // grace period, SIGKILL the full group. Every wait below has a finite
        // deadline and pipe reads are nonblocking.
        _ = Darwin.kill(-processID, SIGTERM)
        Self.waitForExit(
            processID: processID,
            deadline: Self.deadline(after: Self.terminationGrace),
            waitStatus: &waitStatus,
            directChildExited: &directChildExited,
            stdoutDescriptor: stdoutPipe.readDescriptor,
            stderrDescriptor: stderrPipe.readDescriptor,
            stdoutCapture: &stdoutCapture,
            stderrCapture: &stderrCapture)

        if !directChildExited || Self.processGroupExists(processID) {
            _ = Darwin.kill(-processID, SIGKILL)
            Self.waitForExit(
                processID: processID,
                deadline: Self.deadline(after: Self.killGrace),
                waitStatus: &waitStatus,
                directChildExited: &directChildExited,
                stdoutDescriptor: stdoutPipe.readDescriptor,
                stderrDescriptor: stderrPipe.readDescriptor,
                stdoutCapture: &stdoutCapture,
                stderrCapture: &stderrCapture)
        }

        // SIGKILL is pending for any process that could not be reaped during
        // the finite grace period. Closing our read ends cannot block.
        throw DirectProcessError.timedOut(executable: executablePath, seconds: timeout)
    }

    private static func waitForExit(
        processID: pid_t,
        deadline: UInt64,
        waitStatus: inout Int32,
        directChildExited: inout Bool,
        stdoutDescriptor: Int32,
        stderrDescriptor: Int32,
        stdoutCapture: inout OutputCapture,
        stderrCapture: inout OutputCapture
    ) {
        repeat {
            stdoutCapture.drain(from: stdoutDescriptor)
            stderrCapture.drain(from: stderrDescriptor)
            reap(processID, status: &waitStatus, exited: &directChildExited)
            if directChildExited && !processGroupExists(processID) { return }
            Darwin.usleep(pollMicroseconds)
        } while DispatchTime.now().uptimeNanoseconds < deadline

        stdoutCapture.drain(from: stdoutDescriptor)
        stderrCapture.drain(from: stderrDescriptor)
        reap(processID, status: &waitStatus, exited: &directChildExited)
    }

    private static func reap(
        _ processID: pid_t, status: inout Int32, exited: inout Bool
    ) {
        guard !exited else { return }
        while true {
            let result = Darwin.waitpid(processID, &status, WNOHANG)
            if result == processID {
                exited = true
                return
            }
            if result == 0 { return }
            if errno == EINTR { continue }
            if errno == ECHILD { exited = true }
            return
        }
    }

    private static func processGroupExists(_ processGroupID: pid_t) -> Bool {
        if Darwin.kill(-processGroupID, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func terminationStatus(_ waitStatus: Int32) -> Int32 {
        let signal = waitStatus & 0x7f
        if signal == 0 { return (waitStatus >> 8) & 0xff }
        return 128 + signal
    }

    private static func deadline(after interval: TimeInterval) -> UInt64 {
        let nanoseconds = UInt64(interval * 1_000_000_000)
        return DispatchTime.now().uptimeNanoseconds &+ nanoseconds
    }

    private static func check(_ status: Int32) throws {
        guard status != 0 else { return }
        guard let code = POSIXErrorCode(rawValue: status) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(status))
        }
        throw POSIXError(code)
    }

    private static func currentPOSIXError() -> any Error {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func withMutableCStringArray<Result>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) rethrows -> Result {
        let storage = strings.map { string in
            string.withCString { strdup($0) }
        }
        defer { storage.forEach { free($0) } }
        var pointers = storage + [nil]
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }
}

private struct PipeDescriptors {
    private(set) var readDescriptor: Int32
    private(set) var writeDescriptor: Int32

    init() throws {
        var descriptors: [Int32] = [-1, -1]
        guard Darwin.pipe(&descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        readDescriptor = descriptors[0]
        writeDescriptor = descriptors[1]
        _ = Darwin.fcntl(readDescriptor, F_SETFD, FD_CLOEXEC)
        _ = Darwin.fcntl(writeDescriptor, F_SETFD, FD_CLOEXEC)
    }

    mutating func makeReadEndNonblocking() throws {
        let flags = Darwin.fcntl(readDescriptor, F_GETFL)
        guard flags >= 0,
            Darwin.fcntl(readDescriptor, F_SETFL, flags | O_NONBLOCK) == 0
        else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    mutating func closeWriteEnd() {
        guard writeDescriptor >= 0 else { return }
        Darwin.close(writeDescriptor)
        writeDescriptor = -1
    }

    mutating func closeAll() {
        if readDescriptor >= 0 { Darwin.close(readDescriptor) }
        if writeDescriptor >= 0 { Darwin.close(writeDescriptor) }
        readDescriptor = -1
        writeDescriptor = -1
    }
}

private struct OutputCapture {
    let maximumBytes: Int
    private(set) var data = Data()
    private(set) var wasTruncated = false

    mutating func drain(from descriptor: Int32) {
        guard descriptor >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                let retainedCount = min(count, max(0, maximumBytes - data.count))
                if retainedCount > 0 {
                    data.append(contentsOf: buffer.prefix(retainedCount))
                }
                if count > retainedCount { wasTruncated = true }
                continue
            }
            if count == 0 { return }
            if errno == EINTR { continue }
            return
        }
    }
}
