import AppKit
import SwiftUI

struct ModelSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: ModelSettingsViewModel

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.12, blue: 0.16),
                    Color(red: 0.13, green: 0.16, blue: 0.20),
                    Color(red: 0.10, green: 0.12, blue: 0.15)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    sectionHeader(
                        eyebrow: "Dictation Models",
                        title: "Local transcription and speaker tools",
                        subtitle: "FluidAudio is featured first. Custom local ASR and summarization models appear below in the same catalog."
                    )
                    fluidAudioFeaturedCard

                    if !viewModel.localASRModels.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Custom Local ASR")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.95))

                            ForEach(viewModel.localASRModels) { model in
                                catalogRow(model: model, actionTitle: nil) {}
                            }
                        }
                    }

                    sectionHeader(
                        eyebrow: "Speaker Separation",
                        title: "FluidAudio diarization",
                        subtitle: "Provision once through the SDK to enable local speaker separation. Legacy diarization selection remains untouched underneath, but is not surfaced here."
                    )
                    fluidAudioDiarizationCard

                    sectionHeader(
                        eyebrow: "Summarization",
                        title: "Local summary models",
                        subtitle: "Choose the local model used for summary generation. Current runtime behavior stays unchanged."
                    )

                    if viewModel.summarizationCatalogModels.isEmpty {
                        emptyStateCard(
                            title: "No summarization models discovered",
                            subtitle: "Add compatible `.gguf` or `.bin` files to a summarization models folder to use local summaries."
                        )
                    } else {
                        VStack(spacing: 14) {
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
                .padding(24)
            }
        }
        .frame(minWidth: 960, minHeight: 680)
        .onAppear { viewModel.refresh() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Models")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Catalog view for on-device dictation, speaker separation, and summarization.")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.82))
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var fluidAudioFeaturedCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                modelGlyph(systemName: "waveform.badge.magnifyingglass", tint: Color.blue)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 10) {
                        Text("FluidAudio v3")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        capsule("Featured", tint: Color.blue)
                        capsule("Multilingual", tint: Color.teal)
                        capsule("SDK Managed", tint: Color.orange)
                    }

                    Text("Primary on-device dictation engine powered by the FluidAudio SDK. Download once, then transcribe locally without manual model file management.")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.white.opacity(0.82))

                    HStack(spacing: 12) {
                        statChip("ASR")
                        statChip("Local")
                        statChip(fluidStatusLabel(viewModel.fluidProvisioningState))
                    }
                }

                Spacer()
            }

            HStack(alignment: .center) {
                statusMessage(for: viewModel.fluidProvisioningState, noun: "FluidAudio v3 model")

                Spacer()

                Button(viewModel.isFluidModelReady ? "Ready" : "Download") {
                    viewModel.downloadFluidAudioModel()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!viewModel.canDownloadFluidModel)
            }
        }
        .padding(24)
        .background(cardBackground(selected: viewModel.isFluidModelReady))
        .overlay(cardBorder(selected: viewModel.isFluidModelReady))
    }

    private var fluidAudioDiarizationCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                modelGlyph(systemName: "person.2.wave.2.fill", tint: Color.orange)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 10) {
                        Text("FluidAudio Speaker Separation")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)

                        capsule("Provision Card", tint: Color.orange)
                        if viewModel.isFluidDiarizationModelReady {
                            capsule("Ready", tint: Color.green)
                        }
                    }

                    Text("SDK-managed diarization package for local speaker separation. This card reflects provisioning status only and does not alter existing legacy model state.")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.white.opacity(0.78))

                    HStack(spacing: 12) {
                        statChip("Diarization")
                        statChip("Local")
                        statChip(fluidStatusLabel(viewModel.fluidDiarizationProvisioningState))
                    }
                }

                Spacer()
            }

            HStack(alignment: .center) {
                statusMessage(for: viewModel.fluidDiarizationProvisioningState, noun: "FluidAudio diarization package")

                Spacer()

                Button(viewModel.isFluidDiarizationModelReady ? "Ready" : "Download") {
                    viewModel.downloadFluidDiarizationModel()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!viewModel.canDownloadFluidDiarizationModel)
            }
        }
        .padding(24)
        .background(cardBackground(selected: viewModel.isFluidDiarizationModelReady))
        .overlay(cardBorder(selected: viewModel.isFluidDiarizationModelReady))
    }

    private var folderActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model Folders")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.92))

            HStack(spacing: 10) {
                folderButton(title: "Open Summaries Folder", url: viewModel.folderURL(for: .summarization, source: .userLocal))
                folderButton(title: "Open Shared Folder", url: viewModel.folderURL(for: .summarization, source: .shared))
                folderButton(title: "Open App Support Folder", url: viewModel.folderURL(for: .summarization, source: .appSupport))
            }
        }
    }

    private func sectionHeader(eyebrow: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(eyebrow.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.blue.opacity(0.85))

            Text(title)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text(subtitle)
                .font(.body)
                .foregroundStyle(.white.opacity(0.72))
        }
    }

    private func catalogRow(
        model: ModelSettingsViewModel.CatalogModel,
        actionTitle: String?,
        actionProminent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                modelGlyph(systemName: glyph(for: model.kind), tint: tint(for: model.kind))

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 10) {
                        Text(model.title)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)

                        if model.isSelected {
                            capsule("Now Using", tint: Color.blue)
                        }
                        capsule(model.sourceLabel, tint: Color.white.opacity(0.18))
                    }

                    Text(model.subtitle)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.white.opacity(0.76))

                    HStack(spacing: 10) {
                        ForEach(model.metadata, id: \.self) { item in
                            statChip(item)
                        }
                    }

                    if let footnote = model.footnote {
                        Text(footnote)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.50))
                            .lineLimit(2)
                    }
                }

                Spacer()

                if let actionTitle {
                    if actionProminent {
                        Button(actionTitle, action: action)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(!model.supportsSelection || model.isSelected)
                    } else {
                        Button(actionTitle, action: action)
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .disabled(!model.supportsSelection || model.isSelected)
                    }
                }
            }
        }
        .padding(22)
        .background(cardBackground(selected: model.isSelected))
        .overlay(cardBorder(selected: model.isSelected))
    }

    private func emptyStateCard(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.white.opacity(0.72))
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground(selected: false))
        .overlay(cardBorder(selected: false))
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
                .font(.body.weight(.semibold))
                .foregroundStyle(.green.opacity(0.95))
        case .needsDownload:
            Text("\(noun) is not installed yet.")
                .font(.body.weight(.semibold))
                .foregroundStyle(.orange.opacity(0.95))
        case .downloading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Downloading \(noun.lowercased())...")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
            }
        case .failed(let message):
            Text("Download failed: \(message)")
                .font(.body.weight(.semibold))
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

    private func modelGlyph(systemName: String, tint: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(tint.opacity(0.12))
                .frame(width: 82, height: 82)

            Image(systemName: systemName)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(tint.opacity(0.95))
        }
    }

    private func capsule(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(tint, in: Capsule())
    }

    private func statChip(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.86))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.06), in: Capsule())
    }

    private func cardBackground(selected: Bool) -> some ShapeStyle {
        LinearGradient(
            colors: selected
                ? [Color.blue.opacity(0.18), Color.white.opacity(0.04)]
                : [Color.white.opacity(0.05), Color.white.opacity(0.02)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func cardBorder(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .stroke(selected ? Color.blue.opacity(0.90) : Color.white.opacity(0.12), lineWidth: selected ? 2 : 1)
    }
}
