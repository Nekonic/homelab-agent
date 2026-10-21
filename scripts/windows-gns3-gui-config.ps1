# GNS3 GUI 3.1 (Windows) 를 원격 GNS3 서버(controller)에 연결하는 설정을 씁니다.
#   %APPDATA%\GNS3\3.1\gns3_gui.ini (내용은 JSON) 의 Controller 섹션 + 첫 실행 마법사/안내 창 끄기.
#   비밀번호는 표준 입력 첫 줄로만 받습니다(명령줄·파일에 남지 않음). 파일 ACL 은 사용자/SYSTEM/Administrators.
# 사용 (Kolla 호스트, docs/03 §6):
#   sec GNS3_PASSWORD | ssh lab-windows 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\windows-gns3-gui-config.ps1 -GnsHost <GNS3_LAB_IP>'
# GUI 가 실행 중이면 종료한 뒤 실행합니다(GUI 가 종료할 때 자기 설정으로 파일을 덮어쓰기 때문).
param([string]$GnsHost = "<GNS3_LAB_IP>", [int]$Port = 3080, [string]$User = "admin")
$ErrorActionPreference = "Stop"
$pw = [Console]::In.ReadLine(); if ([string]::IsNullOrEmpty($pw)) { throw "password missing on stdin" }
$dir = Join-Path $env:APPDATA "GNS3\3.1"; New-Item -ItemType Directory -Force $dir | Out-Null
$f = Join-Path $dir "gns3_gui.ini"
$cfg = @{}
if (Test-Path $f) { $cfg = Get-Content $f -Raw | ConvertFrom-Json | ForEach-Object { $h=@{}; $_.PSObject.Properties | % { $h[$_.Name]=$_.Value }; $h } }
$cfg["version"] = "3.1.0a6"; $cfg["type"] = "settings"
$cfg["Controller"] = [ordered]@{ remote = $true; auto_start = $false; host = $GnsHost; port = $Port; protocol = "http"; username = $User; password = $pw; accept_insecure_ssl_certificate = $false }
$mw = @{}; if ($cfg.ContainsKey("MainWindow") -and $cfg["MainWindow"]) { $cfg["MainWindow"].PSObject.Properties | % { $mw[$_.Name]=$_.Value } }
$mw["hide_setup_wizard"] = $true; $mw["hide_getting_started_dialog"] = $true
$cfg["MainWindow"] = $mw
[IO.File]::WriteAllText($f, ($cfg | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
icacls $f /inheritance:r /grant:r "${env:USERNAME}:(R,W)" "*S-1-5-18:(F)" "*S-1-5-32-544:(F)" | Out-Null
"written $f"
