import Foundation

enum AppPaths {
    static let appSupportFolderName = "CallRecorderPro"
    static let recordingsFolderName = "recordings"
    static let modelsFolderName = "Models"

    static func recordingsDirectory() throws -> URL {
        let baseDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let appDirectory = baseDirectory.appendingPathComponent(appSupportFolderName, isDirectory: true)
        let recordingsDirectory = appDirectory.appendingPathComponent(recordingsFolderName, isDirectory: true)

        try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        return recordingsDirectory
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

    static func modelsDirectory(kind: ModelKind) -> URL {
        let base: URL
        do {
            base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            base = FileManager.default.temporaryDirectory
        }

        let appDirectory = base.appendingPathComponent(appSupportFolderName, isDirectory: true)
        let modelsDirectory = appDirectory.appendingPathComponent(modelsFolderName, isDirectory: true)
        let typeDirectory = modelsDirectory.appendingPathComponent(kind.rawValue, isDirectory: true)
        try? FileManager.default.createDirectory(at: typeDirectory, withIntermediateDirectories: true)
        return typeDirectory
    }
}
