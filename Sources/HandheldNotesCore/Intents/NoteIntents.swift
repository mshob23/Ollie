import AppIntents
import Foundation

/// Search the corpus by text or place. Returns matching notes, so a Shortcut can
/// act on them (open, copy a transcript) and Siri / Apple Intelligence can reason
/// over them. e.g. "Find Ollie notes matching apartment".
public struct FindNotesIntent: AppIntent {
    public static let title: LocalizedStringResource = "Find Notes"
    public static let description = IntentDescription(
        "Search your Ollie notes by what they say or where they were taken. Returns the matching notes so you can open one, copy a transcript, or chain them into another action.",
        categoryName: "Notes",
        searchKeywords: ["note", "notes", "voice", "memo", "transcript", "search", "find"])

    // The spoken prompt matters: without it, invoking via Siri with no query just
    // stalls. With it, "Find Ollie notes" becomes a conversation.
    @Parameter(title: "Search", requestValueDialog: "What should I look for in your notes?")
    public var query: String

    public init() {}
    public init(query: String) { self.query = query }

    public static var parameterSummary: some ParameterSummary {
        Summary("Find notes matching \(\.$query)")
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<[NoteAppEntity]> & ProvidesDialog {
        let results = NoteIntentStore.search(query, limit: 25)
        let dialog: IntentDialog
        if results.isEmpty {
            dialog = "No notes matching “\(query)”."
        } else {
            // Name the actual matches, not just a count — so "Find Notes" shows WHAT
            // it found. (The full list is also returned as the value for chaining.)
            let names = results.prefix(3).map(\.headline).joined(separator: "; ")
            let more = results.count > 3 ? " (+\(results.count - 3) more)" : ""
            dialog = "Found \(results.count): \(names)\(more)"
        }
        return .result(value: results, dialog: dialog)
    }
}

/// Save a new text note to the corpus, e.g. "Add an Ollie note saying buy milk".
public struct SaveNoteIntent: AppIntent {
    public static let title: LocalizedStringResource = "Save Note"
    public static let description = IntentDescription(
        "Save a new text note straight into Ollie — no need to open the app. Say the note and it's captured.",
        categoryName: "Notes",
        searchKeywords: ["note", "notes", "save", "add", "capture", "remember", "jot"])

    @Parameter(title: "Text", requestValueDialog: "What should the note say?")
    public var text: String

    public init() {}
    public init(text: String) { self.text = text }

    public static var parameterSummary: some ParameterSummary {
        Summary("Save a note saying \(\.$text)")
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<NoteAppEntity> & ProvidesDialog {
        guard let entity = NoteIntentStore.save(text: text) else {
            throw NoteIntentError.emptyText
        }
        // Speak/print a confirmation so Siri closes the loop instead of going silent.
        return .result(value: entity, dialog: "Saved to Ollie.")
    }
}

enum NoteIntentError: Error, CustomLocalizedStringResourceConvertible {
    case emptyText
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .emptyText: return "There was no text to save."
        }
    }
}
