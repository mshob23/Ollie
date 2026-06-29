import HandheldNotesCore
import SwiftUI

/// The left column: brand header, search field, and the scrollable list of notes
/// (newest first). This is the spine of the notes-first layout.
struct NotesListView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchField
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            if model.filteredNotes.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(minWidth: 300, idealWidth: 340, maxWidth: 380)
        .background(Color.hcBackgroundBottom.opacity(0.6))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.hcAccent)
                        .frame(width: 30, height: 30)
                    Image(systemName: "waveform")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.hcOnAccent)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("Ollie")
                        .font(.hcDisplay(18, weight: .semibold))
                        .foregroundStyle(Color.hcPrimaryText)
                    Text("\(model.notes.count) note\(model.notes.count == 1 ? "" : "s")")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.hcMutedText)
                }
                Spacer()
                // Manual refresh: re-project the store on demand. The list normally
                // updates itself on iCloud remote-change notifications
                // (AppModel.observeRemoteChanges()); this is the explicit fallback,
                // sized to sit cleanly beside the brand mark. (The Mac list is a
                // ScrollView, not a List, so a header button fits better than
                // .refreshable's pull gesture.)
                Button(action: { model.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.hcMutedText)
                }
                .buttonStyle(.plain)
                .help("Refresh notes")
                .accessibilityLabel("Refresh notes")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.hcMutedText)
            TextField("Search notes", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color.hcPrimaryText)
            if !model.searchText.isEmpty {
                Button(action: { model.searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.hcMutedText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .hcPanel(fill: .hcPanel, radius: 10)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(model.filteredNotes) { note in
                    NoteRow(note: note, isSelected: note.id == model.selectedNoteID)
                        .onTapGesture { model.selectedNoteID = note.id }
                        .contextMenu {
                            Button(note.isFavorite ? "Unfavorite" : "Favorite") {
                                model.toggleFavorite(note.id)
                            }
                            Button("Delete", role: .destructive) { model.delete(note.id) }
                        }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: model.searchText.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.hcMutedText)
            Text(model.searchText.isEmpty ? "No notes yet" : "No matches")
                .font(.hcDisplay(15))
                .foregroundStyle(Color.hcSecondaryText)
            Text(model.searchText.isEmpty
                 ? "Hold F16 to record, or sync your device."
                 : "Try a different search.")
                .font(.system(size: 12))
                .foregroundStyle(Color.hcMutedText)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }
}

/// One row in the notes list.
struct NoteRow: View {
    let note: Note
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Text(note.preview)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.hcPrimaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if note.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.hcAccent)
                }
            }

            HStack(spacing: 7) {
                Image(systemName: note.source.symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(sourceTint)
                Text(relativeDate)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.hcMutedText)
                if note.hasAudio {
                    Image(systemName: "waveform")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.hcMutedText)
                }
                if let place = note.location {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.hcMutedText)
                    Text(place.label)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.hcMutedText)
                        .lineLimit(1)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isSelected ? Color.hcAccentSoft : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(isSelected ? Color.hcAccent.opacity(0.45) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    private var sourceTint: Color {
        switch note.source {
        case .computer: return .hcAccent
        case .watch:    return .hcAccent
        case .phone:    return .hcAccent
        case .seed:     return .hcSecondaryText
        }
    }

    private var relativeDate: String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: note.createdAt, relativeTo: Date())
    }
}
