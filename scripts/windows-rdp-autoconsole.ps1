# RDP 창을 닫아도 데스크톱이 잠기지 않도록 설정 + Windows-MCP 자동 재시작
#
# 1) RDP 연결이 끊기면(이벤트 24, TerminalServices-LocalSessionManager) SYSTEM 권한으로
#    그 세션을 콘솔로 돌려보냅니다(tscon). 데스크톱 세션이 유지되므로 Windows-MCP가 계속 동작합니다.
# 2) Windows-MCP 시작 스크립트를 "종료되면 15초 뒤 재시작" 루프로 감쌉니다.
#    (세션이 잠깐 끊긴 사이 시작되면 "No active interactive desktop"으로 바로 종료되기 때문)
#
# 관리자 PowerShell에서 한 번 실행합니다. 주의: Windows PowerShell 5용이므로 UTF-8 BOM으로 저장되어 있어야 합니다.
$ErrorActionPreference = "Stop"
$dir = "C:\ProgramData\lab"
New-Item -ItemType Directory -Force -Path $dir | Out-Null

# ---- 1. 끊긴 RDP 세션을 콘솔로 ----
# 주의: 이벤트 24(연결 끊김)는 RDP 창을 닫을 때뿐 아니라, RDP로 접속하는 순간 원래 콘솔 쪽 연결이
# 끊길 때도 발생합니다. 이벤트만 보고 tscon 하면 방금 접속한 RDP 세션을 빼앗아 RDP 창이 닫힙니다
# (2026-10-21 발생 확인). 따라서 세션 상태(WTSConnectState)가 "Disconnected(4)"일 때만 옮깁니다.
# RDP로 접속 중이면 상태가 Active(0)라 아무것도 하지 않습니다. 판단 결과는 rdp-to-console.log 에 남깁니다.
$handler = @'
Start-Sleep -Seconds 3
$log = "C:\ProgramData\lab\rdp-to-console.log"
Add-Type -Namespace Lab -Name Wts -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("wtsapi32.dll")] public static extern bool WTSQuerySessionInformation(System.IntPtr h, int sid, int cls, out System.IntPtr buf, out int bytes);
[System.Runtime.InteropServices.DllImport("wtsapi32.dll")] public static extern void WTSFreeMemory(System.IntPtr p);
"@
function Get-SessionState([int]$id) {
  $buf = [IntPtr]::Zero; $n = 0
  if (-not [Lab.Wts]::WTSQuerySessionInformation([IntPtr]::Zero, $id, 8, [ref]$buf, [ref]$n)) { return -1 }   # 8 = WTSConnectState
  try { return [Runtime.InteropServices.Marshal]::ReadInt32($buf) } finally { [Lab.Wts]::WTSFreeMemory($buf) }
}
$sid = (Get-Process explorer -IncludeUserName -ErrorAction SilentlyContinue |
        Where-Object { $_.UserName -like "*\Admin" } | Select-Object -First 1).SessionId
if ($null -eq $sid) { Add-Content $log ("{0:s} no Admin desktop session" -f (Get-Date)); exit 0 }
$state = Get-SessionState $sid   # 0 Active, 1 Connected, 4 Disconnected
if ($state -eq 4) {
  & "$env:windir\System32\tscon.exe" $sid /dest:console 2>$null
  Add-Content $log ("{0:s} session {1} was Disconnected -> tscon to console (exit {2})" -f (Get-Date), $sid, $LASTEXITCODE)
} else {
  Add-Content $log ("{0:s} session {1} state={2} -> left alone" -f (Get-Date), $sid, $state)
}
'@
Set-Content -Path "$dir\rdp-to-console.ps1" -Value $handler -Encoding Ascii

$taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>RDP disconnect -> move session back to console (keeps desktop unlocked for Windows-MCP)</Description></RegistrationInfo>
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-TerminalServices-LocalSessionManager/Operational"&gt;&lt;Select Path="Microsoft-Windows-TerminalServices-LocalSessionManager/Operational"&gt;*[System[(EventID=24)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>Queue</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT1M</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$dir\rdp-to-console.ps1"</Arguments>
    </Exec>
  </Actions>
</Task>
"@
Register-ScheduledTask -TaskName "rdp-disconnect-to-console" -Xml $taskXml -Force | Out-Null

# ---- 2. Windows-MCP 재시작 루프 ----
$start = "C:\Users\Admin\.windows-mcp\start-server.cmd"
if (Test-Path $start) {
  $body = Get-Content $start -Raw
  if ($body -notmatch ":loop") {
    $body = $body -replace "(?m)^(.*windows_mcp serve.*)$", ":loop`r`n`$1`r`ntimeout /t 15 /nobreak >nul`r`ngoto loop"
    Set-Content -Path $start -Value $body -Encoding Ascii
  }
}

# 이전 방식의 바로가기는 더 이상 필요 없으므로 삭제
Remove-Item "C:\Users\Public\Desktop\RDP-disconnect-to-console.cmd" -ErrorAction SilentlyContinue

"rdp-disconnect-to-console task registered; windows-mcp start script now restarts on exit"
