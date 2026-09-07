import AppKit
import OSLog

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "com.crypton.app", category: "App")
    let manager = VaultManager()
    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        let controller = MainWindowController(manager: manager)
        controller.showWindow(nil)
        windowController = controller
        NSApp.activate(ignoringOtherApps: true)

        registerAutoLockObservers()
    }

    /// Locks every vault on the security-relevant system events.
    /// Reboot and power loss need no handler: unlocked state lives only in the
    /// mount table, so anything that stops the machine leaves all vaults locked.
    private func registerAutoLockObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name: NSNotification.Name in [
            NSWorkspace.willSleepNotification,
            NSWorkspace.willPowerOffNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ] {
            workspace.addObserver(self, selector: #selector(lockEverything), name: name, object: nil)
        }
        // Screen lock is delivered on the distributed centre, not the workspace one.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(lockEverything),
            name: NSNotification.Name("com.apple.screenIsLocked"), object: nil
        )
    }

    @objc private func lockEverything() {
        log.info("System security event: locking all vaults")
        manager.lockAll()
        windowController?.refresh()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let unlocked = manager.allVaults().filter { manager.state(of: $0) == .unlocked }
        guard !unlocked.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Lock \(unlocked.count) unlocked vault\(unlocked.count == 1 ? "" : "s") before quitting?"
        alert.informativeText = "Vaults left unlocked stay accessible until you lock them or restart."
        alert.addButton(withTitle: "Lock and Quit")
        alert.addButton(withTitle: "Quit Without Locking")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            manager.lockAll()
            return .terminateNow
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windowController?.showWindow(nil) }
        return true
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Crypton", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Lock All Vaults", action: #selector(lockEverything), keyEquivalent: "L")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Crypton", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Crypton", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Protect Folder…", action: #selector(MainWindowController.protectFolder), keyEquivalent: "n")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Crypton"
        alert.informativeText = """
            Local-first encrypted folder protection for macOS.

            Vaults are stored as encrypted APFS disk images using AES-128 or \
            AES-256. While locked, contents are ciphertext on disk and \
            unreadable by Finder, Terminal, editors, and scripts alike.

            All vaults lock automatically on sleep, screen lock, logout, and restart.
            """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
