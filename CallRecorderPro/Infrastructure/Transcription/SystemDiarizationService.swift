import Foundation

struct DiarizationServiceConfiguration: Sendable {
    var modelURL: URL
}

enum DiarizationRuntimeError: LocalizedError, Equatable {
    case binaryMissing
    case modelMissing(URL)
    case invalidInput
    case nonZeroExit(code: Int32, stderr: String?)
    case malformedOutput
    case emptySegments
    case cancelled

    var errorDescription: String? {
        switch self {
        case .binaryMissing:
            return "Diarization binary was not found."
        case .modelMissing(let url):
            return "Diarization model is missing at: \(url.path)"
        case .invalidInput:
            return "Invalid diarization input audio or output segment payload."
        case .nonZeroExit(let code, let stderr):
            if let stderr, !stderr.isEmpty {
                return "Diarization failed with code \(code): \(stderr)"
            }
            return "Diarization failed with code \(code)."
        case .malformedOutput:
            return "Diarization runner produced malformed output."
        case .emptySegments:
            return "Diarization runner returned empty segments."
        case .cancelled:
            return "Diarization was cancelled."
        }
    }
}

protocol SystemDiarizationService {
    func diarize(
        systemAudioURL: URL,
        sessionID: UUID,
        configuration: DiarizationServiceConfiguration
    ) async throws -> DiarizationDocument
}

protocol DiarizationProcessExecutor {
    func run(executableURL: URL, arguments: [String], stdinData: Data?) async throws -> DiarizationProcessResult
}

struct DiarizationProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

struct FoundationDiarizationProcessExecutor: DiarizationProcessExecutor {
    func run(executableURL: URL, arguments: [String], stdinData: Data? = nil) async throws -> DiarizationProcessResult {
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
                    try process.run()

                    if let stdinData,
                       let stdinPipe = process.standardInput as? Pipe {
                        stdinPipe.fileHandleForWriting.write(stdinData)
                        try? stdinPipe.fileHandleForWriting.close()
                    }

                    process.waitUntilExit()

                    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                    continuation.resume(returning: DiarizationProcessResult(
                        exitCode: process.terminationStatus,
                        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                        stderr: String(data: stderrData, encoding: .utf8) ?? ""
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

protocol DiarizationRunner {
    func diarize(audioURL: URL, modelURL: URL) async throws -> [DiarizationOutputSegment]
}

struct DiarizationOutputSegment: Equatable {
    let id: String?
    let startMs: Int
    let endMs: Int
    let speakerID: String
    let confidence: Double?
}

struct ProcessDiarizationRunner: DiarizationRunner {
    private let fileManager: FileManager
    private let processExecutor: DiarizationProcessExecutor
    private let resolveBinaryURL: () throws -> URL

    init(
        fileManager: FileManager = .default,
        processExecutor: DiarizationProcessExecutor = FoundationDiarizationProcessExecutor(),
        resolveBinaryURL: @escaping () throws -> URL
    ) {
        self.fileManager = fileManager
        self.processExecutor = processExecutor
        self.resolveBinaryURL = resolveBinaryURL
    }

    func diarize(audioURL: URL, modelURL: URL) async throws -> [DiarizationOutputSegment] {
        if Task.isCancelled {
            throw DiarizationRuntimeError.cancelled
        }

        let binaryURL = try resolveBinaryURL()
        let outputBaseURL = fileManager.temporaryDirectory.appendingPathComponent("diarization-output-\(UUID().uuidString)")
        let outputJSONURL = outputBaseURL.appendingPathExtension("json")

        let args = [
            "-m", modelURL.path,
            "-f", audioURL.path,
            "--output-json",
            "--output-file", outputBaseURL.path,
            "--no-prints"
        ]

        let processResult = try await processExecutor.run(executableURL: binaryURL, arguments: args, stdinData: nil)
        guard processResult.exitCode == 0 else {
            throw DiarizationRuntimeError.nonZeroExit(
                code: processResult.exitCode,
                stderr: processResult.stderr.isEmpty ? nil : processResult.stderr
            )
        }

        let jsonData: Data
        if fileManager.fileExists(atPath: outputJSONURL.path) {
            jsonData = try Data(contentsOf: outputJSONURL)
            try? fileManager.removeItem(at: outputJSONURL)
        } else if !processResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let data = processResult.stdout.data(using: .utf8) {
            jsonData = data
        } else {
            throw DiarizationRuntimeError.malformedOutput
        }

        if Task.isCancelled {
            throw DiarizationRuntimeError.cancelled
        }

        return try parseOutput(data: jsonData)
    }

    private func parseOutput(data: Data) throws -> [DiarizationOutputSegment] {
        let payload: DiarizationRunnerOutputPayload
        do {
            payload = try JSONDecoder().decode(DiarizationRunnerOutputPayload.self, from: data)
        } catch {
            throw DiarizationRuntimeError.malformedOutput
        }

        let normalized = try payload.segments.map { segment -> DiarizationOutputSegment in
            let speakerID = segment.speakerID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard segment.startMs >= 0,
                  segment.endMs > segment.startMs,
                  !speakerID.isEmpty else {
                throw DiarizationRuntimeError.invalidInput
            }

            return DiarizationOutputSegment(
                id: segment.id?.trimmingCharacters(in: .whitespacesAndNewlines),
                startMs: segment.startMs,
                endMs: segment.endMs,
                speakerID: speakerID,
                confidence: segment.confidence
            )
        }

        if normalized.isEmpty {
            throw DiarizationRuntimeError.emptySegments
        }

        return normalized.enumerated().map { index, segment in
            let normalizedID = (segment.id?.isEmpty == false) ? segment.id : "dseg-\(index + 1)"
            return DiarizationOutputSegment(
                id: normalizedID,
                startMs: segment.startMs,
                endMs: segment.endMs,
                speakerID: segment.speakerID,
                confidence: segment.confidence
            )
        }
    }
}

struct CliSystemDiarizationService: SystemDiarizationService {
    private let fileManager: FileManager
    private let runnerFactory: () throws -> DiarizationRunner

    init(
        fileManager: FileManager = .default,
        runnerFactory: @escaping () throws -> DiarizationRunner = {
            try ProcessDiarizationRunner(resolveBinaryURL: { try resolveDiarizationBinaryURL() })
        }
    ) {
        self.fileManager = fileManager
        self.runnerFactory = runnerFactory
    }

    func diarize(
        systemAudioURL: URL,
        sessionID: UUID,
        configuration: DiarizationServiceConfiguration
    ) async throws -> DiarizationDocument {
        if Task.isCancelled {
            throw DiarizationRuntimeError.cancelled
        }

        guard fileManager.fileExists(atPath: systemAudioURL.path) else {
            throw DiarizationRuntimeError.invalidInput
        }

        guard systemAudioURL.lastPathComponent == "system.raw.caf" else {
            throw DiarizationRuntimeError.invalidInput
        }

        guard fileManager.fileExists(atPath: configuration.modelURL.path) else {
            throw DiarizationRuntimeError.modelMissing(configuration.modelURL)
        }

        let runner = try runnerFactory()
        let output = try await runner.diarize(audioURL: systemAudioURL, modelURL: configuration.modelURL)

        if Task.isCancelled {
            throw DiarizationRuntimeError.cancelled
        }

        let segments = output.map {
            DiarizationSegment(
                id: $0.id ?? UUID().uuidString,
                speaker: $0.speakerID,
                startMs: $0.startMs,
                endMs: $0.endMs,
                confidence: $0.confidence
            )
        }

        return DiarizationDocument(
            version: 1,
            sessionID: sessionID,
            createdAt: Date(),
            segments: segments
        )
    }
}

// Kept only for tests/previews where diarization runner is intentionally bypassed.
struct PlaceholderSystemDiarizationService: SystemDiarizationService {
    func diarize(
        systemAudioURL: URL,
        sessionID: UUID,
        configuration: DiarizationServiceConfiguration
    ) async throws -> DiarizationDocument {
        let exists = FileManager.default.fileExists(atPath: systemAudioURL.path)
        guard exists else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard FileManager.default.fileExists(atPath: configuration.modelURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        return DiarizationDocument(
            version: 1,
            sessionID: sessionID,
            createdAt: Date(),
            segments: []
        )
    }
}

func resolveDiarizationBinaryURL(fileManager: FileManager = .default) throws -> URL {
    let candidates: [URL] = [
        Bundle.main.resourceURL?.appendingPathComponent("Binaries/diarization-main"),
        Bundle.main.resourceURL?.appendingPathComponent("diarization-main"),
        URL(fileURLWithPath: "/usr/local/bin/diarization-main"),
        URL(fileURLWithPath: "/opt/homebrew/bin/diarization-main")
    ].compactMap { $0 }

    for candidate in candidates where fileManager.isExecutableFile(atPath: candidate.path) {
        return candidate
    }

    throw DiarizationRuntimeError.binaryMissing
}

private struct DiarizationRunnerOutputPayload: Decodable {
    let segments: [DiarizationRunnerOutputSegment]
}

private struct DiarizationRunnerOutputSegment: Decodable {
    let id: String?
    let startMs: Int
    let endMs: Int
    let speakerID: String
    let confidence: Double?

    private enum CodingKeys: String, CodingKey {
        case id
        case startMs
        case endMs
        case speakerID = "speakerId"
        case confidence
    }
}
