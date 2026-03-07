import SwiftUI

struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isRecording ? Color.red : Color.red.opacity(0.92))
                    .frame(width: 72, height: 72)
                    .shadow(color: .black.opacity(0.24), radius: 10, y: 6)

                RoundedRectangle(cornerRadius: isRecording ? 8 : 36)
                    .fill(.white)
                    .frame(width: isRecording ? 24 : 28, height: isRecording ? 24 : 28)
            }
            .padding(6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }
}

#Preview {
    VStack(spacing: 20) {
        RecordButton(isRecording: false) {}
        RecordButton(isRecording: true) {}
    }
    .padding()
}
