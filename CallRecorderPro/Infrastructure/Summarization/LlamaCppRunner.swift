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

struct FoundationLlamaProcessExecutor: LlamaProcessExecutor {
    private let processTimeoutSeconds: TimeInterval = 25

    func run(executableURL: URL, arguments: [String], stdinData: Data? = nil) async throws -> LlamaProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                if stdinData != nil {
                    process.standardInput = Pipe()
                }

                do {
                    var stdoutData = Data()
                    var stderrData = Data()
                    let stdoutLock = NSLock()
                    let stderrLock = NSLock()
                    let timeoutLock = NSLock()
                    var didTimeout = false
                    let streamReadGroup = DispatchGroup()
                    let timeoutTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))

                    streamReadGroup.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        stdoutLock.lock()
                        stdoutData = data
                        stdoutLock.unlock()
                        streamReadGroup.leave()
                    }

                    streamReadGroup.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        stderrLock.lock()
                        stderrData = data
                        stderrLock.unlock()
                        streamReadGroup.leave()
                    }

                    timeoutTimer.schedule(deadline: .now() + processTimeoutSeconds)
                    timeoutTimer.setEventHandler {
                        timeoutLock.lock()
                        didTimeout = true
                        timeoutLock.unlock()

                        if process.isRunning {
                            process.terminate()
                            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                                if process.isRunning {
                                    kill(process.processIdentifier, SIGKILL)
                                }
                            }
                        }
                    }
                    timeoutTimer.resume()

                    try process.run()

                    if let stdinData,
                       let stdinPipe = process.standardInput as? Pipe {
                        stdinPipe.fileHandleForWriting.write(stdinData)
                        try? stdinPipe.fileHandleForWriting.close()
                    }

                    process.waitUntilExit()
                    timeoutTimer.cancel()
                    streamReadGroup.wait()

                    timeoutLock.lock()
                    let timedOut = didTimeout
                    timeoutLock.unlock()

                    stdoutLock.lock()
                    let capturedStdout = stdoutData
                    stdoutLock.unlock()

                    stderrLock.lock()
                    let capturedStderr = stderrData
                    stderrLock.unlock()

                    if timedOut {
                        continuation.resume(throwing: SummarizationError.cancelled)
                        return
                    }

                    continuation.resume(returning: LlamaProcessResult(
                        exitCode: process.terminationStatus,
                        stdout: String(data: capturedStdout, encoding: .utf8) ?? "",
                        stderr: String(data: capturedStderr, encoding: .utf8) ?? ""
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

protocol LlamaCppRunner {
    func generate(prompt: String, configuration: SummaryEngineConfiguration) async throws -> String
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

    func generate(prompt: String, configuration: SummaryEngineConfiguration) async throws -> String {
        let binaryURL = try resolveBinaryURL()
        let runtime = normalizedRuntimeSettings(configuration.runtime)

        let promptFileURL = temporaryDirectory.appendingPathComponent("llama-prompt-\(UUID().uuidString).txt")
        try prompt.write(to: promptFileURL, atomically: true, encoding: .utf8)

        defer {
            try? fileManager.removeItem(at: promptFileURL)
        }

        let args = [
            "-m", configuration.modelURL.path,
            "--file", promptFileURL.path,
            "--no-display-prompt",
            "--ctx-size", "\(runtime.contextSize)",
            "--temp", String(runtime.temperature),
            "--top-p", String(runtime.topP),
            "-n", "\(maxPredictionTokens)"
        ]

        let result = try await processExecutor.run(executableURL: binaryURL, arguments: args, stdinData: nil)

        guard result.exitCode == 0 else {
            let message = result.stderr.isEmpty ? "exit code \(result.exitCode)" : result.stderr
            throw SummarizationError.inferenceFailed(message: message)
        }

        return result.stdout
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
}

func resolveLlamaBinaryURL(
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws -> URL {
    let binaryNames = ["llama-cli", "main"]
    var candidateURLs: [URL] = []

    if let resourceURL = Bundle.main.resourceURL {
        candidateURLs.append(contentsOf: binaryNames.flatMap { name in
            [
                resourceURL.appendingPathComponent("Binaries/\(name)"),
                resourceURL.appendingPathComponent(name)
            ]
        })
    }

    let currentDirectoryURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)
    candidateURLs.append(contentsOf: binaryNames.map { name in
        currentDirectoryURL.appendingPathComponent(name)
    })

    candidateURLs.append(contentsOf: [
        "/usr/local/bin",
        "/opt/homebrew/bin"
    ].flatMap { directory in
        binaryNames.map { name in
            URL(fileURLWithPath: directory).appendingPathComponent(name)
        }
    })

    if let path = environment["PATH"], !path.isEmpty {
        let directories = path.split(separator: ":").map(String.init)
        candidateURLs.append(contentsOf: directories.flatMap { directory in
            binaryNames.map { name in
                URL(fileURLWithPath: directory).appendingPathComponent(name)
            }
        })
    }

    for candidate in candidateURLs where fileManager.isExecutableFile(atPath: candidate.path) {
        return candidate
    }

    throw SummarizationError.binaryMissing
}
