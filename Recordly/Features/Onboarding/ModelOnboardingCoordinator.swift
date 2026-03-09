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
        guard case .unavailable = availability else {
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
        switch modelManager.availability(for: profile) {
        case .ready, .degradedNoDiarization:
            modelManager.selectedProfile = profile
            modelManager.pendingProfileSelection = nil
            isPresented = false
        case .unavailable:
            break
        }
    }
}
