# Design language

Native macOS first. The app is a menu bar item plus two small windows (Setup, Settings); it should look like a system utility, not a branded product.

- Use stock AppKit controls, SF Symbols/system fonts and system colors so light/dark mode and accessibility settings work without extra code.
- One menu, grouped by tool (Claude Desktop, Claude Code, Codex); a check mark marks the current account; each account line shows quota. Claude shows quota **used**, Codex shows quota **left**, because that is how each tool reports it. Do not normalize them.
- Never act without a click: nothing touches accounts until the user chooses something, and Claude is never quit without asking (except explicit switch/repair actions the menu labels).
- Wording is plain and short, in sentence case; tell the user what will happen to running apps (quit, reopen, restart needed).
- Icon source: `assets/make-icon.swift` produces `assets/AppIcon.icns`.

To verify a UI change: build (`./build.sh`) and look at it: `--setup`, `--settings`, and the menu itself in light and dark mode.
