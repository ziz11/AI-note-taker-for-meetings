import AppKit
import SwiftUI

struct ModelSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: ModelSettingsViewModel

    var body: some View {
        ZStack {
            AppTheme.contentBackground
                .ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header

                        sectionHeader(
                            eyebrow: "Dictation Models",
                            title: "Local transcription and speaker tools",
                            subtitle: "Featured dictation and shared catalogs in one place."
                        )
                        fluidAudioFeaturedCard

                        if !viewModel.localASRModels.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Custom Local ASR")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.primary)

                                ForEach(viewModel.localASRModels) { model in
                                    catalogRow(model: model, actionTitle: nil) {}
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            sectionHeader(
                                eyebrow: "Speaker Separation",
                                title: "FluidAudio diarization",
                                subtitle: "Provision once through the SDK to enable local speaker separation."
                            )
                            fluidAudioDiarizationCard
                        }
                        .id("fluidAudioDiarizationSection")

                        sectionHeader(
                            eyebrow: "Summarization",
                            title: "Local summary models",
                            subtitle: "Choose the local model used for summary generation."
                        )

                        if viewModel.summarizationCatalogModels.isEmpty {
                            emptyStateCard(
                                title: "No summarization models discovered",
                                subtitle: "Add compatible `.gguf` or `.bin` files to a summarization models folder to use local summaries."
                            )
                        } else {
                            VStack(spacing: 10) {
                                ForEach(viewModel.summarizationCatalogModels) { model in
                                    catalogRow(
                                        model: model,
                                        actionTitle: model.isSelected ? "Now Using" : "Use Model",
                                        actionProminent: !model.isSelected
                                    ) {
                                        guard !model.isSelected else { return }
                                        viewModel.selectSummarizationModel(model.id)
                                    }
                                }
                            }
                        }

                        folderActions
                    }
                    .padding(14)
                }
                .onAppear {
                    viewModel.refresh()
                    if viewModel.shouldScrollToDiarizationSection {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo("fluidAudioDiarizationSection", anchor: .top)
                        }
                        viewModel.consumeDiarizationSectionFocusRequest()
                    }
                }
                .onChange(of: viewModel.shouldScrollToDiarizationSection) { shouldScroll in
                    guard shouldScroll else {
                        return
                    }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo("fluidAudioDiarizationSection", anchor: .top)
                    }
                    viewModel.consumeDiarizationSectionFocusRequest()
                }
                .onDisappear {
                    viewModel.consumeDiarizationSectionFocusRequest()
                }
            }
        }
        .frame(minWidth: 960, minHeight: 680)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Models")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Text("Catalog view for on-device dictation, speaker separation, and summarization.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
                    .background(AppTheme.panelFill, in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var fluidAudioFeaturedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                modelGlyph(systemName: "waveform.badge.magnifyingglass", tint: Color.blue)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center, spacing: 8) {
                        Text("FluidAudio v3")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)

                        capsule("Featured", tint: Color.blue)
                        capsule("Multilingual", tint: Color.teal)
                        capsule("SDK Managed", tint: Color.orange)
                    }

                    Text("Primary on-device dictation engine powered by FluidAudio SDK. Download once, then transcribe locally.")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    WrapHStack(spacing: 8, lineSpacing: 8) {
                        statChip("ASR")
                        statChip("Local")
                        statChip(fluidStatusLabel(viewModel.fluidProvisioningState))
                    }
                }

                Spacer()

                Button(viewModel.isFluidModelReady ? "Ready" : "Download") {
                    viewModel.downloadFluidAudioModel()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!viewModel.canDownloadFluidModel)
            }

            statusMessage(for: viewModel.fluidProvisioningState, noun: "FluidAudio v3 model")
        }
        .padding(14)
        .appPanel(selected: viewModel.isFluidModelReady, prominent: true, cornerRadius: 20)
    }

    private var fluidAudioDiarizationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                modelGlyph(systemName: "person.2.wave.2.fill", tint: Color.orange)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center, spacing: 8) {
                        Text("FluidAudio Speaker Separation")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.primary)

                        capsule("SDK managed", tint: Color.orange)
                        if viewModel.isFluidDiarizationModelReady {
                            capsule("Ready", tint: Color.green)
                        }
                    }

                    Text("SDK-managed diarization package used for local speaker separation.")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    WrapHStack(spacing: 8, lineSpacing: 8) {
                        statChip("Diarization")
                        statChip("Local")
                        statChip(fluidStatusLabel(viewModel.fluidDiarizationProvisioningState))
                    }
                }

                Spacer()

                Button(viewModel.isFluidDiarizationModelReady ? "Ready" : "Download speaker separation") {
                    viewModel.downloadFluidDiarizationModel()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!viewModel.canDownloadFluidDiarizationModel)
            }

            statusMessage(for: viewModel.fluidDiarizationProvisioningState, noun: "FluidAudio diarization package")
        }
        .padding(14)
        .appPanel(selected: viewModel.isFluidDiarizationModelReady, prominent: true, cornerRadius: 20)
    }

    private var folderActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model Folders")
                .font(.headline)
                .foregroundStyle(.primary)

            HStack(spacing: 8) {
                folderButton(title: "Open Summaries Folder", url: viewModel.folderURL(for: .summarization, source: .userLocal))
                folderButton(title: "Open Shared Folder", url: viewModel.folderURL(for: .summarization, source: .shared))
                folderButton(title: "Open App Support Folder", url: viewModel.folderURL(for: .summarization, source: .appSupport))
            }
        }
    }

    private func sectionHeader(eyebrow: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.accent)

            Text(title)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(AppTheme.secondaryText)
        }
    }

    private func catalogRow(
        model: ModelSettingsViewModel.CatalogModel,
        actionTitle: String?,
        actionProminent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            modelGlyph(systemName: glyph(for: model.kind), tint: tint(for: model.kind), compact: true)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(model.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if model.isSelected {
                        capsule("Now Using", tint: Color.blue, compact: true)
                    }
                    capsule(model.sourceLabel, tint: Color.white.opacity(0.18), compact: true)

                    Spacer(minLength: 8)

                    if let actionTitle {
                        if actionProminent {
                            Button(actionTitle, action: action)
                                .buttonStyle(.borderedProminent)
                                .controlSize(.mini)
                                .disabled(!model.supportsSelection || model.isSelected)
                        } else {
                            Button(actionTitle, action: action)
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                .disabled(!model.supportsSelection || model.isSelected)
                        }
                    }
                }

                Text(model.subtitle)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)

                WrapHStack(spacing: 8, lineSpacing: 8) {
                    ForEach(model.metadata, id: \.self) { item in
                        statChip(item, compact: true)
                    }
                }

                if let footnote = model.footnote {
                    Text(footnote)
                        .font(.caption)
                        .foregroundStyle(AppTheme.tertiaryText)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(12)
        .appPanel(selected: model.isSelected, cornerRadius: 18)
    }

    private func emptyStateCard(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(AppTheme.secondaryText)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appPanel(cornerRadius: 18)
    }

    private func folderButton(title: String, url: URL?) -> some View {
        Button(title) {
            guard let url else { return }
            NSWorkspace.shared.open(url)
        }
        .buttonStyle(.bordered)
        .disabled(url == nil)
    }

    private func fluidStatusLabel(_ state: FluidAudioModelProvisioningState) -> String {
        switch state {
        case .ready:
            return "Ready"
        case .needsDownload:
            return "Needs Download"
        case .downloading:
            return "Downloading"
        case .failed:
            return "Failed"
        }
    }

    @ViewBuilder
    private func statusMessage(for state: FluidAudioModelProvisioningState, noun: String) -> some View {
        switch state {
        case .ready:
            Text("\(noun) is installed and ready.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.green.opacity(0.95))
        case .needsDownload:
            Text("\(noun) is not installed yet.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.orange.opacity(0.95))
        case .downloading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Downloading \(noun.lowercased())...")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
            }
        case .failed(let message):
            Text("Download failed: \(message)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.red.opacity(0.92))
        }
    }

    private func glyph(for kind: ModelKind) -> String {
        switch kind {
        case .asr:
            return "waveform"
        case .diarization:
            return "person.2.wave.2"
        case .summarization:
            return "text.quote"
        }
    }

    private func tint(for kind: ModelKind) -> Color {
        switch kind {
        case .asr:
            return .blue
        case .diarization:
            return .orange
        case .summarization:
            return .teal
        }
    }

    private func modelGlyph(systemName: String, tint: Color, compact: Bool = false) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: compact ? 14 : 18, style: .continuous)
                .fill(tint.opacity(0.12))
                .frame(width: compact ? 44 : 64, height: compact ? 44 : 64)

            Image(systemName: systemName)
                .font(.system(size: compact ? 18 : 24, weight: .semibold))
                .foregroundStyle(tint.opacity(0.95))
        }
    }

    private func capsule(_ text: String, tint: Color, compact: Bool = false) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .foregroundStyle(.primary)
            .padding(.horizontal, compact ? 10 : 12)
            .padding(.vertical, compact ? 4 : 6)
            .background(tint, in: Capsule())
    }

    private func statChip(_ text: String, compact: Bool = false) -> some View {
        Text(text)
            .font((compact ? Font.caption : Font.subheadline).weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, compact ? 10 : 12)
            .padding(.vertical, compact ? 6 : 8)
            .background(AppTheme.panelFill, in: Capsule())
    }
}

private struct WrapHStack<Content: View>: View {
    let spacing: CGFloat
    let lineSpacing: CGFloat
    let content: Content

    init(
        spacing: CGFloat = 8,
        lineSpacing: CGFloat = 8,
        @ViewBuilder content: () -> Content
    ) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
        self.content = content()
    }

    var body: some View {
        _WrapHStackLayout(spacing: spacing, lineSpacing: lineSpacing) {
            content
        }
    }
}

private struct _WrapHStackLayout: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let rows = arrangeRows(in: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + max(CGFloat(rows.count - 1), 0) * lineSpacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = arrangeRows(in: bounds.width, subviews: subviews)
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX
            for element in row.elements {
                subviews[element.index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(width: element.size.width, height: element.size.height)
                )
                x += element.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private func arrangeRows(in availableWidth: CGFloat, subviews: Subviews) -> [Row] {
        let maxWidth = availableWidth.isFinite ? availableWidth : .greatestFiniteMagnitude
        var rows: [Row] = []
        var current = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let nextWidth = current.elements.isEmpty ? size.width : current.width + spacing + size.width

            if !current.elements.isEmpty, nextWidth > maxWidth {
                rows.append(current)
                current = Row()
            }

            current.elements.append(Row.Element(index: index, size: size))
            current.width = current.elements.count == 1 ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
        }

        if !current.elements.isEmpty {
            rows.append(current)
        }

        return rows
    }

    private struct Row {
        struct Element {
            let index: Int
            let size: CGSize
        }

        var elements: [Element] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }
}
