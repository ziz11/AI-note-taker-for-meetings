import Foundation

protocol FluidAudioRunner {
    func transcribe(audioURL: URL, modelURL: URL) async throws -> FluidAudioRunnerOutput
}

struct FluidAudioRunnerOutput {
    var language: String?
    var segments: [FluidAudioSegment]
}

struct FluidAudioSegment {
    var id: String
    var startMs: Int
    var endMs: Int
    var text: String
    var confidence: Double?
    var words: [ASRWord]?
}

struct ProcessFluidAudioRunner: FluidAudioRunner {
    private let fileManager: FileManager
    private let processExecutor: FluidAudioProcessExecutor
    private let temporaryDirectory: URL
    private let environment: [String: String]
    private let resolveBinaryURL: () throws -> URL
    private let outputBaseURLFactory: () -> URL

    init(
        fileManager: FileManager = .default,
        processExecutor: FluidAudioProcessExecutor = FoundationFluidAudioProcessExecutor(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resolveBinaryURL: (() throws -> URL)? = nil,
        outputBaseURLFactory: (() -> URL)? = nil
    ) {
        self.fileManager = fileManager
        self.processExecutor = processExecutor
        self.temporaryDirectory = temporaryDirectory
        self.environment = environment
        self.resolveBinaryURL = resolveBinaryURL ?? {
            try Self.resolveFluidAudioBinaryURL(
                fileManager: fileManager,
                environment: environment
            )
        }
        self.outputBaseURLFactory = outputBaseURLFactory ?? {
            temporaryDirectory.appendingPathComponent("fluidaudio-output-\(UUID().uuidString)")
        }
    }

    func transcribe(audioURL: URL, modelURL: URL) async throws -> FluidAudioRunnerOutput {
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
            "transcribe",
            effectiveAudioURL.path,
            "--model-path", modelURL.path,
            "--output-json",
            "--output-file", outputBaseURL.path
        ]

        let result = try await processExecutor.run(executableURL: binaryURL, arguments: args)
        guard result.exitCode == 0 else {
            throw ASREngineRuntimeError.inferenceFailed(
                message: result.stderr.isEmpty ? "exit code \(result.exitCode)" : result.stderr
            )
        }

        guard fileManager.fileExists(atPath: outputJSONURL.path) else {
            let detail = result.stderr.isEmpty ? "" : " stderr: \(result.stderr)"
            throw ASREngineRuntimeError.inferenceFailed(
                message: "fluidaudio produced no output file for \(effectiveAudioURL.lastPathComponent).\(detail)"
            )
        }

        let data = try Data(contentsOf: outputJSONURL)
        try? fileManager.removeItem(at: outputJSONURL)

        return try parseFluidAudioJSONOutput(data)
    }

    private func convertToWAVIfNeeded(_ audioURL: URL) throws -> URL {
        let ext = audioURL.pathExtension.lowercased()
        if ext == "wav" {
            return audioURL
        }

        let wavURL = temporaryDirectory.appendingPathComponent("fluidaudio-input-\(UUID().uuidString).wav")
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
            throw ASREngineRuntimeError.inferenceFailed(
                message: "Failed to convert \(audioURL.lastPathComponent) to WAV: \(stderr)"
            )
        }

        guard fileManager.fileExists(atPath: wavURL.path) else {
            throw ASREngineRuntimeError.inferenceFailed(
                message: "Audio conversion produced no output for \(audioURL.lastPathComponent)"
            )
        }

        return wavURL
    }

    private static func resolveFluidAudioBinaryURL(
        fileManager: FileManager,
        environment: [String: String]
    ) throws -> URL {
        let binaryName = "fluidaudio"
        var candidateURLs: [URL] = []

        if let resourceURL = Bundle.main.resourceURL {
            candidateURLs.append(resourceURL.appendingPathComponent("Binaries/\(binaryName)"))
            candidateURLs.append(resourceURL.appendingPathComponent(binaryName))
        }

        candidateURLs.append(contentsOf: [
            "/usr/local/bin",
            "/opt/homebrew/bin"
        ].map { URL(fileURLWithPath: $0).appendingPathComponent(binaryName) })

        if let path = environment["PATH"], !path.isEmpty {
            let directories = path.split(separator: ":").map(String.init)
            candidateURLs.append(contentsOf: directories.map { directory in
                URL(fileURLWithPath: directory).appendingPathComponent(binaryName)
            })
        }

        for candidate in candidateURLs where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }

        throw ASREngineRuntimeError.inferenceFailed(
            message: "fluidaudio binary not found (looked in app resources, Homebrew paths, and PATH)"
        )
    }

    private func parseFluidAudioJSONOutput(_ data: Data) throws -> FluidAudioRunnerOutput {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ASREngineRuntimeError.outputParseFailed
        }

        let language = root["language"] as? String
        let transcription = root["transcription"] as? [[String: Any]]
            ?? root["segments"] as? [[String: Any]]
            ?? []

        let segments: [FluidAudioSegment] = transcription.enumerated().compactMap { index, item in
            let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return nil }

            let offsets = item["offsets"] as? [String: Any]
            let start = (offsets?["from"] as? NSNumber)?.intValue
                ?? (item["start_ms"] as? NSNumber)?.intValue
                ?? (item["startMs"] as? NSNumber)?.intValue
                ?? 0
            let end = (offsets?["to"] as? NSNumber)?.intValue
                ?? (item["end_ms"] as? NSNumber)?.intValue
                ?? (item["endMs"] as? NSNumber)?.intValue
                ?? max(start + 1, start)

            return FluidAudioSegment(
                id: "seg-\(index + 1)",
                startMs: max(0, start),
                endMs: max(start + 1, end),
                text: text,
                confidence: item["confidence"] as? Double,
                words: nil
            )
        }

        guard !segments.isEmpty else {
            throw ASREngineRuntimeError.outputParseFailed
        }

        return FluidAudioRunnerOutput(language: language, segments: segments)
    }
}

protocol FluidAudioProcessExecutor {
    func run(executableURL: URL, arguments: [String]) async throws -> FluidAudioProcessResult
}

struct FluidAudioProcessResult {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

struct FoundationFluidAudioProcessExecutor: FluidAudioProcessExecutor {
    func run(executableURL: URL, arguments: [String]) async throws -> FluidAudioProcessResult {
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

                    continuation.resume(returning: FluidAudioProcessResult(
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

struct FluidAudioASREngine: ASREngine {
    let displayName: String = "FluidAudio"
    private let runnerFactory: () -> FluidAudioRunner

    init(runner: FluidAudioRunner? = nil) {
        if let runner {
            self.runnerFactory = { runner }
        } else {
            self.runnerFactory = { ProcessFluidAudioRunner() }
        }
    }

    func cacheFingerprint(configuration: ASREngineConfiguration) -> String {
        let modelPath = configuration.modelURL.standardizedFileURL.path
        return "\(modelPath)|fluidaudio"
    }

    func transcribe(
        audioURL: URL,
        channel: TranscriptChannel,
        sessionID: UUID,
        configuration: ASREngineConfiguration
    ) async throws -> ASRDocument {
        if Task.isCancelled {
            throw ASREngineRuntimeError.cancelled
        }

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard FileManager.default.fileExists(atPath: configuration.modelURL.path) else {
            throw ASREngineRuntimeError.modelMissing(configuration.modelURL)
        }

        let supportedExtensions: Set<String> = ["caf", "wav", "mp3", "m4a", "flac", "ogg"]
        let ext = audioURL.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            throw ASREngineRuntimeError.unsupportedFormat(audioURL)
        }

        let runner = runnerFactory()
        let output = try await runner.transcribe(audioURL: audioURL, modelURL: configuration.modelURL)

        if Task.isCancelled {
            throw ASREngineRuntimeError.cancelled
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
