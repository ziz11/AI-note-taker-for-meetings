import Foundation

struct ASREngineConfiguration: Sendable {
    var modelURL: URL
}

protocol ASREngine {
    var displayName: String { get }
    func transcribe(
        audioURL: URL,
        channel: TranscriptChannel,
        sessionID: UUID,
        configuration: ASREngineConfiguration
    ) async throws -> ASRDocument
}

enum WhisperCppError: LocalizedError {
    case modelMissing(URL)
    case inferenceFailed(message: String)
    case unsupportedFormat(URL)
    case outputParseFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .modelMissing(let url):
            return "ASR model is missing at: \(url.path)"
        case .inferenceFailed(let message):
            return "ASR inference failed: \(message)"
        case .unsupportedFormat(let url):
            return "Unsupported audio format for ASR: \(url.lastPathComponent)"
        case .outputParseFailed:
            return "Failed to parse ASR output produced by whisper.cpp"
        case .cancelled:
            return "ASR inference was cancelled"
        }
    }
}

protocol WhisperCppRunner {
    func transcribe(audioURL: URL, modelURL: URL) async throws -> WhisperCppRunnerOutput
}

struct WhisperCppRunnerOutput {
    var language: String?
    var segments: [WhisperCppSegment]
}

struct WhisperCppSegment {
    var id: String
    var startMs: Int
    var endMs: Int
    var text: String
    var confidence: Double?
    var words: [ASRWord]?
}

struct ProcessWhisperCppRunner: WhisperCppRunner {
    private let fileManager: FileManager
    private let processExecutor: WhisperProcessExecutor

    init(
        fileManager: FileManager = .default,
        processExecutor: WhisperProcessExecutor = FoundationWhisperProcessExecutor()
    ) {
        self.fileManager = fileManager
        self.processExecutor = processExecutor
    }

    func transcribe(audioURL: URL, modelURL: URL) async throws -> WhisperCppRunnerOutput {
        let binaryURL = try resolveWhisperBinaryURL()
        let outputBaseURL = fileManager.temporaryDirectory.appendingPathComponent("whisper-output-\(UUID().uuidString)")
        let outputJSONURL = outputBaseURL.appendingPathExtension("json")

        let args = [
            "-m", modelURL.path,
            "-f", audioURL.path,
            "--output-json",
            "--output-file", outputBaseURL.path,
            "--no-prints"
        ]

        let result = try await processExecutor.run(executableURL: binaryURL, arguments: args)
        guard result.exitCode == 0 else {
            throw WhisperCppError.inferenceFailed(message: result.stderr.isEmpty ? "exit code \(result.exitCode)" : result.stderr)
        }

        guard fileManager.fileExists(atPath: outputJSONURL.path) else {
            throw WhisperCppError.outputParseFailed
        }

        let data = try Data(contentsOf: outputJSONURL)
        try? fileManager.removeItem(at: outputJSONURL)

        return try parseWhisperJSONOutput(data)
    }

    private func resolveWhisperBinaryURL() throws -> URL {
        let candidateURLs: [URL] = [
            Bundle.main.resourceURL?.appendingPathComponent("Binaries/whisper-main"),
            Bundle.main.resourceURL?.appendingPathComponent("whisper-main"),
            URL(fileURLWithPath: "/usr/local/bin/whisper-main"),
            URL(fileURLWithPath: "/opt/homebrew/bin/whisper-main")
        ].compactMap { $0 }

        for candidate in candidateURLs where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }

        throw WhisperCppError.inferenceFailed(message: "whisper-main binary not found (expected bundled or system install)")
    }

    private func parseWhisperJSONOutput(_ data: Data) throws -> WhisperCppRunnerOutput {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WhisperCppError.outputParseFailed
        }

        let language = (root["result"] as? [String: Any])?["language"] as? String
        let transcription = root["transcription"] as? [[String: Any]] ?? []

        let segments: [WhisperCppSegment] = transcription.enumerated().compactMap { index, item in
            let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return nil }

            let offsets = item["offsets"] as? [String: Any]
            let start = (offsets?["from"] as? NSNumber)?.intValue ?? 0
            let end = (offsets?["to"] as? NSNumber)?.intValue ?? max(start + 1, start)

            return WhisperCppSegment(
                id: "seg-\(index + 1)",
                startMs: max(0, start),
                endMs: max(start + 1, end),
                text: text,
                confidence: nil,
                words: nil
            )
        }

        guard !segments.isEmpty else {
            throw WhisperCppError.outputParseFailed
        }

        return WhisperCppRunnerOutput(language: language, segments: segments)
    }
}

protocol WhisperProcessExecutor {
    func run(executableURL: URL, arguments: [String]) async throws -> WhisperProcessResult
}

struct WhisperProcessResult {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

struct FoundationWhisperProcessExecutor: WhisperProcessExecutor {
    func run(executableURL: URL, arguments: [String]) async throws -> WhisperProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                    continuation.resume(returning: WhisperProcessResult(
                        exitCode: process.terminationStatus,
                        stdout: stdout,
                        stderr: stderr
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

struct WhisperCppEngine: ASREngine {
    let displayName: String = "WhisperCpp (RU+EN)"
    private let runner: WhisperCppRunner

    init(runner: WhisperCppRunner = ProcessWhisperCppRunner()) {
        self.runner = runner
    }

    func transcribe(
        audioURL: URL,
        channel: TranscriptChannel,
        sessionID: UUID,
        configuration: ASREngineConfiguration
    ) async throws -> ASRDocument {
        if Task.isCancelled {
            throw WhisperCppError.cancelled
        }

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard FileManager.default.fileExists(atPath: configuration.modelURL.path) else {
            throw WhisperCppError.modelMissing(configuration.modelURL)
        }

        let supportedExtensions: Set<String> = ["caf", "wav", "mp3", "m4a", "flac"]
        let ext = audioURL.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            throw WhisperCppError.unsupportedFormat(audioURL)
        }

        let output = try await runner.transcribe(audioURL: audioURL, modelURL: configuration.modelURL)

        if Task.isCancelled {
            throw WhisperCppError.cancelled
        }

        return ASRDocument(
            version: 1,
            sessionID: sessionID,
            channel: channel,
            createdAt: Date(),
            segments: output.segments.map {
                ASRSegment(
                    id: $0.id,
                    startMs: $0.startMs,
                    endMs: $0.endMs,
                    text: $0.text,
                    confidence: $0.confidence,
                    language: output.language,
                    words: $0.words
                )
            }
        )
    }
}
