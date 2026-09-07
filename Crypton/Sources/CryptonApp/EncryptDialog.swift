import AppKit

/// Modal sheet collecting the password and algorithm for a new vault.
final class EncryptDialog: NSViewController {
    private let folderPath: String
    private let onConfirm: (String, EncryptionAlgorithm, Bool) -> Void

    private let passwordField = NSSecureTextField()
    private let confirmField = NSSecureTextField()
    private let algorithmPopup = NSPopUpButton()
    private let keychainCheckbox = NSButton(checkboxWithTitle: "Remember password in my Keychain", target: nil, action: nil)
    private let strengthLabel = NSTextField(labelWithString: "")
    private var encryptButton: NSButton!

    init(folderPath: String, onConfirm: @escaping (String, EncryptionAlgorithm, Bool) -> Void) {
        self.folderPath = folderPath
        self.onConfirm = onConfirm
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))

        let title = NSTextField(labelWithString: "Protect Folder")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let folderLabel = NSTextField(labelWithString: (folderPath as NSString).lastPathComponent)
        folderLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let pathLabel = NSTextField(labelWithString: (folderPath as NSString).abbreviatingWithTildeInPath)
        pathLabel.font = .systemFont(ofSize: 10)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle

        passwordField.placeholderString = "Password"
        confirmField.placeholderString = "Confirm password"
        passwordField.target = self; passwordField.action = #selector(fieldChanged)
        confirmField.target = self; confirmField.action = #selector(fieldChanged)
        NotificationCenter.default.addObserver(self, selector: #selector(fieldChanged),
                                               name: NSControl.textDidChangeNotification, object: nil)

        for algorithm in EncryptionAlgorithm.allCases {
            algorithmPopup.addItem(withTitle: algorithm.displayName)
        }
        algorithmPopup.selectItem(withTitle: EncryptionAlgorithm.aes256.displayName)

        strengthLabel.font = .systemFont(ofSize: 10)
        strengthLabel.textColor = .secondaryLabelColor

        let warning = NSTextField(wrappingLabelWithString:
            "If you forget this password, the contents cannot be recovered. There is no backdoor and no reset.")
        warning.font = .systemFont(ofSize: 10)
        warning.textColor = .secondaryLabelColor

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        encryptButton = NSButton(title: "Encrypt", target: self, action: #selector(confirm))
        encryptButton.keyEquivalent = "\r"
        encryptButton.isEnabled = false

        let algorithmRow = NSStackView(views: [NSTextField(labelWithString: "Encryption:"), algorithmPopup])
        algorithmRow.spacing = 8

        let buttonRow = NSStackView(views: [NSView(), cancelButton, encryptButton])
        buttonRow.spacing = 10

        let stack = NSStackView(views: [
            title, folderLabel, pathLabel,
            passwordField, confirmField, strengthLabel,
            algorithmRow, keychainCheckbox, warning, buttonRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            passwordField.widthAnchor.constraint(equalToConstant: 380),
            confirmField.widthAnchor.constraint(equalToConstant: 380),
            warning.widthAnchor.constraint(equalToConstant: 380),
            buttonRow.widthAnchor.constraint(equalToConstant: 380),
        ])
    }

    @objc private func fieldChanged() {
        let password = passwordField.stringValue
        let long = password.count >= VaultManager.minimumPasswordLength
        let matching = !password.isEmpty && password == confirmField.stringValue
        encryptButton.isEnabled = long && matching

        if password.isEmpty {
            strengthLabel.stringValue = ""
        } else if !long {
            strengthLabel.stringValue = "At least \(VaultManager.minimumPasswordLength) characters required."
        } else if !confirmField.stringValue.isEmpty && !matching {
            strengthLabel.stringValue = "Passwords do not match."
        } else {
            strengthLabel.stringValue = password.count >= 16 ? "Strong password." : "Acceptable — longer is stronger."
        }
    }

    @objc private func cancel() { dismiss(nil) }

    @objc private func confirm() {
        let algorithm = EncryptionAlgorithm.allCases[algorithmPopup.indexOfSelectedItem]
        let remember = keychainCheckbox.state == .on
        let password = passwordField.stringValue
        // Clear the on-screen copies as soon as the value is handed off.
        passwordField.stringValue = ""
        confirmField.stringValue = ""
        dismiss(nil)
        onConfirm(password, algorithm, remember)
    }
}

/// Modal sheet for entering an existing vault's password.
final class UnlockDialog: NSViewController {
    private let vaultName: String
    private let onConfirm: (String) -> Void
    private let passwordField = NSSecureTextField()

    init(vaultName: String, onConfirm: @escaping (String) -> Void) {
        self.vaultName = vaultName
        self.onConfirm = onConfirm
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 150))

        let title = NSTextField(labelWithString: "Unlock “\(vaultName)”")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Enter the vault password.")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        passwordField.placeholderString = "Password"

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        let unlockButton = NSButton(title: "Unlock", target: self, action: #selector(confirm))
        unlockButton.keyEquivalent = "\r"

        let buttonRow = NSStackView(views: [NSView(), cancelButton, unlockButton])
        buttonRow.spacing = 10

        let stack = NSStackView(views: [title, subtitle, passwordField, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            passwordField.widthAnchor.constraint(equalToConstant: 340),
            buttonRow.widthAnchor.constraint(equalToConstant: 340),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(passwordField)
    }

    @objc private func cancel() { dismiss(nil) }

    @objc private func confirm() {
        let password = passwordField.stringValue
        passwordField.stringValue = ""
        dismiss(nil)
        onConfirm(password)
    }
}
