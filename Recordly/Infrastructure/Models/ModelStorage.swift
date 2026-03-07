import CryptoKit
import Foundation

final class ModelStorage {
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func installModelData(_ data: Data, descriptor: ModelDescriptor) throws -> InstalledModelMetadata {
        let checksum = try sha256(data: data)
        guard checksum == normalizedChecksum(descriptor.checksum) else {
            throw NSError(domain: "ModelStorage", code: 1002, userInfo: [NSLocalizedDescriptionKey: "Checksum mismatch for \(descriptor.id)"])
        }

        let canonicalDirectory = try AppPaths.canonicalModelDirectory(modelID: descriptor.id, kind: descriptor.kind)
        let canonicalBinaryURL = try AppPaths.canonicalModelBinaryURL(modelID: descriptor.id, kind: descriptor.kind)
        let tempDirectory = try AppPaths.modelsRootDirectory()
            .appendingPathComponent("tmp-install-\(UUID().uuidString)", isDirectory: true)

        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let tempBinaryURL = tempDirectory.appendingPathComponent("model.bin", isDirectory: false)
        try data.write(to: tempBinaryURL, options: .atomic)

        if fileManager.fileExists(atPath: canonicalDirectory.path) {
            try fileManager.removeItem(at: canonicalDirectory)
        }

        try fileManager.moveItem(at: tempDirectory, to: canonicalDirectory)

        let installed = InstalledModelMetadata(
            modelID: descriptor.id,
            kind: descriptor.kind,
            version: descriptor.version,
            installedAt: Date(),
            checksum: descriptor.checksum,
            sizeBytes: Int64(data.count),
            installedPath: canonicalBinaryURL.path
        )

        try upsertInstalledMetadata(installed)
        return installed
    }

    func removeModel(modelID: String, kind: ModelKind) throws {
        let modelDirectory = try AppPaths.canonicalModelDirectory(modelID: modelID, kind: kind)
        if fileManager.fileExists(atPath: modelDirectory.path) {
            try fileManager.removeItem(at: modelDirectory)
        }
        try removeMetadata(modelID: modelID)
    }

    func modelExists(modelID: String, kind: ModelKind) -> Bool {
        guard let url = try? AppPaths.canonicalModelBinaryURL(modelID: modelID, kind: kind) else {
            return false
        }
        return fileManager.fileExists(atPath: url.path)
    }

    func modelSize(modelID: String, kind: ModelKind) -> Int64? {
        guard let url = try? AppPaths.canonicalModelBinaryURL(modelID: modelID, kind: kind),
              let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    func canonicalModelURL(modelID: String, kind: ModelKind) -> URL? {
        try? AppPaths.canonicalModelBinaryURL(modelID: modelID, kind: kind)
    }

    func readInstalledMetadata(modelID: String) -> InstalledModelMetadata? {
        loadMetadata().first(where: { $0.modelID == modelID })
    }

    func isInstallationValid(for descriptor: ModelDescriptor) -> Bool {
        guard let metadata = readInstalledMetadata(modelID: descriptor.id),
              metadata.kind == descriptor.kind,
              metadata.version == descriptor.version,
              metadata.checksum == descriptor.checksum,
              let binaryURL = canonicalModelURL(modelID: descriptor.id, kind: descriptor.kind),
              fileManager.fileExists(atPath: binaryURL.path),
              let data = try? Data(contentsOf: binaryURL),
              let actualChecksum = try? sha256(data: data) else {
            return false
        }

        let expectedChecksum = normalizedChecksum(descriptor.checksum)
        return actualChecksum == expectedChecksum && metadata.sizeBytes == Int64(data.count)
    }

    private func loadMetadata() -> [InstalledModelMetadata] {
        guard let url = try? AppPaths.installedModelsMetadataURL(),
              fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let payload = try? decoder.decode(InstalledModelsMetadataFile.self, from: data) else {
            return []
        }
        return payload.installedModels
    }

    private func saveMetadata(_ metadata: [InstalledModelMetadata]) throws {
        let url = try AppPaths.installedModelsMetadataURL()
        let payload = InstalledModelsMetadataFile(installedModels: metadata)
        let data = try encoder.encode(payload)
        try data.write(to: url, options: .atomic)
    }

    private func upsertInstalledMetadata(_ entry: InstalledModelMetadata) throws {
        var metadata = loadMetadata().filter { $0.modelID != entry.modelID }
        metadata.append(entry)
        try saveMetadata(metadata)
    }

    private func removeMetadata(modelID: String) throws {
        let filtered = loadMetadata().filter { $0.modelID != modelID }
        try saveMetadata(filtered)
    }

    private func sha256(data: Data) throws -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func normalizedChecksum(_ value: String) -> String {
        value.replacingOccurrences(of: "sha256:", with: "")
    }
}
