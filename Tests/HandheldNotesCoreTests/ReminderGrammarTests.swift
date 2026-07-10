import Foundation
import XCTest
@testable import HandheldNotesCore

/// Unit tests for `ReminderGrammar` — the pure parser from an `inbox` view body to the
/// reminders it declares (M24a, contract §7). All cases are deterministic: a fixed
/// time-zone calendar is injected so wall-time → instant resolution is exact and
/// machine-independent, and the M7 `blockId`s are asserted by RELATIONSHIP (reword ⇒
/// different id, reorder ⇒ same id) so no brittle hash is baked in.
///
/// Coverage (the acceptance cases):
///   • a well-formed line parses (id + fireDate + stripped text + dismissed state);
///   • exact-format edge cases (missing space, single-digit fields, `:` without space,
///     empty text) are rejected;
///   • non-matching lines (prose, plain bullets, non-`remind` checkboxes) pass through;
///   • a **reword** yields a DIFFERENT blockId; a **reorder** yields the SAME blockId;
///   • malformed dates/times (`2026-13-40`, `25:99`, `2026-02-30`) are rejected;
///   • `[x]` ⇒ dismissed (still parsed, flagged);
///   • the injected time zone drives the fireDate (a UTC vs +09:00 calendar differ by 9h).
@MainActor
final class ReminderGrammarTests: XCTestCase {

    /// A Gregorian calendar pinned to a fixed time zone, so `YYYY-MM-DD HH:MM` resolves to
    /// a deterministic absolute instant regardless of where the test host runs.
    private func calendar(tzSecondsFromGMT: Int) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: tzSecondsFromGMT)!
        return cal
    }

    private var utc: Calendar { calendar(tzSecondsFromGMT: 0) }

    // MARK: - Happy path

    func testWellFormedReminderParses() {
        let body = "- [ ] remind 2026-07-11 17:00: pick up the meds"
        let reminders = ReminderGrammar.reminders(in: body, calendar: utc)

        XCTAssertEqual(reminders.count, 1)
        let r = reminders[0]
        XCTAssertEqual(r.text, "pick up the meds")
        XCTAssertFalse(r.isDismissed)
        XCTAssertTrue(r.blockId.hasPrefix("cl1:"), "id is the M7 derivation")

        // 2026-07-11 17:00 UTC as an absolute instant.
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 11; comps.hour = 17; comps.minute = 0
        let expected = utc.date(from: comps)!
        XCTAssertEqual(r.fireDate, expected)
    }

    func testTickedReminderIsDismissedButStillParsed() {
        let body = "- [x] remind 2026-07-11 17:00: pick up the meds"
        let reminders = ReminderGrammar.reminders(in: body, calendar: utc)
        XCTAssertEqual(reminders.count, 1, "a dismissed reminder is still parsed (so it can be cancelled)")
        XCTAssertTrue(reminders[0].isDismissed)
    }

    func testUppercaseXAlsoDismissed() {
        let reminders = ReminderGrammar.reminders(in: "- [X] remind 2026-07-11 17:00: x", calendar: utc)
        XCTAssertEqual(reminders.count, 1)
        XCTAssertTrue(reminders[0].isDismissed)
    }

    func testTextWithColonSpaceKeepsEverythingAfterFirstSeparator() {
        // A ": " inside the reminder text must stay in the text — only the FIRST ": "
        // (right after the fixed-width datetime) is the grammar separator.
        let body = "- [ ] remind 2026-07-11 17:00: call Bob re: the invoice"
        let reminders = ReminderGrammar.reminders(in: body, calendar: utc)
        XCTAssertEqual(reminders.first?.text, "call Bob re: the invoice")
    }

    func testMultipleRemindersInDocumentOrder() {
        let body = """
        # inbox
        - [ ] remind 2026-07-11 17:00: first
        - [ ] not a reminder, just a receipt
        - [x] remind 2026-07-12 09:30: second
        """
        let reminders = ReminderGrammar.reminders(in: body, calendar: utc)
        XCTAssertEqual(reminders.map(\.text), ["first", "second"])
        XCTAssertEqual(reminders.map(\.isDismissed), [false, true])
    }

    // MARK: - Time-zone injection

    func testInjectedTimeZoneDrivesFireDate() {
        let body = "- [ ] remind 2026-07-11 17:00: x"
        // Same wall time, two zones nine hours apart → instants nine hours apart.
        let inUTC = ReminderGrammar.reminders(in: body, calendar: calendar(tzSecondsFromGMT: 0))[0].fireDate
        let inJST = ReminderGrammar.reminders(in: body, calendar: calendar(tzSecondsFromGMT: 9 * 3600))[0].fireDate
        // 17:00 JST is EARLIER (in absolute terms) than 17:00 UTC by 9h.
        XCTAssertEqual(inUTC.timeIntervalSince(inJST), 9 * 3600, accuracy: 0.5)
    }

    // MARK: - Pass-through (non-matching lines are ordinary receipts)

    func testNonMatchingLinesPassThroughSilently() {
        let body = """
        # inbox
        Just some prose, not a checkbox.
        - a plain bullet, no checkbox
        - [ ] an ordinary receipt with no remind keyword
        - [ ] reminder 2026-07-11 17:00: wrong keyword (reminder, not remind)
        - [ ] Remind 2026-07-11 17:00: capitalized keyword
        ```
        - [ ] remind 2026-07-11 17:00: inside a code fence, not a checklist
        ```
        """
        let reminders = ReminderGrammar.reminders(in: body, calendar: utc)
        XCTAssertTrue(reminders.isEmpty, "nothing here is a well-formed reminder: \(reminders)")
    }

    // MARK: - Exact-format edge cases

    func testExactFormatRejections() {
        let bad = [
            "- [ ] remind2026-07-11 17:00: x",        // no space after keyword
            "- [ ] remind 2026-07-11 17:00:x",         // colon without following space
            "- [ ] remind 2026-07-11 17:00 x",         // no colon separator at all
            "- [ ] remind 2026-7-11 17:00: x",         // single-digit month
            "- [ ] remind 2026-07-1 17:00: x",         // single-digit day
            "- [ ] remind 2026-07-11 7:00: x",         // single-digit hour
            "- [ ] remind 26-07-11 17:00: x",          // two-digit year
            "- [ ] remind 2026-07-11 17:00: ",         // empty text
            "- [ ] remind 2026-07-11  17:00: x",       // double space between date and time
            "- [ ] remind  2026-07-11 17:00: x",       // double space after keyword
            "- [ ] remind 2026/07/11 17:00: x",        // slashes not dashes
        ]
        for line in bad {
            XCTAssertTrue(ReminderGrammar.reminders(in: line, calendar: utc).isEmpty,
                          "should NOT parse as a reminder: \(line)")
        }
    }

    // MARK: - Malformed dates / times

    func testMalformedDatesRejected() {
        let bad = [
            "- [ ] remind 2026-13-40 17:00: x",   // month 13, day 40
            "- [ ] remind 2026-00-10 17:00: x",   // month 0
            "- [ ] remind 2026-07-00 17:00: x",   // day 0
            "- [ ] remind 2026-02-30 17:00: x",   // Feb 30 (impossible calendar day)
            "- [ ] remind 2026-07-11 25:99: x",   // hour 25, minute 99
            "- [ ] remind 2026-07-11 24:00: x",   // hour 24 (out of 00–23)
            "- [ ] remind 2026-07-11 17:60: x",   // minute 60
        ]
        for line in bad {
            XCTAssertTrue(ReminderGrammar.reminders(in: line, calendar: utc).isEmpty,
                          "malformed date/time should be rejected: \(line)")
        }
    }

    func testLeapDayValidAndInvalid() {
        // 2028 is a leap year → Feb 29 valid; 2026 is not → Feb 29 invalid.
        XCTAssertEqual(ReminderGrammar.reminders(in: "- [ ] remind 2028-02-29 08:00: leap", calendar: utc).count, 1)
        XCTAssertTrue(ReminderGrammar.reminders(in: "- [ ] remind 2026-02-29 08:00: nope", calendar: utc).isEmpty)
    }

    func testMidnightAndEndOfDayBoundaries() {
        XCTAssertEqual(ReminderGrammar.reminders(in: "- [ ] remind 2026-07-11 00:00: midnight", calendar: utc).count, 1)
        XCTAssertEqual(ReminderGrammar.reminders(in: "- [ ] remind 2026-07-11 23:59: eod", calendar: utc).count, 1)
    }

    // MARK: - blockId stability (reword ⇒ new id, reorder ⇒ same id)

    func testRewordYieldsDifferentBlockId() {
        let a = ReminderGrammar.reminders(in: "- [ ] remind 2026-07-11 17:00: pick up the meds", calendar: utc)[0]
        // Change only the text.
        let b = ReminderGrammar.reminders(in: "- [ ] remind 2026-07-11 17:00: pick up the milk", calendar: utc)[0]
        XCTAssertNotEqual(a.blockId, b.blockId, "a reworded reminder gets a new id (reschedules)")

        // Change only the date → also a reword of the line bytes → new id.
        let c = ReminderGrammar.reminders(in: "- [ ] remind 2026-07-12 17:00: pick up the meds", calendar: utc)[0]
        XCTAssertNotEqual(a.blockId, c.blockId, "editing the date changes the id (reschedules)")
    }

    func testReorderYieldsSameBlockIds() {
        let first = """
        - [ ] remind 2026-07-11 17:00: alpha
        - [ ] remind 2026-07-12 09:30: bravo
        """
        let second = """
        - [ ] remind 2026-07-12 09:30: bravo
        - [ ] remind 2026-07-11 17:00: alpha
        """
        let idsByText1 = Dictionary(uniqueKeysWithValues:
            ReminderGrammar.reminders(in: first, calendar: utc).map { ($0.text, $0.blockId) })
        let idsByText2 = Dictionary(uniqueKeysWithValues:
            ReminderGrammar.reminders(in: second, calendar: utc).map { ($0.text, $0.blockId) })
        // Same line text ⇒ same id regardless of position (reorder never re-keys).
        XCTAssertEqual(idsByText1["alpha"], idsByText2["alpha"])
        XCTAssertEqual(idsByText1["bravo"], idsByText2["bravo"])
    }

    func testDuplicateIdenticalRemindersGetDistinctOccurrenceIds() {
        // Two byte-identical reminder lines share the hash but get occ 0 and 1 → distinct
        // ids, so both schedule independently (never collapse into one).
        let body = """
        - [ ] remind 2026-07-11 17:00: dup
        - [ ] remind 2026-07-11 17:00: dup
        """
        let reminders = ReminderGrammar.reminders(in: body, calendar: utc)
        XCTAssertEqual(reminders.count, 2)
        XCTAssertNotEqual(reminders[0].blockId, reminders[1].blockId)
    }

    // MARK: - Empty / no-inbox

    func testEmptyBodyYieldsNoReminders() {
        XCTAssertTrue(ReminderGrammar.reminders(in: "", calendar: utc).isEmpty)
    }
}
