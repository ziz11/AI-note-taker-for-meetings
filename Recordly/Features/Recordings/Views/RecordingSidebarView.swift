import AppKit
import SwiftUI

struct RecordingSidebarView: View {
    @EnvironmentObject private var store: RecordingsStore

    var body: some View {
        VStack(spacing: 14) {
            header
            searchField
            progressSection
            permissionHelp
            recordingsList
            utilityFooter
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Rectangle()
                .fill(sidebarBackground)
                .ignoresSafeArea()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("All Recordings")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("\(store.filteredRecordings.count) items")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.56))
                }

                Spacer(minLength: 12)

                Button {
                    guard !isRecordButtonLocked else { return }
                    Task {
                        if store.isRecording {
                            await store.endRecording()
                        } else {
                            await store.beginRecording()
                        }
                    }
                } label: {
                    Image(systemName: store.isRecording ? "stop.fill" : "waveform")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 58, height: 58)
                        .background(recordButtonBackground, in: Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(isRecordButtonLocked)
            }

            HStack(spacing: 10) {
                chromeButton(title: "Models", systemImage: "cpu") {
                    store.isModelsSheetPresented = true
                }

                chromeButton(title: "Import", systemImage: "square.and.arrow.down") {
                    Task {
                        await store.importAudio()
                    }
                }
                .disabled(store.isRecording)

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(store.viewState.runtime.sidebarStatus)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(store.isRecording ? .red : Color.white.opacity(0.8))

                    Text(store.isRecording ? store.viewState.runtime.recordingDurationLabel : "00:00")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.56))
                        .monospacedDigit()
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.white.opacity(0.45))

            TextField("Titles, Summaries, Transcripts", text: $store.viewState.searchQuery)
                .textFieldStyle(.plain)
                .foregroundStyle(.white)

            if !store.viewState.searchQuery.isEmpty {
                Button {
                    store.viewState.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.white.opacity(0.35))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(Color.white.opacity(0.08), in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }

    @ViewBuilder
    private var progressSection: some View {
        if let transcription = store.viewState.runtime.transcriptionProgress {
            progressCard(title: "Transcribing", detail: store.viewState.runtime.transcriptionStageLabel ?? "Processing", progress: transcription)
        }

        if let summarization = store.viewState.runtime.summarizationProgress {
            progressCard(title: "Summarizing", detail: store.viewState.runtime.summarizationStageLabel ?? "Processing", progress: summarization)
        }
    }

    @ViewBuilder
    private var permissionHelp: some View {
        if shouldShowSystemPermissionHelp {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("System audio permission needed")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Enable Screen Recording access in System Settings.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.54))
                }

                Spacer(minLength: 8)

                Button("Open") {
                    openScreenRecordingSettings()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.white.opacity(0.16))
            }
            .padding(14)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var recordingsList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if store.filteredRecordings.isEmpty {
                    emptyState
                } else {
                    ForEach(store.filteredRecordings) { recording in
                        RecordingRowView(
                            recording: recording,
                            isSelected: store.selectedRecordingID == recording.id
                        )
                        .environmentObject(store)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }

    private var utilityFooter: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                meterColumn(
                    title: "Mic",
                    status: store.isRecording ? "Live" : "Idle",
                    value: store.viewState.runtime.meterLevels.microphoneLevel
                )

                meterColumn(
                    title: "System",
                    status: store.viewState.runtime.meterLevels.systemAudioLabel,
                    value: store.viewState.runtime.meterLevels.systemAudioLevel
                )
            }

            HStack(spacing: 14) {
                toggleChip(title: "Auto Transcribe", isOn: $store.viewState.autoTranscribeEnabled)
                toggleChip(title: "Auto Summarize", isOn: $store.viewState.autoSummarizeEnabled)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: store.viewState.searchQuery.isEmpty ? "waveform" : "magnifyingglass")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.44))

            Text(store.viewState.searchQuery.isEmpty ? "No recordings yet" : "No matching recordings")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)

            Text(store.viewState.searchQuery.isEmpty ? "Start a recording or import audio." : "Try a different title or transcript keyword.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.52))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var isRecordButtonLocked: Bool {
        store.viewState.runtime.activityStatus == "Processing"
            || store.viewState.runtime.transcriptionProgress != nil
            || store.viewState.runtime.summarizationProgress != nil
    }

    private var recordButtonBackground: some ShapeStyle {
        LinearGradient(
            colors: store.isRecording
                ? [Color(red: 0.86, green: 0.24, blue: 0.24), Color(red: 0.68, green: 0.12, blue: 0.18)]
                : [Color(red: 0.12, green: 0.58, blue: 0.98), Color(red: 0.06, green: 0.44, blue: 0.92)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var sidebarBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                Color(red: 0.10, green: 0.10, blue: 0.11),
                Color(red: 0.06, green: 0.06, blue: 0.07)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var shouldShowSystemPermissionHelp: Bool {
        store.viewState.runtime.meterLevels.systemAudioLabel == "Permission denied"
    }

    private func chromeButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Color.white.opacity(0.08), in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func progressCard(title: String, detail: String, progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineLimit(1)
            }

            ProgressView(value: progress, total: 1)
                .tint(Color(red: 0.13, green: 0.58, blue: 0.98))
        }
        .padding(14)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func meterColumn(title: String, status: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                Text(status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineLimit(1)
            }

            ProgressView(value: value, total: 1)
                .tint(Color(red: 0.13, green: 0.58, blue: 0.98))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggleChip(title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
        }
        .toggleStyle(.switch)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

#Preview {
    RecordingSidebarView()
        .environmentObject(RecordingsStore(previewMode: true))
        .frame(width: 340, height: 760)
}
