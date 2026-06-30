import Foundation
import os

/// Centralized diagnostics sink for the sync/observability backbone.
///
/// **Why this exists.** The codebase used to log via `NSLog`, but on this
/// machine `NSLog` output does NOT surface to `log show` (the unified-log query
/// tool) — so the breadcrumbs we most want when sync goes quiet were invisible.
/// `os.Logger` writes to the unified log proper, which `log show` (and Console)
/// can read. We route through here so every diagnostic is unified-log visible.
///
/// **Greppability is preserved.** Every line keeps the historical `HNDIAG`
/// token in the message text, so existing habits/scripts that grep for
/// `HNDIAG` still work:
///
///     log show --predicate 'eventMessage CONTAINS "HNDIAG"' --last 30m
///
/// Sync-event lines additionally carry a `SYNCEVENT` token (`HNDIAG SYNCEVENT
/// ...`) so the CloudKit phase trail can be isolated on its own.
public enum Diag {

    /// The unified-log logger. Subsystem matches the app's bundle identifier so
    /// the lines can be filtered by subsystem in Console / `log show`; category
    /// `sync` scopes them to the sync-health backbone.
    public static let logger = Logger(
        subsystem: "com.mohammadshobaki.handheldnotes",
        category: "sync")

    /// Emit a diagnostic to the unified log. The `HNDIAG` token is assumed to be
    /// present in `message` by callers that want the historical prefix; this
    /// method itself is token-agnostic so it can carry any pre-formatted line
    /// (e.g. the `HNDIAG SYNCEVENT ...` sync-event trail).
    public static func log(_ message: String) {
        // `%{public}@` keeps the message readable in the log (not redacted as
        // `<private>`); these are diagnostics, never secrets.
        logger.log("\(message, privacy: .public)")
    }
}
