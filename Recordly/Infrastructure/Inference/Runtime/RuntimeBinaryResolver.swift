import Foundation

struct RuntimeBinaryResolver {
    let fileManager: FileManager
    let environment: [String: String]
    let bundleResourceURL: URL?
    let currentDirectoryURL: URL
    let homeDirectoryURL: URL

    init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        currentDirectoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.bundleResourceURL = bundleResourceURL
        self.currentDirectoryURL = currentDirectoryURL
        self.homeDirectoryURL = homeDirectoryURL
    }

    func resolve(
        binaryNames: [String],
        environmentOverrideKey: String? = nil,
        bundledSubdirectory: String = "Binaries",
        fixedDirectories: [URL] = []
    ) -> URL? {
        candidateURLs(
            binaryNames: binaryNames,
            environmentOverrideKey: environmentOverrideKey,
            bundledSubdirectory: bundledSubdirectory,
            fixedDirectories: fixedDirectories
        )
        .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private func candidateURLs(
        binaryNames: [String],
        environmentOverrideKey: String?,
        bundledSubdirectory: String,
        fixedDirectories: [URL]
    ) -> [URL] {
        var urls: [URL] = []

        if let bundleResourceURL {
            let bundledDirectory = bundleResourceURL.appendingPathComponent(bundledSubdirectory, isDirectory: true)
            urls.append(contentsOf: binaryNames.map { bundledDirectory.appendingPathComponent($0) })
            urls.append(contentsOf: binaryNames.map { bundleResourceURL.appendingPathComponent($0) })
        }

        if let environmentOverrideKey,
           let override = environment[environmentOverrideKey],
           !override.isEmpty {
            urls.append(URL(fileURLWithPath: override))
        }

        urls.append(contentsOf: binaryNames.map { currentDirectoryURL.appendingPathComponent($0) })
        for directory in fixedDirectories {
            urls.append(contentsOf: binaryNames.map { directory.appendingPathComponent($0) })
        }

        if let path = environment["PATH"], !path.isEmpty {
            let pathDirectories = path
                .split(separator: ":")
                .map { URL(fileURLWithPath: String($0), isDirectory: true) }
            for directory in pathDirectories {
                urls.append(contentsOf: binaryNames.map { directory.appendingPathComponent($0) })
            }
        }

        return urls
    }
}
