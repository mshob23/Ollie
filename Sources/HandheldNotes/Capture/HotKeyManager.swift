import AppKit
import Carbon
import Foundation
import HandheldNotesCore

/// Registers the global **F16** hotkey and reports both press and release, so the
/// app can implement push-to-talk (hold F16 to record, release to stop) exactly
/// as the handheld's D3 button emits it. Adapted from the old app's
/// HotKeyManager, narrowed to the single key this app needs.
///
/// Carbon's `RegisterEventHotKey` is the primary path (no Accessibility
/// permission required); an `NSEvent` monitor is kept as a fallback. A short
/// per-edge debounce collapses the duplicate when both paths see one event.
///
/// macOS-only (Carbon). It satisfies the core's `PushToTalkController` protocol so
/// the platform-agnostic `AppModel` can drive push-to-talk without importing
/// Carbon. Both Carbon's app-event-target handler and the `NSEvent` monitors fire
/// on the main thread, so the call sites bridge onto the main actor (which this
/// `@MainActor` class is isolated to) via `MainActor.assumeIsolated`.
@MainActor
final class HotKeyManager: PushToTalkController {
    /// Called with `true` on press, `false` on release.
    private let callback: @MainActor (Bool) -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var lastFire: [Bool: Date] = [:]

    init(callback: @escaping @MainActor (Bool) -> Void) {
        self.callback = callback
    }

    // No `deinit`: this `@MainActor` type's stored Carbon/NSEvent refs are
    // non-Sendable and can't be touched from a nonisolated deinit under Swift 6.
    // The app owns a single instance for its whole lifetime (the OS reclaims the
    // process-global hot-key and event monitors on exit), so explicit teardown is
    // only ever needed via `unregister()` (called at the top of `register()`).

    /// Returns true if Carbon claimed the key (the NSEvent fallback covers it
    /// otherwise, e.g. when the app isn't focused but the monitor still fires).
    @discardableResult
    func register() -> Bool {
        unregister()

        let eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let handler: EventHandlerUPP = { _, eventRef, userData in
            guard let userData, let eventRef else { return noErr }
            let pressed = GetEventKind(eventRef) == UInt32(kEventHotKeyPressed)
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            // Carbon delivers this on the main run-loop thread.
            MainActor.assumeIsolated { manager.fire(pressed: pressed) }
            return noErr
        }

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(), handler,
            numericCast(eventTypes.count), eventTypes, selfPtr, &eventHandlerRef)

        installFallbackMonitor()

        guard installStatus == noErr else { return false }

        let signature = OSType(UInt32(UInt8(ascii: "H")) << 24 | UInt32(UInt8(ascii: "N")) << 16
            | UInt32(UInt8(ascii: "O")) << 8 | UInt32(UInt8(ascii: "T")))
        let hotKeyID = EventHotKeyID(signature: signature, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(kVK_F16), 0, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            hotKeyRef = ref
            return true
        }
        return false
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef); self.eventHandlerRef = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
    }

    private func installFallbackMonitor() {
        // NSEvent monitor callbacks are delivered on the main thread.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown && event.isARepeat { return event }
            guard UInt32(event.keyCode) == UInt32(kVK_F16) else { return event }
            MainActor.assumeIsolated { self.fire(pressed: event.type == .keyDown) }
            return nil
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return }
            if event.type == .keyDown && event.isARepeat { return }
            guard UInt32(event.keyCode) == UInt32(kVK_F16) else { return }
            MainActor.assumeIsolated { self.fire(pressed: event.type == .keyDown) }
        }
    }

    /// Invoked (on the main thread) from Carbon's app-event-target handler and the
    /// NSEvent monitors. Per-edge debounce, then the @MainActor push-to-talk handler.
    private func fire(pressed: Bool) {
        let now = Date()
        if let last = lastFire[pressed], now.timeIntervalSince(last) <= 0.04 { return }
        lastFire[pressed] = now
        callback(pressed)
    }
}
