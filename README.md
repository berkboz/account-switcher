# Account Switcher

One menu bar icon for switching between accounts in **Claude Desktop**, **Claude Code** (terminal)
and **Codex**. Useful when you have a work subscription and a personal one and keep hitting limits
on one of them.

## Install

Pick one. All three install the same app: the DMG into `/Applications`, the other two into
`~/Applications`, and open the setup window.

**Download** — get `AccountSwitcher-<version>.dmg` from
[Releases](https://github.com/berkboz/account-switcher/releases), open it and drag
Account Switcher to Applications.

**Terminal** — one line, no clone needed:

```bash
curl -fsSL https://raw.githubusercontent.com/berkboz/account-switcher/main/install.sh | zsh
```

**From source** — needs Xcode Command Line Tools (`xcode-select --install`):

```bash
git clone https://github.com/berkboz/account-switcher.git
cd account-switcher
./install.sh
```

Requires macOS 13 or later. The app drives two free helpers —
[claude-swap](https://github.com/realiti4/claude-swap) for Claude Code and
[codex-auth](https://github.com/loongphy/codex-auth) for Codex. The setup window installs them for
you when their prerequisites ([uv](https://docs.astral.sh/uv/), Node.js) are present. Nothing
touches your accounts until you click something.

## First run

The setup window lists Claude Desktop, Claude Code and Codex with their state and one button
each: install the helper, add an account, or get a missing prerequisite. Untick **Show in menu**
for anything you do not use. Reopen it any time from the menu → **Setup…**.

**Settings…** (⌘,) holds the rest: menu bar icon, refresh interval, open at login, sharing Code
sessions across accounts, whether to confirm before Claude quits, what to do with the Codex app
after a switch, and Codex Auto-Switch with its thresholds.

## Setting up your accounts

Do this once per account. Set up only the parts you use.

### Claude Desktop (and its Code tab)

Claude Desktop has no account switcher: signing in with a second account replaces the first.
Account Switcher keeps each account in its own data folder and swaps the active one: Claude quits,
the folders trade places, and Claude reopens signed in as the other account. Chats, settings and
Code sessions for each account come back when you switch back.

The Code tab uses the desktop app's own login, not the terminal one, so this is the switch that
changes Claude Code **inside the desktop app**.

1. Menu bar icon → **Add Claude Desktop Account…**
2. Name the new account (`Work`) and, the first time, your current one (`Personal`).
3. Claude quits and reopens on its sign-in screen. Sign in with the new account.

After that, click an account under **Claude Desktop** (or **Next Claude Desktop Account**, ⌘D)
to switch.

**Code sessions are shared across accounts**, like Codex chats. Hit your limit on one account,
switch, and continue the same Code session on the other. Regular chats (the Chat tab) stay with
their account — they live on Claude's servers. A brand-new account's first sessions join the
shared list after its next switch. The first switch into a new account downloads Claude Code's
runtime once, so that first Code session starts slower. If the same file exists on both sides
when sessions are merged, the newer copy is kept and the other is moved to
`Claude-Shared/_conflicts` — nothing is deleted.

### Claude Code in a terminal

This is a separate login from the desktop app, used by `claude` in Terminal, iTerm and the
VS Code extension. Switching it does **not** change the desktop app's Code tab. For each account:

```bash
claude auth login   # sign in with the account
cswap add           # store it
```

Then switch from the menu, or with `cswap switch`.

> **Never run `/logout` or `claude auth logout`.** It can invalidate a stored account's token.
> To change accounts, switch from the menu instead.

### Codex

For each account:

```bash
codex-auth login
```

Then switch from the menu, or with `codex-auth switch`.

**Restart the Codex app after every switch.** It reads the login only when it starts, so until it
restarts it keeps using the old account — which makes a switch look like it did nothing. After a
manual switch the menu offers the restart.

**Codex Auto-Switch** (menu toggle) moves you to another account when the current one is nearly
out of quota (by default 5-hour < 10% or weekly < 5% left; change the thresholds in Settings).
Two side effects to know:

- It undoes a manual switch to an account that is below those thresholds. The menu tells you
  when that happens; turn Auto-Switch off to force the switch.
- It cannot restart the Codex app, so after a background switch the app is still on the old
  account. The menu sends a notification telling you to restart it.

## Using it

| In the menu | What happens |
|---|---|
| An account under **Claude Desktop** | Quits Claude and reopens it as that account (✓ = current) |
| An account under **Claude Code** or **Codex** | Switches to it (✓ = current) |
| **Next … Account** | Rotates to the next account |
| **Codex Auto-Switch** | Turns codex-auth's automatic switching on or off |
| **Setup…** / **Settings…** (⌘,) | The first-run window / all options, including Open at Login |
| **Refresh** | Re-reads accounts and usage (also happens every minute — see Settings — and when you open the menu) |

Each account line shows quota: Claude shows how much you have **used**, Codex how much is
**left** — that is how each tool reports it.

## Things to know

- **Restart open sessions after switching.** A terminal Claude Code session or the Codex app
  that is already running keeps the old login. The macOS Keychain also caches for ~30 seconds.
- **Switching Claude Desktop quits it.** Running chats and Code sessions stop; they are still
  there when you switch back.
- **Unofficial.** Claude does not support multiple accounts; this relies on how the app stores
  its data today. A future update could change that; the fix would be in this repo.
- **Chat-tab conversations do not move between accounts.** They belong to the account on the
  server. Code sessions do move (see above).
- **Connectors differ per account.** A shared Code session resumed on another account uses that
  account's connectors and MCP servers.
- **Nothing here stores your passwords.** Logins stay where each tool puts them: the macOS
  Keychain for Claude Code, `~/.codex/auth.json` for Codex, and each account's data folder for Desktop.

## Where things live

| Path | What |
|---|---|
| `~/Applications/Account Switcher.app` | The app (`/Applications` when installed from the DMG) |
| `~/Library/Application Support/Claude` | The desktop account that is active now |
| `~/Library/Application Support/Claude-Profile-<name>` | A parked desktop account |
| `~/Library/Application Support/Claude-Shared` | Code sessions and scratch folders every account shares |
| `~/.local/share/account-switcher/README.md` | This guide (menu → Help; opens this page online when missing) |

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/berkboz/account-switcher/main/uninstall.sh | zsh
```

Removes the app and the guide. It leaves your accounts, desktop data and the helper tools alone;
the script prints how to remove those too.

## Troubleshooting

**A section says "Not set up".** The helper tool for it is missing or has no accounts yet — see
[Setting up your accounts](#setting-up-your-accounts).

**"Next … Account" is greyed out.** Fewer than two accounts are stored for that tool.

**The app will not open after a macOS or Claude update.** Reinstall with the terminal line above,
or run `./build.sh` in a clone.

**Claude reopens signed out after a switch.** Expected the first time for a new account — sign
in. If an existing account asks again after a Claude update, sign in again; its data is intact.

**"Claude did not quit, so nothing was changed."** Claude was waiting on a dialog (for example
"quit while sessions are running?"). Answer it and switch again.

**Codex switched but still shows the old account.** Restart the Codex app.

**Codex keeps flipping between accounts.** Both accounts are near their limits and Auto-Switch
is bouncing between them. Turn off **Codex Auto-Switch** and pick one manually.

## Development

```bash
./build.sh                       # build + ad-hoc sign into ~/Applications
./release.sh                     # Developer ID–signed zip + DMG into dist/
NOTARY_PROFILE=<profile> ./release.sh   # …and notarize + staple them
```

`release.sh` picks the first "Developer ID Application" identity in your keychain. Create the
notary profile once with `xcrun notarytool store-credentials <profile> --apple-id <you> --team-id <TEAMID>`.
Publish `dist/AccountSwitcher.zip` (the terminal installer downloads this exact name) and the DMG
as assets of a GitHub release.

The desktop swap and session sharing can be exercised without touching Claude:

```bash
T=$(mktemp -d); mkdir -p "$T/Claude" "$T/Claude-Profile-Test"
ACCOUNT_SWITCHER_ROOT="$T" ~/Applications/"Account Switcher.app"/Contents/MacOS/AccountSwitcher --test-swap Test
# add  -shareCodeSessions NO  to run the same swap without session sharing
```

`--dump` prints what the menu would show; `--setup` and `--settings` open those windows at launch.
`ACCOUNT_SWITCHER_PATH=/usr/bin:/bin` (plus an empty `ACCOUNT_SWITCHER_ROOT`) shows the setup
window as it looks on a Mac without the helpers.

## License

MIT. Not affiliated with Anthropic or OpenAI.
