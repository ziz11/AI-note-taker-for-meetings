import Foundation

enum MLXModelValidator {
    static let requiredFiles = [
        "config.json",
        "tokenizer.json",
        "model.safetensors"
    ]

    static func isValidModelDirectory(
        _ url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let resolvedURL = url.resolvingSymlinksInPath()
        let values = try? resolvedURL.resourceValues(forKeys: [.isDirectoryKey])
        guard values?.isDirectory == true else {
            return false
        }

        return requiredFiles.allSatisfy { fileName in
            fileManager.fileExists(atPath: resolvedURL.appendingPathComponent(fileName).path)
        }
    }
}
