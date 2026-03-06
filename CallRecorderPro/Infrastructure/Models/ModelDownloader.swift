import CryptoKit
import Foundation

final class ModelDownloader {
    private let storage: ModelStorage

    init(storage: ModelStorage) {
        self.storage = storage
    }

    func downloadAndInstall(
        descriptor: ModelDescriptor,
        onProgress: @escaping (Double) -> Void = { _ in }
    ) async throws -> InstalledModelMetadata {
        guard let sourceURL = URL(string: descriptor.downloadURL), sourceURL.scheme == "file" else {
            throw NSError(domain: "ModelDownloader", code: 2001, userInfo: [NSLocalizedDescriptionKey: "Only file:// model source is supported."])
        }

        let sourcePath = sourceURL.path
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            throw NSError(domain: "ModelDownloader", code: 2002, userInfo: [NSLocalizedDescriptionKey: "Model source file does not exist at \(sourcePath)"])
        }

        onProgress(0.1)

        let data = try Data(contentsOf: sourceURL)
        let actualSize = Int64(data.count)
        guard actualSize == descriptor.sizeBytes else {
            throw NSError(domain: "ModelDownloader", code: 2003, userInfo: [NSLocalizedDescriptionKey: "Size mismatch for \(descriptor.id)"])
        }

        onProgress(0.5)

        let actualChecksum = sha256(data: data)
        let expectedChecksum = normalizedChecksum(descriptor.checksum)
        guard actualChecksum == expectedChecksum else {
            throw NSError(domain: "ModelDownloader", code: 2004, userInfo: [NSLocalizedDescriptionKey: "Checksum mismatch for \(descriptor.id)"])
        }

        onProgress(0.8)
        let installedMetadata = try storage.installModelData(data, descriptor: descriptor)
        onProgress(1.0)
        return installedMetadata
    }

    private func sha256(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func normalizedChecksum(_ value: String) -> String {
        value.replacingOccurrences(of: "sha256:", with: "")
    }
}
