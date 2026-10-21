#ps1_sysnative
# lab-windows 첫 부팅 user_data (Cloudbase-Init이 64-bit PowerShell로 실행)
# 사용법: 저장소 밖에 복사 → 자리표시자 채우기 →
#   openstack server create ... --config-drive true --user-data windows.ps1
# 자리표시자:
#   <WIN_ADMIN_PASSWORD> : Admin 계정 비밀번호 (복잡도 정책 충족)
#   <VNC_PASSWORD>       : TightVNC 비밀번호 (최대 8자, 초과분은 잘림)
#   <SSH_PUBLIC_KEY>     : Kolla 호스트의 관리자 키 ~/.ssh/lab-key.pub 한 줄 (ssh-ed25519 AAAA... lab-key, docs/01 B-4).
#                          봇(비서 VM)용 키는 나중에 docs/05 §3-0에서 from= 조건을 붙여 따로 추가합니다.
#   <ASSISTANT_LAB_IP>   : VNC(5900)를 허용할 lab-assistant의 lab-net IP (예: 10.10.0.x). 쉼표로 여러 개 가능
#   <TIGHTVNC_MSI_SHA256>: 아래 TightVNC MSI의 SHA256 (얻는 법은 4번 주석). 비워 두거나 자리표시자 그대로면
#                          VNC 설치를 경고와 함께 건너뜁니다(나머지는 정상 진행).
# 결과: C:\lab-init.log (transcript). sshd(와 해시가 있으면 tvnserver)가 Running일 때만 C:\lab-init.done 을 쓰고
#       Cloudbase-Init을 끕니다. 아니면 exit 1002 → Cloudbase-Init이 다음 부팅에 이 스크립트를 다시 실행.
#       시도 횟수는 C:\lab-init.attempts 에 기록하고, 3번째 시도도 실패하면 경고를 남기고 완료 처리
#       (C:\lab-init.done 에 INCOMPLETE 표시) + Cloudbase-Init 끄기 → 무한 재시도와 부팅마다 비밀번호가
#       바뀌는 문제를 막습니다. 원인은 C:\lab-init.log 에서 확인 후 수동으로 고칩니다.

$ErrorActionPreference = 'Continue'
if (Test-Path 'C:\lab-init.done') { exit 0 }
Start-Transcript -Path 'C:\lab-init.log' -Append
$maxAttempts = 3
$attemptFile = 'C:\lab-init.attempts'
$attempt = 1
if (Test-Path $attemptFile) {
  try { $attempt = [int]((Get-Content $attemptFile -Raw).Trim()) + 1 } catch { $attempt = $maxAttempts }
}
Set-Content -Path $attemptFile -Value $attempt
Write-Output "lab-init attempt $attempt of $maxAttempts"
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

# 주의: Add-WindowsCapability 가 만드는 'OpenSSH-Server-In-TCP' 규칙은 Private 프로필 전용입니다.
# OpenStack VM 의 네트워크는 Public 이라 그 규칙만으로는 22번이 막힙니다(2026-10-21 실제 확인).
# 그래서 모든 프로필에서, lab-assistant 주소에서만 열리는 규칙을 직접 만들거나 덮어씁니다.
$sshFrom = '<ASSISTANT_LAB_IP>' -split ',' | ForEach-Object { $_.Trim() }
if (Get-NetFirewallRule -Name 'lab-sshd-22' -ErrorAction SilentlyContinue) {
  Set-NetFirewallRule -Name 'lab-sshd-22' -Enabled True -Profile Any -RemoteAddress $sshFrom
} else {
  New-NetFirewallRule -Name 'lab-sshd-22' -DisplayName 'OpenSSH Server 22 (lab-assistant, all profiles)' `
    -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -Profile Any -RemoteAddress $sshFrom
}
Restart-Service sshd

# 4. TightVNC 2.8.90 서버 (무인 설치, SHA256 검증 필수)
# 해시 얻는 법: 신뢰할 수 있는 PC에서 같은 URL의 MSI를 받아
#   Windows: Get-FileHash .\tightvnc-2.8.90-gpl-setup-64bit.msi -Algorithm SHA256
#   macOS/Linux: shasum -a 256 tightvnc-2.8.90-gpl-setup-64bit.msi
# 나온 값을 아래에 넣습니다(가능하면 tightvnc.com 다운로드 페이지 표기와 대조). 값이 틀리면 설치하지 않습니다.
$vncUrl = 'https://www.tightvnc.com/download/2.8.90/tightvnc-2.8.90-gpl-setup-64bit.msi'
$vncSha256 = '<TIGHTVNC_MSI_SHA256>'
$vncWanted = $true
$msi = Join-Path $env:TEMP 'tightvnc.msi'
$got = ''
if ($vncSha256 -notmatch '^[0-9A-Fa-f]{64}$') {
  # empty or still the placeholder: VNC is optional (fallback for logon/UAC screens) -> skip, do not retry forever
  $vncWanted = $false
  Write-Warning 'TightVNC SHA256 not set - skipping VNC install (set the hash and install TightVNC manually later)'
} else {
  Invoke-WebRequest -UseBasicParsing -Uri $vncUrl -OutFile $msi
  $got = (Get-FileHash $msi -Algorithm SHA256).Hash
}
if (-not $vncWanted) {
  # nothing to install
} elseif ($got -ne $vncSha256.ToUpper()) {
  Write-Output "TightVNC MSI SHA256 mismatch (got $got) - skipping install"
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
powercfg /change standby-timeout-dc 0
powercfg /change hibernate-timeout-ac 0
powercfg /change hibernate-timeout-dc 0
powercfg /change monitor-timeout-ac 0
powercfg /hibernate off
# 시작 메뉴에서 실수로 '절전'을 눌러도 절전(S3)에 들어가지 않게 정책으로 막습니다.
# QEMU의 Windows는 S3에서 깨어나지 못하고 멈추는 경우가 많고(dompmwakeup 후에도 무응답, 2026-10-21 확인),
# 깨어나지 못하면 nova가 'suspended unexpectedly'로 보고 VM을 끕니다. 정책은 다음 부팅부터 적용됩니다.
$pp = 'HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings\abfc2519-3608-4c2a-94ea-171b0ed546ab'   # Allow standby states (S1-S3)
New-Item -Path $pp -Force | Out-Null
Set-ItemProperty $pp -Name ACSettingIndex -Value 0 -Type DWord
Set-ItemProperty $pp -Name DCSettingIndex -Value 0 -Type DWord
$ep = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'
New-Item -Path $ep -Force | Out-Null
Set-ItemProperty $ep -Name ShowSleepOption -Value 0 -Type DWord   # hide 'Sleep' in the Start menu power button
powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS SBUTTONACTION 0
powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS SBUTTONACTION 0
powercfg /setactive SCHEME_CURRENT

# ---- 5. 상태 확인 → 완료 표시 + Cloudbase-Init 비활성화 ----
# sshd(와 해시를 넣었다면 tvnserver)가 Running이어야 "완료"입니다. 아니면 완료 표시도, Cloudbase-Init 끄기도
# 하지 않고 exit 1002 (Cloudbase-Init: 재부팅 없이, 다음 부팅에 user_data 다시 실행)로 끝냅니다.
# 단, $maxAttempts 번째 시도까지 실패하면 경고를 남기고 완료 처리합니다(무한 재시도 방지).
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
# 서비스가 떠 있어도 방화벽이 막으면 소용없으므로, 모든 프로필용 22번 허용 규칙이 켜져 있는지도 봅니다.
$fw = Get-NetFirewallRule -Name 'lab-sshd-22' -ErrorAction SilentlyContinue
$sshFwOk = [bool]($fw -and $fw.Enabled -eq 'True' -and $fw.Profile -eq 'Any')
$sshOk = $sshOk -and $sshFwOk
if ($vncWanted) { $vncOk = Test-Running 'tvnserver' } else { $vncOk = $true }
Write-Output "health: sshd=$sshOk (firewall all-profiles=$sshFwOk) tvnserver=$vncOk (vnc wanted: $vncWanted)"
$doneNote = 'OK'
if (-not ($sshOk -and $vncOk)) {
  if ($attempt -lt $maxAttempts) {
    Write-Output "not complete - lab-init.done not written, Cloudbase-Init stays enabled (rerun next boot, attempt $attempt of $maxAttempts)"
    Stop-Transcript
    exit 1002
  }
  $doneNote = "INCOMPLETE after $attempt attempts: sshd=$sshOk tvnserver=$vncOk - fix manually, see C:\lab-init.log"
  Write-Warning "giving up after $attempt attempts - marking done and disabling Cloudbase-Init anyway. $doneNote"
}
if (-not $vncWanted) { $doneNote = "$doneNote (VNC skipped: no TightVNC SHA256)" }

Set-Content -Path 'C:\lab-init.done' -Value ((Get-Date -Format o) + ' ' + $doneNote)
# SetUserPasswordPlugin이 ed25519 키페어에서 실패하면 부팅마다 Admin 비밀번호를 임의 값으로 바꿉니다.
# 첫 부팅 설정은 끝났으므로 다음 부팅부터 실행하지 않습니다.
Set-Service cloudbase-init -StartupType Disabled
Stop-Transcript
exit 0
