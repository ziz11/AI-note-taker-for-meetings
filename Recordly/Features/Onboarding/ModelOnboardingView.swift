import SwiftUI

/// Presentation only. Downloads and model selection stay with the SDK-backed Models panel.
struct ModelOnboardingView: View {
    let onContinue: (_ openModels: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(AppTheme.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Barkenson").font(.title.bold())
                    Text("Meeting recorder for Mac").foregroundStyle(.secondary)
                }
            }

            Text("Record meetings, transcribe on this Mac and identify speakers. You can also import an audio file.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 16) {
                guidance("1. Allow audio access", symbol: "mic", text: "When you start recording, macOS asks for microphone and Screen & System Audio Recording access. Enable both for Barkenson in System Settings → Privacy & Security. Screen video is not saved.")
                guidance("2. Download a transcription model", symbol: "arrow.down.circle", text: "Open Models to download a model over the internet, then select it for transcription. You can record or import audio before downloading. Audio and transcripts are processed locally.")
                guidance("3. Add speaker separation if needed", symbol: "person.2", text: "Download the optional speaker separation package in Models. Speaker labels may need correction; transcription can continue without this package.")
            }

            Divider()
            HStack {
                Button("Continue without models") { onContinue(false) }
                Spacer()
                Button("Open Models…") { onContinue(true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 520)
        .background(AppTheme.contentBackground)
    }

    private func guidance(_ title: String, symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
