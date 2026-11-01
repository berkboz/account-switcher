# Account Switcher: agent brief

Menu bar app (Swift, AppKit, macOS 13+) that switches accounts for Claude Desktop, Claude Code
(via the `claude-swap`/`cswap` helper) and Codex (via `codex-auth`). A preview Windows port (C#, .NET 8) lives in `windows/`. Public MIT repo: never commit secrets, personal data or account names.

## Layout
- `main.swift` (menu, switching, session sync), `Onboarding.swift` (setup window), `LocalStorage.swift` (Claude's Local Storage sidebar layout).
- `build.sh` builds a universal `.app` (ad-hoc signed) into `~/Applications`; `release.sh` makes signed zip + DMG in `dist/`; `install.sh` / `uninstall.sh` are the user-facing one-liners (they download releases of `berkboz/account-switcher`).
- `assets/` icon sources; `VERSION` is the single version number read by the build scripts.
- `windows/` is a separate port with its own tests (`dotnet run --project windows/tests/CoreTests -c Release`, also run in CI by `.github/workflows/windows.yml`).
- `AUDIT.md` is a historical pre-publish audit (testing notes), not user documentation.

## Verify a change
There is no unit test suite for the macOS app. Use the built-in switches, which never touch your real Claude data when `ACCOUNT_SWITCHER_ROOT` points at a temp dir:
```bash
T=$(mktemp -d); mkdir -p "$T/Claude" "$T/Claude-Profile-Test"
ACCOUNT_SWITCHER_ROOT="$T" "$HOME/Applications/Account Switcher.app/Contents/MacOS/AccountSwitcher" --test-swap Test
```
`--dump` prints the menu model; `--setup` / `--settings` open those windows. README "Development" lists every flag.

## Pitfalls
- Switching Claude Desktop quits it and swaps data folders (`Claude` vs `Claude-Profile-<name>`). Never test destructive paths against your real account; use `ACCOUNT_SWITCHER_ROOT`.
- Nothing is deleted: replaced files go to `~/Library/Application Support/Account Switcher/conflicts`. Keep that guarantee.
- Never run or recommend `/logout` or `claude auth logout`: it can invalidate stored tokens.
- The app relies on how Claude Desktop stores data today and is unofficial; a Claude update can break it.
- Do not store passwords. Logins stay in each tool's own store (Keychain, `~/.codex/auth.json`, data folders).
- Bump `VERSION` for releases; keep README in sync, since the installer also ships it as the in-app Help.
- Only the maintainer can sign/notarize releases (Developer ID certificate).

## Design
UI is native AppKit (menu bar, setup and settings windows); follow system conventions. See DESIGN.md.
