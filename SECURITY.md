# Security policy

## Reporting a vulnerability

Please report security problems **privately**, not in a public issue:

1. Open the repository's **Security** tab.
2. Choose **Report a vulnerability**.

That opens a private advisory visible only to the maintainer. Include what you
found, how to reproduce it, and which version you were running
(**Net Report ▸ About Net Report**).

You should get a reply within a week. Fixes ship in a new release, and the
advisory is published once a fixed version is available.

## Supported versions

Only the latest release receives security fixes.

## Scope

In scope:

- The app itself: QRZ.com sign-in and lookups, the Keychain item it stores,
  the SQLite databases, CSV import, backup and restore, and the PDFs it writes.
- The release disk image and the scripts in `scripts/` that build it.

Out of scope: QRZ.com's own service, and macOS Gatekeeper prompts caused by the
app being ad-hoc signed rather than notarized. The README explains those
prompts.

## How the app handles your data

- Your QRZ password is kept only in the macOS Keychain, on this Mac. It is
  excluded from iCloud Keychain and from backups. It is sent only to
  `https://xmldata.qrz.com`, and only over HTTPS. Redirects are refused, so the
  password cannot be forwarded to another server.
- Lookup results are held in memory and in your local operator directory. They
  are never written to a network cache.
- The databases and reports stay in the data folder you choose. Nothing is
  uploaded anywhere else.
- Every release lists the disk image's SHA-256 checksum. Check your download
  against it.
