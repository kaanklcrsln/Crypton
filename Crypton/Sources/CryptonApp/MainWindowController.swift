import AppKit
import OSLog

final class MainWindowController: NSWindowController {
    private let log = Logger(subsystem: "com.crypton.app", category: "UI")
    private let manager: VaultManager
    private var vaults: [Vault] = []

    private var tableView: NSTableView!
    private var emptyLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var spinner: NSProgressIndicator!

    init(manager: VaultManager) {
        self.manager = manager
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Crypton"
        window.center()
        window.setFrameAutosaveName("CryptonMainWindow")
        super.init(window: window)
        buildInterface()
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func buildInterface() {
        guard let window else { return }
        let content = NSView()

        let toolbar = NSView()
        let addButton = NSButton(title: "Protect Folder…", target: self, action: #selector(protectFolder))
        addButton.bezelStyle = .rounded
        let lockAllButton = NSButton(title: "Lock All", target: self, action: #selector(lockAll))
        lockAllButton.bezelStyle = .rounded

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let toolbarStack = NSStackView(views: [addButton, lockAllButton, spinner, statusLabel, NSView()])
        toolbarStack.spacing = 10
        toolbarStack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(toolbarStack)
        NSLayoutConstraint.activate([
            toolbarStack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 16),
            toolbarStack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -16),
            toolbarStack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
        ])

        tableView = NSTableView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 62
        tableView.headerView = nil
        tableView.style = .inset
        tableView.selectionHighlightStyle = .regular
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel = NSTextField(wrappingLabelWithString:
            "No protected folders yet.\n\nChoose “Protect Folder…” to encrypt a folder with a password.")
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(toolbar)
        content.addSubview(scrollView)
        content.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 52),

            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            emptyLabel.widthAnchor.constraint(equalToConstant: 320),
        ])

        window.contentView = content
    }

    func refresh() {
        vaults = manager.allVaults().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        emptyLabel.isHidden = !vaults.isEmpty
        tableView.reloadData()
        let unlocked = vaults.filter { manager.state(of: $0) == .unlocked }.count
        statusLabel.stringValue = vaults.isEmpty
            ? ""
            : "\(vaults.count) vault\(vaults.count == 1 ? "" : "s") · \(unlocked) unlocked"
    }

    // MARK: - Long-running work

    /// Runs a vault operation off the main thread so the UI stays responsive,
    /// then refreshes and reports any failure with a native alert.
    private func perform(_ description: String, _ work: @escaping () throws -> Void) {
        spinner.startAnimation(nil)
        statusLabel.stringValue = description
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var thrown: Error?
            do { try work() } catch { thrown = error }
            DispatchQueue.main.async {
                guard let self else { return }
                self.spinner.stopAnimation(nil)
                self.refresh()
                if let thrown { self.presentError(thrown) }
            }
        }
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Crypton"
        // CryptonError descriptions are deliberately non-revealing.
        alert.informativeText = (error as? CryptonError)?.errorDescription ?? error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window!)
    }

    // MARK: - Actions

    @objc func protectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder to protect with Crypton."

        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let path = panel.url?.path, let self else { return }
            let dialog = EncryptDialog(folderPath: path) { password, algorithm, remember in
                self.perform("Encrypting…") {
                    _ = try self.manager.encrypt(
                        folderPath: path,
                        password: password,
                        confirmPassword: password,
                        algorithm: algorithm,
                        savePasswordToKeychain: remember
                    )
                }
            }
            // Present after the open panel's sheet has fully dismissed.
            DispatchQueue.main.async {
                self.contentViewController(present: dialog)
            }
        }
    }

    private func contentViewController(present dialog: NSViewController) {
        if window?.contentViewController == nil {
            let host = NSViewController()
            host.view = window!.contentView!
            window!.contentViewController = host
        }
        window?.contentViewController?.presentAsSheet(dialog)
    }

    @objc private func lockAll() {
        perform("Locking…") { self.manager.lockAll() }
    }

    private func unlock(_ vault: Vault) {
        // Use a saved Keychain password when the user opted in, otherwise prompt.
        if let saved = KeychainStore.loadPassword(vaultID: vault.id) {
            perform("Unlocking…") { try self.manager.unlock(vault, password: saved) }
            return
        }
        let dialog = UnlockDialog(vaultName: vault.name) { [weak self] password in
            guard let self else { return }
            self.perform("Unlocking…") { try self.manager.unlock(vault, password: password) }
        }
        contentViewController(present: dialog)
    }

    private func lock(_ vault: Vault) {
        perform("Locking…") { try self.manager.lock(vault) }
    }

    private func decrypt(_ vault: Vault) {
        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = "Permanently decrypt “\(vault.name)”?"
        confirm.informativeText = """
            The folder returns to normal, unencrypted storage at its original \
            location and Crypton stops protecting it.
            """
        confirm.addButton(withTitle: "Decrypt")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let dialog = UnlockDialog(vaultName: vault.name) { [weak self] password in
            guard let self else { return }
            self.perform("Decrypting…") { try self.manager.decrypt(vault, password: password) }
        }
        contentViewController(present: dialog)
    }

    private func reveal(_ vault: Vault) {
        let path = manager.state(of: vault) == .unlocked ? vault.mountPoint : vault.containerPath
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: (path as NSString).deletingLastPathComponent)
    }
}

// MARK: - Table data

extension MainWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { vaults.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let vault = vaults[row]
        let state = manager.state(of: vault)

        let name = NSTextField(labelWithString: vault.name)
        name.font = .systemFont(ofSize: 13, weight: .semibold)

        let path = NSTextField(labelWithString: (vault.originalPath as NSString).abbreviatingWithTildeInPath)
        path.font = .systemFont(ofSize: 10)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle

        let badge = NSTextField(labelWithString: "\(vault.algorithm.displayName) · \(state.rawValue)")
        badge.font = .systemFont(ofSize: 10, weight: .medium)
        badge.textColor = state == .unlocked ? .systemGreen : .secondaryLabelColor

        let symbolName = state == .unlocked ? "lock.open.fill" : "lock.fill"
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: state.rawValue)
        icon.contentTintColor = state == .unlocked ? .systemGreen : .secondaryLabelColor

        let info = NSStackView(views: [name, path, badge])
        info.orientation = .vertical
        info.alignment = .leading
        info.spacing = 2

        var buttons: [NSView] = []
        if state == .locked {
            let unlockButton = NSButton(title: "Unlock", target: self, action: #selector(unlockRow(_:)))
            unlockButton.tag = row
            unlockButton.bezelStyle = .rounded
            buttons.append(unlockButton)
        } else {
            let lockButton = NSButton(title: "Lock", target: self, action: #selector(lockRow(_:)))
            lockButton.tag = row
            lockButton.bezelStyle = .rounded
            let openButton = NSButton(title: "Open", target: self, action: #selector(revealRow(_:)))
            openButton.tag = row
            openButton.bezelStyle = .rounded
            buttons += [openButton, lockButton]
        }
        let decryptButton = NSButton(title: "Decrypt", target: self, action: #selector(decryptRow(_:)))
        decryptButton.tag = row
        decryptButton.bezelStyle = .rounded
        buttons.append(decryptButton)

        let actions = NSStackView(views: buttons)
        actions.spacing = 6

        let row = NSStackView(views: [icon, info, NSView(), actions])
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        return row
    }

    @objc private func unlockRow(_ sender: NSButton) { unlock(vaults[sender.tag]) }
    @objc private func lockRow(_ sender: NSButton) { lock(vaults[sender.tag]) }
    @objc private func decryptRow(_ sender: NSButton) { decrypt(vaults[sender.tag]) }
    @objc private func revealRow(_ sender: NSButton) { reveal(vaults[sender.tag]) }
}
