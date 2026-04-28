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
        do {
            let audioFile = try AVAudioFile(forReading: preparedInput.url)
            return audioFile.length > 0
        } catch {
            return false
        }
    }
}

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
