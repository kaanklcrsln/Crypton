# Crypton — Threat Model

Stating plainly what Crypton does and does not defend against. Every "protected"
claim below was verified by an executed test; see §4.

## 1. What Crypton protects

Crypton protects the **confidentiality of data at rest while a vault is locked**.

The intended scenario: a laptop is lost, stolen, powered off, or accessed by
someone else while vaults are locked. In that state, vault contents are
ciphertext and unreadable without the password.

## 2. Defended

| # | Threat | Outcome | Why |
|---|---|---|---|
| 1 | Another local app reads vault files while locked | **Protected** | Contents are ciphertext; no plaintext path exists |
| 2 | A process without the password | **Protected** | Decryption requires the password-derived key |
| 3 | Accidental Finder access | **Protected** | Nothing to open — the folder is not present |
| 4 | Terminal / `cat` / `grep` while locked | **Protected** | Verified: `cd` and `cat` fail; `strings` over all bands finds no plaintext |
| 5 | VS Code opening the path while locked | **Protected** | The path does not resolve |
| 6 | Background daemons, Spotlight, backup agents | **Protected** | Unmounted volumes are not indexed or traversable |
| 7 | Direct filesystem path access | **Protected** | Only the encrypted container exists on disk |
| 8 | Copying the container to another machine | **Protected** | It remains encrypted; useless without the password |
| 9 | Renaming or moving the container | **Protected** | Contents stay encrypted regardless of name |
| 10 | Wrong password | **Protected** | Rejected by authenticated decryption; no partial plaintext |
| 11 | Corrupted or tampered ciphertext | **Protected** | Authenticated encryption refuses to mount |
| 12 | Symlink passed to `protect` | **Protected** | Rejected via `lstat`, which does not follow the link |
| 13 | Crash / power loss mid-operation | **Protected** | Rollback plus atomic staging; no partial plaintext |
| 14 | Stale unlock state after reboot | **Protected** | State is derived from the mount table, never stored |
| 15 | Password recovery from the registry file | **Protected** | The registry contains no secrets |
| 16 | Password visible in `ps` | **Protected** | Passwords go via stdin, never argv |
| 17 | Password in shell history | **Protected** | CLI uses `getpass(3)` |

## 3. NOT defended — read this section

Crypton does **not** protect against the following. This list is deliberate.

| # | Threat | Status | Explanation |
|---|---|---|---|
| 18 | **Any access while the vault is UNLOCKED** | **Not protected** | This is by design. An unlocked vault is an ordinary mounted volume: every process running as you can read it. Crypton is at-rest encryption, not per-process access control. |
| 19 | **Root on a running system with a vault unlocked** | **Not protected** | Root can read the mounted volume and can read decryption keys from kernel memory. |
| 20 | **A fully compromised OS or kernel** | **Not protected** | Malware with kernel access defeats any userspace design, including this one. |
| 21 | **Keylogger or malicious input monitor** | **Not protected** | Captures the password as it is typed. |
| 22 | **Memory forensics of a live unlocked system** | **Not protected** | Keys exist in memory while mounted. Crypton does not and cannot guarantee zeroization of key material held by the OS disk-image stack. |
| 23 | **Keychain compromise (if the user opted in)** | **Partially** | Saving the password to the Keychain trades security for convenience: anyone who unlocks your login Keychain can unlock the vault. It is off by default for exactly this reason. |
| 24 | **Weak passwords** | **Not protected** | An 8-character password is brute-forceable by a motivated attacker. Crypton enforces a floor, not strength. |
| 25 | **Metadata leakage** | **Partially** | The container's *existence*, size, and modification time are visible. Filenames and contents are not. |
| 26 | **Coercion** | **Not protected** | No plausible deniability or hidden-volume feature. |
| 27 | **Temporary files written outside the vault** | **Not protected** | If an app writes a draft to `~/Library/Caches` while the vault is unlocked, that copy is outside Crypton's control. |
| 28 | **Swap / hibernation** | **Depends on FileVault** | Decrypted pages may reach swap. Enable FileVault so swap is itself encrypted. |
| 29 | **Hard links created before encryption** | **Not protected** | A pre-existing hard link elsewhere on the volume keeps its own reference to the original data. |
| 30 | **TOCTOU races during encrypt** | **Partially** | The source is checked, then copied. A sufficiently privileged local attacker could alter the folder mid-operation. |

## 4. Evidence

The following were executed against real encrypted vaults, not asserted:

- `strings` across every band of a live container: **0** occurrences of the
  known plaintext marker, both after creation and after a write/lock cycle.
- `grep -r` for file *contents* and for *filenames*: not found.
- `cd` and `cat` against a locked vault: fail with "No such file or directory".
- Wrong password: rejected, vault remains locked, no partial data exposed.
- Corrupted band: mount refused.
- 60 MB file: byte-exact after a full round trip.
- Unicode, spaces, nested trees, empty directories: preserved.

51 of 51 automated tests pass.

## 5. Recommendations

1. **Enable FileVault.** Crypton protects individual folders; FileVault protects
   the whole disk including swap. They complement each other.
2. **Use a long passphrase.** Length beats complexity.
3. **Lock when stepping away.** Sleep and screen lock do this automatically.
4. **There is no recovery.** A forgotten password means the data is gone.
