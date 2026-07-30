import SwiftUI

struct RecordingSidebarView: View {
    @EnvironmentObject private var store: RecordingsStore
    @State private var isQueuePanelExpanded = true
    private let screenCapturePermissionCoordinator = ScreenCapturePermissionCoordinator()

    var body: some View {
        VStack(spacing: 14) {
            header
            searchField
            captureHealthBanner
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

    @ViewBuilder
    private var captureHealthBanner: some View {
        if let presentation = store.viewState.runtime.captureHealthPresentation {
            let color = captureHealthColor(for: presentation.severity)

            HStack(alignment: .center, spacing: 10) {
                if presentation.showsProgress {
                    ProgressView()
                        .controlSize(.small)
                        .tint(color)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(color)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(presentation.message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.secondaryText)
                }

                Spacer(minLength: 8)

                if presentation.isRetryable {
                    Button("Retry now") {
                        store.retryCaptureNow()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(color)
                }
            }
            .padding(12)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(color.opacity(0.45), lineWidth: 1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(presentation.accessibilityLabel)
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
        let transcriptionJobs = store.processingJobs.filter { $0.kind == .transcription }
            .sorted { lhs, rhs in
                if lhs.startedAt == rhs.startedAt {
                    return lhs.recordingTitle.localizedCaseInsensitiveCompare(rhs.recordingTitle) == .orderedAscending
                }
                return lhs.startedAt > rhs.startedAt
            }

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isQueuePanelExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isQueuePanelExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)

                Text("Transcription Queue")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                if !transcriptionJobs.isEmpty {
                    Text("\(transcriptionJobs.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule(style: .continuous).fill(AppTheme.accent.opacity(0.18)))
                }

                Spacer(minLength: 8)

                Button(store.isTranscriptionQueuePaused ? "Resume All" : "Pause All") {
                    if store.isTranscriptionQueuePaused {
                        store.resumeTranscriptionQueue()
                    } else {
                        store.pauseTranscriptionQueue()
                    }
                }
                .disabled(transcriptionJobs.isEmpty)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(store.isTranscriptionQueuePaused ? AppTheme.accent : AppTheme.secondaryText)

                Button("Cancel All") {
                    store.cancelTranscriptionQueue()
                }
                .disabled(transcriptionJobs.isEmpty)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if isQueuePanelExpanded {
                if transcriptionJobs.isEmpty {
                    Text("No transcription jobs queued.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.secondaryText)
                        .padding(.vertical, 6)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(transcriptionJobs) { job in
                                transcriptionQueueRow(job)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                    .scrollIndicators(.visible)
                }
            }
        }
        .padding(14)
        .appPanel(cornerRadius: 18)
    }

    private func transcriptionQueueRow(_ job: RecordingProcessingJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(job.recordingTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(job.stageLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
            }

            ProgressView(value: job.progress, total: 1)
                .tint(AppTheme.accent)

            HStack(spacing: 10) {
                Button("Retry") {
                    store.retryTranscription(for: job.recordingID)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(AppTheme.accent)

                Button("Cancel") {
                    store.cancelTranscription(for: job.recordingID)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(AppTheme.secondaryText)
                .buttonBorderShape(.capsule)
            }
        }
        .padding(12)
        .appPanel(cornerRadius: 16)
    }

    @ViewBuilder
    private var permissionHelp: some View {
        if shouldShowSystemPermissionHelp {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("System audio permission needed")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("Grant Screen Recording access in System Settings, then return to Recordly.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.secondaryText)
                }

                Spacer(minLength: 8)

                Button("Grant Access") {
                    screenCapturePermissionCoordinator.requestSystemRecordingPermission()
                }
                .buttonStyle(.bordered)
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
                    status: meterStatus(
                        for: .microphone,
                        default: store.isRecording ? "Live" : "Idle"
                    ),
                    value: store.viewState.runtime.meterLevels.microphoneLevel,
                    tint: meterTint(for: .microphone)
                )

                meterColumn(
                    title: "System",
                    status: meterStatus(
                        for: .system,
                        default: store.viewState.runtime.meterLevels.systemAudioLabel
                    ),
                    value: store.viewState.runtime.meterLevels.systemAudioLevel,
                    tint: meterTint(for: .system)
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

    private func meterColumn(
        title: String,
        status: String,
        value: Double,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tint)
                    .lineLimit(1)
            }

            ProgressView(value: value, total: 1)
                .tint(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(status)")
    }

    private func meterStatus(for channel: CaptureChannel, default defaultStatus: String) -> String {
        let health = store.viewState.runtime.captureHealth
        guard health.affectedChannels.contains(channel) else {
            return defaultStatus
        }

        switch health.phase {
        case .starting:
            return "Starting"
        case .recovering:
            return "Restoring"
        case .failed:
            return "Not recording"
        case .idle, .healthy:
            return defaultStatus
        }
    }

    private func meterTint(for channel: CaptureChannel) -> Color {
        let health = store.viewState.runtime.captureHealth
        guard health.affectedChannels.contains(channel) else {
            return AppTheme.accent
        }

        switch health.phase {
        case .starting, .recovering:
            return .orange
        case .failed:
            return .red
        case .idle, .healthy:
            return AppTheme.accent
        }
    }

    private func captureHealthColor(for severity: RecordingCaptureHealthSeverity) -> Color {
        switch severity {
        case .warning:
            return .orange
        case .critical:
            return .red
        }
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
}

#Preview {
    RecordingSidebarView()
        .environmentObject(RecordingsStore(previewMode: true))
        .frame(width: 340, height: 760)
}
