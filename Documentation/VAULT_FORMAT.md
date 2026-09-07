# Crypton — Vault Format v1

A Crypton vault has two parts: an **encrypted container** on disk and a
**registry entry** describing it. Only the container holds user data.

## 1. Container

```
<folder>.crypton.sparsebundle/
├── Info.plist          Disk-image metadata (band size, format)
├── Info.bckup          Backup copy of the above
├── token               Encryption header: salt + wrapped key material
├── lock                Mount lock
└── bands/
    ├── 0, 1, 2, …      Encrypted data bands (8 MB each by default)
```

The container is an Apple **encrypted APFS sparsebundle**. The cryptography is
performed by the operating system's disk-image stack, reached through
`hdiutil`. Crypton implements no cryptographic primitives of its own — a
deliberate choice, since inventing cryptography is the most common way to get
it wrong.

### Encryption

| Property | Value |
|---|---|
| Cipher | AES-128 or AES-256, user-selected at creation |
| Mode | Apple's authenticated encrypted disk-image format (CEncryptedEncoding v2) |
| Key derivation | PBKDF2-HMAC-SHA1, iteration count chosen by macOS at creation time |
| Salt | Random per container, stored in `token` |
| Key hierarchy | Password → KEK (via PBKDF2) → unwraps a random per-volume DEK |
| Integrity | HMAC per band; a modified band fails authentication |

The password never encrypts data directly. It derives a key-encryption key,
which unwraps a randomly generated data-encryption key. This is why changing a
password never requires re-encrypting the contents.

### Why filenames are protected

The entire APFS filesystem — directory structure, filenames, sizes, extended
attributes — lives *inside* the encrypted bands. Nothing about the internal
layout is observable from outside. This was verified by grepping a live
container for a known filename: not found.

### Versioning

`Info.plist` carries the disk-image format version, maintained by macOS.
Crypton's own record carries `formatVersion` (currently `1`) so future versions
can detect and migrate older vaults.

## 2. Registry

`~/Library/Application Support/Crypton/vaults.json`, written atomically.

```json
[
  {
    "formatVersion": 1,
    "id": "9C3E1B2A-...",
    "name": "MyProject",
    "originalPath": "/Users/you/Projects/MyProject",
    "containerPath": "/Users/you/Projects/MyProject.crypton.sparsebundle",
    "algorithm": "AES-256",
    "createdAt": "2026-09-07T19:45:00Z"
  }
]
```

**This file contains no secrets** — no password, key, salt, or hash. Deleting it
loses the vault *listing*, not the data: the container remains and can be
mounted directly with `hdiutil attach`, which is a deliberate anti-lock-in
property.

Note that `state` is absent by design. State is derived from whether the volume
is mounted, so it cannot go stale after a crash or reboot.

## 3. Recovery without Crypton

A vault is a standard Apple disk image. If Crypton is unavailable:

```sh
hdiutil attach ~/Projects/MyProject.crypton.sparsebundle
# macOS prompts for the password; the volume mounts at /Volumes/MyProject
```

Your data is never trapped behind Crypton-specific software.
