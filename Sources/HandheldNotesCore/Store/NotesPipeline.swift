import Foundation

/// The convergence point for both capture modes. Given an audio file and where
/// it came from, it: imports the audio into the store, transcribes it, derives a
/// title, and returns a finished `Note`. Mode-agnostic — Computer mode and the
/// (mock or real) device sync both call this.
///
/// Returns the note; the caller (AppModel) is responsible for inserting it into
/// the observable array and persisting. Keeping persistence in the caller means
/// the pipeline stays a pure transform that's easy to reason about.
public struct NotesPipeline: Sendable {
    public var transcription: TranscriptionService

    public init(engine: TranscriptionEngine) {
        self.transcription = TranscriptionService(engine: engine)
    }

    /// The result of transcribing a recording without creating a note — used by
    /// Computer/live mode, where speech is *appended to the active draft* instead
    /// of finalized. The audio is imported into the store under `noteID` so the
    /// eventual concluded note keeps a playable recording.
    public struct TranscribedClip: Sendable {
        public var text: String
        public var storedAudioName: String
        public var durationSeconds: Double?
        public var engineUsed: String?
    }

    /// Import + transcribe a recording and return the text (no `Note` produced).
    /// `noteID` should be the draft's id so the stored audio file matches the note
    /// that will eventually be concluded.
    public func transcribeClip(audioURL: URL, noteID: UUID) async throws -> TranscribedClip {
        let duration = try? AudioInfo.duration(of: audioURL)
        let storedName = try NotesStore.importAudio(from: audioURL, noteID: noteID)
        let result: TranscriptionResult
        do {
            result = try await transcription.transcribe(url: audioURL)
        } catch {
            result = TranscriptionResult(
                text: "[Transcription failed: \(error.localizedDescription)]",
                engineUsed: "error")
        }
        return TranscribedClip(
            text: result.text,
            storedAudioName: storedName,
            durationSeconds: duration,
            engineUsed: result.engineUsed)
    }

    /// Ingest an audio file and produce a saved note.
    /// - Parameter copyAudio: whether to copy the source audio into the store.
    ///   For mock device files (bundled, read-only) we copy; for mic captures we
    ///   also copy so the original temp file can be cleaned up.
    public func ingest(audioURL: URL, source: NoteSource) async throws -> Note {
        let noteID = UUID()
        let duration = try? AudioInfo.duration(of: audioURL)

        // Import the audio first so the note always has its recording even if
        // transcription is slow or partial.
        let storedName = try NotesStore.importAudio(from: audioURL, noteID: noteID)

        let result: TranscriptionResult
        do {
            result = try await transcription.transcribe(url: audioURL)
        } catch {
            // The service already has internal fallbacks; if it still throws,
            // save the note with the error as the body rather than losing the
            // audio entirely.
            result = TranscriptionResult(
                text: "[Transcription failed: \(error.localizedDescription)]",
                engineUsed: "error")
        }

        let now = Date()
        let title = Note.deriveTitle(from: result.text, date: now)
        return Note(
            id: noteID,
            title: title,
            transcript: result.text,
            createdAt: now,
            source: source,
            audioFileName: storedName,
            durationSeconds: duration,
            engineUsed: result.engineUsed)
    }
}
