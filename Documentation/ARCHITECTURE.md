# Crypton — Architecture

Minimum macOS: 13.0. Developed and verified on macOS 26.6.2, Apple Silicon.

## 1. The decision that shaped everything

The original specification asked for transparent, filesystem-level interception:
the folder stays at its original path, and any process touching it while locked
triggers authentication. That design requires **EndpointSecurity**, which on
modern macOS is gated behind three hard requirements:

1. The `com.apple.developer.endpoint-security.client` entitlement, granted only
   by Apple after a manual review of a paid Developer Program account.
2. A Developer ID signature. Unsigned ES system extensions are refused at load.
3. Distribution as a System Extension inside a signed, notarized app.

None of these were satisfiable in the build environment (no Xcode, no signing
identity, no ES entitlement). Rather than simulate protection — which the
specification explicitly forbids — Crypton uses a mechanism that provides
**real, verifiable cryptographic protection**: encrypted APFS disk images.

### What this changes for the user

| Aspect | Requested | Delivered |
|---|---|---|
| Protection | Cryptographic | Cryptographic ✅ |
| Locked contents unreadable | Yes | Yes ✅ |
| Works in Finder/Terminal/VS Code when unlocked | Yes | Yes ✅ |
| Auto-lock on sleep/reboot | Yes | Yes ✅ |
| Unlocked path | Original path | `/Volumes/<Name>`, bridged by a symlink at the original path ⚠️ |
| Per-process access prompts | Yes | No — unlock is per-vault, not per-process ⚠️ |

The two ⚠️ rows are genuine deviations, documented rather than hidden.

## 2. Storage

A vault is an encrypted APFS **sparsebundle** created by `hdiutil`:

```
~/Projects/MyProject               <- plaintext folder, before
~/Projects/MyProject.crypton.sparsebundle   <- encrypted container, after
```

The plaintext folder is deleted only after the copy is verified (see §5).
Encryption is performed by the operating system's own disk-image stack
(AES-128 or AES-256), not by hand-rolled code.

> `hdiutil` silently appends `.sparsebundle` and still exits 0 when the output
> path has a different extension. Crypton names the container explicitly and
> verifies the file exists, because the exit code alone is not trustworthy.

## 3. Lock and unlock

- **Unlock** — `hdiutil attach` with the password on stdin. The volume mounts at
  `/Volumes/<Name>`, and a symlink is created at the original path so existing
  paths, scripts, and editor workspaces keep resolving.
- **Lock** — the symlink is removed, then `hdiutil detach`. Keys are released
  with the mount by the OS.

State is **derived, never stored**: a vault is unlocked exactly when its volume
is mounted, checked via `stat` device-ID comparison against the parent
directory. This is what makes crash safety automatic — a panic, forced power
off, or reboot cannot leave a stale "unlocked" flag, because there is no flag.

## 4. Automatic locking

`AppDelegate` locks every vault on:

- `NSWorkspace.willSleepNotification` — sleep
- `NSWorkspace.willPowerOffNotification` — logout/shutdown
- `NSWorkspace.sessionDidResignActiveNotification` — fast user switching
- `com.apple.screenIsLocked` (distributed centre) — screen lock

Reboot and power loss need no handler, per §3.

## 5. Crash-safe operations

**Encrypt** — create container → copy → detach → **re-attach and verify item
count** → only then delete the plaintext original. Any failure removes the
half-built container and leaves the original untouched.

**Decrypt** — verify the password by attaching first → copy into a
`.crypton-restoring` staging directory → detach → `moveItem` into place
atomically → remove the container. An interruption leaves no partial plaintext
at the real path.

## 6. Passwords

Passwords reach `hdiutil` **only through stdin** (`-stdinpass`), never as
arguments, because process arguments are readable by any local user via `ps`.
The CLI reads them with `getpass(3)`, so they are never echoed and never enter
shell history.

Storing a password in the Keychain is **optional and off by default**
(`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, non-syncing). The registry
JSON holds only names, paths, and algorithm choices — never secrets.

## 7. Components

```
Crypton/Sources/
├── CryptonCore/          Shared engine (no UI dependencies)
│   ├── VaultModel       Types, errors, format version
│   ├── DiskImage        hdiutil wrapper, stdin passwords, stderr parsing
│   ├── KeychainStore    Optional password storage
│   ├── VaultRegistry    Atomic JSON persistence
│   └── VaultManager     encrypt / unlock / lock / decrypt
├── CryptonApp/           AppKit UI
└── crypton-cli/          Terminal front-end
```

The app and CLI share one registry, so a vault made in either is visible in both.

## 8. Why AppKit rather than SwiftUI

SwiftUI is not present in the Command Line Tools SDK. AppKit is, and the
specification permits it. The UI uses native controls, SF Symbols, and standard
alerts throughout.
