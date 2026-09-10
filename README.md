# Crypton

Encrypted folders for macOS. Lock a folder behind a password; while it's locked
the contents are ciphertext on disk and nothing can read them.

**v0.0.1** — first release.

## Why

A cold wallet doesn't sync, doesn't phone home, and doesn't ask you to trust a
service. It holds one thing and holds it properly. Crypton takes the same
position with folders.

Most encryption tools drift toward being platforms: accounts, sync, sharing,
recovery portals, subscriptions. Every one of those is another party who can be
breached, another server that can go down, another way your data leaves the
machine you put it on.

Crypton has none of it:

- **No account.** Nothing to sign up for.
- **No cloud, no sync, no telemetry.** It never opens a network connection.
- **No recovery service.** Nobody holds a spare key, including me.
- **No custom crypto.** Encryption is done by macOS's own disk-image stack —
  the same one behind FileVault-era encrypted images. I wrote no ciphers.
- **No lock-in.** A vault is a standard Apple disk image. If Crypton vanished
  tomorrow, `hdiutil attach` still opens it.

Your password, your machine, your files. That's the whole model.

## Install

Download `Crypton.dmg` from
[Releases](https://github.com/kaanklcrsln/Crypton/releases), open it, and drag
**Crypton** to Applications.

**First launch:** the app is signed ad-hoc rather than with a paid Apple
Developer ID, so Gatekeeper blocks a plain double-click the first time.

```
Right-click Crypton.app → Open → Open
```

Once only. If macOS still refuses:

```sh
xattr -dr com.apple.quarantine /Applications/Crypton.app
```

### Terminal (optional)

```sh
sudo ln -sf /Applications/Crypton.app/Contents/Resources/crypton /usr/local/bin/crypton
```

## Use

In the app: **Protect Folder…**, pick a folder, set a password, choose AES-128
or AES-256. The folder becomes a locked vault. *Unlock* opens it, *Lock* closes
it, *Decrypt* turns it back into a normal folder for good.

From the terminal:

```sh
crypton list
crypton protect ~/Projects/MyProject
crypton unlock MyProject
crypton lock MyProject
crypton lock-all
crypton decrypt MyProject
```

Passwords are never accepted as arguments — they're read without echo, so they
stay out of `ps` and your shell history.

## How it works

Each vault is an encrypted APFS sparsebundle. Unlocking mounts it at
`/Volumes/<Name>` and drops a symlink at the original path, so existing paths,
scripts, and editor workspaces keep resolving. Finder, Terminal, VS Code, and
Git all treat it as an ordinary folder while it's open.

Vaults lock automatically on **sleep, screen lock, logout, and shutdown**.
Unlock state lives only in the mount table — there's no stored flag — so
**everything is locked after a reboot or a power cut**.

## Limits

Worth knowing before you rely on it:

- **An unlocked vault is a normal mounted volume.** Any process running as you
  can read it. This is encryption at rest, not per-app access control.
- The unlocked path is `/Volumes/<Name>`, bridged by a symlink — not true
  same-path interception. That needs an EndpointSecurity system extension,
  which requires an Apple-granted entitlement and a Developer ID signature.
- **Forget the password and the data is gone.** No backdoor, no reset. This is
  the point, but it cuts both ways.
- Turn on **FileVault** as well, so swap is encrypted too.


## Build from source

Requires macOS 13+ and Swift 6 (Xcode Command Line Tools are enough).

