import AppKit
import SwiftUI

final class AppTerminationCoordinator: NSObject, NSApplicationDelegate {
    weak var recordingsStore: RecordingsStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let recordingsStore, recordingsStore.isRecording else {
            return .terminateNow
        }

        Task { @MainActor in
            await recordingsStore.finalizeActiveRecordingBeforeTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }
}

@main
struct RecordlyApp: App {
    @NSApplicationDelegateAdaptor(AppTerminationCoordinator.self) private var terminationCoordinator
    @StateObject private var recordingsStore: RecordingsStore

    init() {
        let modelManager = ModelManager()
        let fluidAudioModelProvider = FluidAudioModelProvider()
        let composition = DefaultInferenceComposition.make(
            modelManager: modelManager,
            fluidAudioModelProvider: fluidAudioModelProvider
        )
        let pipeline = TranscriptionPipeline()
        _recordingsStore = StateObject(
            wrappedValue: RecordingsStore(
                audioCaptureEngine: composition.audioCaptureEngine,
                transcriptionPipeline: pipeline,
                runtimeProfileSelector: composition.runtimeProfileSelector,
                inferenceEngineFactory: composition.engineFactory,
                transcriptionEngineDisplayName: composition.transcriptionEngineDisplayName,
                modelManager: modelManager,
                fluidAudioModelProvider: fluidAudioModelProvider
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(recordingsStore)
                .frame(minWidth: 800, minHeight: 600)
                .onAppear {
                    terminationCoordinator.recordingsStore = recordingsStore
                }
        }
        .commands {
            SidebarCommands()
            CommandGroup(after: .newItem) {
                Button("Import Audio") {
                    Task {
                        await recordingsStore.importAudio()
                    }
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Button(recordingsStore.isRecording ? "Stop Recording" : "Start Recording") {
                    Task {
                        if recordingsStore.isRecording {
                            await recordingsStore.endRecording()
                        } else {
                            await recordingsStore.beginRecording()
                        }
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Delete Recording") {
                    recordingsStore.deleteSelectedRecording()
                }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(recordingsStore.selectedRecording == nil || recordingsStore.viewState.runtime.isRecording)
            }
        }
    }
}
