import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: RecordingsStore

    var body: some View {
        NavigationSplitView {
            RecordingSidebarView()
        } detail: {
            Group {
                if let recording = store.selectedRecording {
                    RecordingDetailView(recording: recording)
                } else {
                    EmptyRecordingView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 380)
        .alert("Action Failed", isPresented: errorBinding) {
            Button("OK", role: .cancel) {
                store.dismissError()
            }
        } message: {
            Text(store.viewState.alert?.message ?? "")
        }
        .sheet(isPresented: onboardingBinding) {
            ModelOnboardingView(
                coordinator: store.modelOnboardingCoordinator,
                modelManager: store.modelManagerProxy
            )
        }
        .sheet(isPresented: $store.isModelsSheetPresented) {
            ModelSettingsView(viewModel: store.modelSettingsViewModelProxy)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Models") {
                    store.isModelsSheetPresented = true
                }
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.viewState.alert != nil },
            set: { newValue in
                if !newValue {
                    store.dismissError()
                }
            }
        )
    }

    private var onboardingBinding: Binding<Bool> {
        Binding(
            get: { store.modelOnboardingCoordinator.isPresented },
            set: { newValue in
                if !newValue {
                    store.modelOnboardingCoordinator.dismiss()
                }
            }
        )
    }
}

#Preview {
    ContentView()
        .environmentObject(RecordingsStore(previewMode: true))
}
