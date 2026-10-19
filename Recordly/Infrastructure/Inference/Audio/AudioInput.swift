import AVFoundation
import Foundation

enum AudioInput: Equatable, Sendable {
    case sessionAsset(fileName: String, channel: TranscriptChannel)
    case absoluteURL(url: URL, channel: TranscriptChannel?)
}

struct PreparedAudioInput: Equatable, Sendable {
    var input: AudioInput
    var url: URL
    var channel: TranscriptChannel?
}

protocol AudioInputAdapter {
    func prepare(_ input: AudioInput, in sessionDirectory: URL) throws -> PreparedAudioInput?
}

protocol AudioInputValidating {
    func isUsable(_ preparedInput: PreparedAudioInput) -> Bool
}

struct AVFoundationAudioInputValidator: AudioInputValidating {
    func isUsable(_ preparedInput: PreparedAudioInput) -> Bool {
        AudioFileProbe.isReadable(preparedInput.url, caller: "AudioInputValidator")
    }
}

/// Central chokepoint for "can this file be opened as audio". Skips files that
/// are missing/empty/non-audio before touching AVAudioFile (opening a mid-write
/// or non-audio file spams CoreAudio errors), and — in debug — logs the caller
/// so runaway probe loops are traceable.
enum AudioFileProbe {
    private static let audioExtensions: Set<String> = ["m4a", "caf", "flac", "wav", "mp3", "aac", "aiff", "aif"]

    static func isReadable(_ url: URL, caller: String) -> Bool {
        guard audioExtensions.contains(url.pathExtension.lowercased()) else {
            return false
        }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
            return false
        }
        #if DEBUG
        AudioFileProbeLog.record(url: url, caller: caller)
        #endif
        guard let file = try? AVAudioFile(forReading: url) else {
            return false
        }
        return file.length > 0
    }
}

#if DEBUG
/// Rate-limited diagnostic: prints how often each caller probes each file so a
/// spinning validator loop shows up as a high count in the console.
enum AudioFileProbeLog {
    private static let lock = NSLock()
    private static var counts: [String: Int] = [:]
    private static var lastFlush = Date()

    static func record(url: URL, caller: String) {
        lock.lock()
        let key = "\(caller) → \(url.lastPathComponent)"
        counts[key, default: 0] += 1
        let now = Date()
        let shouldFlush = now.timeIntervalSince(lastFlush) >= 2
        let snapshot = shouldFlush ? counts : nil
        if shouldFlush {
            counts.removeAll()
            lastFlush = now
        }
        lock.unlock()

        if let snapshot, !snapshot.isEmpty {
            let summary = snapshot.sorted { $0.value > $1.value }
                .map { "\($0.value)× \($0.key)" }
                .joined(separator: ", ")
            print("[AudioFileProbe] last 2s: \(summary)")
        }
    }
}
#endif

struct PassthroughAudioInputAdapter: AudioInputAdapter {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func prepare(_ input: AudioInput, in sessionDirectory: URL) throws -> PreparedAudioInput? {
        switch input {
        case let .sessionAsset(fileName, channel):
            let url = sessionDirectory.appendingPathComponent(fileName)
            guard fileManager.fileExists(atPath: url.path) else {
                return nil
            }
            return PreparedAudioInput(input: input, url: url, channel: channel)
        case let .absoluteURL(url, channel):
            guard fileManager.fileExists(atPath: url.path) else {
                return nil
            }
            return PreparedAudioInput(input: input, url: url, channel: channel)
        }
    }
}
