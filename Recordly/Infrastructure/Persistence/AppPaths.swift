import Foundation

enum AppPaths {
    static let appSupportFolderName = "Recordly"
    static let recordingsFolderName = "recordings"
    static let modelsFolderName = "Models"
    static let sharedModelsFolder = "/Users/Shared/RecordlyModels"
    static let userModelsFolder = "models"
    static let installedModelsMetadataName = "installed-models.json"

    static func appSupportDirectory() throws -> URL {
        let baseDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appDirectory = baseDirectory.appendingPathComponent(appSupportFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        return appDirectory
    }

    static func recordingsDirectory() throws -> URL {
        let directory = try appSupportDirectory().appendingPathComponent(recordingsFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func sessionDirectory(for id: UUID) throws -> URL {
        let recordingsDirectory = try recordingsDirectory()
        let sessionDirectory = recordingsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        return sessionDirectory
    }

    static func sessionMetadataURL(for id: UUID) throws -> URL {
        try sessionDirectory(for: id).appendingPathComponent("session.json")
    }

    static func modelsRootDirectory() throws -> URL {
        let directory = try appSupportDirectory().appendingPathComponent(modelsFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func modelsDirectory(kind: ModelKind) throws -> URL {
        let directory = try modelsRootDirectory().appendingPathComponent(kind.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func sharedModelsDirectory(kind: ModelKind) throws -> URL {
        let root = URL(fileURLWithPath: sharedModelsFolder, isDirectory: true)
        let directory = root.appendingPathComponent(kind.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func userModelsDirectory(kind: ModelKind) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directory = home
            .appendingPathComponent(userModelsFolder, isDirectory: true)
            .appendingPathComponent(kind.rawValue, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return nil
        }
        return directory
    }

    static func repositoryRootDirectory(
        startingAt: URL = URL(fileURLWithPath: #filePath),
        fileManager: FileManager = .default
    ) -> URL? {
        var current = startingAt.hasDirectoryPath ? startingAt : startingAt.deletingLastPathComponent()

        while true {
            let gitDirectory = current.appendingPathComponent(".git", isDirectory: true)
            if fileManager.fileExists(atPath: gitDirectory.path) {
                return current
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return nil
            }
            current = parent
        }
    }

    static func projectLocalModelsDirectories(repoRoot: URL? = repositoryRootDirectory()) -> [URL] {
        guard let repoRoot else {
            return []
        }

        return [
            repoRoot.appendingPathComponent("Models", isDirectory: true),
            repoRoot.appendingPathComponent("models", isDirectory: true),
        ]
    }

    static func canonicalModelDirectory(modelID: String, kind: ModelKind) throws -> URL {
        try modelsDirectory(kind: kind).appendingPathComponent(modelID, isDirectory: true)
    }

    static func canonicalModelBinaryURL(modelID: String, kind: ModelKind) throws -> URL {
        try canonicalModelDirectory(modelID: modelID, kind: kind).appendingPathComponent("model.bin", isDirectory: false)
    }

    static func installedModelsMetadataURL() throws -> URL {
        try modelsRootDirectory().appendingPathComponent(installedModelsMetadataName, isDirectory: false)
    }
}
