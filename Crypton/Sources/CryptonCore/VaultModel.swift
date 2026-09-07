import Foundation

/// Encryption strength selectable by the user at vault-creation time.
/// Maps directly to the cipher used by the underlying encrypted disk image.
public enum EncryptionAlgorithm: String, Codable, CaseIterable, Sendable {
    case aes128 = "AES-128"
    case aes256 = "AES-256"

    /// The value `hdiutil` expects for its `-encryption` flag.
    var hdiutilName: String {
        switch self {
        case .aes128: return "AES-128"
        case .aes256: return "AES-256"
        }
    }

    public var displayName: String { rawValue }
}

public enum VaultState: String, Codable, Sendable {
    case locked = "LOCKED"
    case unlocked = "UNLOCKED"
}

/// On-disk record describing one vault. Contains NO secret material:
/// no password, no key, no salt. Secrets live only in the Keychain and
/// inside the encrypted image itself.
public struct Vault: Codable, Identifiable, Sendable, Equatable {
    /// Format version of this registry record, so future Crypton versions can migrate safely.
    public var formatVersion: Int
    public var id: UUID
    /// Display name, derived from the original folder name.
    public var name: String
    /// The path the folder originally occupied. While unlocked, a symlink here
    /// points at the mounted volume so existing workflows keep working.
    public var originalPath: String
    /// Absolute path to the encrypted `.sparsebundle` container.
    public var containerPath: String
    public var algorithm: EncryptionAlgorithm
    public var createdAt: Date

    public init(
        formatVersion: Int = Vault.currentFormatVersion,
        id: UUID = UUID(),
        name: String,
        originalPath: String,
        containerPath: String,
        algorithm: EncryptionAlgorithm,
        createdAt: Date = Date()
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.name = name
        self.originalPath = originalPath
        self.containerPath = containerPath
        self.algorithm = algorithm
        self.createdAt = createdAt
    }

    public static let currentFormatVersion = 1

    /// Where this vault's volume appears while unlocked.
    public var mountPoint: String { "/Volumes/\(name)" }
}

public enum CryptonError: LocalizedError, Equatable {
    case folderNotFound(String)
    case notADirectory(String)
    case alreadyProtected(String)
    case destinationExists(String)
    case authenticationFailed
    case passwordMismatch
    case passwordTooShort(minimum: Int)
    case imageCreationFailed(String)
    case attachFailed(String)
    case detachFailed(String)
    case copyFailed(String)
    case vaultBusy(String)
    case integrityCheckFailed
    case keychainFailure(OSStatus)
    case symlinkEscape(String)

    public var errorDescription: String? {
        switch self {
        case .folderNotFound(let p): return "Folder not found: \(p)"
        case .notADirectory(let p): return "Not a folder: \(p)"
        case .alreadyProtected(let n): return "“\(n)” is already protected by Crypton."
        case .destinationExists(let p): return "An item already exists at \(p)."
        // Deliberately vague: never reveal whether the password, the metadata,
        // or the authentication tag was the failing component.
        case .authenticationFailed: return "Unable to unlock the vault."
        case .passwordMismatch: return "Passwords do not match."
        case .passwordTooShort(let m): return "Password must be at least \(m) characters."
        case .imageCreationFailed(let d): return "Could not create the encrypted container. \(d)"
        case .attachFailed(let d): return "Could not open the vault. \(d)"
        case .detachFailed(let d): return "Could not lock the vault. \(d)"
        case .copyFailed(let d): return "Could not transfer files. \(d)"
        case .vaultBusy(let n): return "“\(n)” is in use. Close any open files and try again."
        case .integrityCheckFailed: return "Unable to unlock the vault."
        case .keychainFailure(let s): return "Keychain error (code \(s))."
        case .symlinkEscape(let p): return "Refusing to operate on a symbolic link: \(p)"
        }
    }
}
