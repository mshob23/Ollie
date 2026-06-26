import Foundation

/// The convergence point for both capture modes. Given an audio file and where
/// it came from, it: imports the audio into the store, transcribes it, derives a
/// title, and returns a finished `Note`. Mode-agnostic — Computer mode and the
/// (mock or real) device sync both call this.
///
/// Returns the note; the caller (AppModel) is responsible for inserting it into
/// the observable array and persisting. Keeping persistence in the caller means
/// the pipeline stays a pure transform that's easy to reason about.
struct NotesPipeline: Sendable {
    var transcription: TranscriptionService

    init(engine: TranscriptionEngine) {
        self.transcription = TranscriptionService(engine: engine)
    }

    /// Ingest an audio file and produce a saved note.
    /// - Parameter copyAudio: whether to copy the source audio into the store.
    ///   For mock device files (bundled, read-only) we copy; for mic captures we
    ///   also copy so the original temp file can be cleaned up.
    func ingest(audioURL: URL, source: NoteSource) async throws -> Note {
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
