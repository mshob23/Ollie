import AppKit
import Combine
import HandheldNotesCore
import SwiftUI

/// Hosts the SwiftUI `RootView` inside a real AppKit window. We drive the window
/// from an AppDelegate (rather than the SwiftUI `App` lifecycle) so the menu-bar
/// presence, the global Quick Capture hotkeys, and the AppKit interop all live in
/// one place and the window reliably shows on launch for screenshots.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    // Inject the macOS Carbon hotkey manager as the core's CaptureHotKeyController
    // so the platform-agnostic AppModel can drive Quick Capture without Carbon.
    private let model = AppModel(captureHotKeys: { handler in HotKeyManager(callback: handler) })
    private var statusItem: NSStatusItem?
    private var quickPadPanel: NSPanel?
    private let overlay = QuickCaptureOverlayController()
    private var lastRecordingState: RecordingState = .idle
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupMainMenu()
        setupStatusItem()
        observeQuickCapture()

        let hosting = NSHostingController(rootView: RootView().environmentObject(model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Ollie"
        window.setContentSize(NSSize(width: 1080, height: 720))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // NB: do NOT set `isMovableByWindowBackground = true`. With
        // `.fullSizeContentView` the content extends under the (hidden) title bar,
        // and a background-movable window installs an invisible window-drag tracking
        // region across that whole top strip — exactly where the capture bar's
        // Send / Space / Newline / Backspace buttons sit. That region intercepts the
        // mouseDown for window dragging, so clicks on those controls never reach the
        // SwiftUI hit-test (this surfaced in testing as a phantom transparent window
        // swallowing clicks over the capture area). Leaving it off lets the controls
        // receive their clicks; the window is still draggable by the empty title-bar
        // strip above the capture content.
        window.backgroundColor = NSColor(red: 0.122, green: 0.118, blue: 0.114, alpha: 1)
        window.minSize = NSSize(width: 880, height: 560)
        window.center()
        window.appearance = NSAppearance(named: .darkAqua)
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)

        // CloudKit *incremental* sync needs silent remote-notification pushes. SwiftData /
        // NSPersistentCloudKitContainer creates the CKDatabaseSubscription but does NOT
        // register the app for remote notifications — so without this call the app only
        // imports peers' changes at store setup (i.e. on launch), never live. (apsd showed
        // zero pushes for our container until this was added.) Silent/content-available
        // pushes need no user permission, so there's nothing to prompt for.
        NSApp.registerForRemoteNotifications()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NSLog("HNDIAG APNs registered: %d-byte token — CloudKit live push enabled", deviceToken.count)
    }

    func application(_ application: NSApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("HNDIAG APNs registration FAILED: %@", error.localizedDescription)
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        // A CloudKit silent push. NSPersistentCloudKitContainer imports the change and
        // posts .NSPersistentStoreRemoteChange, which AppModel observes to refresh the UI.
        NSLog("HNDIAG remote notification received (CloudKit change)")
    }

    // MARK: Quick Capture — menu bar indicator + confirm + quick pad

    /// A menu-bar mic that doubles as the discreet recording indicator: gray at
    /// rest, red while a quick capture is live, accent while transcribing.
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        updateStatusIcon()

        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Start Dictation",
                                action: #selector(menuToggleDictation), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        let pad = NSMenuItem(title: "Quick Note…",
                             action: #selector(menuQuickPad), keyEquivalent: "")
        pad.target = self
        menu.addItem(pad)
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Ollie",
                              action: #selector(menuOpenApp), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        item.menu = menu
    }

    private func observeQuickCapture() {
        // Icon + menu title track the capture state; the floating overlay follows
        // QUICK captures only (the in-app draft flow has the capture bar).
        model.$recordingState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                self.updateStatusIcon()
                self.updateOverlay(for: state)
            }
            .store(in: &cancellables)

        // Live mic level → the overlay's listening meter.
        model.$micLevel
            .receive(on: RunLoop.main)
            .sink { [weak self] level in self?.overlay.update(level: level) }
            .store(in: &cancellables)

        // "Ask before saving": a finished quick capture awaits Save/Discard.
        model.$pendingQuickCapture
            .receive(on: RunLoop.main)
            .compactMap { $0 }
            .sink { [weak self] pending in self?.presentQuickCaptureConfirm(pending) }
            .store(in: &cancellables)

        // The quick-pad shortcut fired.
        model.$quickPadRequestCount
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.showQuickPad() }
            .store(in: &cancellables)
    }

    /// Drive the floating overlay from the quick-capture lifecycle:
    /// recording → listening meter; transcribing → breathing dome; done → a brief
    /// "Saved to Ollie" flash (unless the confirm dialog is taking over).
    private func updateOverlay(for state: RecordingState) {
        defer { lastRecordingState = state }
        guard model.captureMode == .quick else {
            // A DRAFT capture (in-app) never shows the overlay; make sure a stale
            // quick overlay isn't lingering when the draft flow starts.
            if case .recording = state { overlay.hide() }
            return
        }
        switch state {
        case .recording:
            overlay.show(mode: .recording)
        case .transcribing:
            overlay.show(mode: .transcribing)
        case .idle:
            switch lastRecordingState {
            case .transcribing where model.pendingQuickCapture == nil:
                // Finished and auto-saved (failures save a recoverable placeholder,
                // so "saved" is honest either way).
                overlay.flashResult(success: true, message: "Saved to Ollie")
            case .recording:
                // Stopped without transcribing = sub-0.5s accidental tap (discarded)
                // or a mic error — just slip away.
                overlay.hide()
            default:
                overlay.hide()
            }
        case .error:
            overlay.hide()
        }
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let (symbol, color): (String, NSColor?) = {
            switch model.recordingState {
            case .recording:
                return ("mic.fill", .systemRed)
            case .transcribing:
                return ("waveform", NSColor(red: 0.91, green: 0.45, blue: 0.32, alpha: 1))
            default:
                return ("mic", nil)   // template gray at rest
            }
        }()
        var image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Ollie capture")
        if let color {
            image = image?.withSymbolConfiguration(.init(paletteColors: [color]))
            image?.isTemplate = false
        } else {
            image?.isTemplate = true
        }
        button.image = image

        if let toggle = statusItem?.menu?.items.first {
            toggle.title = model.recordingState == .recording && model.captureMode == .quick
                ? "Stop & Save" : "Start Dictation"
        }
    }

    @objc private func menuToggleDictation() {
        Task { await model.toggleQuickCapture() }
    }

    @objc private func menuQuickPad() { showQuickPad() }

    @objc private func menuOpenApp() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The Save/Discard confirmation for "ask before saving": ↩ saves (default
    /// button), ⇥ then ␣ — or esc — discards.
    private func presentQuickCaptureConfirm(_ pending: AppModel.PendingQuickCapture) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Save this note?"
        let preview = pending.text.count > 400
            ? String(pending.text.prefix(400)) + "…" : pending.text
        alert.informativeText = preview
        alert.addButton(withTitle: "Save")                     // first = default (↩)
        let discard = alert.addButton(withTitle: "Discard")
        discard.keyEquivalent = "\u{1b}"                       // esc also discards
        let save = alert.runModal() == .alertFirstButtonReturn
        model.resolveQuickCapture(save: save)
        overlay.flashResult(success: save,
                            message: save ? "Saved to Ollie" : "Discarded")
    }

    /// Show (or re-show) the floating quick-note pad. Fresh content each time.
    private func showQuickPad() {
        quickPadPanel?.close()
        let content = QuickPadView(
            onSave: { [weak self] text in
                self?.model.saveQuickTextNote(text)
                self?.quickPadPanel?.close()
                self?.quickPadPanel = nil
            },
            onCancel: { [weak self] in
                self?.quickPadPanel?.close()
                self?.quickPadPanel = nil
            })
        let hosting = NSHostingController(rootView: content)
        let panel = NSPanel(contentViewController: hosting)
        panel.title = "Quick note"
        panel.styleMask = [.titled, .closable, .fullSizeContentView]
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.level = .floating
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = NSColor(red: 0.122, green: 0.118, blue: 0.114, alpha: 1)
        panel.isReleasedWhenClosed = false
        panel.center()
        quickPadPanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Ollie", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Ollie", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Ollie", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }
}
