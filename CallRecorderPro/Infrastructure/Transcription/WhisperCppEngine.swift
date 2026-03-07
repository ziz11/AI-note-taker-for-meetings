import Foundation

struct ASREngineConfiguration: Sendable {
    var modelURL: URL
}

protocol ASREngine {
    var displayName: String { get }
    func cacheFingerprint(configuration: ASREngineConfiguration) -> String
    func transcribe(
        audioURL: URL,
        channel: TranscriptChannel,
        sessionID: UUID,
        configuration: ASREngineConfiguration
    ) async throws -> ASRDocument
}

extension ASREngine {
    func cacheFingerprint(configuration: ASREngineConfiguration) -> String {
        configuration.modelURL.standardizedFileURL.path
    }
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
    private let temporaryDirectory: URL
    private let environment: [String: String]
    private let languageCodeProvider: () -> String
    private let resolveBinaryURL: () throws -> URL
    private let outputBaseURLFactory: () -> URL

    init(
        fileManager: FileManager = .default,
        processExecutor: WhisperProcessExecutor = FoundationWhisperProcessExecutor(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        languageCode: String = "ru",
        resolveBinaryURL: (() throws -> URL)? = nil,
        outputBaseURLFactory: (() -> URL)? = nil
    ) {
        self.fileManager = fileManager
        self.processExecutor = processExecutor
        self.temporaryDirectory = temporaryDirectory
        self.environment = environment
        self.languageCodeProvider = { languageCode }
        self.resolveBinaryURL = resolveBinaryURL ?? {
            try Self.resolveWhisperBinaryURL(
                fileManager: fileManager,
                environment: environment
            )
        }
        self.outputBaseURLFactory = outputBaseURLFactory ?? {
            temporaryDirectory.appendingPathComponent("whisper-output-\(UUID().uuidString)")
        }
    }

    init(
        fileManager: FileManager = .default,
        processExecutor: WhisperProcessExecutor = FoundationWhisperProcessExecutor(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        languageCodeProvider: @escaping () -> String,
        resolveBinaryURL: (() throws -> URL)? = nil,
        outputBaseURLFactory: (() -> URL)? = nil
    ) {
        self.fileManager = fileManager
        self.processExecutor = processExecutor
        self.temporaryDirectory = temporaryDirectory
        self.environment = environment
        self.languageCodeProvider = languageCodeProvider
        self.resolveBinaryURL = resolveBinaryURL ?? {
            try Self.resolveWhisperBinaryURL(
                fileManager: fileManager,
                environment: environment
            )
        }
        self.outputBaseURLFactory = outputBaseURLFactory ?? {
            temporaryDirectory.appendingPathComponent("whisper-output-\(UUID().uuidString)")
        }
    }

    func transcribe(audioURL: URL, modelURL: URL) async throws -> WhisperCppRunnerOutput {
        let binaryURL = try resolveBinaryURL()
        let outputBaseURL = outputBaseURLFactory()
        let outputJSONURL = outputBaseURL.appendingPathExtension("json")

        let effectiveAudioURL = try convertToWAVIfNeeded(audioURL)
        let shouldCleanupConverted = (effectiveAudioURL != audioURL)

        defer {
            if shouldCleanupConverted {
                try? fileManager.removeItem(at: effectiveAudioURL)
            }
        }

        let args = [
            "-m", modelURL.path,
            "-f", effectiveAudioURL.path,
            "--language", languageCodeProvider(),
            "--output-json",
            "--output-file", outputBaseURL.path,
            "--no-prints"
        ]

        let result = try await processExecutor.run(executableURL: binaryURL, arguments: args)
        guard result.exitCode == 0 else {
            throw WhisperCppError.inferenceFailed(message: result.stderr.isEmpty ? "exit code \(result.exitCode)" : result.stderr)
        }

        guard fileManager.fileExists(atPath: outputJSONURL.path) else {
            let detail = result.stderr.isEmpty ? "" : " stderr: \(result.stderr)"
            throw WhisperCppError.inferenceFailed(
                message: "whisper-cli produced no output file for \(effectiveAudioURL.lastPathComponent).\(detail)"
            )
        }

        let data = try Data(contentsOf: outputJSONURL)
        try? fileManager.removeItem(at: outputJSONURL)

        return try parseWhisperJSONOutput(data)
    }

    private func convertToWAVIfNeeded(_ audioURL: URL) throws -> URL {
        let supportedByWhisper: Set<String> = ["wav", "flac", "mp3", "ogg"]
        let ext = audioURL.pathExtension.lowercased()
        if supportedByWhisper.contains(ext) {
            return audioURL
        }

        let wavURL = temporaryDirectory.appendingPathComponent("whisper-input-\(UUID().uuidString).wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = [
            "-f", "WAVE",
            "-d", "LEI16@16000",
            "-c", "1",
            audioURL.path,
            wavURL.path
        ]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw WhisperCppError.inferenceFailed(
                message: "Failed to convert \(audioURL.lastPathComponent) to WAV: \(stderr)"
            )
        }

        guard fileManager.fileExists(atPath: wavURL.path) else {
            throw WhisperCppError.inferenceFailed(
                message: "Audio conversion produced no output for \(audioURL.lastPathComponent)"
            )
        }

        return wavURL
    }

    func defaultResolveWhisperBinaryURL() throws -> URL {
        try Self.resolveWhisperBinaryURL(fileManager: fileManager, environment: environment)
    }

    private static func resolveWhisperBinaryURL(
        fileManager: FileManager,
        environment: [String: String]
    ) throws -> URL {
        let binaryNames = ["whisper-main", "whisper-cli", "main"]
        var candidateURLs: [URL] = []

        if let resourceURL = Bundle.main.resourceURL {
            candidateURLs.append(contentsOf: binaryNames.flatMap { name in
                [
                    resourceURL.appendingPathComponent("Binaries/\(name)"),
                    resourceURL.appendingPathComponent(name)
                ]
            })
        }

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

        throw WhisperCppError.inferenceFailed(
            message: "whisper binary not found (looked for whisper-main, whisper-cli, or main in app resources, Homebrew paths, and PATH)"
        )
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
    private let preferences: ModelPreferencesStore

    init(
        runner: WhisperCppRunner? = nil,
        preferences: ModelPreferencesStore = ModelPreferencesStore()
    ) {
        self.preferences = preferences
        self.runner = runner ?? ProcessWhisperCppRunner(
            languageCodeProvider: { preferences.selectedASRLanguage.whisperCode }
        )
    }

    func cacheFingerprint(configuration: ASREngineConfiguration) -> String {
        let modelPath = configuration.modelURL.standardizedFileURL.path
        let language = preferences.selectedASRLanguage.whisperCode
        return "\(modelPath)|lang:\(language)"
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

        let supportedExtensions: Set<String> = ["caf", "wav", "mp3", "m4a", "flac", "ogg"]
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
