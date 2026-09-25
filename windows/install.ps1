# Installs Account Switcher for Windows (current user, no admin rights needed).
#
#   irm https://raw.githubusercontent.com/berkboz/account-switcher/main/windows/install.ps1 | iex
#
# Downloads the latest release for this PC's architecture into
# %LOCALAPPDATA%\Programs\Account Switcher, adds a Start menu shortcut, installs the two free
# helpers it drives when their prerequisites are present (claude-swap needs uv + the Claude Code
# CLI, codex-auth needs Node.js), then opens the setup window.
$ErrorActionPreference = 'Stop'
$repo = 'berkboz/account-switcher'
$dir = Join-Path $env:LOCALAPPDATA 'Programs\Account Switcher'
$exe = Join-Path $dir 'AccountSwitcher.exe'

function Step($text) { Write-Host "`n$text" -ForegroundColor White }
function Ok($text) { Write-Host "  √ $text" -ForegroundColor Green }
function Skip($text) { Write-Host "  – $text" -ForegroundColor DarkGray }
function Warn($text) { Write-Host "  ! $text" -ForegroundColor Yellow }

Write-Host 'Account Switcher — install' -ForegroundColor White
Write-Host 'Switch accounts for Claude Desktop, Claude Code and Codex from the tray.' -ForegroundColor DarkGray

Step '1/4  Checking this PC'
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { 'arm64' } else { 'x64' }
Ok "Windows $([Environment]::OSVersion.Version) ($arch)"

Step '2/4  Installing the app'
Get-Process AccountSwitcher -ErrorAction SilentlyContinue | Stop-Process -Force
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$zip = Join-Path $env:TEMP "AccountSwitcher-$([guid]::NewGuid().ToString('N').Substring(0,8)).zip"
try {
    Invoke-WebRequest "https://github.com/$repo/releases/latest/download/AccountSwitcher-win-$arch.zip" -OutFile $zip -UseBasicParsing
} catch {
    Warn "Download failed. Check your connection or get the zip from https://github.com/$repo/releases"
    return
}
Expand-Archive $zip -DestinationPath $dir -Force
Remove-Item $zip
Ok "installed to $dir"

$shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'Account Switcher.lnk'
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut($shortcut)
$link.TargetPath = $exe
$link.Save()
Ok 'Start menu shortcut added'

Step '3/4  Helpers (optional — the setup window can install these too)'
$env:PATH = "$env:USERPROFILE\.local\bin;$env:APPDATA\npm;$env:PATH"
function Has($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }
if (Has cswap) { Ok 'claude-swap already installed' }
elseif ((Has uv) -and (Has claude)) { uv tool install claude-swap | Out-Null; Ok 'claude-swap installed' }
else { Skip 'claude-swap skipped (needs uv and the Claude Code CLI)' }
if (Has codex-auth) { Ok 'codex-auth already installed' }
elseif (Has npm) {
    npm install -g @loongphy/codex-auth *> $null
    if ($LASTEXITCODE -eq 0) { Ok 'codex-auth installed' } else { Warn 'codex-auth install failed — try: npm install -g @loongphy/codex-auth' }
}
else { Skip 'codex-auth skipped (needs Node.js)' }

Step '4/4  Opening the setup window'
Start-Process $exe -ArgumentList '--setup'
Ok 'look for the Account Switcher icon in the system tray (it may be under the ^ arrow)'
Write-Host ''
