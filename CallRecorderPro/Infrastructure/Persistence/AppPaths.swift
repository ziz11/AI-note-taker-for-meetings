import Foundation

enum AppPaths {
    static let appSupportFolderName = "CallRecorderPro"
    static let recordingsFolderName = "recordings"
    static let modelsFolderName = "Models"
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
