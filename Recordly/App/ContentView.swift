import SwiftUI

enum AppTheme {
    static let accent = Color.accentColor
    static let sidebarBackground = Color(nsColor: .underPageBackgroundColor)
    static let contentBackground = Color(nsColor: .windowBackgroundColor)
    static let panelFill = Color(nsColor: .controlBackgroundColor).opacity(0.72)
    static let elevatedPanelFill = Color(nsColor: .controlBackgroundColor).opacity(0.9)
    static let subtleFill = Color.primary.opacity(0.05)
    static let selectionFill = accent.opacity(0.18)
    static let hairline = Color.primary.opacity(0.10)
    static let strongHairline = Color.primary.opacity(0.16)
    static let secondaryText = Color.secondary
    static let tertiaryText = Color.secondary.opacity(0.78)
}

struct AppPanelModifier: ViewModifier {
    let selected: Bool
    let prominent: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(background, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(selected ? AppTheme.strongHairline : AppTheme.hairline, lineWidth: selected ? 1.5 : 1)
            )
    }

    private var background: some ShapeStyle {
        if selected {
            return AnyShapeStyle(AppTheme.selectionFill)
        }
        if prominent {
            return AnyShapeStyle(AppTheme.elevatedPanelFill)
        }
        return AnyShapeStyle(AppTheme.panelFill)
    }
}

extension View {
    func appPanel(
        selected: Bool = false,
        prominent: Bool = false,
        cornerRadius: CGFloat = 20
    ) -> some View {
        modifier(AppPanelModifier(selected: selected, prominent: prominent, cornerRadius: cornerRadius))
    }
}

enum AdaptiveLayoutMetrics {
    static let compactWindowThreshold: CGFloat = 800
    static let narrowSidebarThreshold: CGFloat = 260

    static func isCompactWindow(_ width: CGFloat) -> Bool {
        width <= compactWindowThreshold
    }

    static func isSidebarNarrow(_ width: CGFloat) -> Bool {
        width < narrowSidebarThreshold
    }
}

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
            .background(AppTheme.contentBackground)
        }
        .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 420)
        .alert("Action Failed", isPresented: errorBinding) {
            if let primaryAction = store.viewState.alert?.primaryAction {
                switch primaryAction {
                case .openModels:
                    Button("Open Models") {
                        store.openModelsFromAlert()
                    }
                }
            }
            Button("OK", role: .cancel) {
                store.dismissError()
            }
        } message: {
            Text(store.viewState.alert?.message ?? "")
        }
        .alert(
            "Resume pending transcriptions?",
            isPresented: recoveryPromptBinding
        ) {
            Button("Resume") {
                store.acknowledgeRecoveryPrompt(shouldResume: true)
            }
            Button("Later", role: .cancel) {
                store.acknowledgeRecoveryPrompt(shouldResume: false)
            }
        } message: {
            Text("Found \(store.pendingRecoveryTranscriptionCount) recordings with unfinished transcriptions from the previous session. Resume them now?")
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

    private var recoveryPromptBinding: Binding<Bool> {
        Binding(
            get: { store.shouldPresentRecoveryPrompt },
            set: { newValue in
                if !newValue {
                    store.acknowledgeRecoveryPrompt(shouldResume: false)
                }
            }
        )
    }
}

#Preview {
    ContentView()
        .environmentObject(RecordingsStore(previewMode: true))
}
