import Foundation

struct ModelRegistryPayload: Codable {
    let models: [ModelDescriptor]
}

final class ModelRegistry {
    private let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func loadModels() -> [ModelDescriptor] {
        guard let url = bundle.url(forResource: "model-registry", withExtension: "json") else {
            return []
        }

        do {
            let data = try Data(contentsOf: url)
            let payload = try JSONDecoder().decode(ModelRegistryPayload.self, from: data)
            return payload.models
        } catch {
            return []
        }
    }
}
