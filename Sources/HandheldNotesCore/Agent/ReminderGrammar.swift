import Foundation

/// A **reminder** parsed out of the `inbox` view body (M24a, contract §7).
///
/// The `inbox` view doubles as the *delivery* channel (M19): its checkbox lines are
/// receipts, and a receipt of one exact shape is a **reminder** the app schedules a
/// local notification for. This value is what ``ReminderGrammar`` distils each such
/// line into — a pure projection the ``NotificationScheduler`` reconciles against the
/// notification center. It carries no I/O and no live date resolution of its own; the
/// `fireDate` was resolved once, at parse time, in the device's calendar.
public struct Reminder: Equatable, Hashable, Sendable {
    /// The line's **M7 `blockId`** (`cl1:<hash16>:<occ>`), derived by the SAME
    /// `MarkdownLite` block parser the renderer and checkbox layer use — never
    /// reforked here. It is the scheduling identity (contract §7): a republish that
    /// only *reorders* the inbox keeps each line's id (the hash is over the line text,
    /// the ordinal over document order among identical lines), so a reorder never
    /// double-schedules; a **reword** (including editing the date or text) changes the
    /// bytes → a new id → a reschedule; a tick cancels.
    public let blockId: String

    /// The moment to fire, resolved from the line's `YYYY-MM-DD HH:MM` as **device-local
    /// wall time** in the calendar passed to ``ReminderGrammar/reminders(in:calendar:)``
    /// (production: `Calendar.current`, whose `timeZone` is the device's). Resolved once
    /// at parse time and frozen into the value — the scheduler compares it to `now` and
    /// skips past-due ones; it does no date math of its own.
    public let fireDate: Date

    /// The reminder body — everything after `remind <date> <time>: `, i.e. the grammar
    /// stripped away. This is the notification text (and the arrival-banner body for a
    /// reminder line). Never empty for a successful parse (a trailing-empty-text line is
    /// not a reminder — see the grammar).
    public let text: String

    /// Whether the source checkbox is ticked (`- [x]`). A tick **is** the dismissal
    /// channel (contract §7, as for every receipt): a dismissed reminder is still parsed
    /// (so the scheduler can see it and cancel any pending request for its `blockId`),
    /// but it is never (re)scheduled.
    public let isDismissed: Bool

    public init(blockId: String, fireDate: Date, text: String, isDismissed: Bool) {
        self.blockId = blockId
        self.fireDate = fireDate
        self.text = text
        self.isDismissed = isDismissed
    }
}

/// The **reminder grammar** (contract §7, M24a): a pure, total parser from an `inbox`
/// view body to the reminders it declares. No side effects, no throwing — a malformed
/// line is simply *not a reminder* and passes through silently (the same tolerance every
/// fence and receipt has: a non-matching line is an ordinary receipt, never an error).
///
/// ## Grammar (exact)
/// A reminder is an inbox checkbox line of the form
///
/// ```
/// - [ ] remind 2026-07-11 17:00: pick up the meds
/// ```
///
/// i.e. a checklist item whose text is: the literal `remind ` (lower-case, exactly one
/// trailing space), then `YYYY-MM-DD` (4-digit year, 2-digit month, 2-digit day), a
/// single space, `HH:MM` (2-digit 24-hour hour `00`–`23`, 2-digit minute `00`–`59`),
/// then `: ` (colon-space), then the reminder text (which must be non-empty after
/// trimming). Ticked (`- [x]`) means **dismissed**. The calendar/time-zone components of
/// the date are interpreted as **device-local wall time**.
///
/// Anything that fails any part — a wrong prefix, a bad separator, a date that isn't a
/// real calendar day (`2026-13-40`), a time out of range (`25:99`), an empty body — is
/// not a reminder and yields nothing for that line. The rest of the body is unaffected.
///
/// ## Reuse (no forked derivation)
/// The `blockId`s come from ``MarkdownLite/blocks(from:)`` — the single M7 derivation the
/// renderer and the checkbox overlay already share (`cl1:<hash16>:<occ>`, hash over the
/// classifier-captured item text, ordinal in document order). This parser only *reads*
/// those ids off the parsed checklist items; it never recomputes the hash. So the
/// notification identity and the checkbox identity are the same string by construction —
/// a tick in the UI and a cancel in the scheduler key off the same `blockId`.
///
/// ## Platform
/// Pure Foundation + the shared `MarkdownLite` parser — compiles on macOS, iOS, and (in
/// principle) watchOS. But per the watch-target rule it must **not** be referenced from
/// the watch's path-referenced file set (`MarkdownLite`/`FenceWidgets`); it is reached
/// only from `AppModel`, off the watch build.
public enum ReminderGrammar {

    /// The literal grammar prefix. Lower-case, exactly one trailing space (contract §7).
    private static let keyword = "remind "

    /// Parse every reminder declared in an `inbox` view `body`, in document order.
    ///
    /// Pure and total: never throws, never touches I/O. Non-matching checklist lines and
    /// all non-checklist content (prose, headings, plain bullets, fences) are ignored.
    /// A line that *looks* like a reminder but has a malformed date/time is rejected and
    /// contributes nothing (it renders as an ordinary receipt elsewhere).
    ///
    /// - Parameters:
    ///   - body: the view body markdown (the §6 dialect). Typically the latest `inbox`
    ///     revision's body.
    ///   - calendar: the calendar (carrying the time zone) in which the `YYYY-MM-DD HH:MM`
    ///     wall time is resolved to an absolute `fireDate`. **Defaults to
    ///     `Calendar.current`** (device-local, the production path); tests inject a fixed
    ///     time zone to assert wall-time → instant correctness deterministically.
    /// - Returns: the reminders, in the order their lines appear in `body`. Each carries
    ///   its M7 `blockId`, resolved `fireDate`, stripped `text`, and dismissed state.
    public static func reminders(in body: String,
                                 calendar: Calendar = .current) -> [Reminder] {
        var out: [Reminder] = []
        // Walk the SAME parsed blocks the renderer produces, so the blockIds (and their
        // document-order occurrence ordinals) match the checkbox layer exactly. Only
        // checklist items (non-nil blockId + non-nil checked) can be reminders.
        for block in MarkdownLite.blocks(from: body) {
            guard case let .list(items) = block else { continue }
            for item in items {
                guard let blockId = item.blockId, let checked = item.checked else { continue }
                guard let parsed = parseLine(item.text, calendar: calendar) else { continue }
                out.append(Reminder(blockId: blockId,
                                    fireDate: parsed.fireDate,
                                    text: parsed.text,
                                    isDismissed: checked))
            }
        }
        return out
    }

    /// Parse ONE checklist item's captured text (the label after the `- [ ]` marker,
    /// already trimmed by the classifier) against the reminder grammar. Returns the
    /// resolved fire date + stripped text, or nil if it isn't a well-formed reminder.
    ///
    /// Exposed at file scope only through ``reminders(in:calendar:)``; kept `internal`
    /// (not private) so a focused grammar test can hit it directly without reconstructing
    /// a whole view body.
    static func parseLine(_ label: String, calendar: Calendar) -> (fireDate: Date, text: String)? {
        // 1. Literal `remind ` prefix (case-sensitive, exact spacing).
        guard label.hasPrefix(keyword) else { return nil }
        let afterKeyword = label.dropFirst(keyword.count)

        // 2. Split off the datetime from the text at the FIRST ": ". The datetime part is
        //    fixed-width ("YYYY-MM-DD HH:MM", 16 chars), so the first ": " after it is the
        //    grammar separator; a ": " inside the reminder text stays in the text.
        guard let sepRange = afterKeyword.range(of: ": ") else { return nil }
        let datetime = afterKeyword[afterKeyword.startIndex..<sepRange.lowerBound]
        let text = String(afterKeyword[sepRange.upperBound...])

        // 3. Text must be non-empty (a bare "remind <date> <time>: " is not a reminder).
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        // 4. Datetime must be EXACTLY "YYYY-MM-DD HH:MM" and a REAL calendar instant.
        guard let fireDate = resolveDate(String(datetime), calendar: calendar) else { return nil }

        return (fireDate, text)
    }

    /// Resolve a `YYYY-MM-DD HH:MM` string to an absolute instant in `calendar` (its time
    /// zone = device-local wall time), or nil if the string isn't that exact shape or names
    /// an impossible date/time. We parse the digits ourselves (not a lenient
    /// `DateFormatter`) so a garbage day/time is *rejected* rather than silently rolled
    /// over — `2026-13-40` and `25:99` must fail, per the acceptance cases.
    private static func resolveDate(_ s: String, calendar: Calendar) -> Date? {
        // Structure: 4-2-2 date, one space, 2-2 time. Fixed width; anything else is out.
        let parts = s.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let dateParts = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        let timeParts = parts[1].split(separator: ":", omittingEmptySubsequences: false)
        guard dateParts.count == 3, timeParts.count == 2 else { return nil }

        guard let year = fixedWidthInt(dateParts[0], width: 4),
              let month = fixedWidthInt(dateParts[1], width: 2),
              let day = fixedWidthInt(dateParts[2], width: 2),
              let hour = fixedWidthInt(timeParts[0], width: 2),
              let minute = fixedWidthInt(timeParts[1], width: 2)
        else { return nil }

        // Range-gate the wall-clock fields up front. Calendar.date(from:) with a lenient
        // calendar would happily roll 25:99 into the next day; we forbid that so the
        // grammar stays exact (hour 00–23, minute 00–59, month 01–12, day 01–31; the
        // day-vs-month validity is enforced by the round-trip check below).
        guard (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0

        guard let date = calendar.date(from: components) else { return nil }
        // Reject impossible dates (e.g. 2026-02-30, 2026-13-40 already caught above):
        // Calendar.date(from:) normalizes out-of-range components, so a rolled-over input
        // resolves to a DIFFERENT day than requested. Round-trip the resolved instant back
        // to components and require an exact match — only a real calendar day survives.
        let check = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard check.year == year, check.month == month, check.day == day,
              check.hour == hour, check.minute == minute else { return nil }
        return date
    }

    /// Parse a fixed-width, all-ASCII-digit field to an Int, or nil if it isn't exactly
    /// `width` digit characters. This is what makes the format strict: `7` (not `07`) for
    /// a 2-width field, a `+`/`-` sign, spaces, or non-digits all fail — so only the exact
    /// zero-padded grammar parses.
    private static func fixedWidthInt(_ s: Substring, width: Int) -> Int? {
        guard s.count == width, s.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(s)
    }
}
