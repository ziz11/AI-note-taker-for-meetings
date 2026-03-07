import XCTest
@testable import Recordly

final class ModelDiscoveryTests: XCTestCase {
    private var tempDirectory: URL!
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ModelDiscoveryTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        defaultsSuiteName = "ModelDiscoveryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDownWithError() throws {
        if let defaultsSuiteName {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        defaults = nil
        defaultsSuiteName = nil
        tempDirectory = nil
    }

    func testRepositoryRootDirectoryFindsGitTopLevelFromNestedPath() throws {
        let repoRoot = tempDirectory.appendingPathComponent("repo", isDirectory: true)
        let nestedDirectory = repoRoot
            .appendingPathComponent("Recordly/Infrastructure/Models", isDirectory: true)

        try FileManager.default.createDirectory(
            at: repoRoot.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)

        XCTAssertEqual(
            AppPaths.repositoryRootDirectory(startingAt: nestedDirectory),
            repoRoot
        )
    }

    func testProjectLocalModelsDirectoriesUseRepositoryRootAnchor() {
        let repoRoot = tempDirectory.appendingPathComponent("repo", isDirectory: true)

        XCTAssertEqual(
            AppPaths.projectLocalModelsDirectories(repoRoot: repoRoot),
            [
                repoRoot.appendingPathComponent("Models", isDirectory: true),
                repoRoot.appendingPathComponent("models", isDirectory: true),
            ]
        )
    }

    @MainActor
    func testListLocalOptionsDeduplicatesByBasenameUsingSourcePriority() throws {
        let appSupportRoot = tempDirectory.appendingPathComponent("app-support", isDirectory: true)
        let sharedRoot = tempDirectory.appendingPathComponent("shared", isDirectory: true)
        let repoRoot = tempDirectory.appendingPathComponent("repo", isDirectory: true)
        let projectModels = repoRoot.appendingPathComponent("Models", isDirectory: true)

        try createModel(named: "whisper-small.bin", in: appSupportRoot.appendingPathComponent("asr", isDirectory: true))
        try createModel(named: "whisper-small.bin", in: sharedRoot.appendingPathComponent("asr", isDirectory: true))
        try createModel(named: "whisper-small.bin", in: projectModels)

        let manager = makeManager(
            appSupportRoot: appSupportRoot,
            sharedRoot: sharedRoot,
            projectDirectories: [projectModels]
        )

        let options = manager.listLocalOptions(kind: .asr)

        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(options.first?.source, .appSupport)
        XCTAssertEqual(
            options.first?.url.deletingLastPathComponent().resolvingSymlinksInPath(),
            appSupportRoot.appendingPathComponent("asr", isDirectory: true).resolvingSymlinksInPath()
        )
    }

    @MainActor
    func testSelectedLocalOptionUsesHighestPriorityAvailableSourceForASRFallback() throws {
        let sharedRoot = tempDirectory.appendingPathComponent("shared", isDirectory: true)
        let repoRoot = tempDirectory.appendingPathComponent("repo", isDirectory: true)
        let projectModels = repoRoot.appendingPathComponent("Models", isDirectory: true)

        try createModel(named: "whisper-medium.bin", in: sharedRoot.appendingPathComponent("asr", isDirectory: true))
        try createModel(named: "whisper-medium.bin", in: projectModels)

        let manager = makeManager(
            appSupportRoot: nil,
            sharedRoot: sharedRoot,
            projectDirectories: [projectModels]
        )

        let selected = manager.selectedLocalOption(kind: .asr)

        XCTAssertEqual(selected?.source, .shared)
        XCTAssertEqual(
            selected?.url.deletingLastPathComponent().resolvingSymlinksInPath(),
            sharedRoot.appendingPathComponent("asr", isDirectory: true).resolvingSymlinksInPath()
        )
        XCTAssertEqual(manager.selectedASRModelID, selected?.id)
    }

    @MainActor
    func testProjectLocalClassificationUsesExtensionAndFilenameHeuristics() throws {
        let repoRoot = tempDirectory.appendingPathComponent("repo", isDirectory: true)
        let modelsDirectory = repoRoot.appendingPathComponent("Models", isDirectory: true)

        try createModel(named: "whisper-large.bin", in: modelsDirectory)
        try createModel(named: "team-asr.bin", in: modelsDirectory)
        try createModel(named: "diarization-enhanced.bin", in: modelsDirectory)
        try createModel(named: "summary.gguf", in: modelsDirectory)
        try createModel(named: "generic.bin", in: modelsDirectory)

        let manager = makeManager(
            appSupportRoot: nil,
            sharedRoot: nil,
            projectDirectories: [modelsDirectory]
        )

        XCTAssertEqual(
            Set(manager.listLocalOptions(kind: .asr).map { $0.url.lastPathComponent }),
            ["whisper-large.bin", "team-asr.bin"]
        )
        XCTAssertEqual(
            Set(manager.listLocalOptions(kind: .diarization).map { $0.url.lastPathComponent }),
            ["diarization-enhanced.bin"]
        )
        XCTAssertEqual(
            Set(manager.listLocalOptions(kind: .summarization).map { $0.url.lastPathComponent }),
            ["summary.gguf", "generic.bin"]
        )
    }

    @MainActor
    private func makeManager(
        appSupportRoot: URL?,
        sharedRoot: URL?,
        projectDirectories: [URL]
    ) -> ModelManager {
        let discoveryPaths = ModelDiscoveryPaths(
            appSupportDirectory: { kind in
                appSupportRoot?.appendingPathComponent(kind.rawValue, isDirectory: true)
            },
            sharedDirectory: { kind in
                sharedRoot?.appendingPathComponent(kind.rawValue, isDirectory: true)
            },
            userDirectory: { _ in nil },
            projectDirectories: {
                projectDirectories
            }
        )

        return ModelManager(
            preferences: ModelPreferencesStore(defaults: defaults),
            fileManager: .default,
            discoveryPaths: discoveryPaths
        )
    }

    private func createModel(named name: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("model".utf8).write(to: directory.appendingPathComponent(name, isDirectory: false))
    }
}
