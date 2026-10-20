# Windows 자동 로그온 설정 (Windows-MCP처럼 데스크톱 세션이 필요한 도구용)
#
# MS 문서의 기본 방식(Winlogon 레지스트리 DefaultPassword)을 씁니다.
# https://learn.microsoft.com/troubleshoot/windows-server/user-profiles-and-logon/turn-on-automatic-logon
#
# 2026-10-21 확인 (Windows 11 build 26200, OpenStack VM):
#   - LSA 비밀(Sysinternals Autologon 방식)로 넣으면 '재부팅'은 되지만(ARSO 덕분),
#     전원을 껐다 켜면(nova stop/start) 자동 로그온이 되지 않았습니다.
#   - 레지스트리 DefaultPassword 방식은 전원을 껐다 켜도 39초 만에 로그온됩니다.
# 트레이드오프: 비밀번호가 HKLM Winlogon 키에 평문으로 남습니다(로컬 사용자가 읽을 수 있음).
#   사용자가 Admin 하나뿐이고 보안 그룹으로 접근이 막힌 실습용 VM이라 감수합니다.
#
# 주의: Windows PowerShell 5에서 쓰려면 이 파일을 UTF-8 BOM으로 저장해야 합니다(저장소 파일은 BOM 포함).
#
# 사용법 (관리자 PowerShell, 비밀번호는 표준 입력 첫 줄로 전달):
#   <비밀번호를 출력하는 명령> | ssh Admin@<WIN_IP> "powershell -File C:\...\windows-autologon.ps1 -User Admin"
# 해제:  powershell -File windows-autologon.ps1 -Disable

param(
  [string]$User = "Admin",
  [switch]$Disable
)
$ErrorActionPreference = "Stop"
$wl = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

if ($Disable) {
  Set-ItemProperty $wl -Name AutoAdminLogon -Value "0"
  Remove-ItemProperty $wl -Name DefaultPassword -ErrorAction SilentlyContinue
  "autologon disabled"
  exit 0
}

$pw = [Console]::In.ReadLine()
if ([string]::IsNullOrEmpty($pw)) { throw "password not provided on stdin" }

# 비밀번호가 맞는지 먼저 확인 (틀리면 부팅 때 로그온 실패 화면에 멈춤)
Add-Type -AssemblyName System.DirectoryServices.AccountManagement
$ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext("Machine")
if (-not $ctx.ValidateCredentials($User, $pw)) { throw "password for $User is wrong" }

Set-ItemProperty $wl -Name AutoAdminLogon    -Value "1"
Set-ItemProperty $wl -Name DefaultUserName   -Value $User
Set-ItemProperty $wl -Name DefaultDomainName -Value $env:COMPUTERNAME
Set-ItemProperty $wl -Name DefaultPassword   -Value $pw     # 없으면 Windows가 AutoAdminLogon을 0으로 되돌림
Remove-ItemProperty $wl -Name AutoLogonCount -ErrorAction SilentlyContinue   # 횟수 제한 없음

# Windows 11의 "Microsoft 계정은 Windows Hello로만 로그인" 요구 끄기 (자동 로그온을 방해할 수 있음)
$pl = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device"
New-Item -Path $pl -Force | Out-Null
Set-ItemProperty $pl -Name DevicePasswordLessBuildVersion -Value 0 -Type DWord

# 화면 보호기 잠금 끄기 (잠긴 데스크톱에서는 UI 자동화가 동작하지 않음)
$cp = "HKCU:\Control Panel\Desktop"
Set-ItemProperty $cp -Name ScreenSaveActive -Value "0" -ErrorAction SilentlyContinue
Set-ItemProperty $cp -Name ScreenSaverIsSecure -Value "0" -ErrorAction SilentlyContinue

"autologon enabled for $env:COMPUTERNAME\$User"
