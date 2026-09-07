# Crypton — Security Notes

## Design rules followed

1. **No custom cryptography.** All encryption is performed by Apple's disk-image
   stack. Crypton orchestrates; it does not implement primitives.
2. **No plaintext passwords anywhere.** Passwords travel to `hdiutil` on stdin,
   are read via `getpass(3)` in the CLI, and are never written to disk, logs, or
   process arguments.
3. **No plaintext left behind.** The original folder is deleted only after the
   encrypted copy is verified by re-mounting it.
4. **No fake security.** Where the requested design was not achievable, the
   limitation is documented rather than simulated.

## Specific measures

**Passwords never enter argv.** Process arguments are world-readable through
`ps`. Every password is written to the child process's stdin and the pipe is
closed immediately; the local buffer is then zeroed on a best-effort basis.

**Error messages reveal nothing.** A wrong password, a corrupted container, and
a failed authentication tag all produce the same message: *"Unable to unlock the
vault."* No oracle is offered to an attacker.

**`hdiutil` exit codes are not trusted.** During development `hdiutil` was
observed exiting `0` while reporting `Authentication error`, and separately
exiting `0` while silently writing to a different path. Crypton therefore parses
stderr for authentication failures and verifies that the expected file exists.

**Symlinks are rejected, not followed.** `attributesOfItem` follows symlinks,
which would allow a link to redirect encryption at an unintended target.
Detection uses `lstat(2)` instead. On lock, only a symlink is ever removed from
the original path — never a real directory.

**Keychain storage is opt-in.** Off by default. When enabled, entries are
`WhenUnlockedThisDeviceOnly` and non-syncing. The tradeoff is documented in the
threat model (§23).

**Logging is metadata-only.** `OSLog` records events such as "Vault unlocked"
and the algorithm name. It never records passwords, keys, paths, or contents.

## Known limitations

- An **unlocked vault is a normal mounted volume**. Any process running as you
  can read it. This is at-rest encryption, not per-process access control.
- **Root and kernel-level attackers are out of scope** while a vault is mounted.
- **Key zeroization is not guaranteed.** Keys are held by the OS disk-image
  stack; Crypton cannot make claims about memory it does not own. No such claim
  is made.
- **Ad-hoc signing only.** This build is not notarized, so Gatekeeper requires a
  right-click → Open on first launch. Distribution to other Macs requires a
  Developer ID certificate.

## If you need what EndpointSecurity would have given

Per-process authorization prompts require the ES entitlement from Apple, a
Developer ID signature, and a notarized System Extension. That path is
documented in `ARCHITECTURE.md` §1 and remains open as future work; it would
layer *on top of* the encryption here rather than replace it.
