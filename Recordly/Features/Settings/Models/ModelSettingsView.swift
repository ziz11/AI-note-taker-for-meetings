import SwiftUI
import AppKit

struct ModelSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: ModelSettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Models")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button("Close") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }

                Text("Select local models directly from your model folders. No hardcoded profile switching.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Transcription Backend")
                        .font(.headline)
                    Text("Choose the ASR engine while keeping the same transcription pipeline.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Transcription Backend", selection: Binding(
                        get: { viewModel.selectedASRBackend },
                        set: { viewModel.selectASRBackend($0) }
                    )) {
                        ForEach(ASRBackend.allCases, id: \.self) { backend in
                            Text(backend.displayName).tag(backend)
                        }
                    }
                    .pickerStyle(.segmented)

                    if viewModel.selectedASRBackend == .fluidAudio {
                        Text("FluidAudio uses SDK-managed multilingual v3 provisioning. Local ASR file picking is not required.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )

                if viewModel.selectedASRBackend == .whisperCpp {
                    modelPickerCard(
                        title: "Transcription Model",
                        subtitle: "Required for speech-to-text pipeline.",
                        options: viewModel.asrModels,
                        selection: Binding(
                            get: { viewModel.selectedASRModelID },
                            set: { viewModel.selectASRModel($0) }
                        ),
                        kind: .asr,
                        allowsNone: false
                    )
                } else {
                    fluidAudioProvisioningCard
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Transcription Language")
                        .font(.headline)
                    Text("Controls language hint for ASR decoding.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if viewModel.isASRLanguageEditable {
                        Picker("Transcription Language", selection: Binding(
                            get: { viewModel.selectedASRLanguage },
                            set: { viewModel.selectASRLanguage($0) }
                        )) {
                            ForEach(ASRLanguage.allCases, id: \.self) { language in
                                Text(language.displayName).tag(language)
                            }
                        }
                        .pickerStyle(.segmented)
                    } else {
                        Text("Language override is disabled for FluidAudio (multilingual v3).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )

                modelPickerCard(
                    title: "Speaker Separation Model",
                    subtitle: "Optional. Improves remote speaker labeling.",
                    options: viewModel.diarizationModels,
                    selection: Binding(
                        get: { viewModel.selectedDiarizationModelID },
                        set: { viewModel.selectDiarizationModel($0) }
                    ),
                    kind: .diarization,
                    allowsNone: true
                )

                modelPickerCard(
                    title: "Summarization Model",
                    subtitle: "Used by local summarization via llama.cpp-compatible CLI binaries.",
                    options: viewModel.summarizationModels,
                    selection: Binding(
                        get: { viewModel.selectedSummarizationModelID },
                        set: { viewModel.selectSummarizationModel($0) }
                    ),
                    kind: .summarization,
                    allowsNone: true
                )
            }
            .padding(18)
        }
        .frame(minWidth: 820, minHeight: 460)
        .onAppear { viewModel.refresh() }
    }


    private var fluidAudioProvisioningCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FluidAudio Model")
                .font(.headline)
            Text("FluidAudio uses SDK-managed provisioning (v3). Download once, then transcribe immediately.")
                .font(.caption)
                .foregroundStyle(.secondary)

            switch viewModel.fluidProvisioningState {
            case .ready:
                Text("FluidAudio v3 model is installed and ready.")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .needsDownload:
                Text("No FluidAudio model installed.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .downloading:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading FluidAudio v3 model...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text("Download failed: \(message)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button("Download FluidAudio v3 Model") {
                viewModel.downloadFluidAudioModel()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canDownloadFluidModel)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    private func modelPickerCard(
        title: String,
        subtitle: String,
        options: [LocalModelOption],
        selection: Binding<String?>,
        kind: ModelKind,
        allowsNone: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker(title, selection: selection) {
                if allowsNone {
                    Text("Not Selected").tag(String?.none)
                }

                ForEach(options) { option in
                    Text(viewModel.modelLabel(for: option)).tag(String?.some(option.id))
                }
            }
            .pickerStyle(.menu)

            if let selected = options.first(where: { $0.id == selection.wrappedValue }) {
                Text("Selected: \(selected.url.lastPathComponent) • \(viewModel.sourceLabel(selected.source))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if options.isEmpty {
                if kind == .asr {
                    Text("No compatible WhisperCpp .bin models found.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("No compatible model files found in configured folders.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                if let shared = viewModel.folderURL(for: kind, source: .shared) {
                    Button("Open Shared Folder") {
                        NSWorkspace.shared.open(shared)
                    }
                    .buttonStyle(.bordered)
                }

                if let appSupport = viewModel.folderURL(for: kind, source: .appSupport) {
                    Button("Open App Support Folder") {
                        NSWorkspace.shared.open(appSupport)
                    }
                    .buttonStyle(.bordered)
                }

                if let userLocal = viewModel.folderURL(for: kind, source: .userLocal) {
                    Button("Open User Folder") {
                        NSWorkspace.shared.open(userLocal)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }
}
