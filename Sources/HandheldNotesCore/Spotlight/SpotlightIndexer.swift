import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Donates notes to the system Spotlight index so they're findable in system
/// search (swipe-down on iOS, ⌘-Space on Mac) and feed Apple Intelligence's
/// on-device semantic index. Rung 2 of the exposability ladder, alongside the App
/// Intents. Best-effort and non-fatal — an indexing failure never affects a note.
///
/// Unlike App Intents (whose discovery needs a build-time extraction step), this is
/// a pure runtime API, so it works identically on the SPM-built Mac app and the
/// Xcode-built iOS app.
public enum SpotlightIndexer {
    /// Groups Ollie's notes in the shared index, so a full wipe can clear just ours.
    public static let domainIdentifier = "com.mohammadshobaki.ollie.notes"

    /// Upsert notes into the index (keyed by note id, so re-indexing an edited note
    /// replaces its old entry).
    public static func index(_ notes: [Note]) {
        guard CSSearchableIndex.isIndexingAvailable(), !notes.isEmpty else { return }
        let items = notes.map { note -> CSSearchableItem in
            let attrs = CSSearchableItemAttributeSet(contentType: .text)
            attrs.title = note.derivedTitle
            attrs.contentDescription = note.transcript
            attrs.contentCreationDate = note.createdAt
            if let place = note.location?.label { attrs.namedLocation = place }
            return CSSearchableItem(
                uniqueIdentifier: note.id.uuidString,
                domainIdentifier: domainIdentifier,
                attributeSet: attrs)
        }
        CSSearchableIndex.default().indexSearchableItems(items)
    }

    /// Remove specific notes from the index (on delete).
    public static func remove(ids: [UUID]) {
        guard CSSearchableIndex.isIndexingAvailable(), !ids.isEmpty else { return }
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: ids.map(\.uuidString))
    }

    /// Clear every Ollie note from the index (on a full wipe).
    public static func removeAll() {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domainIdentifier])
    }
}
