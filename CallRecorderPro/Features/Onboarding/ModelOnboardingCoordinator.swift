import Foundation

enum ModelInstallPromptStyle {
    case fullOnboarding
    case compactPrompt
}

@MainActor
final class ModelOnboardingCoordinator: ObservableObject {
    @Published private(set) var isPresented = false
    @Published private(set) var style: ModelInstallPromptStyle = .fullOnboarding

    private let modelManager: ModelManager

    init(modelManager: ModelManager) {
        self.modelManager = modelManager
    }

    func presentIfNeeded(for availability: TranscriptionAvailability) {
        guard case .requiresASRModel = availability else {
            return
        }

        style = modelManager.onboardingSeen ? .compactPrompt : .fullOnboarding
        isPresented = true
        modelManager.onboardingSeen = true
    }

    func dismiss() {
        isPresented = false
    }

    func notNow() {
        isPresented = false
    }

    func downloadAndContinue(profile: ModelProfile) async {
        await modelManager.install(profile: profile)
        if modelManager.availability(for: profile) != .requiresASRModel(profileOptions: ModelProfile.allCases) {
            modelManager.selectedProfile = profile
            modelManager.pendingProfileSelection = nil
            isPresented = false
        }
    }
}
