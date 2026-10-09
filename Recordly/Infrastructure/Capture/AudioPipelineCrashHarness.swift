#if DEBUG
import AVFoundation
import Darwin
import Foundation

/// A child-process fixture executes real writers and dies without app finalization.
/// Debug-only entry point; invoked before application dependencies or UI initialize.
enum AudioPipelineCrashHarness {
    static func runIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["RECORDLY_CRASH_FIXTURE_DIRECTORY"],
              let point = environment["RECORDLY_CRASH_FIXTURE_POINT"],
              let id = UUID(uuidString: environment["RECORDLY_CRASH_FIXTURE_ID"] ?? "") else { return }
        Task.detached {
            do {
                let root = URL(fileURLWithPath: path)
                var store = SessionAudioStore(directory: root, sessionID: id, hostTimeOrigin: 100)
                try store.save(SessionAudioManifest(sessionID: id, hostTimeOrigin: 100))
                let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
                buffer.frameLength = 4_800
                buffer.floatChannelData![0].initialize(repeating: 0.1, count: 4_800)
                if point == "rotation-handoff" {
                    let recoveryStore = store
                    store.faultInjector = { location in
                        if location == point, (try? recoveryStore.load().segments.count) ?? 0 > 0 { kill(getpid(), SIGKILL) }
                    }
                    let writer = SegmentedTrackWriter(kind: .system, store: store, committer: SessionAudioCommitter(store: store), chunkDuration: 0.1)
                    try await writer.append(pcmBuffer: buffer, presentationTime: CMTime(seconds: 100, preferredTimescale: 48_000))
                    try await writer.append(pcmBuffer: buffer, presentationTime: CMTime(seconds: 100.1, preferredTimescale: 48_000))
                    for _ in 0..<200 {
                        if (try? store.load().segments.count) ?? 0 > 0 { break }
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                    try await writer.append(pcmBuffer: buffer, presentationTime: CMTime(seconds: 100.2, preferredTimescale: 48_000))
                    exit(78)
                }
                for index in 0..<2 {
                    var chunk = SessionAudioSegment(track: .system, index: index, startFrame: Int64(index * 4_800))
                    try store.prepare(chunk)
                    let writer = try PCMTrackWriter(kind: .system, fileName: chunk.fileName, fileURL: store.pendingURL(for: chunk))
                    try await writer.append(pcmBuffer: buffer, presentationTime: CMTime(seconds: 100 + Double(index) * 0.1, preferredTimescale: 48_000))
                    if index == 1, point == "active-write" { kill(getpid(), SIGKILL) }
                    let stats = await writer.finalize()
                    chunk.frameCount = stats.framesWritten
                    if index == 1 {
                        store.faultInjector = { location in if location == point { kill(getpid(), SIGKILL) } }
                    }
                    try store.publish(chunk)
                }
                exit(78)
            } catch { exit(79) }
        }
        // The fixture never returns; its child process must die at a named hook.
        DispatchSemaphore(value: 0).wait()
    }
}
#endif
