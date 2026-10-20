# RDP 창을 그냥 닫아도 데스크톱이 잠기지 않게 하기 + Windows-MCP 자동 재시작
#
# 1) RDP 연결이 끊기면(이벤트 24, TerminalServices-LocalSessionManager) SYSTEM 권한으로
#    그 세션을 콘솔로 돌려보냅니다(tscon). 데스크톱이 계속 살아 있어 Windows-MCP가 동작합니다.
# 2) Windows-MCP 시작 스크립트를 "죽으면 15초 뒤 재시작" 루프로 감쌉니다.
#    (세션이 잠깐 끊긴 사이 시작되면 "No active interactive desktop"으로 바로 종료되기 때문)
#
# 관리자 PowerShell에서 한 번 실행합니다. 주의: Windows PowerShell 5용이므로 UTF-8 BOM으로 저장되어 있어야 합니다.
$ErrorActionPreference = "Stop"
$dir = "C:\ProgramData\lab"
New-Item -ItemType Directory -Force -Path $dir | Out-Null

# ---- 1. 끊긴 RDP 세션을 콘솔로 ----
$handler = @'
# Admin의 데스크톱 세션(explorer.exe가 있는 세션)을 콘솔로 옮김. 이미 콘솔이면 아무 일도 안 함.
Start-Sleep -Seconds 2
$sid = (Get-Process explorer -IncludeUserName -ErrorAction SilentlyContinue |
        Where-Object { $_.UserName -like "*\Admin" } | Select-Object -First 1).SessionId
if ($sid) { & "$env:windir\System32\tscon.exe" $sid /dest:console 2>$null }
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

# 예전 방식의 바로가기는 이제 필요 없음
Remove-Item "C:\Users\Public\Desktop\RDP-disconnect-to-console.cmd" -ErrorAction SilentlyContinue

"rdp-disconnect-to-console task registered; windows-mcp start script now restarts on exit"
