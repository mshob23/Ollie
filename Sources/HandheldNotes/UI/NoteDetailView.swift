import AppKit
import HandheldNotesCore
import SwiftUI

/// The right pane: the selected note's editable title, a clear source indicator,
/// metadata chips, the audio player, and the transcript in a calm, editable
/// reading panel. When nothing is selected it shows a friendly empty state.
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
                SourceBanner(source: note.source)
                NoteHeader(note: note)
                AudioPlayerView(url: model.audioURL(for: note))
                TranscriptEditor(note: note)
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Re-key on the note id so per-note @State (title/transcript drafts) and
        // the scroll position reset cleanly when the selection changes.
        .id(note.id)
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.hcMutedText)
            Text("Select a note")
                .font(.hcDisplay(20))
                .foregroundStyle(Color.hcSecondaryText)
            Text("Pick a note on the left, or capture a new one above.")
                .font(.system(size: 13))
                .foregroundStyle(Color.hcMutedText)
        }
    }
}

// MARK: - Source banner (a clear Computer / Local indicator)

/// A prominent, plain-language strip that tells you at a glance where this note
/// came from — the live Mac mic (Computer), the handheld's SD card synced over
/// BLE (Local / Device), or the bundled demo content.
private struct SourceBanner: View {
    let source: NoteSource

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.opacity(0.16))
                    .frame(width: 34, height: 34)
                Image(systemName: source.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(headline)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.hcPrimaryText)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.hcSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(0.28), lineWidth: 1)
        )
    }

    private var tint: Color {
        switch source {
        case .computer: return .hcAccent
        case .watch:    return .hcAccent
        case .phone:    return .hcAccent
        case .seed:     return .hcSecondaryText
        }
    }

    private var headline: String {
        switch source {
        case .computer: return "Computer · captured on this Mac"
        case .watch:    return "Watch · captured on Apple Watch"
        case .phone:    return "iPhone · composed on your iPhone"
        case .seed:     return "Demo note"
        }
    }

    private var detail: String {
        switch source {
        case .computer:
            return "Dictated live with the F16 push-to-talk hotkey, then transcribed here."
        case .watch:
            return "Recorded on the Apple Watch and transferred to your iPhone, which transcribed it."
        case .phone:
            return "Typed or dictated in the iPhone app's note composer."
        case .seed:
            return "Sample content seeded on first launch so the app isn't empty."
        }
    }
}

// MARK: - Header (editable title + metadata chips + actions)

/// Editable title + a row of metadata chips + favorite/delete actions.
private struct NoteHeader: View {
    @EnvironmentObject var model: AppModel
    let note: Note
    @State private var titleDraft: String = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 12) {
                TextField("Title", text: $titleDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.hcDisplay(26, weight: .semibold))
                    .foregroundStyle(Color.hcPrimaryText)
                    .lineLimit(1...3)
                    .focused($titleFocused)
                    .onSubmit { commit() }
                    .help("Click to rename this note")

                Spacer(minLength: 0)

                Button(action: { model.toggleFavorite(note.id) }) {
                    Image(systemName: note.isFavorite ? "star.fill" : "star")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(note.isFavorite ? Color.hcAccent : Color.hcMutedText)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help(note.isFavorite ? "Remove from favorites" : "Mark as favorite")

                Button(action: { model.delete(note.id) }) {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.hcMutedText)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help("Delete this note")
            }

            // Metadata chips wrap to a second line on a narrow pane.
            FlowChips {
                Chip(note.source.label, symbol: note.source.symbol, tint: sourceTint)
                Chip(relativeDate, symbol: "clock")
                    .help(fullDate)
                if let secs = note.durationSeconds, secs > 0 {
                    Chip(AudioPlayerModel.timeString(secs), symbol: "waveform")
                }
                if let engine = note.engineUsed, !engine.isEmpty {
                    Chip(engine, symbol: "wand.and.stars")
                }
                Chip("\(note.wordCount) word\(note.wordCount == 1 ? "" : "s")", symbol: "text.alignleft")
                if note.updatedAt.timeIntervalSince(note.createdAt) > 60 {
                    Chip("edited", symbol: "pencil", tint: .hcMutedText)
                        .help("Edited \(Self.relative(from: note.updatedAt))")
                }
            }
        }
        .onAppear { titleDraft = note.title }
        .onChange(of: note.id) { _, _ in titleDraft = note.title; titleFocused = false }
        .onChange(of: titleFocused) { _, focused in if !focused { commit() } }
    }

    private func commit() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != note.title else {
            titleDraft = note.title   // snap back if cleared
            return
        }
        model.updateTitle(trimmed, for: note.id)
    }

    private var sourceTint: Color {
        switch note.source {
        case .computer: return .hcAccent
        case .watch:    return .hcAccent
        case .phone:    return .hcAccent
        case .seed:     return .hcSecondaryText
        }
    }

    private var fullDate: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE, MMM d, yyyy 'at' h:mm a"
        return fmt.string(from: note.createdAt)
    }

    private var relativeDate: String { Self.relative(from: note.createdAt) }

    /// "just now / 12m ago / 3h ago / yesterday / Mar 4" — like the list, but the
    /// chip carries the full timestamp in its tooltip.
    static func relative(from date: Date) -> String {
        let now = Date()
        let secs = now.timeIntervalSince(date)
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(Int(secs / 60))m ago" }
        if secs < 86_400 { return "\(Int(secs / 3600))h ago" }
        if Calendar.current.isDateInYesterday(date) { return "yesterday" }
        let days = Int(secs / 86_400)
        if days < 7 { return "\(days)d ago" }
        let fmt = DateFormatter()
        fmt.dateFormat = Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
            ? "MMM d" : "MMM d, yyyy"
        return fmt.string(from: date)
    }
}

// MARK: - Transcript (editable, with a copy button + live word count)

/// The transcript in a calm, editable reading panel with a copy-to-clipboard
/// action and a small live word count.
private struct TranscriptEditor: View {
    @EnvironmentObject var model: AppModel
    let note: Note
    @State private var draft: String = ""
    @FocusState private var focused: Bool

    private var liveWordCount: Int {
        draft.split { $0 == " " || $0.isNewline }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Eyebrow(text: "Transcript")
                Text("\(liveWordCount) word\(liveWordCount == 1 ? "" : "s")")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.hcMutedText)
                Spacer()
                if focused {
                    Text("Editing — click away to save")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.hcMutedText)
                        .transition(.opacity)
                }
                CopyTranscriptButton(text: draft)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            TextEditor(text: $draft)
                .focused($focused)
                .font(.system(size: 15))
                .foregroundStyle(Color.hcPrimaryText)
                .lineSpacing(5)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 240)
                .padding(14)
                .hcPanel(fill: .hcPanel)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.hcAccent.opacity(focused ? 0.35 : 0), lineWidth: 1)
                )
                .animation(.easeInOut(duration: 0.15), value: focused)
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

/// A small copy button that flips to a "Copied" confirmation for ~1.4s.
private struct CopyTranscriptButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 5) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10.5, weight: .semibold))
                Text(copied ? "Copied" : "Copy")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(copied ? Color.hcOk : Color.hcSecondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.hcPrimaryText.opacity(0.06)))
            .overlay(Capsule().stroke((copied ? Color.hcOk : Color.hcPrimaryText).opacity(0.2), lineWidth: 1))
            .contentShape(Capsule())
            .animation(.easeInOut(duration: 0.15), value: copied)
        }
        .buttonStyle(.plain)
        .help("Copy the transcript to the clipboard")
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            copied = false
        }
    }
}

// MARK: - A small wrapping HStack for the metadata chips

/// Lays out its children left-to-right and wraps onto new lines when the pane is
/// narrow — so the metadata row degrades gracefully instead of clipping.
private struct FlowChips: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxWidth {
                widest = max(widest, x - spacing)
                x = 0; y += lineHeight + lineSpacing; lineHeight = 0
            }
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
        }
        widest = max(widest, x - spacing)
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxWidth {
                x = 0; y += lineHeight + lineSpacing; lineHeight = 0
            }
            v.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
        }
    }
}
