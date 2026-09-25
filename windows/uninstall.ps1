# Removes Account Switcher for Windows. Accounts and Claude Desktop data stay.
#   irm https://raw.githubusercontent.com/berkboz/account-switcher/main/windows/uninstall.ps1 | iex
Get-Process AccountSwitcher -ErrorAction SilentlyContinue | Stop-Process -Force
Remove-Item -Recurse -Force (Join-Path $env:LOCALAPPDATA 'Programs\Account Switcher') -ErrorAction SilentlyContinue
Remove-Item -Force (Join-Path ([Environment]::GetFolderPath('Programs')) 'Account Switcher.lnk') -ErrorAction SilentlyContinue
Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Account Switcher' -ErrorAction SilentlyContinue
Remove-Item -Force (Join-Path $env:APPDATA 'Account Switcher\settings.json') -ErrorAction SilentlyContinue
Write-Host 'Removed Account Switcher.'
Write-Host @'

Left in place on purpose:
  Accounts          cswap remove <email>   /  codex-auth remove <email>
  Helper tools      uv tool uninstall claude-swap  /  npm uninstall -g @loongphy/codex-auth
  Desktop accounts  parked ones live next to %APPDATA%\Claude as Claude-Profile-<name>
                    (deleting one removes that account's local data in Claude Desktop)
  Conflict copies   %APPDATA%\Account Switcher\conflicts
'@
