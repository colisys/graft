import Foundation
import Darwin

/// Result of a finished external command.
public struct ProcessResult: Sendable {
    public let executable: String
    public let arguments: [String]
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let duration: TimeInterval

    public init(
        executable: String,
        arguments: [String],
        exitCode: Int32,
        stdout: String,
        stderr: String,
        duration: TimeInterval
    ) {
        self.executable = executable
        self.arguments = arguments
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.duration = duration
    }

    public var succeeded: Bool { exitCode == 0 }

    public var combinedOutput: String {
        var parts: [String] = []
        let trimmedOut = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedErr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOut.isEmpty { parts.append(trimmedOut) }
        if !trimmedErr.isEmpty { parts.append(trimmedErr) }
        return parts.joined(separator: "\n")
    }
}

public enum ProcessRunnerError: Error, LocalizedError, Sendable {
    case launchFailed(executable: String, message: String)
    case timedOut(result: ProcessResult)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let executable, let message):
            return "无法启动进程 \(executable): \(message)"
        case .timedOut(let result):
            let tail = result.combinedOutput.suffix(800)
            return "命令执行超时: \(result.executable) \(result.arguments.joined(separator: " "))\n\(tail)"
        }
    }
}

/// Options shared by all process invocations.
public struct RunOptions: Sendable {
    /// Extra environment variables merged into the inherited environment.
    public var environment: [String: String]?
    public var currentDirectory: URL?
    /// If set, the process is terminated (SIGTERM, then SIGKILL) after this
    /// many seconds and `ProcessRunnerError.timedOut` is thrown.
    public var timeout: TimeInterval?
    /// Data written to the process' standard input.
    public var standardInput: String?

    public init(
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: TimeInterval? = nil,
        standardInput: String? = nil
    ) {
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.timeout = timeout
        self.standardInput = standardInput
    }
}

/// Asynchronous wrapper around `Foundation.Process`.
///
/// Graft is a process scheduler: every external dependency (Colima, Docker
/// CLI, XQuartz utilities, `sips`, `iconutil`, `curl`) is invoked through this
/// runner. stdout and stderr are captured in full *and* streamed line by line
/// so the UI can show live build / installation logs.
public final class ProcessRunner: @unchecked Sendable {
    public static let shared = ProcessRunner()

    private final class LineBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = Data()
        private var complete = Data()

        func append(_ data: Data, emit: (@Sendable (String) -> Void)?) {
            guard !data.isEmpty else { return }
            lock.lock()
            complete.append(data)
            pending.append(data)
            var lines: [String] = []
            // Treat carriage returns as line breaks too: curl's progress bar
            // and several package managers update in place with `\r`.
            while let delimiterIndex = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let lineData = pending[pending.startIndex..<delimiterIndex]
                let delimiter = pending[delimiterIndex]
                pending.removeSubrange(pending.startIndex...delimiterIndex)
                if delimiter == 0x0D, pending.first == 0x0A {
                    pending.removeFirst()
                }
                lines.append(String(decoding: lineData, as: UTF8.self))
            }
            lock.unlock()
            for line in lines { emit?(line) }
        }

        func finish(emit: (@Sendable (String) -> Void)?) {
            lock.lock()
            let tail = pending
            pending.removeAll()
            lock.unlock()
            if !tail.isEmpty {
                emit?(String(decoding: tail, as: UTF8.self))
            }
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: complete, as: UTF8.self)
        }
    }

    private final class CompletionState: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        private var timedOut = false

        func markTimedOut() {
            lock.lock()
            timedOut = true
            lock.unlock()
        }

        var didTimeOut: Bool {
            lock.lock()
            defer { lock.unlock() }
            return timedOut
        }

        /// Returns true exactly once.
        func claimResume() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if resumed { return false }
            resumed = true
            return true
        }
    }

    public init() {}

    @discardableResult
    public func run(
        _ executable: String,
        _ arguments: [String] = [],
        options: RunOptions = RunOptions(),
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let startedAt = Date()
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutBuffer = LineBuffer()
        let stderrBuffer = LineBuffer()
        let completion = CompletionState()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        if let extraEnvironment = options.environment {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in extraEnvironment {
                merged[key] = value
            }
            process.environment = merged
        }
        if let directory = options.currentDirectory {
            process.currentDirectoryURL = directory
        }

        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var stdinPipe: Pipe?
        if options.standardInput != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stdoutBuffer.append(data, emit: onLine)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stderrBuffer.append(data, emit: onLine)
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
            process.terminationHandler = { finished in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                let remainingOut = stdoutPipe.fileHandleForReading.availableData
                if !remainingOut.isEmpty {
                    stdoutBuffer.append(remainingOut, emit: onLine)
                }
                let remainingErr = stderrPipe.fileHandleForReading.availableData
                if !remainingErr.isEmpty {
                    stderrBuffer.append(remainingErr, emit: onLine)
                }
                stdoutBuffer.finish(emit: onLine)
                stderrBuffer.finish(emit: onLine)

                let result = ProcessResult(
                    executable: executable,
                    arguments: arguments,
                    exitCode: finished.terminationStatus,
                    stdout: stdoutBuffer.text,
                    stderr: stderrBuffer.text,
                    duration: Date().timeIntervalSince(startedAt)
                )

                guard completion.claimResume() else { return }
                if completion.didTimeOut {
                    continuation.resume(throwing: ProcessRunnerError.timedOut(result: result))
                } else {
                    continuation.resume(returning: result)
                }
            }

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                guard completion.claimResume() else { return }
                let result = ProcessResult(
                    executable: executable,
                    arguments: arguments,
                    exitCode: -1,
                    stdout: "",
                    stderr: error.localizedDescription,
                    duration: Date().timeIntervalSince(startedAt)
                )
                continuation.resume(
                    throwing: ProcessRunnerError.launchFailed(
                        executable: executable,
                        message: "\(error.localizedDescription) [exit \(result.exitCode)]"
                    )
                )
                return
            }

            if let timeout = options.timeout, timeout > 0 {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak process] in
                    guard let process, process.isRunning else { return }
                    completion.markTimedOut()
                    process.terminate()
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak process] in
                        guard let process, process.isRunning else { return }
                        _ = kill(process.processIdentifier, SIGKILL)
                    }
                }
            }

            if let input = options.standardInput, let pipe = stdinPipe {
                DispatchQueue.global(qos: .utility).async {
                    pipe.fileHandleForWriting.write(Data(input.utf8))
                    try? pipe.fileHandleForWriting.close()
                }
            }
        }
    }

    /// Convenience wrapper for shell snippets (`bash -lc`).
    @discardableResult
    public func runShell(
        _ command: String,
        options: RunOptions = RunOptions(),
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        try await run("/bin/bash", ["-lc", command], options: options, onLine: onLine)
    }
}
