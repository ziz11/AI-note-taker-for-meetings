import SwiftUI

struct EmptyRecordingView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(Color(red: 0.18, green: 0.62, blue: 0.99))

            Text("No Recording Selected")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("Choose a recording from the list, or start a new one from the record control on the left.")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.56))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.09, green: 0.09, blue: 0.10),
                    Color(red: 0.05, green: 0.05, blue: 0.06)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

#Preview {
    EmptyRecordingView()
}
