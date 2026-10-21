#ps1_sysnative
# lab-windows 첫 부팅 user_data (Cloudbase-Init이 64-bit PowerShell로 실행)
# 사용법: 저장소 밖에 복사 → 자리표시자 채우기 →
#   openstack server create ... --config-drive true --user-data windows.ps1
# 자리표시자:
#   <WIN_ADMIN_PASSWORD> : Admin 계정 비밀번호 (복잡도 정책 충족)
#   <VNC_PASSWORD>       : TightVNC 비밀번호 (최대 8자, 초과분은 잘림)
#   <SSH_PUBLIC_KEY>     : lab-assistant가 쓸 SSH 공개키 한 줄 (ssh-ed25519 AAAA... comment)
#   <ASSISTANT_LAB_IP>   : VNC(5900)를 허용할 lab-assistant의 lab-net IP (예: 10.10.0.x). 쉼표로 여러 개 가능
#   <TIGHTVNC_MSI_SHA256>: 아래 TightVNC MSI의 SHA256 (얻는 법은 4번 주석)
# 결과: C:\lab-init.log (transcript). sshd·tvnserver가 둘 다 Running일 때만 C:\lab-init.done 을 쓰고
#       Cloudbase-Init을 끕니다. 아니면 exit 1002 → Cloudbase-Init이 다음 부팅에 이 스크립트를 다시 실행.

$ErrorActionPreference = 'Continue'
if (Test-Path 'C:\lab-init.done') { exit 0 }
Start-Transcript -Path 'C:\lab-init.log' -Append
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 1. Admin 비밀번호
$pw = ConvertTo-SecureString '<WIN_ADMIN_PASSWORD>' -AsPlainText -Force
Set-LocalUser -Name 'Admin' -Password $pw -PasswordNeverExpires $true

# 2. RDP 활성화 + 방화벽 (그룹 리소스 ID 사용 → 한국어 등 지역화 OS에서도 동작)
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0
Enable-NetFirewallRule -Group '@FirewallAPI.dll,-28752'

# 3. OpenSSH Server (이미지에는 클라이언트만 있음)
Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd

New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name 'DefaultShell' `
  -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force | Out-Null

# 관리자 계정은 ~/.ssh/authorized_keys 대신 이 파일을 사용
$ak = 'C:\ProgramData\ssh\administrators_authorized_keys'
Set-Content -Path $ak -Value '<SSH_PUBLIC_KEY>' -Encoding ascii
# 상속 제거, Administrators(S-1-5-32-544)·SYSTEM(S-1-5-18)만 허용 — 아니면 sshd가 무시함
icacls.exe $ak /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F'

if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
    -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
}
Restart-Service sshd

# 4. TightVNC 2.8.90 서버 (무인 설치, SHA256 검증 필수)
# 해시 얻는 법: 신뢰할 수 있는 PC에서 같은 URL의 MSI를 받아
#   Windows: Get-FileHash .\tightvnc-2.8.90-gpl-setup-64bit.msi -Algorithm SHA256
#   macOS/Linux: shasum -a 256 tightvnc-2.8.90-gpl-setup-64bit.msi
# 나온 값을 아래에 넣습니다(가능하면 tightvnc.com 다운로드 페이지 표기와 대조). 값이 틀리면 설치하지 않습니다.
$vncUrl = 'https://www.tightvnc.com/download/2.8.90/tightvnc-2.8.90-gpl-setup-64bit.msi'
$vncSha256 = '<TIGHTVNC_MSI_SHA256>'
$msi = Join-Path $env:TEMP 'tightvnc.msi'
Invoke-WebRequest -UseBasicParsing -Uri $vncUrl -OutFile $msi
$got = (Get-FileHash $msi -Algorithm SHA256).Hash
if ($vncSha256 -notmatch '^[0-9A-Fa-f]{64}$' -or $got -ne $vncSha256.ToUpper()) {
  Write-Output "TightVNC MSI SHA256 mismatch or not set (got $got) - skipping install"
} else {
  $msiArgs = @(
    '/i', "`"$msi`"", '/quiet', '/norestart',
    'ADDLOCAL=Server',
    'SET_USEVNCAUTHENTICATION=1', 'VALUE_OF_USEVNCAUTHENTICATION=1',
    'SET_PASSWORD=1', 'VALUE_OF_PASSWORD=<VNC_PASSWORD>',
    'SET_ALLOWLOOPBACK=1', 'VALUE_OF_ALLOWLOOPBACK=1'
  )
  Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait
}
Remove-Item $msi -Force -ErrorAction SilentlyContinue

# VNC는 lab-assistant에서만 (RDP와 달리 VNC 인증은 약함: 비밀번호 8자, 평문에 가까움)
$vncFrom = '<ASSISTANT_LAB_IP>' -split ',' | ForEach-Object { $_.Trim() }
if (Get-NetFirewallRule -Name 'TightVNC-In-TCP-5900' -ErrorAction SilentlyContinue) {
  Set-NetFirewallRule -Name 'TightVNC-In-TCP-5900' -RemoteAddress $vncFrom
} else {
  New-NetFirewallRule -Name 'TightVNC-In-TCP-5900' -DisplayName 'TightVNC Server (5900)' `
    -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 5900 -RemoteAddress $vncFrom
}

# ---- 절전 끄기 ----
# 게스트가 절전(S3)에 들어가면 nova가 'suspended unexpectedly'로 보고 VM을 stop합니다.
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /change monitor-timeout-ac 0
powercfg /hibernate off

# ---- 5. 상태 확인 → 완료 표시 + Cloudbase-Init 비활성화 ----
# sshd·tvnserver가 둘 다 Running이어야 "완료"입니다. 아니면 완료 표시도, Cloudbase-Init 끄기도 하지 않고
# exit 1002 (Cloudbase-Init: 재부팅 없이, 다음 부팅에 user_data 다시 실행)로 끝냅니다.
function Test-Running($name) {
  for ($i = 0; $i -lt 12; $i++) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') { return $true }
    if ($svc) { Start-Service -Name $name -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 5
  }
  return $false
}
$sshOk = Test-Running 'sshd'
$vncOk = Test-Running 'tvnserver'
Write-Output "health: sshd=$sshOk tvnserver=$vncOk"
if (-not ($sshOk -and $vncOk)) {
  Write-Output 'not complete - lab-init.done not written, Cloudbase-Init stays enabled (rerun next boot)'
  Stop-Transcript
  exit 1002
}

Set-Content -Path 'C:\lab-init.done' -Value (Get-Date -Format o)
# SetUserPasswordPlugin이 ed25519 키페어에서 실패하면 부팅마다 Admin 비밀번호를 임의 값으로 바꿉니다.
# 첫 부팅 설정은 끝났으므로 다음 부팅부터 실행하지 않습니다.
Set-Service cloudbase-init -StartupType Disabled
Stop-Transcript
exit 0
