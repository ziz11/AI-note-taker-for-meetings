import SwiftUI

struct RecordingRowView: View {
    @EnvironmentObject private var store: RecordingsStore

    let recording: RecordingSession
    let isSelected: Bool

    var body: some View {
        Button {
            store.selectedRecordingID = recording.id
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(recording.title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if recording.isFavorite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color(red: 1.0, green: 0.82, blue: 0.28))
                        }
                    }

                    Text(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)

                    Text(store.processingBadgeText(for: recording)
                        ?? (recording.source == .importedAudio ? "Imported audio" : recording.statusBadgeText))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.tertiaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 8) {
                    Text(recording.durationLabel)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(isSelected ? .primary : AppTheme.secondaryText)
                        .monospacedDigit()

                    Image(systemName: recording.lifecycleState == .recording ? "waveform.circle.fill" : "circle.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(recording.lifecycleState == .recording ? .red : AppTheme.tertiaryText)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appPanel(selected: isSelected)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(recording.isFavorite ? "Remove Favorite" : "Favorite") {
                store.toggleFavorite(for: recording)
            }

            Button("Duplicate") {
                store.duplicate(recording)
            }

            Button("Open Folder") {
                store.openFolder(for: recording)
            }

            Button(role: .destructive) {
                store.delete(recording)
            } label: {
                Text("Delete")
            }
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        RecordingRowView(recording: .draft(index: 1), isSelected: true)
            .environmentObject(RecordingsStore(previewMode: true))

        RecordingRowView(recording: .draft(index: 2), isSelected: false)
            .environmentObject(RecordingsStore(previewMode: true))
    }
    .padding()
    .frame(width: 340)
    .background(AppTheme.sidebarBackground)
}
