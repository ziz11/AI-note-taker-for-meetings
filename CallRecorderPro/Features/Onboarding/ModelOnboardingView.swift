import SwiftUI

struct ModelOnboardingView: View {
    @ObservedObject var coordinator: ModelOnboardingCoordinator
    @ObservedObject var modelManager: ModelManager

    @State private var selectedProfile: ModelProfile = .balanced

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(coordinator.style == .fullOnboarding ? "Install Local Transcription Models" : "Install Required ASR Model")
                .font(.title2.weight(.semibold))

            Text("Transcription runs fully on-device. Audio and transcripts stay local on your Mac.")
            Text("Choose a profile by quality and download size. You can switch or remove models later in Models settings.")
            Text("Enhanced includes an optional speaker separation package.")
                .foregroundStyle(.secondary)

            ForEach(ModelProfile.allCases, id: \.self) { profile in
                Button {
                    selectedProfile = profile
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.displayName).font(.headline)
                            Text(profile.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selectedProfile == profile {
                            Image(systemName: "checkmark.circle.fill")
                        }
                    }
                    .padding(10)
                    .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }

            HStack {
                Button("Not Now") {
                    coordinator.notNow()
                }

                Spacer()

                Button("Download and Continue") {
                    Task {
                        await coordinator.downloadAndContinue(profile: selectedProfile)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            selectedProfile = modelManager.pendingProfileSelection ?? modelManager.selectedProfile
        }
    }
}
