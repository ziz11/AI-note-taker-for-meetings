import AppKit
import ApplicationServices
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
                .fill(AppTheme.sidebarBackground)
                .ignoresSafeArea()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("All Recordings")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)

                    Text("\(store.filteredRecordings.count) items")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppTheme.secondaryText)
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
                        .overlay(Circle().stroke(AppTheme.hairline, lineWidth: 1))
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
                .disabled(store.isRecording || store.viewState.runtime.isCaptureTransitionInFlight)

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(store.viewState.runtime.sidebarStatus)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(store.isRecording ? .red : .primary)

                    Text(store.isRecording ? store.viewState.runtime.recordingDurationLabel : "00:00")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.secondaryText)
                        .monospacedDigit()
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.secondaryText)

            TextField("Titles, Summaries, Transcripts", text: $store.viewState.searchQuery)
                .textFieldStyle(.plain)
                .foregroundStyle(.primary)

            if !store.viewState.searchQuery.isEmpty {
                Button {
                    store.viewState.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(AppTheme.panelFill, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).stroke(AppTheme.hairline, lineWidth: 1))
    }

    @ViewBuilder
    private var progressSection: some View {
        if !store.processingJobs.isEmpty {
            ForEach(store.processingJobs) { job in
                progressCard(
                    title: "\(job.kind.label) · \(job.recordingTitle)",
                    detail: job.stageLabel,
                    progress: job.progress
                )
            }
        }
    }

    @ViewBuilder
    private var permissionHelp: some View {
        if shouldShowSystemPermissionHelp {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("System audio permission needed")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("Enable Screen Recording access in System Settings.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.secondaryText)
                }

                Spacer(minLength: 8)

                Button("Open") {
                    Task {
                        await requestSystemRecordingPermission()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
            }
            .padding(14)
            .appPanel(cornerRadius: 18)
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
        .appPanel(cornerRadius: 22)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: store.viewState.searchQuery.isEmpty ? "waveform" : "magnifyingglass")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(AppTheme.secondaryText)

            Text(store.viewState.searchQuery.isEmpty ? "No recordings yet" : "No matching recordings")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)

            Text(store.viewState.searchQuery.isEmpty ? "Start a recording or import audio." : "Try a different title or transcript keyword.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var isRecordButtonLocked: Bool {
        store.viewState.runtime.isCaptureTransitionInFlight
    }

    private var recordButtonBackground: some ShapeStyle {
        if store.isRecording {
            return AnyShapeStyle(Color.red)
        }
        return AnyShapeStyle(AppTheme.accent.gradient)
    }

    private var shouldShowSystemPermissionHelp: Bool {
        store.viewState.runtime.meterLevels.systemAudioLabel == "Permission denied"
    }

    private func chromeButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(AppTheme.panelFill, in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func progressCard(title: String, detail: String, progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
            }

            ProgressView(value: progress, total: 1)
                .tint(AppTheme.accent)
        }
        .padding(14)
        .appPanel(cornerRadius: 18)
    }

    private func meterColumn(title: String, status: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
            }

            ProgressView(value: value, total: 1)
                .tint(AppTheme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggleChip(title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
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

    private func requestSystemRecordingPermission() async {
        if CGPreflightScreenCaptureAccess() {
            return
        }

        let granted = await Task.detached(priority: .userInitiated) {
            CGRequestScreenCaptureAccess()
        }.value

        if !granted {
            openScreenRecordingSettings()
        }
    }
}

#Preview {
    RecordingSidebarView()
        .environmentObject(RecordingsStore(previewMode: true))
        .frame(width: 340, height: 760)
}
