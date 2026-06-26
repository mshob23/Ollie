import SwiftUI

/// The right pane: the selected note's editable title, metadata, audio player,
/// and the transcript in a calm reading panel. When nothing is selected it shows
/// a friendly empty state.
struct NoteDetailView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if let note = model.selectedNote {
                content(for: note)
            } else {
                empty
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(for note: Note) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                NoteHeader(note: note)
                AudioPlayerView(url: model.audioURL(for: note))
                TranscriptEditor(note: note)
            }
            .padding(28)
        }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.hcMutedText)
            Text("Select a note")
                .font(.hcDisplay(20))
                .foregroundStyle(Color.hcSecondaryText)
            Text("Pick a note on the left, or capture a new one.")
                .font(.system(size: 13))
                .foregroundStyle(Color.hcMutedText)
        }
    }
}

/// Editable title + metadata chips + favorite/delete actions.
private struct NoteHeader: View {
    @EnvironmentObject var model: AppModel
    let note: Note
    @State private var titleDraft: String = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                TextField("Title", text: $titleDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.hcDisplay(26, weight: .semibold))
                    .foregroundStyle(Color.hcPrimaryText)
                    .lineLimit(1...3)
                    .focused($titleFocused)
                    .onSubmit { commit() }

                Spacer(minLength: 0)

                Button(action: { model.toggleFavorite(note.id) }) {
                    Image(systemName: note.isFavorite ? "star.fill" : "star")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(note.isFavorite ? Color.hcAccent : Color.hcMutedText)
                }
                .buttonStyle(.plain)
                .help(note.isFavorite ? "Unfavorite" : "Favorite")

                Button(action: { model.delete(note.id) }) {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.hcMutedText)
                }
                .buttonStyle(.plain)
                .help("Delete note")
            }

            HStack(spacing: 8) {
                Chip(note.source.label, symbol: note.source.symbol, tint: sourceTint)
                Chip(fullDate, symbol: "clock")
                if let secs = note.durationSeconds {
                    Chip(AudioPlayerModel.timeString(secs), symbol: "waveform")
                }
                if let engine = note.engineUsed {
                    Chip(engine, symbol: "wand.and.stars")
                }
                Chip("\(note.wordCount) words")
            }
        }
        .onAppear { titleDraft = note.title }
        .onChange(of: note.id) { _, _ in titleDraft = note.title; titleFocused = false }
        .onChange(of: titleFocused) { _, focused in if !focused { commit() } }
    }

    private func commit() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != note.title else { return }
        model.updateTitle(trimmed, for: note.id)
    }

    private var sourceTint: Color {
        switch note.source {
        case .computer: return .hcAccent
        case .device:   return .hcOk
        case .seed:     return .hcSecondaryText
        }
    }

    private var fullDate: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, yyyy · h:mm a"
        return fmt.string(from: note.createdAt)
    }
}

/// The transcript in a calm, editable reading panel.
private struct TranscriptEditor: View {
    @EnvironmentObject var model: AppModel
    let note: Note
    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Eyebrow(text: "Transcript")
                Spacer()
                if focused {
                    Text("Editing — click away to save")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.hcMutedText)
                }
            }
            TextEditor(text: $draft)
                .focused($focused)
                .font(.system(size: 15))
                .foregroundStyle(Color.hcPrimaryText)
                .lineSpacing(5)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 220)
                .padding(14)
                .hcPanel(fill: .hcPanel)
        }
        .onAppear { draft = note.transcript }
        .onChange(of: note.id) { _, _ in draft = note.transcript; focused = false }
        .onChange(of: focused) { _, isFocused in
            if !isFocused, draft != note.transcript {
                model.updateTranscript(draft, for: note.id)
            }
        }
    }
}
