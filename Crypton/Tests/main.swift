import Foundation

// A dependency-free test harness. XCTest is unavailable without Xcode, so this
// runs as a plain executable and exercises the real filesystem and real hdiutil.

var passed = 0, failed = 0
var failures: [String] = []

func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() { passed += 1; print("  ok   \(name)") }
    else { failed += 1; failures.append(name); print("  FAIL \(name)") }
}

func checkThrows<T>(_ name: String, _ expected: CryptonError, _ body: () throws -> T) {
    do {
        _ = try body()
        failed += 1; failures.append(name)
        print("  FAIL \(name) (expected an error, none thrown)")
    } catch let error as CryptonError where error == expected {
        passed += 1; print("  ok   \(name)")
    } catch {
        failed += 1; failures.append(name)
        print("  FAIL \(name) (got \(error))")
    }
}

func section(_ title: String) { print("\n\(title)") }

let fm = FileManager.default
let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("crypton-tests-\(UUID().uuidString)")
try! fm.createDirectory(at: sandbox, withIntermediateDirectories: true)

func makeManager() -> VaultManager {
    let store = sandbox.appendingPathComponent("registry-\(UUID().uuidString).json")
    return VaultManager(registry: VaultRegistry(storeURL: store))
}

/// Builds a folder with nested dirs, unicode names, spaces, and a large file.
@discardableResult
func makeFolder(_ name: String, largeFileMB: Int = 0) -> String {
    let root = sandbox.appendingPathComponent(name)
    try? fm.createDirectory(at: root.appendingPathComponent("nested/deep"), withIntermediateDirectories: true)
    try? "hello world".write(to: root.appendingPathComponent("plain.txt"), atomically: true, encoding: .utf8)
    try? "spaced".write(to: root.appendingPathComponent("file with spaces.txt"), atomically: true, encoding: .utf8)
    try? "unicode".write(to: root.appendingPathComponent("türkçe-日本語-🔐.txt"), atomically: true, encoding: .utf8)
    try? "deep".write(to: root.appendingPathComponent("nested/deep/buried.txt"), atomically: true, encoding: .utf8)
    try? fm.createDirectory(at: root.appendingPathComponent("empty-dir"), withIntermediateDirectories: true)
    if largeFileMB > 0 {
        let data = Data(repeating: 0xAB, count: largeFileMB * 1_048_576)
        try? data.write(to: root.appendingPathComponent("large.bin"))
    }
    return root.path
}

let PW = "correct-horse-battery"

// ---------------------------------------------------------------
section("Password and input validation")
// ---------------------------------------------------------------
do {
    let m = makeManager()
    let folder = makeFolder("validation")

    checkThrows("mismatched passwords rejected", .passwordMismatch) {
        try m.encrypt(folderPath: folder, password: "aaaaaaaa", confirmPassword: "bbbbbbbb", algorithm: .aes256)
    }
    checkThrows("short password rejected", .passwordTooShort(minimum: 8)) {
        try m.encrypt(folderPath: folder, password: "abc", confirmPassword: "abc", algorithm: .aes256)
    }
    checkThrows("missing folder rejected", .folderNotFound(sandbox.appendingPathComponent("nope").path)) {
        try m.encrypt(folderPath: sandbox.appendingPathComponent("nope").path,
                      password: PW, confirmPassword: PW, algorithm: .aes256)
    }
    // A file is not a folder.
    let filePath = sandbox.appendingPathComponent("a-file.txt").path
    try? "x".write(toFile: filePath, atomically: true, encoding: .utf8)
    checkThrows("non-directory rejected", .notADirectory(filePath)) {
        try m.encrypt(folderPath: filePath, password: PW, confirmPassword: PW, algorithm: .aes256)
    }
    // Symlinks must not be followed into an unintended target.
    let linkPath = sandbox.appendingPathComponent("a-symlink").path
    try? fm.createSymbolicLink(atPath: linkPath, withDestinationPath: folder)
    checkThrows("symlink source rejected", .symlinkEscape(linkPath)) {
        try m.encrypt(folderPath: linkPath, password: PW, confirmPassword: PW, algorithm: .aes256)
    }
    check("lstat detects symlink", VaultManager.isSymlink(linkPath))
    check("lstat does not flag real dir", !VaultManager.isSymlink(folder))
    try? fm.removeItem(atPath: folder)
}

// ---------------------------------------------------------------
section("AES-256 round trip")
// ---------------------------------------------------------------
do {
    let m = makeManager()
    let folder = makeFolder("aes256-vault")
    let vault = try! m.encrypt(folderPath: folder, password: PW, confirmPassword: PW, algorithm: .aes256)

    check("algorithm recorded", vault.algorithm == .aes256)
    check("format version stamped", vault.formatVersion == Vault.currentFormatVersion)
    check("container exists", fm.fileExists(atPath: vault.containerPath))
    check("plaintext folder removed", !fm.fileExists(atPath: folder))
    check("state is LOCKED after creation", m.state(of: vault) == .locked)
    check("registry persisted the vault", m.allVaults().contains { $0.id == vault.id })

    // The central security claim: no plaintext survives inside the container.
    let grep = Process()
    grep.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
    grep.arguments = ["-r", "-q", "hello world", vault.containerPath]
    try! grep.run(); grep.waitUntilExit()
    check("no plaintext content in container", grep.terminationStatus != 0)

    let grepName = Process()
    grepName.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
    grepName.arguments = ["-r", "-q", "buried.txt", vault.containerPath]
    try! grepName.run(); grepName.waitUntilExit()
    check("no plaintext filenames in container", grepName.terminationStatus != 0)

    // Wrong password must fail, and must not partially expose data.
    checkThrows("wrong password denied", .authenticationFailed) {
        try m.unlock(vault, password: "definitely-not-it")
    }
    check("still locked after failed unlock", m.state(of: vault) == .locked)

    let mount = try! m.unlock(vault, password: PW)
    check("state is UNLOCKED after unlock", m.state(of: vault) == .unlocked)
    check("nested file readable", fm.fileExists(atPath: mount + "/nested/deep/buried.txt"))
    check("unicode filename preserved", fm.fileExists(atPath: mount + "/türkçe-日本語-🔐.txt"))
    check("spaced filename preserved", fm.fileExists(atPath: mount + "/file with spaces.txt"))
    check("empty dir preserved", fm.fileExists(atPath: mount + "/empty-dir"))
    check("content intact", (try? String(contentsOfFile: mount + "/plain.txt", encoding: .utf8)) == "hello world")
    check("compat symlink restores original path", VaultManager.isSymlink(folder))
    check("original path resolves while unlocked", fm.fileExists(atPath: folder + "/plain.txt"))

    // Writes made while unlocked must persist across a lock/unlock cycle.
    try? "written while unlocked".write(toFile: mount + "/new.txt", atomically: true, encoding: .utf8)

    try! m.lock(vault)
    check("state is LOCKED after lock", m.state(of: vault) == .locked)
    check("compat symlink removed on lock", !fm.fileExists(atPath: folder))

    let mount2 = try! m.unlock(vault, password: PW)
    check("new file persisted", (try? String(contentsOfFile: mount2 + "/new.txt", encoding: .utf8)) == "written while unlocked")
    try! m.lock(vault)

    // Decrypt returns a normal plaintext folder and removes the container.
    try! m.decrypt(vault, password: PW)
    check("plaintext folder restored", fm.fileExists(atPath: folder + "/plain.txt"))
    check("nested tree restored", fm.fileExists(atPath: folder + "/nested/deep/buried.txt"))
    check("unicode survived decrypt", fm.fileExists(atPath: folder + "/türkçe-日本語-🔐.txt"))
    check("container removed after decrypt", !fm.fileExists(atPath: vault.containerPath))
    check("vault dropped from registry", !m.allVaults().contains { $0.id == vault.id })
    try? fm.removeItem(atPath: folder)
}

// ---------------------------------------------------------------
section("AES-128 round trip")
// ---------------------------------------------------------------
do {
    let m = makeManager()
    let folder = makeFolder("aes128-vault")
    let vault = try! m.encrypt(folderPath: folder, password: PW, confirmPassword: PW, algorithm: .aes128)
    check("AES-128 recorded", vault.algorithm == .aes128)
    check("AES-128 container exists", fm.fileExists(atPath: vault.containerPath))
    let mount = try! m.unlock(vault, password: PW)
    check("AES-128 content intact", (try? String(contentsOfFile: mount + "/plain.txt", encoding: .utf8)) == "hello world")
    try! m.lock(vault)
    checkThrows("AES-128 wrong password denied", .authenticationFailed) {
        try m.unlock(vault, password: "nope-nope-nope")
    }
    try! m.decrypt(vault, password: PW)
    check("AES-128 decrypt restored folder", fm.fileExists(atPath: folder + "/plain.txt"))
    try? fm.removeItem(atPath: folder)
}

// ---------------------------------------------------------------
section("Tamper detection")
// ---------------------------------------------------------------
do {
    let m = makeManager()
    let folder = makeFolder("tamper-vault")
    let vault = try! m.encrypt(folderPath: folder, password: PW, confirmPassword: PW, algorithm: .aes256)

    // Corrupt the encrypted band data; authenticated encryption must reject it.
    let bands = vault.containerPath + "/bands"
    if let entries = try? fm.contentsOfDirectory(atPath: bands), let first = entries.first {
        let bandPath = bands + "/" + first
        if let handle = FileHandle(forWritingAtPath: bandPath) {
            handle.seek(toFileOffset: 0)
            handle.write(Data(repeating: 0xFF, count: 4096))
            handle.closeFile()
        }
        var opened = true
        do { _ = try m.unlock(vault, password: PW); try? m.lock(vault) }
        catch { opened = false }
        check("corrupted ciphertext rejected or unreadable", !opened)
    } else {
        check("corrupted ciphertext rejected or unreadable", false)
    }
    try? m.lock(vault)
    try? fm.removeItem(atPath: vault.containerPath)
    try? fm.removeItem(atPath: folder)
}

// ---------------------------------------------------------------
section("Rollback and crash safety")
// ---------------------------------------------------------------
do {
    let m = makeManager()
    let folder = makeFolder("rollback-vault")
    // Pre-create the container path so encryption must refuse and change nothing.
    let container = folder + ".crypton.sparsebundle"
    try? fm.createDirectory(atPath: container, withIntermediateDirectories: true)
    checkThrows("refuses to clobber an existing container", .destinationExists(container)) {
        try m.encrypt(folderPath: folder, password: PW, confirmPassword: PW, algorithm: .aes256)
    }
    check("plaintext untouched after refusal", fm.fileExists(atPath: folder + "/plain.txt"))
    try? fm.removeItem(atPath: container)

    // Decrypt must refuse when a folder already occupies the destination.
    let vault = try! m.encrypt(folderPath: folder, password: PW, confirmPassword: PW, algorithm: .aes256)
    try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
    checkThrows("decrypt refuses to overwrite existing path", .destinationExists(folder)) {
        try m.decrypt(vault, password: PW)
    }
    check("container survives refused decrypt", fm.fileExists(atPath: vault.containerPath))
    check("no staging dir left behind", !fm.fileExists(atPath: folder + ".crypton-restoring"))
    try? fm.removeItem(atPath: folder)
    try? m.lock(vault)
    try? fm.removeItem(atPath: vault.containerPath)
}

// ---------------------------------------------------------------
section("Folders containing .DS_Store (Finder-visited)")
// ---------------------------------------------------------------
do {
    // Regression: copyContents skips .DS_Store, so verification must skip it too.
    // Counting it on the source side but not the destination made every
    // Finder-visited folder fail with "Verification found N of N+1 items."
    let m = makeManager()
    let folder = makeFolder("dsstore-vault")
    try? "fake finder metadata".write(toFile: folder + "/.DS_Store", atomically: true, encoding: .utf8)
    try? fm.createDirectory(atPath: folder + "/.Spotlight-V100", withIntermediateDirectories: true)

    var vault: Vault?
    do { vault = try m.encrypt(folderPath: folder, password: PW, confirmPassword: PW, algorithm: .aes256) }
    catch { print("  (encrypt threw: \(error))") }
    check("folder with .DS_Store encrypts", vault != nil)

    if let vault {
        let mount = try! m.unlock(vault, password: PW)
        check("real files still copied", fm.fileExists(atPath: mount + "/plain.txt"))
        check("nested tree still copied", fm.fileExists(atPath: mount + "/nested/deep/buried.txt"))
        check(".DS_Store not carried into vault", !fm.fileExists(atPath: mount + "/.DS_Store"))
        try! m.lock(vault)
        try? fm.removeItem(atPath: vault.containerPath)
    }
    try? fm.removeItem(atPath: folder)
}

// ---------------------------------------------------------------
section("Large file and registry")
// ---------------------------------------------------------------
do {
    let m = makeManager()
    let folder = makeFolder("large-vault", largeFileMB: 60)
    let vault = try! m.encrypt(folderPath: folder, password: PW, confirmPassword: PW, algorithm: .aes256)
    let mount = try! m.unlock(vault, password: PW)
    let size = (try? fm.attributesOfItem(atPath: mount + "/large.bin")[.size] as? Int) ?? 0
    check("60MB file survived round trip", size == 60 * 1_048_576)
    try! m.lock(vault)

    // State must be derived from the live mount, never from stored state.
    check("locked state derived from filesystem", m.state(of: vault) == .locked)
    try? fm.removeItem(atPath: vault.containerPath)
}

do {
    let store = sandbox.appendingPathComponent("reg-test.json")
    let r = VaultRegistry(storeURL: store)
    let v = Vault(name: "X", originalPath: "/tmp/x", containerPath: "/tmp/x.crypton", algorithm: .aes256)
    try! r.add(v)
    check("registry round trips", VaultRegistry(storeURL: store).load().first?.id == v.id)
    // The registry must never contain secret material.
    let raw = (try? String(contentsOf: store, encoding: .utf8)) ?? ""
    check("registry stores no password", !raw.contains(PW))
    try! r.remove(id: v.id)
    check("registry removal works", VaultRegistry(storeURL: store).load().isEmpty)
}

// ---------------------------------------------------------------
section("hdiutil auth-failure parsing")
// ---------------------------------------------------------------
do {
    // hdiutil was observed exiting 0 on auth failure, so stderr text is authoritative.
    check("detects authentication error", DiskImage.indicatesAuthFailure("hdiutil: attach failed - Authentication error"))
    check("does not false-positive on success", !DiskImage.indicatesAuthFailure("/dev/disk5s1  /Volumes/Test"))
}

try? fm.removeItem(at: sandbox)

print("\n" + String(repeating: "=", count: 46))
print("passed: \(passed)   failed: \(failed)")
if !failures.isEmpty { print("failing: " + failures.joined(separator: ", ")) }
print(String(repeating: "=", count: 46))
exit(failed == 0 ? 0 : 1)
