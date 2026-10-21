# Security policy

## Reporting a vulnerability

If you find a security issue in this repository (for example, a script that writes to an unexpected location, an unverified download, or a policy that weakens security features), please report it privately rather than opening a public issue.

- Email: open an issue titled "Security: <short description>" and mark it confidential, or contact the maintainer via GitHub.
- Include: affected file, reproduction steps, impact, and a suggested fix if you have one.

You can expect an acknowledgment within a few days.

## Security design notes

- This project only uses official Firefox mechanisms (enterprise policies and `user.js`). It does not download or execute arbitrary code at runtime; the only network access is the merge script fetching pinned Arkenfox and Betterfox commits, whose SHA-256 checksums are verified.
- Security features are deliberately left on: Safe Browsing, updates, Remote Settings, captive portal detection.
- The merge script pins upstream commits and verifies checksums. If a checksum fails, the script aborts.
- UAC / sudo is required only for writing `policies.json`; profile changes run as the regular user.

## Supported versions

Only the latest commit on `main` is supported. Tagged releases (e.g. `v1.0.0`) are snapshots.