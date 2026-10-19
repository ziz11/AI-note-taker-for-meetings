import Foundation

struct CaptureFinalizationResult {
    var tracks: [TrackRuntimeStats] = []
    var persistenceDiagnostics: [String] = []
}

enum CaptureFinalizationCoordinator {
    /// Persistence failure must never bypass source shutdown or another writer's close.
    static func finish(stopSources: () async -> Void, drainSources: () async -> Void,
                       beginMetadata: () async throws -> Void, writers: [MirroredTrackWriter],
                       updateMetadata: (TrackRuntimeStats) async throws -> Void) async -> CaptureFinalizationResult {
        await stopSources()
        var result = CaptureFinalizationResult()
        do { try await beginMetadata() }
        catch { result.persistenceDiagnostics.append("Finalization metadata failed: \(error.localizedDescription)") }
        await drainSources()
        for writer in writers {
            let tracks = await writer.finalize()
            result.tracks += tracks
            for track in tracks {
                do { try await updateMetadata(track) }
                catch { result.persistenceDiagnostics.append("\(track.kind.rawValue) metadata failed: \(error.localizedDescription)") }
            }
        }
        return result
    }
}
