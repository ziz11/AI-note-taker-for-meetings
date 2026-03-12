import SwiftUI

private enum DetailContentTab: String, CaseIterable {
    case summary = "Summary"
    case transcript = "Transcript"
}

struct RecordingDetailView: View {
    @EnvironmentObject private var store: RecordingsStore

    let recording: RecordingSession

    @State private var draftTitle = ""
    @State private var isEditingTitle = false
    @State private var selectedTab: DetailContentTab = .summary
    @State private var actionsPanelWidth: CGFloat = 0
    @State private var isMetadataExpanded = false
    @FocusState private var isTitleFieldFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let isCompact = AdaptiveLayoutMetrics.isCompactWindow(proxy.size.width)
            ScrollView {
                VStack(spacing: isCompact ? 18 : 22) {
                    topChrome(isCompact: isCompact)
                    heroPanel(isCompact: isCompact)
                    processingPanel
                    playbackPanel(isCompact: isCompact)
                    secondaryActionsPanel(isCompact: isCompact)
                    notesPanel(isCompact: isCompact)
                    metadataSection(isCompact: isCompact)
                }
                .padding(isCompact ? 18 : 28)
                .frame(maxWidth: .infinity)
            }
            .background {
                Rectangle()
                    .fill(AppTheme.contentBackground)
                    .ignoresSafeArea()
            }
        }
        .onAppear {
            draftTitle = recording.title
        }
        .onChange(of: recording.id) { _, _ in
            draftTitle = recording.title
            isEditingTitle = false
            selectedTab = .summary
            isMetadataExpanded = false
        }
    }

    private func topChrome(isCompact: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                actionCluster
            }

            VStack(alignment: .trailing, spacing: 12) {
                actionCluster
            }
        }
    }

    private var actionCluster: some View {
        HStack(spacing: 0) {
            if let shareURL = store.shareableAudioURL(for: recording) {
                ShareLink(item: shareURL) {
                    clusterIcon(systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
            } else {
                clusterButton(systemImage: "square.and.arrow.up", isDisabled: true) {}
            }

            clusterDivider

            clusterButton(
                systemImage: recording.isFavorite ? "star.fill" : "star",
                tint: recording.isFavorite ? Color(red: 1.0, green: 0.82, blue: 0.28) : .white,
                isDisabled: false
            ) {
                store.toggleFavorite(for: recording)
            }

            clusterDivider

            clusterButton(systemImage: "plus.square.on.square") {
                store.duplicate(recording)
            }

            clusterDivider

            clusterButton(systemImage: "trash", tint: .red) {
                store.delete(recording)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 54)
        .background(AppTheme.panelFill, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).stroke(AppTheme.hairline, lineWidth: 1))
    }

    private func heroPanel(isCompact: Bool) -> some View {
        VStack(spacing: isCompact ? 12 : 14) {
            if isEditingTitle {
                TextField("Recording Title", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: isCompact ? 28 : 40, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                    .focused($isTitleFieldFocused)
                    .onSubmit {
                        applyRename()
                    }
                    .onChange(of: isTitleFieldFocused) { _, isFocused in
                        if !isFocused, isEditingTitle {
                            applyRename()
                        }
                    }
                    .onAppear {
                        isTitleFieldFocused = true
                    }
            } else {
                Button {
                    draftTitle = recording.title
                    isEditingTitle = true
                    isTitleFieldFocused = true
                } label: {
                    Text(recording.title)
                        .font(.system(size: isCompact ? 28 : 40, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                heroMetaText(recording.createdDayLabel)
                Text("•")
                    .foregroundStyle(AppTheme.tertiaryText)
                heroMetaText(recording.durationLabel)
                Text("•")
                    .foregroundStyle(AppTheme.tertiaryText)
                heroMetaText(recording.lifecycleState.label)
            }

            Text(recording.transcriptState.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.secondaryText)
        }
        .padding(isCompact ? 16 : 22)
        .frame(maxWidth: .infinity)
        .appPanel(prominent: true, cornerRadius: 30)
    }

    @ViewBuilder
    private var processingPanel: some View {
        let jobs = store.processingJobs(for: recording.id)
        ForEach(jobs) { job in
            progressCard(
                title: job.kind == .transcription ? "Transcription" : "Summary",
                detail: job.stageLabel,
                value: job.progress
            )
        }
    }

    private func playbackPanel(isCompact: Bool) -> some View {
        VStack(spacing: isCompact ? 18 : 22) {
            VStack(spacing: 10) {
                Slider(value: playbackProgressBinding, in: 0...1)
                    .tint(AppTheme.accent)
                    .disabled(!store.playbackState.isAvailable)

                HStack {
                    Text(store.playbackState.currentTimeLabel)
                    Spacer()
                    Text(store.playbackState.remainingTimeLabel)
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.secondaryText)
                .monospacedDigit()
            }

            HStack(spacing: isCompact ? 16 : 24) {
                transportButton(systemImage: "gobackward.15") {
                    store.skipPlayback(for: recording, by: -15)
                }

                Button {
                    store.togglePlayback(for: recording)
                } label: {
                    Image(systemName: store.playbackState.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: isCompact ? 28 : 34, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: isCompact ? 84 : 94, height: isCompact ? 84 : 94)
                        .background(
                            AppTheme.accent.gradient,
                            in: Circle()
                        )
                        .overlay(Circle().stroke(AppTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!store.playbackState.isAvailable || store.isRecording)

                transportButton(systemImage: "goforward.15") {
                    store.skipPlayback(for: recording, by: 15)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    sourceSelector
                    playbackRateMenu
                }

                VStack(spacing: 12) {
                    sourceSelector
                    playbackRateMenu
                }
            }
        }
        .padding(isCompact ? 20 : 24)
        .frame(maxWidth: .infinity)
        .appPanel(prominent: true, cornerRadius: 34)
    }

    private func secondaryActionsPanel(isCompact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Actions")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.secondaryText)

            WrappingHStack(maxWidth: actionsPanelWidth, horizontalSpacing: 10, verticalSpacing: 10) {
                secondaryActionButton(
                    title: "Transcribe",
                    systemImage: "waveform.badge.magnifyingglass",
                    isDisabled: store.isRecording
                        || recording.playableAudioFileName == nil
                        || store.isProcessing(.transcription, for: recording.id)
                ) {
                    Task {
                        await store.transcribeSelectedRecording()
                    }
                }

                secondaryActionButton(
                    title: "Summarize",
                    systemImage: "sparkles",
                    isDisabled: store.isRecording
                        || !hasTranscript
                        || store.isProcessing(.transcription, for: recording.id)
                        || store.isProcessing(.summarization, for: recording.id)
                ) {
                    Task {
                        await store.summarizeSelectedRecording()
                    }
                }

                secondaryActionButton(
                    title: "Open Folder",
                    systemImage: "folder"
                ) {
                    store.openFolder(for: recording)
                }

                secondaryActionButton(
                    title: "Export Transcript",
                    systemImage: "doc.text"
                ) {
                    store.exportTranscript(for: recording)
                }

                Menu {
                    Button("Copy Summary") {
                        store.copySummary(for: recording)
                    }
                    Button("Copy Transcript") {
                        store.copyTranscript(for: recording)
                    }
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(Color.white.opacity(0.08), in: Capsule(style: .continuous))
                }
                .menuStyle(.button)
                .disabled(!hasTranscript && store.summaryText(for: recording) == nil)
            }
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { actionsPanelWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, width in
                            actionsPanelWidth = width
                        }
                }
            )
        }
        .padding(isCompact ? 16 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appPanel(cornerRadius: 26)
    }

    private func notesPanel(isCompact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Content", selection: $selectedTab) {
                    Text(DetailContentTab.summary.rawValue).tag(DetailContentTab.summary)
                    Text(DetailContentTab.transcript.rawValue).tag(DetailContentTab.transcript)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: isCompact ? .infinity : 260)

                Spacer(minLength: 12)

                Button {
                    if selectedTab == .summary {
                        store.copySummary(for: recording)
                    } else {
                        store.copyTranscript(for: recording)
                    }
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
            }

            Text(activeNotesText)
                .font(.system(size: 14))
                .foregroundStyle(activeNotesIsFallback ? AppTheme.secondaryText : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(isCompact ? 16 : 18)
                .background(AppTheme.subtleFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .padding(isCompact ? 16 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appPanel(cornerRadius: 26)
    }

    private func metadataSection(isCompact: Bool) -> some View {
        DisclosureGroup("Details", isExpanded: $isMetadataExpanded) {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(minimum: isCompact ? 140 : 180), spacing: 14, alignment: .leading),
                    GridItem(.flexible(minimum: isCompact ? 140 : 180), spacing: 14, alignment: .leading)
                ],
                alignment: .leading,
                spacing: 14
            ) {
                metadataItem(title: "Created", value: recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                metadataItem(title: "Duration", value: recording.durationLabel)
                metadataItem(title: "Capture Mode", value: recording.captureModeLabel)
                metadataItem(title: "Transcript Source", value: recording.transcriptSourceLabel)
                metadataItem(title: "State", value: recording.lifecycleState.label)
                metadataItem(title: "Recording ID", value: recording.id.uuidString.uppercased())
                metadataItem(title: "Mic Track", value: stateLabel(for: recording.microphoneState))
                metadataItem(title: "System Track", value: stateLabel(for: recording.systemAudioState))
                metadataItem(title: "Merge Track", value: mergeTrackLabel)
                metadataItem(title: "Capture Note", value: recording.notes)
            }
            .padding(.top, 14)
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.primary)
        .padding(isCompact ? 16 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appPanel(cornerRadius: 26)
    }

    private var sourceSelector: some View {
        HStack(spacing: 8) {
            ForEach(store.playbackState.sourceAvailability) { option in
                Button {
                    store.selectPlaybackSource(option.source, for: recording)
                } label: {
                    HStack(spacing: 6) {
                        Text(option.source.label)
                        if option.source == .mixed && option.isProcessing {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(option.source == store.playbackState.selectedSource ? .primary : AppTheme.secondaryText)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(
                        (option.source == store.playbackState.selectedSource ? AppTheme.selectionFill : AppTheme.panelFill),
                        in: Capsule(style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!option.isAvailable || store.isRecording)
            }
        }
    }

    private var playbackRateMenu: some View {
        Menu {
            ForEach(PlaybackState.supportedPlaybackRates, id: \.self) { rate in
                Button(playbackRateLabel(for: rate)) {
                    store.setPlaybackRate(rate, for: recording)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "speedometer")
                Text(store.playbackState.playbackRateLabel)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(AppTheme.panelFill, in: Capsule(style: .continuous))
        }
        .menuStyle(.button)
    }

    private var hasTranscript: Bool {
        recording.hasSummarizationSource || store.transcriptText(for: recording) != nil
    }

    private var mergeTrackLabel: String {
        if recording.source == .importedAudio {
            return "Not used"
        }
        if recording.isMixedTrackProcessing {
            return "Processing"
        }
        return recording.assets.mergedCallFile == nil ? "Missing" : "Captured"
    }

    private var activeNotesText: String {
        switch selectedTab {
        case .summary:
            return store.summaryText(for: recording) ?? recording.summaryPreviewFallback
        case .transcript:
            return store.transcriptText(for: recording) ?? recording.transcriptPreviewFallback
        }
    }

    private var activeNotesIsFallback: Bool {
        switch selectedTab {
        case .summary:
            return store.summaryText(for: recording) == nil
        case .transcript:
            return store.transcriptText(for: recording) == nil
        }
    }

    private var clusterDivider: some View {
        Rectangle()
            .fill(AppTheme.hairline)
            .frame(width: 1, height: 24)
            .padding(.vertical, 14)
    }

    private var playbackProgressBinding: Binding<Double> {
        Binding(
            get: { store.playbackState.progress },
            set: { newValue in
                store.seekPlayback(for: recording, to: newValue)
            }
        )
    }

    private func clusterButton(
        systemImage: String,
        tint: Color = .white,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            clusterIcon(systemImage: systemImage, tint: tint)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.35 : 1)
    }

    private func clusterIcon(systemImage: String, tint: Color = .white) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 46, height: 46)
            .contentShape(Circle())
    }

    private func heroMetaText(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(AppTheme.secondaryText)
            .monospacedDigit()
    }

    private func transportButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 64, height: 64)
                .background(AppTheme.panelFill, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!store.playbackState.isAvailable || store.isRecording)
    }

    private func secondaryActionButton(
        title: String,
        systemImage: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(AppTheme.panelFill, in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.35 : 1)
    }

    private func progressCard(title: String, detail: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)
            }

            ProgressView(value: value, total: 1)
                .tint(AppTheme.accent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appPanel(cornerRadius: 24)
    }

    private func metadataItem(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.secondaryText)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stateLabel(for state: RecordingSourceState) -> String {
        switch state {
        case .live:
            return "Listening"
        case .recorded:
            return "Captured"
        case .stub:
            return "Stub"
        case .missing:
            return "Missing"
        }
    }

    private func playbackRateLabel(for rate: Float) -> String {
        if rate == floor(rate) {
            return String(format: "%.0fx", rate)
        }

        return String(format: "%.2gx", rate)
    }

    private func applyRename() {
        let updatedTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if updatedTitle.isEmpty {
            draftTitle = recording.title
            isEditingTitle = false
            isTitleFieldFocused = false
            return
        }

        store.renameSelectedRecording(to: updatedTitle)
        draftTitle = updatedTitle
        isEditingTitle = false
        isTitleFieldFocused = false
    }
}

private struct WrappingHStack: Layout {
    let maxWidth: CGFloat
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    init(maxWidth: CGFloat, horizontalSpacing: CGFloat = 8, verticalSpacing: CGFloat = 8) {
        self.maxWidth = maxWidth
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrangeRows(in: proposal.width ?? maxWidth, subviews: subviews)
        return CGSize(width: proposal.width ?? maxWidth, height: rows.totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrangeRows(in: bounds.width, subviews: subviews)
        var y = bounds.minY

        for row in rows.items {
            var x = bounds.minX
            for (index, item) in row.enumerated() {
                let size = item.size
                item.subview.place(
                    at: CGPoint(x: x, y: y + (rows.rowHeight[item.id] ?? size.height) / 2),
                    anchor: .leading,
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
                x += size.width
                if index < row.count - 1 {
                    x += horizontalSpacing
                }
            }
            y += (rows.rowHeight[row.first?.id ?? 0] ?? 0) + verticalSpacing
        }
    }

    private func arrangeRows(in availableWidth: CGFloat, subviews: Subviews) -> (items: [[Item]], rowHeight: [Int: CGFloat], totalHeight: CGFloat) {
        let effectiveWidth = max(availableWidth, 1)
        var rows: [[Item]] = []
        var rowHeights: [Int: CGFloat] = [:]
        var currentRow: [Item] = []
        var currentRowWidth: CGFloat = 0
        var rowIndex = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let spacedWidth = currentRow.isEmpty ? size.width : size.width + horizontalSpacing

            if currentRowWidth + spacedWidth > effectiveWidth, !currentRow.isEmpty {
                rows.append(currentRow)
                rowIndex += 1
                currentRow = []
                currentRowWidth = 0
            }

            currentRow.append(Item(id: rowIndex, subview: subview, size: size))
            currentRowWidth += currentRow.count == 1 ? size.width : size.width + horizontalSpacing
            rowHeights[rowIndex] = max(rowHeights[rowIndex] ?? 0, size.height)
        }

        if !currentRow.isEmpty {
            rows.append(currentRow)
        }

        let totalHeight = rows.enumerated().reduce(CGFloat(0)) { partial, item in
            let (index, _) = item
            let height = rowHeights[index] ?? 0
            if index == 0 { return partial + height }
            return partial + verticalSpacing + height
        }

        return (rows, rowHeights, totalHeight)
    }

    private struct Item {
        let id: Int
        let subview: LayoutSubview
        let size: CGSize
    }
}
