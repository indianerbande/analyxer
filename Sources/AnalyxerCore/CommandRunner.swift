import Foundation
import Darwin

public struct Command: Sendable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let timeout: TimeInterval
    public let outputLimit: Int
    public let workingDirectory: URL?
    /// Written to standard input, which is then closed; `nil` means no input at all.
    public let input: Data?
    public init(executable: URL, arguments: [String], timeout: TimeInterval = 30, outputLimit: Int = 4 * 1024 * 1024, environment: [String: String] = [:],
                workingDirectory: URL? = nil, input: Data? = nil) {
        self.executable = executable; self.arguments = arguments
        self.timeout = timeout; self.outputLimit = outputLimit; self.environment = environment
        self.workingDirectory = workingDirectory; self.input = input
    }
}

public struct CommandResult: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let status: Int32
    public let truncated: Bool
    public var text: String { String(decoding: stdout, as: UTF8.self) }
    public init(stdout: Data = Data(), stderr: Data = Data(), status: Int32 = 0, truncated: Bool = false) {
        self.stdout = stdout; self.stderr = stderr; self.status = status; self.truncated = truncated
    }
}

public protocol CommandRunning: Sendable {
    func run(_ command: Command) async throws -> CommandResult
    func launch(_ command: Command) async throws
}

/// Runs argument arrays directly, never via a shell. Both pipes are drained throughout
/// execution, even after the output cap is reached, so verbose tools cannot deadlock.
public struct ProcessCommandRunner: CommandRunning {
    public init() {}
    public func run(_ command: Command) async throws -> CommandResult {
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try Self.execute(command, cancellation: cancellation)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { cancellation.cancel() })
    }

    public func launch(_ command: Command) async throws {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, value in value }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let identifier = UUID()
        process.terminationHandler = { _ in LaunchedProcesses.shared.remove(identifier) }
        LaunchedProcesses.shared.add(process, identifier: identifier)
        do { try process.run() }
        catch { LaunchedProcesses.shared.remove(identifier); throw error }
        // A brief startup check catches immediate SDK/configuration failures.
        try? await Task.sleep(nanoseconds: 350_000_000)
        if !process.isRunning && process.terminationStatus != 0 {
            throw AnalyxerError.failed(String(localized: "The emulator could not start (status \(Int(process.terminationStatus))). Check the AVD configuration and system image."))
        }
    }

    private static func execute(_ command: Command, cancellation: CancellationFlag) throws -> CommandResult {
        if cancellation.isCancelled { throw AnalyxerError.cancelled }
        let process = Process()
        let output = Pipe(), errors = Pipe()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, value in value }
        process.currentDirectoryURL = command.workingDirectory
        let input = command.input.map { _ in Pipe() }
        process.standardInput = input ?? FileHandle.nullDevice
        process.standardOutput = output; process.standardError = errors
        try process.run()
        output.fileHandleForWriting.closeFile(); errors.fileHandleForWriting.closeFile()
        if let input, let data = command.input {
            // Small answers only (e.g. licence confirmations); a closed reader must not raise SIGPIPE.
            signal(SIGPIPE, SIG_IGN)
            try? input.fileHandleForWriting.write(contentsOf: data)
            try? input.fileHandleForWriting.close()
        }
        let handles = [output.fileHandleForReading, errors.fileHandleForReading]
        for handle in handles { _ = fcntl(handle.fileDescriptor, F_SETFL, O_NONBLOCK) }
        defer { handles.forEach { $0.closeFile() } }
        var buffers = [Data(), Data()]
        var ended = [false, false]
        var truncated = false
        let limit = max(0, command.outputLimit)
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.01, command.timeout)
        var stoppedAt: TimeInterval?
        var exitSeenAt: TimeInterval?
        var terminationError: AnalyxerError?
        var bytes = [UInt8](repeating: 0, count: 65536)
        while true {
            // A bounded number of reads per stream prevents an endless writer from
            // starving the other stream, timeout checks, or cancellation checks.
            for index in 0..<2 where !ended[index] {
                for _ in 0..<16 {
                    let count = Darwin.read(handles[index].fileDescriptor, &bytes, bytes.count)
                    if count > 0 {
                        let remaining = max(0, limit - buffers[index].count)
                        buffers[index].append(contentsOf: bytes.prefix(min(count, remaining)))
                        if count > remaining { truncated = true }
                    } else {
                        if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) { ended[index] = true }
                        break
                    }
                }
            }
            let now = ProcessInfo.processInfo.systemUptime
            if process.isRunning {
                if stoppedAt == nil && (now >= deadline || cancellation.isCancelled) {
                    terminationError = cancellation.isCancelled ? .cancelled : .timedOut
                    stoppedAt = now
                    process.terminate()
                } else if let stop = stoppedAt, now - stop > 0.3 {
                    // Signal only the process created here, never adb servers/devices.
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                }
            } else {
                if exitSeenAt == nil { exitSeenAt = now }
                // Descendants may inherit a pipe. Do not wait indefinitely for them.
                if ended.allSatisfy({ $0 }) || now - (exitSeenAt ?? now) > 0.3 { break }
            }
            usleep(10_000)
        }
        if let error = terminationError { throw error }
        return CommandResult(stdout: buffers[0], stderr: buffers[1], status: process.terminationStatus, truncated: truncated)
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

private final class LaunchedProcesses: @unchecked Sendable {
    static let shared = LaunchedProcesses()
    private let lock = NSLock()
    private var processes: [UUID: Process] = [:]
    func add(_ process: Process, identifier: UUID) {
        lock.lock(); defer { lock.unlock() }
        processes[identifier] = process
    }
    func remove(_ identifier: UUID) {
        lock.lock(); defer { lock.unlock() }
        processes.removeValue(forKey: identifier)
    }
}
