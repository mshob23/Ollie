import AppIntents
import Foundation

/// Search the corpus by text or place. Returns matching notes, so a Shortcut can
/// act on them (open, copy a transcript) and Siri / Apple Intelligence can reason
/// over them. e.g. "Find Ollie notes matching apartment".
public struct FindNotesIntent: AppIntent {
    public static let title: LocalizedStringResource = "Find Notes"
    public static let description = IntentDescription(
        "Search your Ollie notes by what they say or where they were taken.")

    @Parameter(title: "Search")
    public var query: String

    public init() {}
    public init(query: String) { self.query = query }

    public static var parameterSummary: some ParameterSummary {
        Summary("Find notes matching \(\.$query)")
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<[NoteAppEntity]> & ProvidesDialog {
        let results = NoteIntentStore.search(query, limit: 25)
        let dialog: IntentDialog = results.isEmpty
            ? "No notes matching “\(query)”."
            : "Found \(results.count) note\(results.count == 1 ? "" : "s")."
        return .result(value: results, dialog: dialog)
    }
}

/// Save a new text note to the corpus, e.g. "Add an Ollie note saying buy milk".
public struct SaveNoteIntent: AppIntent {
    public static let title: LocalizedStringResource = "Save Note"
    public static let description = IntentDescription("Save a new text note to Ollie.")

    @Parameter(title: "Text")
    public var text: String

    public init() {}
    public init(text: String) { self.text = text }

    public static var parameterSummary: some ParameterSummary {
        Summary("Save a note saying \(\.$text)")
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<NoteAppEntity> {
        guard let entity = NoteIntentStore.save(text: text) else {
            throw NoteIntentError.emptyText
        }
        return .result(value: entity)
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
