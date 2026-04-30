import Foundation

protocol MlxLmRunner {
    func generate(prompt: String, configuration: SummarizationConfiguration) async throws -> String
}

struct MlxSummarizationEngine: SummarizationEngine {
    static let minimumTranscriptLength = 50

    private let runner: MlxLmRunner

    init(runner: MlxLmRunner = ProcessMlxLmRunner()) {
        self.runner = runner
    }

    func summarize(
        transcript: String,
        srtText: String?,
        recordingTitle: String,
        configuration: SummarizationConfiguration
    ) async throws -> SummaryDocument {
        if Task.isCancelled {
            throw SummarizationError.cancelled
        }

        let effectiveSource = if let srtText, !srtText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            srtText
        } else {
            transcript
        }

        guard effectiveSource.count >= Self.minimumTranscriptLength else {
            throw SummarizationError.transcriptTooShort
        }

        guard MLXModelValidator.isValidModelDirectory(configuration.modelURL) else {
            throw SummarizationError.modelMissing(configuration.modelURL)
        }

        let prompt = SummaryPromptBuilder.build(
            transcript: transcript,
            srtText: srtText,
            recordingTitle: recordingTitle
        )

        let output = try await runner.generate(prompt: prompt, configuration: configuration)

        if Task.isCancelled {
            throw SummarizationError.cancelled
        }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SummarizationError.emptyOutput
        }

        let document = try SummaryOutputParser.parse(trimmed)
        let hasStructuredContent = !document.topics.isEmpty
            || !document.decisions.isEmpty
            || !document.actionItems.isEmpty
            || !document.risks.isEmpty
        guard hasStructuredContent else {
            throw SummarizationError.outputParseFailed
        }

        return document
    }
}

struct ProcessMlxLmRunner: MlxLmRunner {
    private let processExecutor: LlamaProcessExecutor
    private let resolveBinaryURL: () throws -> URL
    private let maxPredictionTokens: Int = 1024

    init(
        processExecutor: LlamaProcessExecutor = FoundationLlamaProcessExecutor(),
        resolveBinaryURL: @escaping () throws -> URL = { try resolveMlxLmGenerateBinaryURL() }
    ) {
        self.processExecutor = processExecutor
        self.resolveBinaryURL = resolveBinaryURL
    }

    func generate(prompt: String, configuration: SummarizationConfiguration) async throws -> String {
        let binaryURL = try resolveBinaryURL()
        let runtime = normalizedRuntimeSettings(configuration.runtime)
        let arguments = [
            "--model", configuration.modelURL.path,
            "--prompt", prompt,
            "--max-tokens", "\(maxPredictionTokens)",
            "--temp", String(runtime.temperature),
            "--top-p", String(runtime.topP)
        ]

        let result = try await processExecutor.run(executableURL: binaryURL, arguments: arguments, stdinData: nil)
        if result.exitCode == 0 {
            return stripMlxPromptEcho(from: result.stdout, prompt: prompt)
        }

        let message = result.stderr.isEmpty ? "exit code \(result.exitCode)" : result.stderr
        throw SummarizationError.inferenceFailed(message: message)
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

    private func stripMlxPromptEcho(from output: String, prompt: String) -> String {
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedOutput.hasPrefix(trimmedPrompt) else {
            return output
        }
        return String(trimmedOutput.dropFirst(trimmedPrompt.count))
    }
}

func resolveMlxLmGenerateBinaryURL(
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    bundleResourceURL: URL? = Bundle.main.resourceURL
) throws -> URL {
    let resolver = RuntimeBinaryResolver(
        fileManager: fileManager,
        environment: environment,
        bundleResourceURL: bundleResourceURL,
        currentDirectoryURL: URL(fileURLWithPath: fileManager.currentDirectoryPath),
        homeDirectoryURL: homeDirectoryURL
    )
    let fixedDirectories = [
        homeDirectoryURL.appendingPathComponent(".local/bin", isDirectory: true),
        URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
        URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
    ]

    if let binaryURL = resolver.resolve(
        binaryNames: ["mlx_lm.generate"],
        environmentOverrideKey: "MLX_LM_GENERATE_PATH",
        fixedDirectories: fixedDirectories
    ) {
        return binaryURL
    }

    throw SummarizationError.inferenceFailed(message: "mlx_lm.generate not found")
}
