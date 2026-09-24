#!/bin/zsh
# Installs Account Switcher.
#
#   One line, no clone needed (downloads the latest signed release):
#     curl -fsSL https://raw.githubusercontent.com/berkboz/account-switcher/main/install.sh | zsh
#
#   From a clone (builds from source, needs Xcode Command Line Tools):
#     ./install.sh
#
# Either way it also installs the two free helpers it drives (claude-swap for Claude Code,
# codex-auth for Codex) when their prerequisites are present, then opens the setup window.
set -e

REPO="berkboz/account-switcher"
APP_DIR="$HOME/Applications"
APP="$APP_DIR/Account Switcher.app"

BOLD=$'\e[1m'; DIM=$'\e[2m'; OK=$'\e[32m'; WARN=$'\e[33m'; OFF=$'\e[0m'
step() { print -P "\n${BOLD}$1${OFF}"; }
ok()   { print -P "  ${OK}✓${OFF} $1"; }
warn() { print -P "  ${WARN}!${OFF} $1"; }

# Running from a checkout? (When piped through `curl | zsh` there is no script file.)
SRC=""
[[ -n "$ZSH_SCRIPT" && -f "${ZSH_SCRIPT:A:h}/main.swift" ]] && SRC="${ZSH_SCRIPT:A:h}"

print -P "${BOLD}Account Switcher — install${OFF}"
print -P "${DIM}Switch accounts for Claude Desktop, Claude Code and Codex from the menu bar.${OFF}"

step "1/4  Checking this Mac"
[[ "$(uname)" == "Darwin" ]] || { print "Account Switcher is macOS only."; exit 1; }
[[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 13 ]] || { print "Needs macOS 13 or later."; exit 1; }
ok "macOS $(sw_vers -productVersion)"
[[ -d /Applications/Claude.app ]] && ok "Claude Desktop found" \
  || warn "Claude Desktop not in /Applications (only needed for desktop switching)"

step "2/4  Installing the app"
mkdir -p "$APP_DIR"
if [[ -n "$SRC" ]]; then
  xcode-select -p >/dev/null 2>&1 || { warn "Building needs Xcode Command Line Tools: xcode-select --install"; exit 1; }
  pkill -x AccountSwitcher 2>/dev/null || true
  (cd "$SRC" && ./build.sh >/dev/null)
  ok "built from source into ~/Applications"
  README_SRC="$SRC/README.md"
else
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  curl -fsSL "https://github.com/$REPO/releases/latest/download/AccountSwitcher.zip" -o "$TMP/app.zip" \
    || { warn "Download failed. Check your connection or get the DMG from https://github.com/$REPO/releases"; exit 1; }
  pkill -x AccountSwitcher 2>/dev/null || true
  rm -rf "$APP"
  ditto -x -k "$TMP/app.zip" "$APP_DIR"
  ok "downloaded the latest release into ~/Applications"
  curl -fsSL "https://raw.githubusercontent.com/$REPO/main/README.md" -o "$TMP/README.md" 2>/dev/null || true
  README_SRC="$TMP/README.md"
fi
mkdir -p "$HOME/.local/share/account-switcher"
[[ -s "$README_SRC" ]] && cp "$README_SRC" "$HOME/.local/share/account-switcher/README.md"

step "3/4  Helpers (optional — the setup window can install these too)"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
if command -v cswap >/dev/null; then
  ok "claude-swap already installed"
elif command -v uv >/dev/null && command -v claude >/dev/null; then
  uv tool install claude-swap >/dev/null && ok "claude-swap installed" \
    || warn "claude-swap install failed — try: uv tool install claude-swap"
else
  print -P "  ${DIM}– claude-swap skipped (needs uv and the Claude Code CLI)${OFF}"
fi
if command -v codex-auth >/dev/null; then
  ok "codex-auth already installed"
elif command -v npm >/dev/null; then
  npm install -g @loongphy/codex-auth >/dev/null 2>&1 && ok "codex-auth installed" \
    || warn "codex-auth install failed — try: npm install -g @loongphy/codex-auth"
else
  print -P "  ${DIM}– codex-auth skipped (needs Node.js)${OFF}"
fi

step "4/4  Opening the setup window"
open "$APP" --args --setup
ok "look for the Account Switcher icon in your menu bar"
print
