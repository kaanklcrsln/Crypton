import Foundation
import OSLog

/// Thin, security-conscious wrapper around `hdiutil`.
///
/// Design notes:
/// - The password is ALWAYS delivered through stdin (`-stdinpass`). It is never
///   passed as an argument, because process arguments are world-readable via `ps`.
/// - `hdiutil` does not reliably signal authentication failure through its exit
///   code (it was observed returning 0 on "Authentication error"), so stderr is
///   parsed as the authoritative signal.
enum DiskImage {
    private static let log = Logger(subsystem: "com.crypton.app", category: "DiskImage")

    struct Result {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        var combined: String { stdout + stderr }
    }

    /// Runs hdiutil, optionally writing `password` to its stdin.
    /// Never logs the password or the raw stdin buffer.
    @discardableResult
    static func run(_ arguments: [String], password: String? = nil) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments

        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        try process.run()

        if let password {
            // Write the password bytes, then immediately close the pipe so
            // hdiutil stops waiting. Zero the buffer afterwards on a best-effort basis.
            var bytes = Array(password.utf8)
            bytes.withUnsafeBufferPointer { buf in
                inPipe.fileHandleForWriting.write(Data(buffer: buf))
            }
            for i in bytes.indices { bytes[i] = 0 }
        }
        inPipe.fileHandleForWriting.closeFile()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Result(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    /// True when hdiutil's output indicates the supplied password was rejected.
    static func indicatesAuthFailure(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("authentication error")
            || lowered.contains("decryption failed")
            || lowered.contains("no such file or directory is corrupt")
            || lowered.contains("corrupt")
    }

    /// Creates an encrypted, growable APFS sparsebundle.
    static func create(
        at containerPath: String,
        volumeName: String,
        sizeMB: Int,
        algorithm: EncryptionAlgorithm,
        password: String
    ) throws {
        let result = try run([
            "create",
            "-size", "\(sizeMB)m",
            "-type", "SPARSEBUNDLE",
            "-fs", "APFS",
            "-volname", volumeName,
            "-encryption", algorithm.hdiutilName,
            "-stdinpass",
            "-quiet",
            containerPath
        ], password: password)

        // hdiutil silently rewrites the output path when the extension is not
        // ".sparsebundle", and still exits 0, so verify the file we expect exists.
        guard result.exitCode == 0,
              FileManager.default.fileExists(atPath: containerPath) else {
            log.error("Container creation failed (exit \(result.exitCode))")
            let detail = result.stderr.trimmed.isEmpty
                ? "hdiutil did not produce the container at the expected path."
                : result.stderr.trimmed
            throw CryptonError.imageCreationFailed(detail)
        }
    }

    /// Attaches the container and returns the resulting mount point.
    static func attach(containerPath: String, mountPoint: String?, password: String) throws -> String {
        var args = ["attach", "-stdinpass", "-nobrowse", "-noautoopen"]
        if let mountPoint {
            args += ["-mountpoint", mountPoint]
        }
        args.append(containerPath)

        let result = try run(args, password: password)

        if indicatesAuthFailure(result.combined) {
            // Do not distinguish wrong-password from tampering in the surfaced error.
            throw CryptonError.authenticationFailed
        }
        guard result.exitCode == 0 else {
            throw CryptonError.attachFailed(result.stderr.trimmed)
        }

        if let mountPoint { return mountPoint }

        // Parse the final whitespace-separated field, which is the mount path.
        for line in result.stdout.split(separator: "\n").reversed() {
            if let range = line.range(of: "/Volumes/") {
                return String(line[range.lowerBound...]).trimmed
            }
        }
        throw CryptonError.attachFailed("Could not determine the mount point.")
    }

    /// Detaches a mounted vault. Retries once with `-force` when the volume is busy.
    static func detach(mountPoint: String) throws {
        var result = try run(["detach", mountPoint, "-quiet"])
        if result.exitCode != 0 {
            // A lingering file handle is the usual cause; force is appropriate here
            // because leaving the vault mounted is the less safe outcome.
            result = try run(["detach", mountPoint, "-force", "-quiet"])
        }
        guard result.exitCode == 0 else {
            throw CryptonError.detachFailed(result.stderr.trimmed)
        }
    }

    /// Verifies the password without leaving the vault mounted.
    static func verifyPassword(containerPath: String, password: String) -> Bool {
        guard let mount = try? attach(containerPath: containerPath, mountPoint: nil, password: password) else {
            return false
        }
        try? detach(mountPoint: mount)
        return true
    }

    static func isMounted(_ mountPoint: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: mountPoint, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        // A directory at /Volumes/X only counts as mounted if it is a real mount root.
        let result = try? run(["info"])
        return result?.stdout.contains(mountPoint) ?? false
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
