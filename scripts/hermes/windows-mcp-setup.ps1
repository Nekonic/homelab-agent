# Windows-MCP setup on lab-windows (run as the desktop user, e.g. Admin).
# Prereq: uv + windows-mcp installed (see docs/05-mcp.md).
# The auth key is read from stdin ([Console]::In.ReadLine()) so it never appears on a command line or in this file:
#   (lab-assistant) grep -m1 '^WINDOWS_MCP_AUTH_KEY=' ~/.hermes/.env | cut -d= -f2- \
#     | ssh win 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\Admin\windows-mcp-setup.ps1 -WinIp <WIN_LAB_IP> -AssistantIp <ASSISTANT_LAB_IP>'
#   No `$input |` in front: the child powershell inherits the ssh session's stdin (docs/05 Troubleshooting).
param(
  [string]$WinIp       = "<WIN_LAB_IP>",        # e.g. 10.10.0.x  (bind address)
  [string]$AssistantIp = "<ASSISTANT_LAB_IP>",  # e.g. 10.10.0.y  (only allowed client)
  [int]$Port           = 8000
)
$ErrorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"
$env:PYTHONUTF8 = "1"; $env:Path = "$env:USERPROFILE\.local\bin;$env:Path"
$k = [Console]::In.ReadLine()          # first line only; $null when stdin is empty
if ($null -eq $k) { throw "auth key missing on stdin (empty input)" }
$k = $k.Trim()
if ($k.Length -lt 20) { throw "auth key missing on stdin (too short)" }

# 1) ~/.windows-mcp/config.toml (secret lives only on this machine, ACL: user/SYSTEM/Administrators)
$d = "$env:USERPROFILE\.windows-mcp"; New-Item -ItemType Directory -Force $d | Out-Null
$lines = @(
  '# windows-mcp config. Contains a secret (auth_key) - never copy into git.',
  '[server]',
  'transport = "streamable-http"',
  ('host      = "' + $WinIp + '"'),
  ('port      = ' + $Port),
  ('auth_key  = "' + $k + '"'),
  '',
  '[security]',
  ('ip_allowlist = ["' + $AssistantIp + '/32"]')
)
[IO.File]::WriteAllText("$d\config.toml", ($lines -join "`r`n") + "`r`n", (New-Object Text.UTF8Encoding($false)))
Remove-Variable k
# SIDs instead of names: "SYSTEM"/"Administrators" are localized on non-English Windows
icacls "$d\config.toml" /inheritance:r /grant:r "${env:USERNAME}:(R,W)" "*S-1-5-18:(F)" "*S-1-5-32-544:(F)" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls failed on $d\config.toml (exit $LASTEXITCODE)" }   # native exit codes ignore ErrorActionPreference
"config.toml written ({0} bytes)" -f (Get-Item "$d\config.toml").Length

# 2) per-user Scheduled Task "windows-mcp-server" (AtLogOn, Interactive, RunLevel Limited)
#    NOTE: `install --force` regenerates start-server.cmd and drops the restart loop added by
#    scripts/windows-rdp-autoconsole.ps1. After this script, re-run windows-rdp-autoconsole.ps1
#    (elevated PowerShell) - see docs/05-mcp.md.
#    windows-mcp may print a cp949 decode traceback on Korean Windows; the task is still registered.
#    A stale start-server.cmd is removed first so the Test-Path check below proves THIS install wrote it.
#    Output is captured in full (piping straight into `Select-Object -First` can stop the installer early).
$w = "$d\start-server.cmd"
Remove-Item $w -Force -ErrorAction SilentlyContinue
$ErrorActionPreference = "Continue"
$out = @(windows-mcp install --transport streamable-http --host $WinIp --port $Port --force 2>&1)
$rc = $LASTEXITCODE
$out | Select-Object -First 12 | ForEach-Object { "$_" }
if ($out.Count -gt 12) { "... ({0} more lines)" -f ($out.Count - 12) }
"windows-mcp install exit code: $rc"
$ErrorActionPreference = "Stop"

# 3) wrapper env: UTF-8 console (Korean locale) + telemetry off. Re-run after any `install --force`.
if (-not (Test-Path $w)) { throw "start-server.cmd not found after 'windows-mcp install' ($w) - check the output above" }
$c = Get-Content $w -Raw
if ($c -notmatch "ANONYMIZED_TELEMETRY") {
  $c = $c -replace "setlocal`r?`n", "setlocal`r`nset PYTHONUTF8=1`r`nset ANONYMIZED_TELEMETRY=false`r`n"
  [IO.File]::WriteAllText($w, $c, (New-Object Text.UTF8Encoding($false)))
}
"--- start-server.cmd ---"; Get-Content $w

# 3b) run the task without a visible console window (otherwise a cmd window stays open on the desktop).
#     conhost --headless keeps the process in the user's interactive session (needed for UI automation).
$t = Get-ScheduledTask -TaskName 'windows-mcp-server' -ErrorAction SilentlyContinue
if (-not $t) { throw "scheduled task 'windows-mcp-server' not found after install" }
$a = New-ScheduledTaskAction -Execute "$env:windir\System32\conhost.exe" -Argument ('--headless cmd.exe /c "' + $w + '"')
Set-ScheduledTask -TaskName 'windows-mcp-server' -Action $a | Out-Null
"task action: " + ((Get-ScheduledTask -TaskName 'windows-mcp-server').Actions | ForEach-Object { $_.Execute + ' ' + $_.Arguments })

# 4) Windows Firewall: TCP $Port only from lab-assistant
if (-not (Get-NetFirewallRule -Name "windows-mcp-$Port" -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -Name "windows-mcp-$Port" -DisplayName "Windows-MCP $Port from lab-assistant" `
    -Direction Inbound -Protocol TCP -LocalPort $Port -RemoteAddress $AssistantIp -Action Allow -Profile Any | Out-Null
} else {
  # rule exists (re-run): make sure it still points at the current assistant IP
  Set-NetFirewallRule -Name "windows-mcp-$Port" -RemoteAddress $AssistantIp -Enabled True | Out-Null
}
Get-NetFirewallRule -Name "windows-mcp-$Port" | Select-Object Name,Enabled,Direction,Action | Format-Table -Auto | Out-String
Get-ScheduledTask -TaskName windows-mcp-server | Select-Object TaskName,State | Format-Table -Auto | Out-String
"NEXT: re-run windows-rdp-autoconsole.ps1 as Administrator (install --force removed its restart loop from start-server.cmd)."
