import Foundation

// Terminal front-end for Crypton. Shares the same core and registry as the app,
// so vaults created in either are visible and controllable from both.

let manager = VaultManager()

func readPassword(prompt: String) -> String {
    // Uses getpass(3) so the password is never echoed and never enters argv.
    guard let raw = getpass(prompt) else { return "" }
    return String(cString: raw)
}

func printUsage() {
    print("""
    crypton — encrypted folder protection

    USAGE
      crypton list                     Show all vaults and their state
      crypton protect <folder>         Encrypt a folder into a new vault
      crypton unlock <name>            Mount a vault for normal use
      crypton lock <name>              Unmount a vault
      crypton lock-all                 Lock every unlocked vault
      crypton decrypt <name>           Permanently restore a plaintext folder

    OPTIONS
      --aes128                        Use AES-128 (default is AES-256)

    Passwords are read from the terminal without echo. They are never accepted
    as command-line arguments, because arguments are visible to other users
    through ps(1).
    """)
}

func findVault(_ name: String) -> Vault? {
    let all = manager.allVaults()
    return all.first { $0.name == name }
        ?? all.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { printUsage(); exit(0) }
let operands = arguments.dropFirst().filter { !$0.hasPrefix("--") }
let useAES128 = arguments.contains("--aes128")

switch command {
case "list", "ls":
    let vaults = manager.allVaults()
    if vaults.isEmpty { print("No vaults."); exit(0) }
    for vault in vaults {
        let state = manager.state(of: vault)
        let marker = state == .unlocked ? "○" : "●"
        print("\(marker) \(vault.name)  [\(vault.algorithm.displayName)] \(state.rawValue)")
        print("    \((vault.originalPath as NSString).abbreviatingWithTildeInPath)")
        if state == .unlocked { print("    mounted at \(vault.mountPoint)") }
    }

case "protect", "encrypt":
    guard let folder = operands.first else { fail("usage: crypton protect <folder>") }
    let password = readPassword(prompt: "Password: ")
    guard password.count >= VaultManager.minimumPasswordLength else {
        fail("password must be at least \(VaultManager.minimumPasswordLength) characters")
    }
    let confirm = readPassword(prompt: "Confirm password: ")
    guard password == confirm else { fail("passwords do not match") }
    do {
        let vault = try manager.encrypt(
            folderPath: folder,
            password: password,
            confirmPassword: confirm,
            algorithm: useAES128 ? .aes128 : .aes256
        ) { print($0) }
        print("Protected “\(vault.name)” with \(vault.algorithm.displayName). Vault is LOCKED.")
    } catch { fail(error.localizedDescription) }

case "unlock":
    guard let name = operands.first, let vault = findVault(name) else { fail("no such vault") }
    let password = KeychainStore.loadPassword(vaultID: vault.id) ?? readPassword(prompt: "Password: ")
    do {
        let mount = try manager.unlock(vault, password: password)
        print("Unlocked at \(mount)")
        print("Original path also works: \((vault.originalPath as NSString).abbreviatingWithTildeInPath)")
    } catch { fail(error.localizedDescription) }

case "lock":
    guard let name = operands.first, let vault = findVault(name) else { fail("no such vault") }
    do { try manager.lock(vault); print("Locked “\(vault.name)”.") }
    catch { fail(error.localizedDescription) }

case "lock-all":
    manager.lockAll()
    print("All vaults locked.")

case "decrypt":
    guard let name = operands.first, let vault = findVault(name) else { fail("no such vault") }
    print("This permanently removes encryption from “\(vault.name)”.")
    print("Type the vault name to confirm: ", terminator: "")
    guard readLine()?.trimmed == vault.name else { print("Cancelled."); exit(0) }
    let password = readPassword(prompt: "Password: ")
    do {
        try manager.decrypt(vault, password: password) { print($0) }
        print("Decrypted to \((vault.originalPath as NSString).abbreviatingWithTildeInPath)")
    } catch { fail(error.localizedDescription) }

case "help", "--help", "-h":
    printUsage()

default:
    fail("unknown command “\(command)”. Run `crypton help`.")
}
