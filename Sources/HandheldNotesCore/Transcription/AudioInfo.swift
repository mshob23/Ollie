import AVFoundation
import Foundation

/// Small helper for reading an audio file's duration (used for note metadata and
/// the transcription timeout budget). Cross-platform (AVFoundation).
enum AudioInfo {
    static func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
