#!/bin/zsh
# Removes the Account Switcher app, its guide and its settings. Accounts and desktop data stay.
#   curl -fsSL https://raw.githubusercontent.com/berkboz/account-switcher/main/uninstall.sh | zsh
pkill -x AccountSwitcher 2>/dev/null || true
rm -rf "$HOME/Applications/Account Switcher.app" "/Applications/Account Switcher.app" \
       "$HOME/.local/share/account-switcher"
defaults delete io.berk.account-switcher 2>/dev/null || true
echo "Removed Account Switcher."
cat <<'T'

Left in place on purpose:
  Accounts          cswap remove <email>   /  codex-auth remove <email>
  Helper tools      uv tool uninstall claude-swap  /  npm uninstall -g @loongphy/codex-auth
  Desktop accounts  parked ones live in ~/Library/Application Support/Claude-Profile-<name>
                    (deleting one removes that account's local data in Claude Desktop)
  Shared sessions   ~/Library/Application Support/Claude-Shared  (keep it while any account
                    folder still links to it)
T
