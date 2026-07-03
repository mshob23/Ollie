import AppKit
import Carbon
import Foundation
import HandheldNotesCore

/// Registers the user's Quick Capture global shortcuts and reports press/release
/// per action, so the app can implement hold-to-dictate (press = record, release =
/// save), toggle dictation, and the quick-pad popup from anywhere in macOS.
///
/// Carbon's `RegisterEventHotKey` is the primary path (no Accessibility permission
/// required) — one registration per bound action, distinguished by the
/// `EventHotKeyID` carried in the event. An `NSEvent` monitor pair is kept as a
/// fallback; a short per-edge debounce collapses the duplicate when both paths see
/// one event.
///
/// macOS-only (Carbon). It satisfies the core's `CaptureHotKeyController` protocol
/// so the platform-agnostic `AppModel` can drive capture without importing Carbon.
/// Both Carbon's app-event-target handler and the `NSEvent` monitors fire on the
/// main thread, so call sites bridge onto the main actor via `MainActor.assumeIsolated`.
@MainActor
final class HotKeyManager: CaptureHotKeyController {
    /// Called with the bound action and `true` on press / `false` on release.
    private let callback: @MainActor (CaptureHotKeyAction, Bool) -> Void

    /// Stable Carbon ids per action (the id rides inside the event).
    private static let actionIDs: [CaptureHotKeyAction: UInt32] = [
        .holdToDictate: 1, .toggleDictation: 2, .quickPad: 3,
    ]

    private var bindings: [CaptureHotKeyAction: KeyShortcut] = [:]
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandlerRef: EventHandlerRef?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var lastFire: [String: Date] = [:]   // "<action>-<pressed>" → time

    init(callback: @escaping @MainActor (CaptureHotKeyAction, Bool) -> Void) {
        self.callback = callback
    }

    // No `deinit`: this `@MainActor` type's stored Carbon/NSEvent refs are
    // non-Sendable and can't be touched from a nonisolated deinit under Swift 6.
    // The app owns a single instance for its whole lifetime.

    /// Replace ALL current registrations with `bindings` (the settings change path
    /// simply calls this again).
    func apply(bindings: [CaptureHotKeyAction: KeyShortcut]) {
        unregister()
        self.bindings = bindings
        guard !bindings.isEmpty else { return }

        let eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let handler: EventHandlerUPP = { _, eventRef, userData in
            guard let userData, let eventRef else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                eventRef, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return noErr }
            let pressed = GetEventKind(eventRef) == UInt32(kEventHotKeyPressed)
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            // Carbon delivers this on the main run-loop thread.
            MainActor.assumeIsolated { manager.fire(id: hotKeyID.id, pressed: pressed) }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), handler,
                            numericCast(eventTypes.count), eventTypes, selfPtr, &eventHandlerRef)

        let signature = OSType(UInt32(UInt8(ascii: "H")) << 24 | UInt32(UInt8(ascii: "N")) << 16
            | UInt32(UInt8(ascii: "O")) << 8 | UInt32(UInt8(ascii: "T")))
        for (action, shortcut) in bindings {
            guard let id = Self.actionIDs[action] else { continue }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                shortcut.keyCode, shortcut.carbonModifiers,
                EventHotKeyID(signature: signature, id: id),
                GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { hotKeyRefs.append(ref) }
        }

        installFallbackMonitors()
    }

    private func unregister() {
        for ref in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef); self.eventHandlerRef = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
    }

    // MARK: NSEvent fallback (covers edge cases where Carbon didn't claim the key)

    private func installFallbackMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown && event.isARepeat { return event }
            var consumed = false
            MainActor.assumeIsolated { consumed = self.handleMonitorEvent(event) }
            return consumed ? nil : event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return }
            if event.type == .keyDown && event.isARepeat { return }
            MainActor.assumeIsolated { _ = self.handleMonitorEvent(event) }
        }
    }

    /// Match a monitored key event against the bindings; fire and report consumption.
    private func handleMonitorEvent(_ event: NSEvent) -> Bool {
        let mods = Self.carbonModifiers(from: event.modifierFlags)
        for (action, shortcut) in bindings
        where shortcut.keyCode == UInt32(event.keyCode) && shortcut.carbonModifiers == mods {
            guard let id = Self.actionIDs[action] else { continue }
            fire(id: id, pressed: event.type == .keyDown)
            return true
        }
        return false
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option)  { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift)   { mods |= UInt32(shiftKey) }
        return mods
    }

    /// Invoked (on the main thread) from Carbon's handler and the NSEvent monitors.
    /// Per-action-per-edge debounce, then the @MainActor capture handler.
    private func fire(id: UInt32, pressed: Bool) {
        guard let action = Self.actionIDs.first(where: { $0.value == id })?.key else { return }
        let key = "\(action.rawValue)-\(pressed)"
        let now = Date()
        if let last = lastFire[key], now.timeIntervalSince(last) <= 0.04 { return }
        lastFire[key] = now
        callback(action, pressed)
    }
}
