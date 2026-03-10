import SwiftUI

struct EmptyRecordingView: View {
    var body: some View {
        VStack {
            VStack(spacing: 14) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(AppTheme.accent)

                Text("No Recording Selected")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Text("Choose a recording from the list, or start a new one from the record control on the left.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .padding(32)
            .appPanel(prominent: true, cornerRadius: 24)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.contentBackground)
    }
}

#Preview {
    EmptyRecordingView()
}
