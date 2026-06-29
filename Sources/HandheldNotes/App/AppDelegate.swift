import AppKit
import HandheldNotesCore
import SwiftUI

/// Hosts the SwiftUI `RootView` inside a real AppKit window. We drive the window
/// from an AppDelegate (rather than the SwiftUI `App` lifecycle) so the menu-bar
/// app, the global F16 hotkey, and the AppKit interop all live in one place and
/// the window reliably shows on launch for screenshots.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    // Inject the macOS Carbon hotkey as the core's PushToTalkController so the
    // platform-agnostic AppModel can drive push-to-talk without importing Carbon.
    private let model = AppModel(pushToTalk: { handler in HotKeyManager(callback: handler) })

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupMainMenu()

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
