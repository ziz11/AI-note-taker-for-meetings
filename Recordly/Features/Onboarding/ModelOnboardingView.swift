import SwiftUI

struct ModelOnboardingView: View {
    @ObservedObject var coordinator: ModelOnboardingCoordinator
    @ObservedObject var modelManager: ModelManager

    @State private var selectedProfile: ModelProfile = .balanced

    var body: some View {
        ZStack {
            AppTheme.contentBackground
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(coordinator.style == .fullOnboarding ? "Install Local Transcription Models" : "Install Required ASR Model")
                        .font(.system(size: 26, weight: .bold, design: .rounded))

                    Text("Transcription runs fully on-device. Audio and transcripts stay local on your Mac.")
                        .foregroundStyle(.primary)
                    Text("Choose a profile by quality and download size. You can switch or remove models later in Models settings.")
                        .foregroundStyle(AppTheme.secondaryText)
                    Text("Enhanced includes an optional speaker separation package.")
                        .foregroundStyle(AppTheme.tertiaryText)
                }

                VStack(spacing: 10) {
                    ForEach(ModelProfile.allCases, id: \.self) { profile in
                        Button {
                            selectedProfile = profile
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(profile.displayName)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text(profile.summary)
                                        .font(.subheadline)
                                        .foregroundStyle(AppTheme.secondaryText)
                                }
                                Spacer()
                                if selectedProfile == profile {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(AppTheme.accent)
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .appPanel(selected: selectedProfile == profile)
                        }
                        .buttonStyle(.plain)
                    }
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
            .padding(24)
            .frame(width: 560)
            .appPanel(prominent: true, cornerRadius: 24)
            .padding(24)
        }
        .onAppear {
            selectedProfile = modelManager.pendingProfileSelection ?? modelManager.selectedProfile
        }
    }
}
