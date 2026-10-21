# 03. Windows 11 실습 VM

## 목적

- `lab-windows`가 첫 부팅 때 자동으로 **RDP / OpenSSH Server / TightVNC**를 켜도록 구성
- AI 비서(`lab-assistant`)가 SSH(PowerShell)와 VNC(화면)로 Windows를 조작할 수 있게 함
- GNS3 GUI **3.1.0a6**(서버와 동일 버전)을 설치하고 원격 GNS3 서버에 연결

> 이 VM은 다 만든 뒤 **평소 꺼 둡니다**. 자동 로그온, RDP 창 닫기 처리, Windows-MCP, 전원 제어(`ssh winpower start|stop|status`), 봇용 `ssh win` 별칭은 [05 문서](05-mcp.md#3-windows-mcp-lab-windows)에서 설정합니다.

## 사전조건

- [01 문서](01-openstack-reset-and-base.md)의 Windows 11 이미지(`win11`), `sg-windows`, flavor `lab.windows16`
- [02 문서](02-gns3-server.md)의 GNS3 server 동작
- 자리표시자: `<WIN_ADMIN_PASSWORD>`, `<VNC_PASSWORD>`(8자 이하), `<SSH_PUBLIC_KEY>`, `<ASSISTANT_LAB_IP>`, `<TIGHTVNC_MSI_SHA256>`, `<WIN_LAB_IP>`, `<FLOATING_IP_WINDOWS>`, `<ASSISTANT_FIP>`, `<GNS3_LAB_IP>`, `<GNS3_PASSWORD>`
- 이 문서의 `os`는 [00 문서](00-host-check.md)의 admin 헬퍼(Kolla 호스트에서 `kolla_toolbox` 안의 `openstack`을 admin openrc로 부르는 셸 함수)입니다.

## 절차

### 1. 이미지 내부 확인 (libguestfs)

이미지에 무엇이 들어 있는지 알아야 user_data를 맞게 쓸 수 있습니다. Kolla 호스트에서:

```bash
sudo apt install -y libguestfs-tools
virt-filesystems --long --parts --filesystems -a ~/images/<WIN11_QCOW2>.qcow2
```

`guestfish -i`(자동 OS 인식)는 실패했으므로, Windows 파티션(예시: `/dev/sda3`)을 직접 마운트합니다.

```bash
guestfish --ro -a ~/images/<WIN11_QCOW2>.qcow2
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
| Cloudbase-Init | 있음. `username=Admin`, `inject_user_password=true`, metadata = **ConfigDrive** | `--config-drive true` 필수, 계정명은 `Admin` |
| Virtio-Win | 있음 | virtio 디스크/NIC 사용 가능 |
| QEMU guest agent | 있음 | `hw_qemu_guest_agent=yes` |
| OpenSSH | **클라이언트만** (sshd 없음) | user_data에서 Server 설치 필요 |
| VNC 서버 | 없음 | user_data에서 TightVNC 설치 |

### 2. 첫 부팅 스크립트

스크립트: [scripts/windows-userdata.ps1](../scripts/windows-userdata.ps1) (`#ps1_sysnative` → Cloudbase-Init이 64-bit PowerShell로 실행)

하는 일:

1. `Admin` 비밀번호 설정
2. RDP 활성화 + 방화벽 그룹 허용
3. `Add-WindowsCapability OpenSSH.Server`, sshd 자동 시작, 기본 셸 PowerShell
4. `administrators_authorized_keys`에 공개키 등록 + `icacls`로 권한 정리, 방화벽 22
5. TightVNC 2.8.90 MSI를 받아 **SHA256 검증 후** 무인 설치 (`ADDLOCAL=Server`, VNC 인증, `VALUE_OF_PASSWORD`(최대 8자), `ALLOWLOOPBACK`). 해시가 비어 있거나 다르면 설치하지 않습니다. 방화벽 5900은 `-RemoteAddress <ASSISTANT_LAB_IP>`로 비서 VM만
6. 절전 끄기
7. `sshd`·`tvnserver`가 **둘 다 Running일 때만** 완료 표시 `C:\lab-init.done`을 쓰고 Cloudbase-Init을 끕니다. 아니면 `exit 1002`로 끝나 다음 부팅에 스크립트가 다시 돕니다. 전체 로그 `C:\lab-init.log`

`<TIGHTVNC_MSI_SHA256>` 얻는 법: 신뢰할 수 있는 PC에서 스크립트의 `$vncUrl` 파일을 받아 `shasum -a 256 <파일>`(macOS/Linux) 또는 `Get-FileHash <파일> -Algorithm SHA256`(Windows)으로 계산합니다. 가능하면 tightvnc.com 다운로드 페이지의 표기와 대조하세요.

저장소 밖에 복사해서 자리표시자를 채운 뒤, [01 문서 D 단계](01-openstack-reset-and-base.md#d-서버-생성)대로 `--config-drive true --user-data /tmp/lab/windows.ps1`로 서버를 만듭니다.

```bash
mkdir -p -m 700 ~/lab
cp scripts/windows-userdata.ps1 ~/lab/windows.ps1
vi ~/lab/windows.ps1     # <WIN_ADMIN_PASSWORD>, <VNC_PASSWORD>, <SSH_PUBLIC_KEY>, <ASSISTANT_LAB_IP>, <TIGHTVNC_MSI_SHA256>
```

`<SSH_PUBLIC_KEY>`에는 lab-assistant에서 쓸 키의 공개키(예: `~/.ssh/lab-key.pub` 내용)를 넣습니다.

첫 부팅은 Windows 기능 설치 때문에 수 분 이상 걸립니다. 진행 상황:

```bash
os console log show lab-windows | tail
```

### 3. 보안 그룹 정책 정리

| 포트 | 출발지 | 이유 |
|---|---|---|
| 22 (SSH) | `sg-assistant`만 | 비서 전용 제어 채널 |
| 5900 (VNC) | `sg-assistant`만 | VNC는 암호화가 약함 → LAN에도 열지 않음 |
| 3389 (RDP) | LAN + WireGuard 대역 | 사람이 직접 화면 사용 ([01 문서](01-openstack-reset-and-base.md#b-5-보안-그룹)의 WG 규칙) |
| 8000 (Windows-MCP) | `sg-assistant`만 | [05 문서](05-mcp.md)에서 추가 |

### 4. 램·디스크 늘리기 (리사이즈)와 C: 드라이브 확장

[01 문서](01-openstack-reset-and-base.md#b-3-flavor)대로 처음부터 `lab.windows16`(16GB/150GB)으로 만들었다면 리사이즈는 건너뛰고 아래 **C: 확장**만 하면 됩니다.

**리사이즈.** (예전 `lab.windows` 8GB/80GB로 만든 VM일 때) 단일 노드에서는 nova에 `allow_resize_to_same_host = true`가 있어야 합니다. 이 구성에는 이미 있었습니다(`grep allow_resize /etc/kolla/nova-api/nova.conf`). VM이 꺼진 상태에서 진행합니다.

```bash
os flavor show lab.windows16 >/dev/null 2>&1 || os flavor create lab.windows16 --vcpus 4 --ram 16384 --disk 150
os server resize --flavor lab.windows16 --wait lab-windows
os server resize confirm lab-windows      # VERIFY_RESIZE → 확정
```

2026-10-21: 8GB/80GB → 16GB/150GB. 리사이즈는 같은 호스트 안에서 디스크를 복사하므로 몇 분 걸립니다. 꺼진 VM도 플레이버만큼 메모리를 예약(placement)하므로 호스트 여유를 먼저 확인하세요(`os hypervisor stats show`).

**C: 확장.** 디스크를 늘려도(처음부터 150GB로 만들어도) C:는 자동으로 커지지 않습니다. 80GB일 때도 C: 여유가 **약 44GB**뿐이었습니다. 복구(Recovery) 파티션이 C: **뒤에** 있어서 Cloudbase-Init의 ExtendVolumes 플러그인이 C:를 늘리지 못하기 때문입니다. 필요하면 관리자 PowerShell에서:

```powershell
Get-Partition -DiskNumber 0                     # Recovery 파티션 번호 확인
reagentc /disable                               # WinRE를 C:\Windows\System32\Recovery로 이동
# diskpart: select disk 0 → select partition <N> → delete partition override
$max = (Get-PartitionSupportedSize -DriveLetter C).SizeMax
Resize-Partition -DriveLetter C -Size $max
reagentc /enable
```

> 파티션 삭제는 되돌릴 수 없습니다. 스냅숏(`os server image create`)을 먼저 떠두세요.

PowerShell만으로도 됩니다. `Remove-Partition -DiskNumber 0 -PartitionNumber <N> -Confirm:$false`를 쓰면 diskpart 없이 지울 수 있습니다.

결과 (2026-10-21): C: 149.8GB(여유 122.5GB). WinRE는 C: 안의 이미지로 다시 **Enabled**입니다.

SSH로 실행할 때 출력이 한글(CP949)로 나와 깨지면, 스크립트 첫 줄에 `[Console]::OutputEncoding = [Text.Encoding]::UTF8`을 넣으세요.

### 5. GNS3 GUI 3.1.0a6 설치

GitHub `gns3-gui` 릴리스 `v3.1.0a6`의 all-in-one 설치 파일을 받아 `.sha256` 자산과 대조한 뒤 무인 설치합니다. SSH(PowerShell)나 RDP에서 실행:

```powershell
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

예시 환경 결과:

- SHA256 일치, `/S` 무인 설치가 프롬프트 없이 몇 분 만에 종료 코드 `0`
- `gns3.exe`의 ProductVersion은 `3.1.0` — 파일 버전에는 `a6` 접미사가 붙지 않으므로 **정상**
- 번들 Wireshark도 함께 설치됨
- **Npcap은 설치되지 않음** (무인 모드에서 건너뜀) → 아래 트러블슈팅 참고

### 6. GUI를 원격 GNS3 서버에 연결 (수동)

RDP로 `<FLOATING_IP_WINDOWS>`에 `Admin`으로 접속한 뒤 GNS3 GUI에서:

1. **Edit → Preferences → Server**(버전에 따라 Controller)에서 로컬 서버 사용 해제
2. 원격 서버: `http://<GNS3_LAB_IP>:3080`
3. 인증: `admin` / `<GNS3_PASSWORD>`
4. 저장 후 GUI 재시작, 상태 표시줄에 서버 연결 확인

> Windows와 GNS3는 같은 lab-net에 있으므로 Floating IP가 아니라 **lab-net IP**를 씁니다.

## 검증

lab-assistant VM에서:

```bash
nc -zv <WIN_LAB_IP> 22      # succeeded
nc -zv <WIN_LAB_IP> 5900    # succeeded
```

LAN(또는 WireGuard)의 PC에서:

```bash
# RDP: <FLOATING_IP_WINDOWS>:3389 로 접속
# SSH는 비서 VM을 점프 호스트로
ssh -J ubuntu@<ASSISTANT_FIP> Admin@<WIN_LAB_IP>
```

접속하면 PowerShell 프롬프트가 떠야 합니다. 그 안에서:

```powershell
Get-Service sshd, tvnserver | Format-Table Name, Status, StartType   # 둘 다 Running
Get-Content C:\lab-init.done
Get-Content C:\lab-init.log -Tail 30
```

| 확인 | 기대값 |
|---|---|
| assistant → 22/5900 | 열림 |
| LAN/WireGuard → 3389 | RDP 로그인 가능 |
| LAN → 22/5900 | **차단** (SG) |
| `ssh -J ... Admin@<WIN_LAB_IP>` | PowerShell |
| `sshd`, `tvnserver` | Running |
| GNS3 GUI | 원격 서버 `<GNS3_LAB_IP>:3080` 연결, 버전 일치 |

## 트러블슈팅 (gotchas)

- **user_data가 실행 안 됨**: `--config-drive true`를 빠뜨렸는지 확인하세요. 이 이미지의 Cloudbase-Init은 ConfigDrive에서만 메타데이터를 읽습니다. 로그: `C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init.log`
- **`Add-WindowsCapability OpenSSH.Server` 실패**: 인터넷(Windows Update) 접근이 필요합니다. lab-router의 외부 게이트웨이와 DNS를 확인하세요.
- **SSH 키 인증이 안 되고 비밀번호를 물음**: `Admin`은 Administrators 그룹이라 `C:\ProgramData\ssh\administrators_authorized_keys`를 씁니다. 이 파일 ACL에 Administrators·SYSTEM 외 권한이 있으면 sshd가 무시합니다(`icacls`로 재설정).
- **방화벽 `-DisplayGroup 'Remote Desktop'`이 한국어 Windows에서 실패**: 표시 이름은 지역화됩니다. 스크립트처럼 `-Group '@FirewallAPI.dll,-28752'`를 쓰세요.
- **VNC 비밀번호가 다르게 동작**: VNC 인증은 **최대 8자**만 사용합니다.
- **`.sha256` 비교가 항상 불일치 (Windows PowerShell 5)**: `(Invoke-WebRequest ...).Content`가 이 자산에 대해 문자열이 아니라 **바이트 배열**을 돌려줍니다. `-OutFile`로 저장한 뒤 `Get-Content`로 읽으세요.
- **GUI ↔ 서버 버전 불일치 오류**: GUI와 서버는 `3.1.0a6`으로 정확히 같아야 합니다. 파일 속성의 `3.1.0`은 접미사가 빠진 것뿐입니다.
- **Windows에서 패킷 캡처가 안 됨**: 무인 설치(`/S`)는 **Npcap을 설치하지 않습니다.** Wireshark 캡처가 필요하면 RDP로 접속해 [npcap.com](https://npcap.com/)에서 Npcap을 수동 설치하세요(무료판은 무인 설치 미지원).
- **C: 공간 부족**: 위 4단계 참고.
- **재부팅 후 Admin 비밀번호가 바뀌어 RDP 로그인이 안 됨**
  - 원인: Cloudbase-Init의 `SetUserPasswordPlugin`이 부팅할 때마다 임의의 비밀번호를 만들어 설정합니다. 이 값을 메타데이터로 올리려면 RSA 키가 필요한데 ed25519 키페어라서 `Invalid SSH key`로 실패합니다. 실패한 플러그인은 완료로 기록되지 않아 **다음 부팅에서 다시 실행**되고, 그때마다 비밀번호가 다시 바뀝니다.
  - 확인: `os console log show lab-windows | grep -E "SetUserPasswordPlugin|Password succesfully updated"`
  - 해결: SSH 키 접속은 계속 되므로, 비밀번호를 다시 설정하고 첫 부팅 설정이 끝난 Cloudbase-Init을 끕니다.

    ```powershell
    Set-LocalUser -Name Admin -Password (Read-Host -AsSecureString)
    Set-Service cloudbase-init -StartupType Disabled
    ```

  - 예방: 첫 부팅 스크립트 마지막에 위의 `Set-Service ... Disabled`를 넣거나, RSA 키페어로 서버를 만들고 `nova get-password`로 비밀번호를 받습니다.
- **VM이 30분쯤 뒤 저절로 꺼짐 (SHUTOFF)**
  - 원인: Windows 기본 전원 설정이 **30분 뒤 절전(S3)**입니다. 게스트가 절전에 들어가면 nova가 이를 감지하고 `Instance is suspended unexpectedly. Calling the stop API.`로 VM을 꺼 버립니다.
    - stop 요청에는 사용자가 없어서 `server event list`에 `user_id: null`인 `stop`이 남습니다.
    - QEMU 로그에는 `shutting down, reason=destroyed`가 남습니다.
    - Windows에는 이벤트 41/6008(예기치 않은 종료)만 남습니다.
  - 확인 (Kolla 호스트):

    ```bash
    sudo grep -h "suspended unexpectedly" /var/log/kolla/nova/nova-compute.log
    ```

  - 해결 (Windows, 관리자 PowerShell): 절전과 최대 절전을 끕니다. 첫 부팅 스크립트에도 넣어 두었습니다.

    ```powershell
    powercfg /change standby-timeout-ac 0
    powercfg /change hibernate-timeout-ac 0
    powercfg /change monitor-timeout-ac 0
    powercfg /hibernate off
    ```
