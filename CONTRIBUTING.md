# Contributing

Thanks for your interest. This is a personal toolkit shared as-is, but PRs are welcome.

## Ground rules

- **No em dashes or en dashes** in documentation. Use regular hyphens (`-`).
- Keep changes reversible and consistent with the existing layer model (policies -> debloat block -> Arkenfox -> Betterfox -> overrides).
- Don't commit real profile data, backups, `prefs.js`, `user-overrides.js` or anything under `.gitignore`.
- Keep the AGPL-3.0 license intact for vendored firefox-debloat code.

## How to contribute

1. Fork and create a feature branch.
2. Make your change. If you touch scripts, run the linters:
   - Windows: `Invoke-ScriptAnalyzer -Path windows\firefox-debloat.ps1`
   - Linux: `shellcheck linux/*.sh tests/*.sh scripts/*.sh`
3. Update the README if behavior changes. Run `tests/check-readme.sh` (Linux) to keep config documented.
4. Open a PR with a clear description and, if applicable, screenshots.

## Areas that need help

- Scripting the Linux merge step further (already added; improvements welcome).
- macOS support (policies path and profile locations).
- More override recipes.
- Translations.

## Code of conduct

Be kind. This project exists to help people take control of their browser. Disagreements about privacy trade-offs are fine; personal attacks are not.