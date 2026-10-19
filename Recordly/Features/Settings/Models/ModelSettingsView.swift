import SwiftUI

struct ModelSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: ModelSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Models").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close models")
                .keyboardShortcut(.cancelAction)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Transcription").font(.system(size: 11)).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.speechModels.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider() }
                        speechRow(row)
                    }
                }
                .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(AppTheme.hairline))
                if let error = viewModel.modelActionError {
                    errorText(error)
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Speaker separation")
                    Spacer(minLength: 8)
                    diarizationStatus
                }
                if case let .failed(message) = viewModel.fluidDiarizationProvisioningState {
                    errorText(message)
                }
            }

            if !viewModel.localASRModels.isEmpty {
                DisclosureGroup("Other local files (\(viewModel.localASRModels.count))") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(viewModel.localASRModels) { model in
                                Text(model.title)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .foregroundStyle(.secondary)
                                    .help("Not supported by the current transcription engine")
                            }
                        }
                        .font(.system(size: 11))
                    }
                    .frame(height: min(CGFloat(viewModel.localASRModels.count) * 20, 100))
                    .padding(.top, 4)
                }
                .font(.system(size: 11))
            }

            Text("Processing stays on this Mac.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .padding(20)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .background(AppTheme.contentBackground)
        .onAppear {
            viewModel.refresh()
            viewModel.consumeDiarizationSectionFocusRequest()
        }
        .onChange(of: viewModel.shouldScrollToDiarizationSection) { requested in
            // Both stages are visible in the compact panel; scrolling is unnecessary.
            if requested { viewModel.consumeDiarizationSectionFocusRequest() }
        }
        .onDisappear { viewModel.consumeDiarizationSectionFocusRequest() }
    }

    private func speechRow(_ row: ModelSettingsViewModel.SpeechModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { viewModel.selectSpeechModel(row.model) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: row.isSelected ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 13))
                            .foregroundStyle(row.isSelected ? Color.accentColor : Color.secondary)
                        Text(row.model.title).foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(row.state != .ready)
                .accessibilityLabel("Use \(row.model.title)")
                .accessibilityValue(row.isSelected ? "Selected" : "Not selected")
                .help("\(row.model.estimatedSize) · FluidAudio / Core ML · Used for the next transcription")
                speechAction(row)
            }
            if row.state == .downloading {
                VStack(alignment: .leading, spacing: 4) {
                    if let progress = row.progress {
                        ProgressView(value: progress.fraction).progressViewStyle(.linear)
                        Text(progress.detail)
                    } else {
                        Text("Preparing download…")
                    }
                    Text("Current file progress").foregroundStyle(.tertiary)
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
            }
            if case let .failed(message) = row.state {
                errorText(message).padding(.leading, 20)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func speechAction(_ row: ModelSettingsViewModel.SpeechModel) -> some View {
        switch row.state {
        case .ready:
            if !row.isSelected {
                Button(role: .destructive) { viewModel.removeSpeechModel(row.model) } label: {
                    Image(systemName: "trash").font(.system(size: 11))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isDownloadingAnySpeechModel)
                .help("Remove \(row.model.title)")
                .accessibilityLabel("Remove \(row.model.title)")
            }
        case .needsDownload, .failed:
            Button(downloadLabel(row.state)) { viewModel.downloadSpeechModel(row.model) }
                .disabled(viewModel.isDownloadingAnySpeechModel)
        case .downloading:
            ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                .accessibilityLabel("Downloading \(row.model.title)")
        }
    }

    @ViewBuilder
    private var diarizationStatus: some View {
        switch viewModel.fluidDiarizationProvisioningState {
        case .ready:
            Text("Ready").foregroundStyle(.secondary)
        case .needsDownload, .failed:
            Button(downloadLabel(viewModel.fluidDiarizationProvisioningState)) {
                viewModel.downloadFluidDiarizationModel()
            }
            .disabled(!viewModel.canDownloadFluidDiarizationModel)
        case .downloading:
            ProgressView().controlSize(.mini).frame(width: 12, height: 12)
            Text("Downloading…").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func errorText(_ message: String) -> some View {
        Text(message).font(.system(size: 10)).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func downloadLabel(_ state: FluidAudioModelProvisioningState) -> String {
        if case .failed = state { return "Retry" }
        return "Download"
    }
}
