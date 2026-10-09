import Foundation
import Darwin

struct LlamaProcessResult {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

protocol LlamaProcessExecutor {
    func run(executableURL: URL, arguments: [String], stdinData: Data?) async throws -> LlamaProcessResult
}

enum LlamaCppRuntimeError: LocalizedError, Equatable {
    case executableNotConfigured
    case executableMissing(URL)
    case executableNotExecutable(URL)
    case runtimeLaunchFailed(String)
    case modelLoadFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .executableNotConfigured: return "Configure the llama-cli executable in Models settings before generating a summary."
        case let .executableMissing(url): return "Configured llama-cli executable is missing at: \(url.path)"
        case let .executableNotExecutable(url): return "Configured llama-cli path is not an executable file: \(url.path)"
        case let .runtimeLaunchFailed(message): return "Summarization runtime launch failed: \(message)"
        case let .modelLoadFailed(message): return "Summarization model load failed: \(message)"
        case .timedOut: return "Summarization runtime timed out."
        }
    }
}

/// Owns the process between cancellation before launch and cancellation while running.
private final class LlamaProcessControl: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    private var timedOut = false
    private var ownedProcessGroup: pid_t?

    func launch() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try process.run()
        let pid = process.processIdentifier
        // Foundation normally starts its child in a new group. Never signal the
        // application's group when an alternate launcher does not provide that.
        if getpgid(pid) == pid { ownedProcessGroup = pid }
    }

    func stop(timeout: Bool) {
        lock.lock()
        if timeout { timedOut = true } else { cancelled = true }
        if let group = ownedProcessGroup { kill(-group, SIGTERM) }
        else if process.isRunning { process.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) { [self] in
            lock.lock()
            defer { lock.unlock() }
            if let group = ownedProcessGroup { kill(-group, SIGKILL) }
            else if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        lock.unlock()
    }

    func terminateRemainingGroupMembers() {
        lock.lock()
        defer { lock.unlock() }
        if let group = ownedProcessGroup { kill(-group, SIGKILL) }
        ownedProcessGroup = nil
    }

    func checkCompletion() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        if timedOut { throw LlamaCppRuntimeError.timedOut }
    }
}

/// Nonblocking readers let teardown finish even if a wrapper's descendants
/// inherit its output pipes. Waiting for EOF would turn a finite timeout into
/// an unbounded wait after the direct child has already terminated.
private final class LlamaProcessOutput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "recordly.llama.output")
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private var stdout = Data()
    private var stderr = Data()
    private var finished = false
    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?

    init(stdout: FileHandle, stderr: FileHandle) {
        stdoutHandle = stdout
        stderrHandle = stderr
        for handle in [stdout, stderr] {
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            _ = fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK)
        }
        let outSource = DispatchSource.makeReadSource(fileDescriptor: stdout.fileDescriptor, queue: queue)
        let errSource = DispatchSource.makeReadSource(fileDescriptor: stderr.fileDescriptor, queue: queue)
        stdoutSource = outSource
        stderrSource = errSource
        outSource.setEventHandler { [weak self] in self?.drain(stdout: true) }
        errSource.setEventHandler { [weak self] in self?.drain(stdout: false) }
        outSource.resume()
        errSource.resume()
    }

    private func drain(stdout isStdout: Bool) {
        guard !finished else { return }
        let fd = isStdout ? stdoutHandle.fileDescriptor : stderrHandle.fileDescriptor
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        // Bound each handler/drain turn even if a descendant continuously writes.
        for _ in 0..<64 {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if count > 0 {
                if isStdout { stdout.append(contentsOf: bytes.prefix(count)) }
                else { stderr.append(contentsOf: bytes.prefix(count)) }
            } else if count < 0 && errno == EINTR { continue }
            else { break }
        }
    }

    func finish() -> (stdout: Data, stderr: Data) {
        queue.sync {
            drain(stdout: true)
            drain(stdout: false)
            finished = true
            stdoutSource?.cancel()
            stderrSource?.cancel()
            try? stdoutHandle.close()
            try? stderrHandle.close()
            return (stdout, stderr)
        }
    }
}

struct FoundationLlamaProcessExecutor: LlamaProcessExecutor {
    private let processTimeoutSeconds: TimeInterval

    init(processTimeoutSeconds: TimeInterval = 180) {
        self.processTimeoutSeconds = max(processTimeoutSeconds, 0.1)
    }

    func run(executableURL: URL, arguments: [String], stdinData: Data? = nil) async throws -> LlamaProcessResult {
        let control = LlamaProcessControl()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = control.process
                    process.executableURL = executableURL
                    process.arguments = arguments
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    let stdinPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe
                    // Never inherit the app's stdin. Empty input means immediate EOF.
                    process.standardInput = stdinPipe
                    do {
                        try control.launch()
                    } catch {
                        if error is CancellationError { continuation.resume(throwing: error) }
                        else { continuation.resume(throwing: LlamaCppRuntimeError.runtimeLaunchFailed(error.localizedDescription)) }
                        return
                    }
                    let output = LlamaProcessOutput(stdout: stdoutPipe.fileHandleForReading, stderr: stderrPipe.fileHandleForReading)
                    let timeoutTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
                    timeoutTimer.schedule(deadline: .now() + processTimeoutSeconds)
                    timeoutTimer.setEventHandler { control.stop(timeout: true) }
                    timeoutTimer.resume()
                    if let stdinData, !stdinData.isEmpty { stdinPipe.fileHandleForWriting.write(stdinData) }
                    try? stdinPipe.fileHandleForWriting.close()
                    process.waitUntilExit()
                    timeoutTimer.cancel()
                    control.terminateRemainingGroupMembers()
                    let captured = output.finish()
                    do {
                        try control.checkCompletion()
                        let result = LlamaProcessResult(exitCode: process.terminationStatus,
                            stdout: String(data: captured.stdout, encoding: .utf8) ?? "",
                            stderr: String(data: captured.stderr, encoding: .utf8) ?? "")
                        continuation.resume(returning: result)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { control.stop(timeout: false) })
    }
}

protocol LlamaCppRunner {
    func generate(prompt: String, configuration: SummarizationConfiguration) async throws -> String
}

struct ProcessLlamaCppRunner: LlamaCppRunner {
    private let fileManager: FileManager
    private let processExecutor: LlamaProcessExecutor
    private let resolveBinaryURL: () throws -> URL
    private let temporaryDirectory: URL
    private let maxPredictionTokens: Int = 1024

    init(
        fileManager: FileManager = .default,
        processExecutor: LlamaProcessExecutor = FoundationLlamaProcessExecutor(),
        resolveBinaryURL: @escaping () throws -> URL = { try resolveLlamaBinaryURL() },
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.fileManager = fileManager
        self.processExecutor = processExecutor
        self.resolveBinaryURL = resolveBinaryURL
        self.temporaryDirectory = temporaryDirectory
    }

    func generate(prompt: String, configuration: SummarizationConfiguration) async throws -> String {
        let binaryURL = try resolveBinaryURL()
        let runtime = normalizedRuntimeSettings(configuration.runtime)

        let promptFileURL = temporaryDirectory.appendingPathComponent("llama-prompt-\(UUID().uuidString).txt")
        try prompt.write(to: promptFileURL, atomically: true, encoding: .utf8)

        defer {
            try? fileManager.removeItem(at: promptFileURL)
        }

        let baseArgs = [
            "-m", configuration.modelURL.path,
            "--file", promptFileURL.path,
            "--no-display-prompt",
            "--single-turn",
            "--ctx-size", "\(runtime.contextSize)",
            "--temp", String(runtime.temperature),
            "--top-p", String(runtime.topP),
            "-n", "\(maxPredictionTokens)"
        ]

        let result = try await processExecutor.run(executableURL: binaryURL, arguments: baseArgs, stdinData: nil)
        if result.exitCode == 0 {
            return result.stdout
        }

        if shouldRetryWithCompatibilityFlags(stderr: result.stderr) {
            let compatibilityArgs = baseArgs + ["--no-jinja", "--chat-template", "chatml"]
            let retryResult = try await processExecutor.run(
                executableURL: binaryURL,
                arguments: compatibilityArgs,
                stdinData: nil
            )
            if retryResult.exitCode == 0 {
                return retryResult.stdout
            }
            let message = retryResult.stderr.isEmpty ? "exit code \(retryResult.exitCode)" : retryResult.stderr
            throw processFailure(message)
        }

        let message = result.stderr.isEmpty ? "exit code \(result.exitCode)" : result.stderr
        throw processFailure(message)
    }

    private func processFailure(_ message: String) -> Error {
        let normalized = message.lowercased()
        if normalized.contains("failed to load model") || normalized.contains("error loading model")
            || normalized.contains("failed to load gguf") || normalized.contains("unknown model architecture") {
            return LlamaCppRuntimeError.modelLoadFailed(message)
        }
        return SummarizationError.inferenceFailed(message: message)
    }

    private func normalizedRuntimeSettings(_ settings: SummarizationRuntimeSettings) -> SummarizationRuntimeSettings {
        let contextSize = max(settings.contextSize, 256)
        let temperature = min(max(settings.temperature, 0), 2)
        let topP = min(max(settings.topP, 0), 1)
        return SummarizationRuntimeSettings(
            contextSize: contextSize,
            temperature: temperature,
            topP: topP
        )
    }

    private func shouldRetryWithCompatibilityFlags(stderr: String) -> Bool {
        let normalized = stderr.lowercased()
        return normalized.contains("common_chat_templates_init")
            || normalized.contains("chat template parsing error")
            || normalized.contains("consider disabling jinja")
    }
}

func resolveLlamaBinaryURL(
    fileManager: FileManager = .default,
    environment: [String: String] = [:],
    configuredPath: String? = nil
) throws -> URL {
    // The environment argument remains source-compatible for legacy callers;
    // production resolution deliberately never depends on a shell's PATH.
    guard let configuredPath, !configuredPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw LlamaCppRuntimeError.executableNotConfigured
    }
    guard configuredPath.hasPrefix("/") else {
        throw LlamaCppRuntimeError.executableNotExecutable(URL(fileURLWithPath: configuredPath))
    }
    let url = URL(fileURLWithPath: configuredPath)
    guard fileManager.fileExists(atPath: url.path) else { throw LlamaCppRuntimeError.executableMissing(url) }
    let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey])
    guard values?.isRegularFile == true, fileManager.isExecutableFile(atPath: url.path) else {
        throw LlamaCppRuntimeError.executableNotExecutable(url)
    }
    return url
}
