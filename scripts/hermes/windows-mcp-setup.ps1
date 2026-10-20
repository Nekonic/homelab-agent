# Windows-MCP setup on lab-windows (run as the desktop user, e.g. Admin).
# Prereq: uv + windows-mcp installed (see docs/05-mcp.md).
# The auth key is read from stdin so it never appears on a command line or in this file:
#   (lab-assistant) grep '^WINDOWS_MCP_AUTH_KEY=' ~/.hermes/.env | cut -d= -f2- \
#     | ssh Admin@<WIN_LAB_IP> '$input | powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\Admin\windows-mcp-setup.ps1'
param(
  [string]$WinIp       = "<WIN_LAB_IP>",        # e.g. 10.10.0.x  (bind address)
  [string]$AssistantIp = "<ASSISTANT_LAB_IP>",  # e.g. 10.10.0.y  (only allowed client)
  [int]$Port           = 8000
)
$ErrorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"
$env:PYTHONUTF8 = "1"; $env:Path = "$env:USERPROFILE\.local\bin;$env:Path"
$k = [Console]::In.ReadLine().Trim()
if ($k.Length -lt 20) { throw "auth key missing on stdin" }

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
icacls "$d\config.toml" /inheritance:r /grant:r "${env:USERNAME}:(R,W)" "SYSTEM:(F)" "Administrators:(F)" | Out-Null
"config.toml written ({0} bytes)" -f (Get-Item "$d\config.toml").Length

# 2) per-user Scheduled Task "windows-mcp-server" (AtLogOn, Interactive, RunLevel Limited)
#    windows-mcp may print a cp949 decode traceback on Korean Windows; the task is still registered.
$ErrorActionPreference = "Continue"
windows-mcp install --transport streamable-http --host $WinIp --port $Port --force 2>&1 | Select-Object -First 12

# 3) wrapper env: UTF-8 console (Korean locale) + telemetry off. Re-run after any `install --force`.
$w = "$d\start-server.cmd"
$c = Get-Content $w -Raw
if ($c -notmatch "ANONYMIZED_TELEMETRY") {
  $c = $c -replace "setlocal`r?`n", "setlocal`r`nset PYTHONUTF8=1`r`nset ANONYMIZED_TELEMETRY=false`r`n"
  [IO.File]::WriteAllText($w, $c, (New-Object Text.UTF8Encoding($false)))
}
"--- start-server.cmd ---"; Get-Content $w

# 4) Windows Firewall: TCP $Port only from lab-assistant
if (-not (Get-NetFirewallRule -Name "windows-mcp-$Port" -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -Name "windows-mcp-$Port" -DisplayName "Windows-MCP $Port from lab-assistant" `
    -Direction Inbound -Protocol TCP -LocalPort $Port -RemoteAddress $AssistantIp -Action Allow -Profile Any | Out-Null
}
Get-NetFirewallRule -Name "windows-mcp-$Port" | Select-Object Name,Enabled,Direction,Action | Format-Table -Auto | Out-String
Get-ScheduledTask -TaskName windows-mcp-server | Select-Object TaskName,State | Format-Table -Auto | Out-String
