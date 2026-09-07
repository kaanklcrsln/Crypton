import Foundation
import OSLog

/// Orchestrates the vault lifecycle: encrypt, unlock, lock, decrypt.
///
/// Ordering rules that protect user data:
/// - During ENCRYPT, the original folder is deleted only after every file has
///   been copied in and the container has been detached and re-verified.
/// - During DECRYPT, plaintext is written to a temporary staging directory and
///   moved into place atomically; a failure part-way leaves no partial output.
public final class VaultManager: @unchecked Sendable {
    private let log = Logger(subsystem: "com.crypton.app", category: "VaultManager")
    private let registry: VaultRegistry
    private let fm = FileManager.default

    public static let minimumPasswordLength = 8

    /// Volume bookkeeping entries that are never user data. Both the copy and
    /// the verification step use this same set, so their counts cannot diverge.
    private static let skippedNames: Set<String> = [
        ".fseventsd", ".Trashes", ".Spotlight-V100", ".DS_Store", ".TemporaryItems",
    ]

    public init(registry: VaultRegistry = VaultRegistry()) {
        self.registry = registry
    }

    public func allVaults() -> [Vault] { registry.load() }

    /// A vault is unlocked exactly when its volume is mounted. This is derived
    /// from the live filesystem rather than stored, so a crash, forced power-off,
    /// or reboot can never leave a stale "unlocked" record behind.
    public func state(of vault: Vault) -> VaultState {
        isMountPoint(vault.mountPoint) ? .unlocked : .locked
    }

    /// Verifies a path is a real mount root by comparing device IDs with its parent.
    private func isMountPoint(_ path: String) -> Bool {
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let deviceID = attrs[.systemNumber] as? Int else { return false }
        let parent = (path as NSString).deletingLastPathComponent
        guard let parentAttrs = try? fm.attributesOfItem(atPath: parent),
              let parentDeviceID = parentAttrs[.systemNumber] as? Int else { return false }
        return deviceID != parentDeviceID
    }

    // MARK: - Encrypt

    /// Converts a plaintext folder into an encrypted vault.
    public func encrypt(
        folderPath: String,
        password: String,
        confirmPassword: String,
        algorithm: EncryptionAlgorithm,
        savePasswordToKeychain: Bool = false,
        progress: ((String) -> Void)? = nil
    ) throws -> Vault {
        guard password == confirmPassword else { throw CryptonError.passwordMismatch }
        guard password.count >= Self.minimumPasswordLength else {
            throw CryptonError.passwordTooShort(minimum: Self.minimumPasswordLength)
        }

        // Resolve symlinks up front: a path string alone does not identify a
        // filesystem object, and we must not follow a link out of the intended target.
        let source = (folderPath as NSString).expandingTildeInPath
        guard fm.fileExists(atPath: source) else { throw CryptonError.folderNotFound(source) }

        // attributesOfItem follows symlinks, so use lstat(2) to inspect the link itself.
        if Self.isSymlink(source) {
            throw CryptonError.symlinkEscape(source)
        }
        var isDir: ObjCBool = false
        fm.fileExists(atPath: source, isDirectory: &isDir)
        guard isDir.boolValue else { throw CryptonError.notADirectory(source) }

        let name = (source as NSString).lastPathComponent
        if allVaults().contains(where: { $0.originalPath == source }) {
            throw CryptonError.alreadyProtected(name)
        }

        // hdiutil appends ".sparsebundle" unless the path already ends with it,
        // so name the container explicitly to keep our path and the real one identical.
        let containerPath = source + ".crypton.sparsebundle"
        guard !fm.fileExists(atPath: containerPath) else {
            throw CryptonError.destinationExists(containerPath)
        }

        progress?("Measuring folder…")
        let sizeMB = requiredSizeMB(of: source)

        progress?("Creating encrypted container…")
        try DiskImage.create(
            at: containerPath,
            volumeName: name,
            sizeMB: sizeMB,
            algorithm: algorithm,
            password: password
        )

        let vault = Vault(
            name: name,
            originalPath: source,
            containerPath: containerPath,
            algorithm: algorithm
        )

        do {
            progress?("Copying files into the vault…")
            let mount = try DiskImage.attach(
                containerPath: containerPath,
                mountPoint: nil,
                password: password
            )
            try copyContents(from: source, to: mount)
            // Flush to the encrypted backing store before we trust the copy.
            try DiskImage.detach(mountPoint: mount)

            progress?("Verifying…")
            // Re-open with the same password to confirm the container is sound
            // and readable BEFORE the plaintext original is removed.
            let verifyMount = try DiskImage.attach(
                containerPath: containerPath,
                mountPoint: nil,
                password: password
            )
            // Compare the actual names, not just counts, so a mismatch says which
            // item is missing instead of reporting an opaque number.
            let copied = Set(try fm.contentsOfDirectory(atPath: verifyMount)
                .filter { !Self.skippedNames.contains($0) })
            let expected = Set(try fm.contentsOfDirectory(atPath: source)
                .filter { !Self.skippedNames.contains($0) })
            try DiskImage.detach(mountPoint: verifyMount)

            let missing = expected.subtracting(copied)
            guard missing.isEmpty else {
                let names = missing.sorted().prefix(3).joined(separator: ", ")
                let suffix = missing.count > 3 ? " and \(missing.count - 3) more" : ""
                throw CryptonError.copyFailed("These items did not transfer: \(names)\(suffix).")
            }

            progress?("Removing the plaintext folder…")
            // Only now is it safe to destroy the original.
            try fm.removeItem(atPath: source)

            if savePasswordToKeychain {
                try? KeychainStore.savePassword(password, vaultID: vault.id)
            }
            try registry.add(vault)
            log.info("Vault created (\(algorithm.rawValue, privacy: .public))")
            return vault

        } catch {
            // Roll back: never strand a half-built container next to intact plaintext.
            try? fm.removeItem(atPath: containerPath)
            throw error
        }
    }

    // MARK: - Unlock / Lock

    /// Mounts the vault and restores a symlink at the original path so existing
    /// paths, scripts, and editor workspaces keep resolving.
    @discardableResult
    public func unlock(_ vault: Vault, password: String) throws -> String {
        if state(of: vault) == .unlocked { return vault.mountPoint }

        let mount = try DiskImage.attach(
            containerPath: vault.containerPath,
            mountPoint: nil,
            password: password
        )
        createCompatibilitySymlink(for: vault, target: mount)
        log.info("Vault unlocked")
        return mount
    }

    public func lock(_ vault: Vault) throws {
        removeCompatibilitySymlink(for: vault)
        guard state(of: vault) == .unlocked else { return }
        try DiskImage.detach(mountPoint: vault.mountPoint)
        log.info("Vault locked")
    }

    /// Locks every mounted vault. Used for sleep, screen lock, and quit.
    public func lockAll() {
        for vault in allVaults() where state(of: vault) == .unlocked {
            try? lock(vault)
        }
    }

    /// Bridges the original folder path to the mounted volume.
    /// This is a convenience link, not a security boundary: when the vault is
    /// locked the link is removed and its target no longer exists.
    private func createCompatibilitySymlink(for vault: Vault, target: String) {
        let link = vault.originalPath
        if Self.isSymlink(link) {
            try? fm.removeItem(atPath: link)
        }
        guard !fm.fileExists(atPath: link) else { return }
        try? fm.createSymbolicLink(atPath: link, withDestinationPath: target)
    }

    private func removeCompatibilitySymlink(for vault: Vault) {
        let link = vault.originalPath
        // Only ever remove a symlink — never a real directory.
        guard Self.isSymlink(link) else { return }
        try? fm.removeItem(atPath: link)
    }

    // MARK: - Decrypt

    /// Permanently converts the vault back into a normal plaintext folder.
    public func decrypt(_ vault: Vault, password: String, progress: ((String) -> Void)? = nil) throws {
        progress?("Verifying password…")
        // Fail before touching anything if the password is wrong.
        let mount = try DiskImage.attach(
            containerPath: vault.containerPath,
            mountPoint: nil,
            password: password
        )

        removeCompatibilitySymlink(for: vault)
        let destination = vault.originalPath
        if fm.fileExists(atPath: destination) {
            try? DiskImage.detach(mountPoint: mount)
            throw CryptonError.destinationExists(destination)
        }

        // Stage into a sibling temp directory, then move into place, so an
        // interrupted decrypt never leaves partial plaintext at the real path.
        let staging = destination + ".crypton-restoring"
        try? fm.removeItem(atPath: staging)

        do {
            progress?("Decrypting files…")
            try fm.createDirectory(atPath: staging, withIntermediateDirectories: true)
            try copyContents(from: mount, to: staging)
            try DiskImage.detach(mountPoint: mount)

            progress?("Finalizing…")
            try fm.moveItem(atPath: staging, toPath: destination)

            try fm.removeItem(atPath: vault.containerPath)
            try? KeychainStore.deletePassword(vaultID: vault.id)
            try registry.remove(id: vault.id)
            log.info("Vault decrypted and removed")
        } catch {
            try? fm.removeItem(atPath: staging)
            try? DiskImage.detach(mountPoint: mount)
            throw error
        }
    }

    // MARK: - Helpers

    /// Reports whether the path itself is a symbolic link, without following it.
    static func isSymlink(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// Copies directory contents, skipping volume bookkeeping directories.
    private func copyContents(from source: String, to destination: String) throws {
        let items = try fm.contentsOfDirectory(atPath: source)
        for item in items where !Self.skippedNames.contains(item) {
            let src = (source as NSString).appendingPathComponent(item)
            let dst = (destination as NSString).appendingPathComponent(item)
            if fm.fileExists(atPath: dst) { try fm.removeItem(atPath: dst) }
            do {
                try fm.copyItem(atPath: src, toPath: dst)
            } catch {
                throw CryptonError.copyFailed("\(item): \(error.localizedDescription)")
            }
        }
    }

    /// Sizes the sparsebundle with headroom. The image is sparse, so this
    /// reserves an upper bound without consuming the space on disk.
    private func requiredSizeMB(of path: String) -> Int {
        var total: UInt64 = 0
        if let e = fm.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in e {
                total += UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        let mb = Int(total / 1_048_576)
        // Generous growth room, with a sane floor for small/empty folders.
        return max(mb * 3, 100) + 200
    }
}
