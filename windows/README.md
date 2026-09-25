# Account Switcher for Windows

The Windows version of [Account Switcher](../README.md): one tray icon for switching between
accounts in **Claude Desktop** (including its Code tab), **Claude Code** in a terminal and
**Codex**. Same features and settings as the macOS app.

> **Status: preview.** The switching logic is the same as on macOS and is tested on Windows in
> CI, but the Claude Desktop switch has not yet been confirmed on a real Windows install. Run
> [`tools/spike.ps1`](tools/spike.ps1) first and report what it prints.

## Install

One line in PowerShell, no admin rights needed:

```powershell
irm https://raw.githubusercontent.com/berkboz/account-switcher/main/windows/install.ps1 | iex
```

It downloads the latest release for your PC (x64 or ARM64) into
`%LOCALAPPDATA%\Programs\Account Switcher`, adds a Start menu shortcut, installs the helpers
when it can, and opens the setup window. Or download `AccountSwitcher-win-x64.zip` /
`AccountSwitcher-win-arm64.zip` from [Releases](https://github.com/berkboz/account-switcher/releases)
and run `AccountSwitcher.exe`.

Requires Windows 10 or 11. No .NET install needed. The helpers need
[uv](https://docs.astral.sh/uv/) (for claude-swap) and Node.js (for codex-auth); the setup
window installs them when those are present.

## How it works on Windows

| | |
|---|---|
| **Claude Desktop** | Quits Claude, renames `%APPDATA%\Claude` to `Claude-Profile-<name>`, moves the other account's folder into place, reopens Claude. The Microsoft Store build's virtualized folder is detected automatically. If Claude keeps running in the tray after its window closes, you are asked before it is ended. |
| **Shared Code sessions** | Session and scratch folders move with the active account, so their path never changes. Per-account session folders are **directory junctions** to one common folder — junctions need no admin rights or Developer Mode. |
| **Claude Code (terminal)** | [claude-swap](https://github.com/realiti4/claude-swap) (`cswap`). On Windows Claude Code keeps its login in `%USERPROFILE%\.claude\.credentials.json`, so switches apply immediately. |
| **Codex** | [codex-auth](https://github.com/loongphy/codex-auth). After a switch the app offers to restart the Codex app, which only reads its login at startup. |
| **Settings** | `%APPDATA%\Account Switcher\settings.json`. Open at sign-in uses `HKCU\…\Run`. |
| **Conflicts** | Never deleted: copies set aside go to `%APPDATA%\Account Switcher\conflicts`. |

## Uninstall

```powershell
irm https://raw.githubusercontent.com/berkboz/account-switcher/main/windows/uninstall.ps1 | iex
```

Removes the app, shortcut, autostart entry and settings. Accounts, Claude Desktop data and the
helpers are left alone; it prints how to remove those.

## Development

```
windows/
  src/Core/       switching logic, no UI (net8.0, builds and tests on any OS)
  src/App/        WinForms tray app (net8.0-windows)
  tests/CoreTests switch/merge/parse tests against scratch folders
  tools/spike.ps1 read-only check of a Windows PC's Claude/Codex setup
```

```bash
dotnet run --project tests/CoreTests            # tests (any OS)
dotnet run --project tests/CoreTests -- --live  # + read-only check of your real helper accounts
./build.sh                                      # tests + both zips into dist/ (macOS/Linux/Git Bash)
```

CI ([`.github/workflows/windows.yml`](../.github/workflows/windows.yml)) runs the tests on
`windows-latest` and, when a GitHub release is published, attaches both zips to it.

**Code signing.** The builds are unsigned. The PowerShell installer is usually unaffected, but a
zip downloaded in a browser triggers SmartScreen's "Windows protected your PC" on first run
(More info → Run anyway). To remove that, sign `AccountSwitcher.exe` with an
Authenticode certificate — [Azure Trusted Signing](https://learn.microsoft.com/azure/trusted-signing/)
is the cheapest route and has a GitHub Action.
