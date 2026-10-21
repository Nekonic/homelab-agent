# 03. Windows 11 실습 VM

## 목적

- `lab-windows`가 첫 부팅 때 RDP, OpenSSH Server, TightVNC를 자동으로 활성화하도록 구성
- AI 에이전트(`lab-assistant`)가 SSH(PowerShell)와 VNC(화면)로 Windows를 조작할 수 있도록 설정
- GNS3 GUI 3.1.0a6(서버와 동일 버전)을 설치하고 원격 GNS3 서버에 연결

> 이 VM은 구성을 마친 뒤 평소에는 꺼 둡니다. 자동 로그온, RDP 창 닫기 처리, Windows-MCP, 전원 제어(`ssh winpower start|stop|status`), 봇용 `ssh win` 별칭은 [05 문서](05-mcp.md#3-windows-mcp-lab-windows)에서 설정합니다.

## 사전 요구사항

- [01 문서](01-openstack-reset-and-base.md)의 Windows 11 이미지(`win11`), `sg-windows`, flavor `lab.windows16`
- [02 문서](02-gns3-server.md)의 GNS3 server 동작
- `lab-windows`는 [01 문서 D-2·D-3](01-openstack-reset-and-base.md#d-2-windows-user_data-준비)에서 user_data를 채워 생성 완료 (lab-assistant를 먼저 만들고 그 IP를 `<ASSISTANT_LAB_IP>`에 넣음)
- Kolla 호스트 `~/.ssh/config`의 `lab-assistant`, `lab-windows` 별칭 ([01 문서 D-5](01-openstack-reset-and-base.md#d-5-kolla-호스트-ssh-별칭-설정), `lab-windows`는 lab-assistant를 점프 호스트로 사용)
- Placeholder
  - `<WIN_LAB_IP>`: lab-windows의 lab-net IP (`os server show lab-windows -c addresses`)
  - `<WIN_FIP>`, `<ASSISTANT_FIP>`, `<GNS3_LAB_IP>`, `<GNS3_PASSWORD>`
  - `<WIN11_QCOW2>`: `~/lab-images`에 둔 Windows 이미지 파일 이름 (확장자 제외)
  - user_data placeholder는 01 D-2 표 참고
- 이 문서의 `os`는 [00 문서](00-host-check.md)의 admin helper입니다. Kolla 호스트에서 `kolla_toolbox` 안의 `openstack`을 admin openrc로 호출하는 셸 함수입니다.
- 명령마다 실행하는 머신을 `# (Kolla 호스트)`, `# (Windows, PowerShell)`, `# (PC)`처럼 표시했습니다.

## 절차

### 1. 이미지 내부 확인 (libguestfs)

user_data를 이미지에 맞게 작성하려면 이미지에 무엇이 설치되어 있는지 먼저 확인해야 합니다. 01 C-2에서 이미지를 업로드하기 전에 확인해 두는 것이 좋습니다.

```bash
# (Kolla 호스트)
sudo apt install -y libguestfs-tools
virt-filesystems --long --parts --filesystems -a ~/lab-images/<WIN11_QCOW2>.qcow2
```

이 이미지에서는 `guestfish -i`(OS 자동 인식)가 실패했으므로 Windows 파티션(예: `/dev/sda3`)을 직접 마운트합니다.

```bash
# (Kolla 호스트)
guestfish --ro -a ~/lab-images/<WIN11_QCOW2>.qcow2
><fs> run
><fs> mount /dev/sda3 /
><fs> ls "/Program Files"
><fs> ls "/Program Files/Cloudbase Solutions/Cloudbase-Init/conf"
><fs> cat "/Program Files/Cloudbase Solutions/Cloudbase-Init/conf/cloudbase-init.conf"
><fs> ls /Windows/System32/OpenSSH
><fs> exit
```

예시 이미지에서 확인된 내용:

| 항목 | 결과 | 의미 |
|---|---|---|
| Cloudbase-Init | 있음. `username=Admin`, `inject_user_password=true`, metadata = ConfigDrive | `--config-drive true` 필수, 계정명은 `Admin` |
| Virtio-Win | 있음 | virtio 디스크/NIC 사용 가능 |
| QEMU guest agent | 있음 | `hw_qemu_guest_agent=yes` |
| OpenSSH | 클라이언트만 (sshd 없음) | user_data에서 Server 설치 필요 |
| VNC 서버 | 없음 | user_data에서 TightVNC 설치 |

### 2. 첫 부팅 스크립트

스크립트: [scripts/windows-userdata.ps1](../scripts/windows-userdata.ps1) (`#ps1_sysnative` → Cloudbase-Init이 64-bit PowerShell로 실행)

하는 일:

1. `Admin` 비밀번호 설정
2. RDP 활성화 + 방화벽 그룹 허용
3. `Add-WindowsCapability OpenSSH.Server`, sshd 자동 시작, 기본 셸 PowerShell
4. `administrators_authorized_keys`에 공개키 등록 + `icacls`로 권한 정리, 방화벽 22번 허용(**모든 프로필**, lab-assistant 주소만). OpenSSH 설치 시 생성되는 기본 규칙은 Private 프로필 전용이라, 네트워크 프로필이 Public인 OpenStack VM에서는 22번이 막힙니다.
5. TightVNC 2.8.90 MSI를 다운로드해 SHA256을 검증한 뒤 무인 설치 (`ADDLOCAL=Server`, VNC 인증, `VALUE_OF_PASSWORD`(최대 8자), `ALLOWLOOPBACK`). 해시가 비어 있거나 placeholder 그대로면 경고를 남기고 VNC 설치만 건너뜁니다. VNC는 로그온·UAC 화면용 fallback입니다. 해시가 다르면 설치하지 않고 다음 부팅에 다시 시도합니다. 방화벽 5900번은 `-RemoteAddress <ASSISTANT_LAB_IP>`로 lab-assistant만 허용
6. 절전 끄기
7. `sshd`가 Running일 때만 완료 표시 `C:\lab-init.done`을 쓰고 Cloudbase-Init을 비활성화합니다. 해시를 넣었다면 `tvnserver`도 Running이어야 합니다. 그렇지 않으면 `exit 1002`로 종료하고, 다음 부팅에 스크립트가 다시 실행됩니다. 시도 횟수는 `C:\lab-init.attempts`에 기록됩니다. **3번째 시도까지 실패하면** 경고를 남기고 완료 처리(`lab-init.done`에 `INCOMPLETE`)한 뒤 Cloudbase-Init을 비활성화합니다. 무한 재시도와 부팅마다 비밀번호가 바뀌는 문제(아래 Troubleshooting 참고)를 막기 위한 동작입니다. 전체 로그는 `C:\lab-init.log`에 남습니다.

Placeholder 채우기(`<TIGHTVNC_MSI_SHA256>` 계산 포함)와 서버 생성은 [01 문서 D-2·D-3](01-openstack-reset-and-base.md#d-2-windows-user_data-준비)에서 진행합니다. 첫 부팅은 Windows 기능 설치 때문에 수 분 이상 걸립니다. 진행 상황은 `os console log show lab-windows | tail`로 확인합니다.

### 3. 보안 그룹 정책

| 포트 | 출발지 | 이유 |
|---|---|---|
| 22 (SSH) | `sg-assistant`만 | lab-assistant 전용 제어 채널 |
| 5900 (VNC) | `sg-assistant`만 | VNC는 암호화가 약해 LAN에도 열지 않음 |
| 3389 (RDP) | LAN + WireGuard 대역(`<WG_SUBNET>`) | 사람이 직접 화면 사용 ([01 문서](01-openstack-reset-and-base.md#b-5-보안-그룹)의 WG 규칙) |
| 8000 (Windows-MCP) | `sg-assistant`만 | [05 문서](05-mcp.md)에서 추가 |

### 4. RAM·디스크 resize와 C: 드라이브 확장

[01 문서](01-openstack-reset-and-base.md#b-3-flavor)대로 `lab.windows16`(16GB/150GB)으로 만들었다면 resize는 건너뛰고 아래 C: 확장만 진행합니다.

**Resize** (더 작은 flavor로 만든 VM을 늘릴 때). 단일 노드에서는 nova 설정에 `allow_resize_to_same_host = true`가 있어야 합니다(`sudo grep allow_resize /etc/kolla/nova-api/nova.conf`). VM을 끈 상태에서 진행합니다.

```bash
# (Kolla 호스트)
os flavor show lab.windows16 >/dev/null 2>&1 || os flavor create lab.windows16 --vcpus 4 --ram 16384 --disk 150
os server resize --flavor lab.windows16 --wait lab-windows
os server resize confirm lab-windows      # VERIFY_RESIZE → 확정
```

- 같은 호스트 안에서 디스크를 복사하므로 몇 분 걸립니다.
- 꺼진 VM도 placement에서 flavor 크기만큼 메모리를 예약하므로, `os hypervisor stats show`로 호스트 여유 자원을 먼저 확인하세요.

**C: 확장.** 디스크를 늘려도 C:는 자동으로 커지지 않습니다. 처음부터 150GB로 만든 경우도 마찬가지입니다. 복구(Recovery) 파티션이 C: 뒤에 있어서 Cloudbase-Init의 ExtendVolumes 플러그인이 C:를 확장하지 못하기 때문입니다. 필요하면 관리자 PowerShell에서 다음을 실행합니다.

```powershell
# (Windows, 관리자 PowerShell)
Get-Partition -DiskNumber 0                     # Recovery 파티션 번호 확인
reagentc /disable                               # WinRE를 C:\Windows\System32\Recovery로 이동
# diskpart: select disk 0 → select partition <N> → delete partition override
$max = (Get-PartitionSupportedSize -DriveLetter C).SizeMax
Resize-Partition -DriveLetter C -Size $max
reagentc /enable
```

> 파티션 삭제는 되돌릴 수 없습니다. 먼저 snapshot(`os server image create`)을 만들어 두세요.

diskpart 대신 PowerShell만 써도 됩니다. `Remove-Partition -DiskNumber 0 -PartitionNumber <N> -Confirm:$false`로 파티션을 삭제할 수 있습니다.

- 검증 (2026-10-21): 150GB 디스크에서 C: 149.8GB로 확장, WinRE 다시 Enabled.

SSH로 실행할 때 출력이 CP949로 인코딩되어 한글이 깨지면, 스크립트 첫 줄에 `[Console]::OutputEncoding = [Text.Encoding]::UTF8`을 추가하세요.

### 5. GNS3 GUI 3.1.0a6 설치

GitHub `gns3-gui` 릴리스 `v3.1.0a6`의 all-in-one 설치 파일을 다운로드하고 `.sha256` 자산으로 해시를 검증한 뒤 무인 설치합니다. SSH(Kolla 호스트에서 `ssh lab-windows`, 별칭은 [01 문서 D-5](01-openstack-reset-and-base.md#d-5-kolla-호스트-ssh-별칭-설정))나 RDP 세션의 PowerShell에서 실행합니다.

```powershell
# (Windows, PowerShell)
$v    = 'v3.1.0a6'
$name = 'GNS3-3.1.0a6-all-in-one.exe'
$base = "https://github.com/GNS3/gns3-gui/releases/download/$v"
$exe  = Join-Path $env:TEMP $name
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Invoke-WebRequest -UseBasicParsing "$base/$name"        -OutFile $exe
Invoke-WebRequest -UseBasicParsing "$base/$name.sha256" -OutFile "$exe.sha256"   # 자산 이름은 릴리스 페이지에서 확인

$expected = ((Get-Content "$exe.sha256" -Raw).Trim() -split '\s+')[0].ToUpper()
$actual   = (Get-FileHash $exe -Algorithm SHA256).Hash
if ($expected -ne $actual) { throw "SHA256 mismatch: $expected vs $actual" }

$p = Start-Process -FilePath $exe -ArgumentList '/S' -Wait -PassThru
$p.ExitCode                                                        # 0
(Get-Item 'C:\Program Files\GNS3\gns3.exe').VersionInfo.ProductVersion   # 3.1.0
```

- 검증 (2026-10-21): SHA256 일치, `/S` 종료 코드 `0`, ProductVersion `3.1.0`(파일 버전에는 `a6`가 붙지 않아 정상), 번들 Wireshark 설치됨, Npcap은 설치되지 않음(아래 Troubleshooting 참고)

### 6. GUI를 원격 GNS3 서버에 연결

GUI 설정 파일 `%APPDATA%\GNS3\3.1\gns3_gui.ini`(내용은 JSON)의 `Controller` 섹션에 원격 서버를 기록합니다. 첫 실행 마법사와 안내 창도 끕니다. 스크립트: [scripts/windows-gns3-gui-config.ps1](../scripts/windows-gns3-gui-config.ps1). 비밀번호는 표준 입력으로만 전달합니다.

```bash
# (Kolla 호스트) GUI가 실행 중이면 먼저 종료합니다(GUI는 종료할 때 자기 설정으로 파일을 덮어씀)
scp "$REPO/scripts/windows-gns3-gui-config.ps1" lab-windows:C:/Windows/Temp/
sec GNS3_PASSWORD | ssh lab-windows 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\windows-gns3-gui-config.ps1 -GnsHost <GNS3_LAB_IP>; Remove-Item C:\Windows\Temp\windows-gns3-gui-config.ps1'
```

그다음 RDP로 접속해 GNS3를 실행합니다. GUI 로그 `%APPDATA%\GNS3\3.1\gns3_gui.log`에 `Authenticated with controller <GNS3_LAB_IP> on port 3080`이 기록되면 연결된 것입니다. 2026-10-21에 이 로그가 기록되고 GUI에 프로젝트 창이 열리는 것을 확인했습니다.

```bash
ssh lab-windows 'Get-Content $env:APPDATA\GNS3\3.1\gns3_gui.log -Tail 5'
```

수동으로 설정할 때는 **Edit → Preferences → Server**에서 원격 서버 `http://<GNS3_LAB_IP>:3080`, `admin` / `<GNS3_PASSWORD>`를 입력합니다.

> Windows와 GNS3는 같은 lab-net에 있으므로 Floating IP가 아니라 **lab-net IP**를 사용합니다. sg-gns3는 sg-windows에서 들어오는 3080, 5000-5100, 5900-5999 트래픽을 허용합니다(01 B-5).

## 검증

```bash
# (lab-assistant)
nc -zv <WIN_LAB_IP> 22      # succeeded
nc -zv <WIN_LAB_IP> 5900    # succeeded (해시를 넣어 TightVNC를 설치한 경우)
```

Windows는 `lab-key`(개인키는 Kolla 호스트에만 있음)를 신뢰하고, 22번은 lab-assistant에서만 열려 있습니다. 따라서 Kolla 호스트에서 처음 SSH로 접속할 때는 lab-assistant를 점프 호스트로 사용합니다. [01 문서 D-5](01-openstack-reset-and-base.md#d-5-kolla-호스트-ssh-별칭-설정)에서 만든 `lab-windows` 별칭(`ProxyJump lab-assistant`)이 그 경로입니다.

```bash
# (Kolla 호스트)
ssh lab-windows             # PowerShell 프롬프트가 나와야 함
# (PC) RDP: <WIN_FIP>:3389 로 접속 (LAN 또는 WireGuard)
```

PowerShell 프롬프트에서:

```powershell
# (Windows, PowerShell)
Get-Service sshd, tvnserver -ErrorAction SilentlyContinue | Format-Table Name, Status, StartType   # 둘 다 Running
Get-Content C:\lab-init.done                 # 날짜 + OK (INCOMPLETE면 lab-init.log 확인)
Get-Content C:\lab-init.log -Tail 30
```

> TightVNC 해시(`<TIGHTVNC_MSI_SHA256>`)를 비워 VNC를 건너뛰었다면 `tvnserver` 서비스가 없으므로 `sshd` 한 줄만 나오면 정상입니다(`-ErrorAction SilentlyContinue`가 "서비스 없음" 오류를 숨김).

| 확인 | 기대값 |
|---|---|
| assistant → 22/5900 | 열림 |
| LAN/WireGuard → 3389 | RDP 로그인 가능 |
| LAN → 22/5900 | 차단 (SG) |
| (Kolla 호스트) `ssh lab-windows` | PowerShell |
| `sshd`, `tvnserver` | Running (VNC를 건너뛰었으면 `sshd`만) |
| GNS3 GUI | 원격 서버 `<GNS3_LAB_IP>:3080` 연결, 버전 일치 |

## Troubleshooting

- **user_data가 실행되지 않음**: `--config-drive true`를 빠뜨렸는지 확인하세요. 이 이미지의 Cloudbase-Init은 ConfigDrive에서만 메타데이터를 읽습니다. 로그: `C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init.log`
- **`Add-WindowsCapability OpenSSH.Server` 실패**: 인터넷(Windows Update) 접근이 필요합니다. lab-router의 외부 게이트웨이와 DNS를 확인하세요.
- **SSH 키 인증이 실패하고 비밀번호를 요구함**: `Admin`은 Administrators 그룹에 속하므로 sshd는 `C:\ProgramData\ssh\administrators_authorized_keys`를 사용합니다. 이 파일의 ACL에 Administrators·SYSTEM 외 권한이 있으면 sshd가 파일을 무시합니다. `icacls`로 권한을 재설정하세요.
- **방화벽 `-DisplayGroup 'Remote Desktop'`이 한국어 Windows에서 실패**: 표시 이름은 지역화됩니다. 스크립트처럼 `-Group '@FirewallAPI.dll,-28752'`를 쓰세요.
- **VNC 비밀번호가 다르게 동작**: VNC 인증은 비밀번호를 최대 8자까지만 사용합니다.
- **`.sha256` 비교가 항상 불일치 (Windows PowerShell 5)**: 이 자산은 `(Invoke-WebRequest ...).Content`가 문자열이 아니라 바이트 배열을 반환합니다. `-OutFile`로 저장한 뒤 `Get-Content`로 읽으세요.
- **GUI ↔ 서버 버전 불일치 오류**: GUI와 서버는 `3.1.0a6`으로 정확히 같아야 합니다. 파일 속성에 `3.1.0`으로 나오는 것은 접미사가 표시되지 않기 때문입니다.
- **Windows에서 패킷 캡처가 되지 않음**: 무인 설치(`/S`)는 Npcap을 설치하지 않습니다. Wireshark 캡처가 필요하면 RDP로 접속해 [npcap.com](https://npcap.com/)에서 Npcap을 수동으로 설치하세요. 무료판은 무인 설치를 지원하지 않습니다.
- **C: 공간 부족**: 위 4단계를 참고하세요.
- **재부팅 후 Admin 비밀번호가 바뀌어 RDP에 로그인할 수 없음**
  - 원인: Cloudbase-Init의 `SetUserPasswordPlugin`이 부팅할 때마다 임의의 비밀번호를 만들어 설정합니다. 이 값을 메타데이터에 올리려면 RSA 키가 필요한데, 이 구성은 ed25519 keypair를 쓰므로 `Invalid SSH key`로 실패합니다. 실패한 플러그인은 완료로 기록되지 않아 다음 부팅에서 다시 실행되고, 그때마다 비밀번호가 다시 바뀝니다.
  - 확인: `os console log show lab-windows | grep -E "SetUserPasswordPlugin|Password succesfully updated"`
  - 해결: SSH 키 접속은 계속 가능하므로, SSH로 접속해 비밀번호를 다시 설정하고 첫 부팅 설정이 끝난 Cloudbase-Init을 비활성화합니다.

    ```powershell
    Set-LocalUser -Name Admin -Password (Read-Host -AsSecureString)
    Set-Service cloudbase-init -StartupType Disabled
    ```

  - 예방: 첫 부팅 스크립트는 마지막 단계에서 `Set-Service cloudbase-init -StartupType Disabled`를 실행합니다. 3회 실패한 경우에도 실행합니다. `C:\lab-init.done`이 있는지만 확인하세요. 다른 방법으로는 RSA keypair로 서버를 만들고 `nova get-password`로 비밀번호를 받을 수 있습니다.
- **VM이 30분쯤 뒤 자동으로 꺼짐 (SHUTOFF)**
  - 원인: Windows 기본 전원 설정은 30분 뒤 절전(S3)입니다. 게스트가 절전에 들어가면 nova가 이를 감지하고 `Instance is suspended unexpectedly. Calling the stop API.`로 VM을 종료합니다.
    - 사용자가 보낸 stop 요청이 아니므로 `server event list`에 `user_id: null`인 `stop`이 남습니다.
    - QEMU 로그에는 `shutting down, reason=destroyed`가 남습니다.
    - Windows에는 이벤트 41/6008(예기치 않은 종료)만 남습니다.
  - 확인 (Kolla 호스트):

    ```bash
    sudo grep -h "suspended unexpectedly" /var/log/kolla/nova/nova-compute.log
    ```

  - 해결 (Windows, 관리자 PowerShell): 절전과 최대 절전을 끕니다. 첫 부팅 스크립트에 이미 들어 있으므로 직접 만든 이미지·VM일 때만 실행합니다.

    ```powershell
    powercfg /change standby-timeout-ac 0
    powercfg /change hibernate-timeout-ac 0
    powercfg /change monitor-timeout-ac 0
    powercfg /hibernate off
    ```
- **시작 메뉴에서 실수로 '절전'을 누름 → 응답 없음, 곧 꺼짐**
  - QEMU의 Windows는 절전(S3)에서 깨어나지 못하고 멈추는 경우가 많습니다. 2026-10-21 확인: `virsh domstate`가 `pmsuspended`였고, `virsh dompmwakeup`으로 `running`으로 바뀌어도 네트워크(ARP)가 응답하지 않았습니다. 이 상태로 두면 nova가 VM을 종료합니다.
  - 복구: `openstack server reboot --hard lab-windows`. 디스크는 유지되고 저장하지 않은 작업만 사라집니다. 자동 로그온 후 1분쯤 지나면 Windows-MCP까지 다시 시작됩니다.
  - 예방: 첫 부팅 스크립트가 정책으로 절전을 막습니다. 정책은 "절전 시 대기 상태(S1-S3) 허용"을 AC·DC 모두 끄고(`HKLM\SOFTWARE\Policies\Microsoft\Power\PowerSettings\abfc2519-3608-4c2a-94ea-171b0ed546ab`), 시작 메뉴의 절전 항목을 숨기고(`ShowSleepOption=0`), 절전 버튼 동작을 "없음"으로 바꿉니다. **재부팅 후** `powercfg /a`에 S3가 "현재 전원 정책에서 비활성화"로 나오면 적용된 것입니다. 적용 뒤 실제로 절전 요청(`SetSuspendState`)을 보내도 VM이 `running`을 유지하는 것을 확인했습니다.
