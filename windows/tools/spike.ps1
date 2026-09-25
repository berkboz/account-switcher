# Read-only check of the assumptions the Windows app makes. Changes nothing, prints no secrets.
# Run in PowerShell on the Windows PC, with Claude Desktop installed and signed in:
#   powershell -ExecutionPolicy Bypass -File tools\spike.ps1
# Paste the output into an issue or back to whoever is working on the Windows port.
$ErrorActionPreference = 'SilentlyContinue'
function Line($label, $value) { Write-Host ("{0,-34} {1}" -f $label, $value) }

Write-Host "`n== Machine"
Line 'Windows' "$([Environment]::OSVersion.Version) $env:PROCESSOR_ARCHITECTURE"
Line 'PowerShell' $PSVersionTable.PSVersion

Write-Host "`n== Claude Desktop install"
foreach ($p in @("$env:LOCALAPPDATA\AnthropicClaude\claude.exe",
                 "$env:LOCALAPPDATA\Programs\Claude\Claude.exe",
                 "$env:ProgramFiles\Claude\Claude.exe")) { Line $p (Test-Path $p) }
$msix = Get-AppxPackage *Claude* | Select-Object -First 1
Line 'MSIX package' $(if ($msix) { "$($msix.Name) $($msix.Version)" } else { 'none' })
$running = Get-Process Claude
Line 'Claude processes' $running.Count
Line 'Main process path' ($running | Where-Object MainWindowHandle -ne 0 | Select-Object -First 1 -ExpandProperty Path)

Write-Host "`n== Claude Desktop data folder"
$candidates = @("$env:APPDATA\Claude")
if ($msix) { $candidates += "$env:LOCALAPPDATA\Packages\$($msix.PackageFamilyName)\LocalCache\Roaming\Claude" }
foreach ($c in $candidates) {
    Line $c (Test-Path $c)
    if (Test-Path $c) {
        $names = (Get-ChildItem $c -Force | Select-Object -ExpandProperty Name) -join ', '
        Write-Host "   contains: $names"
        $sessions = Join-Path $c 'claude-code-sessions'
        if (Test-Path $sessions) {
            Get-ChildItem $sessions -Directory | ForEach-Object {
                $acct = $_
                Get-ChildItem $acct.FullName -Directory | ForEach-Object {
                    $n = (Get-ChildItem $_.FullName -Filter 'local_*.json').Count
                    Write-Host "   sessions: <account $($acct.Name.Substring(0,8))…>\<org $($_.Name.Substring(0,8))…>  $n session files"
                }
            }
            $other = Get-ChildItem $sessions -Recurse -File | Where-Object Name -notlike 'local_*' | Select-Object -ExpandProperty Name -Unique
            Write-Host "   other files in sessions: $($other -join ', ')"
        }
        Line '   scratch-workspaces present' (Test-Path (Join-Path $c 'scratch-workspaces'))
        $cfg = Join-Path $c 'config.json'
        if (Test-Path $cfg) {
            $keys = (Get-Content $cfg -Raw | ConvertFrom-Json).PSObject.Properties.Name | Where-Object { $_ -like '*oauth*' }
            Line '   login stored in config.json' $(if ($keys) { "yes ($($keys -join ', '))" } else { 'no' })
        }
    }
}

Write-Host "`n== Directory junctions (needed for shared sessions)"
$t = Join-Path $env:TEMP "as-spike-$([guid]::NewGuid().ToString('N').Substring(0,6))"
New-Item -ItemType Directory "$t\target" | Out-Null
cmd /d /c mklink /J "$t\link" "$t\target" | Out-Null
Line 'mklink /J without admin' (Test-Path "$t\link")
cmd /d /c rmdir "$t\link" | Out-Null
Remove-Item -Recurse -Force $t

Write-Host "`n== Helpers"
$env:PATH = "$env:USERPROFILE\.local\bin;$env:APPDATA\npm;$env:PATH"
foreach ($c in 'claude', 'uv', 'cswap', 'node', 'npm', 'codex', 'codex-auth') {
    $cmd = Get-Command $c | Select-Object -First 1
    Line $c $(if ($cmd) { $cmd.Source } else { 'not found' })
}
if (Get-Command cswap) { Line 'cswap accounts' ((cswap list --json | ConvertFrom-Json).accounts.Count) }
if (Get-Command codex-auth) { Write-Host '   codex-auth status:'; codex-auth status | ForEach-Object { "     $_" } }
Line 'Claude Code credentials file' (Test-Path "$env:USERPROFILE\.claude\.credentials.json")

Write-Host "`n== Codex app"
$codex = Get-Process Codex, ChatGPT | Select-Object -First 3
foreach ($p in $codex) { Line "process $($p.Name)" $p.Path }
if (-not $codex) { Line 'Codex/ChatGPT process' 'not running' }

Write-Host "`nNext (manual, reversible): quit Claude from the tray, rename %APPDATA%\Claude to Claude-test,"
Write-Host "rename it back, start Claude and check it is still signed in."
