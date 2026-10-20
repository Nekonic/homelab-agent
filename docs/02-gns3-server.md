# 02. GNS3 server 3.1.0a6 + 내장 MCP

## 목적

`lab-gns3` VM에 GNS3 server를 설치하고, AI 비서가 붙을 수 있도록 **내장 MCP 서버**를 인증·DNS rebinding 보호와 함께 켭니다.

## 버전 선택

2026-10 기준 상황:

| 버전 | 상태 | MCP |
|---|---|---|
| 3.0.6 | PyPI 최신 안정판 | 없음 |
| 2.2.61 | 2.x 안정판 | 없음 (서드파티 `Wael-Rd/gns3-mcp-server` 필요) |
| **3.1.0a6** | 알파 | **내장 MCP (도구 76개)** |

→ **3.1.0a6으로 고정(pin)** 했습니다. 알파이므로 업그레이드는 신중히 하세요.

> **GUI 버전은 서버와 정확히 같아야 합니다.** Windows에도 GNS3 GUI 3.1.0a6을 설치합니다([03 문서](03-windows-vm.md)).

## 사전조건

- [01 문서](01-openstack-reset-and-base.md)로 `lab-gns3` 생성 완료, `/dev/kvm` 존재와 `vmx` 확인됨
- `sg-gns3`에서 3080, 5000-5100 허용
- 자리표시자
  - `<GNS3_PASSWORD>`: GNS3 관리자 비밀번호
  - `<GNS3_FIP>` / `<FLOATING_IP_GNS3>`: lab-gns3 Floating IP (예: `192.168.0.201`)
  - `<GNS3_LAB_IP>`: lab-gns3의 lab-net IP (예: `10.10.0.x`)

## 절차

템플릿을 VM으로 복사한 뒤 접속해서 진행합니다.

```bash
scp -i ~/.ssh/lab-key scripts/gns3_server.conf.example scripts/gns3server.service ubuntu@<FLOATING_IP_GNS3>:
ssh -i ~/.ssh/lab-key ubuntu@<FLOATING_IP_GNS3>
```

### 1. 패키지

```bash
sudo add-apt-repository -y ppa:gns3/ppa
echo "ubridge ubridge/install-setuid boolean true" | sudo debconf-set-selections
sudo apt update
sudo DEBIAN_FRONTEND=noninteractive apt install -y \
  qemu-kvm qemu-utils ovmf dynamips ubridge vpcs cloud-image-utils \
  python3-venv python3-dev build-essential genisoimage telnet \
  libvirt-daemon-system
```

- `libvirt-daemon-system`은 GNS3 **NAT 노드**가 쓰는 `virbr0`(libvirt default 네트워크)용입니다.

  ```bash
  sudo virsh net-autostart default && sudo virsh net-start default 2>/dev/null; ip -br a show virbr0
  ```

- 서버 본체는 PPA의 `gns3-server` 패키지가 아니라 **pip로 정확한 버전**을 설치합니다.

### 2. 사용자와 venv

```bash
id gns3 2>/dev/null || sudo useradd -m -s /bin/bash gns3
sudo usermod -aG kvm,ubridge gns3

sudo -u gns3 python3 -m venv /home/gns3/venv
sudo -u gns3 /home/gns3/venv/bin/pip install --upgrade pip
sudo -u gns3 /home/gns3/venv/bin/pip install "gns3-server[ai-features]==3.1.0a6"
```

### 3. 디렉터리

`secrets_dir`는 **미리 존재해야** 합니다.

```bash
sudo -u gns3 mkdir -p -m 700 /home/gns3/.config/GNS3/secrets
sudo -u gns3 mkdir -p /home/gns3/.config/GNS3/3.1
sudo -u gns3 mkdir -p /home/gns3/GNS3/{images,projects,appliances,symbols,configs}
```

### 4. 설정 파일

템플릿: [scripts/gns3_server.conf.example](../scripts/gns3_server.conf.example)

```ini
[Controller]
; openssl rand -hex 32
jwt_secret_key = <JWT_SECRET>
default_admin_username = admin
; 컨트롤러 DB 최초 생성 시에만 적용!
default_admin_password = <GNS3_PASSWORD>

[Server]
host = 0.0.0.0
port = 3080
secrets_dir = /home/gns3/.config/GNS3/secrets
images_path = /home/gns3/GNS3/images
projects_path = /home/gns3/GNS3/projects
appliances_path = /home/gns3/GNS3/appliances
symbols_path = /home/gns3/GNS3/symbols
configs_path = /home/gns3/GNS3/configs
report_errors = False
console_start_port_range = 5000
console_end_port_range = 5100
; 3.x 기본 False — 원격 GUI 콘솔에 필요
allow_remote_console = True
vnc_console_start_port_range = 5900
vnc_console_end_port_range = 5999
udp_start_port_range = 20000
udp_end_port_range = 30000
enable_http_auth = True
compute_username = gns3
; openssl rand -hex 16
compute_password = <COMPUTE_PASSWORD>
allowed_interfaces = ens3,virbr0
mcp_enable_dns_rebinding_protection = True
mcp_allowed_hosts = 127.0.0.1:*,localhost:*,<GNS3_FIP>:*,<GNS3_LAB_IP>:*
mcp_allowed_origins = http://127.0.0.1:*,http://localhost:*,http://<GNS3_FIP>:*,http://<GNS3_LAB_IP>:*

[Qemu]
enable_hardware_acceleration = True
require_hardware_acceleration = True
monitor_host = 127.0.0.1
ovmf_firmware_dir = /usr/share/OVMF

[WebWireshark]
; docker 필요
enabled = False
```

자리표시자를 채운 파일을 설치합니다.

```bash
umask 077
cp gns3_server.conf.example gns3_server.conf
openssl rand -hex 32   # → <JWT_SECRET>
openssl rand -hex 16   # → <COMPUTE_PASSWORD>
vi gns3_server.conf    # 자리표시자 채우기
sudo install -o gns3 -g gns3 -m 600 gns3_server.conf /home/gns3/.config/GNS3/3.1/gns3_server.conf
shred -u gns3_server.conf
```

> `allowed_interfaces`의 `ens3`는 VM의 NIC 이름입니다. `ip -br link`로 확인해 맞추세요.

### 5. systemd

유닛: [scripts/gns3server.service](../scripts/gns3server.service)

```bash
sudo install -m 644 gns3server.service /etc/systemd/system/gns3server.service
sudo systemctl daemon-reload
sudo systemctl enable --now gns3server
journalctl -u gns3server -n 50 --no-pager
```

### 6. MCP용 API 키 발급 (권장)

JWT는 만료되므로, 비서에는 **API 키**를 주는 것을 권장합니다. 키는 **발급 시 한 번만** 표시되며 형식은 `gns3_<uuid>_<secret>`, 언제든 폐기할 수 있습니다.

```bash
curl -s -X POST http://127.0.0.1:3080/v3/access/api-keys \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"lab-assistant"}' | jq
```

(`$TOKEN`은 아래 검증 2단계에서 얻습니다. 목록 조회·폐기 엔드포인트는 `http://<GNS3_LAB_IP>:3080/docs`에서 확인하세요.)

MCP 접속 정보:

| 항목 | 값 |
|---|---|
| 전송 | SSE |
| URL | `http://<GNS3_LAB_IP>:3080/v3/mcp/transport/sse` |
| 인증 헤더 | `Authorization: Bearer <JWT 또는 API 키>` |

### 7. (선택) Rocky Linux 템플릿

이번 구성에서는 생략했습니다. 필요하면 [Rocky GenericCloud 이미지](https://dl.rockylinux.org/pub/rocky/9/images/x86_64/)(qcow2)를 `images/QEMU`에 넣고, `cloud-localds`(cloud-image-utils)로 만든 cloud-init seed ISO를 QEMU 템플릿의 CD-ROM으로 붙여 계정/SSH 키를 주입하는 방식이 간단합니다.

```bash
cloud-localds seed.iso user-data.yaml meta-data.yaml
```

## 검증

```bash
G=http://127.0.0.1:3080

# 1) 버전
curl -s $G/v3/version          # {"version":"3.1.0a6",...}

# 2) 로그인 → JWT (비밀번호가 history에 남지 않게 read 사용)
read -rs GNS3_PASSWORD
TOKEN=$(jq -n --arg p "$GNS3_PASSWORD" '{username:"admin",password:$p}' \
  | curl -s -X POST $G/v3/access/users/authenticate -H 'Content-Type: application/json' -d @- \
  | jq -r .access_token)
echo ${TOKEN:0:16}...

# 3) 기본 비밀번호는 거부되어야 함 → 401
curl -s -o /dev/null -w '%{http_code}\n' -X POST $G/v3/access/users/authenticate \
  -H 'Content-Type: application/json' -d '{"username":"admin","password":"admin"}'

# 4) MCP 엔드포인트 → "GNS3 MCP Server"
curl -s -H "Authorization: Bearer $TOKEN" $G/v3/mcp/

# 5) SSE 인증 없이 → 401
curl -s -o /dev/null -w '%{http_code}\n' -m 3 $G/v3/mcp/transport/sse

# 6) 허용되지 않은 Host → 421 (DNS rebinding 보호 동작)
curl -s -o /dev/null -w '%{http_code}\n' -m 3 -H "Authorization: Bearer $TOKEN" \
  -H 'Host: evil.com:3080' $G/v3/mcp/transport/sse

# 7) 로컬 compute
curl -s -H "Authorization: Bearer $TOKEN" $G/v3/computes          # [] 이 정상
curl -s -H "Authorization: Bearer $TOKEN" $G/v3/computes/local | jq .connected   # true
```

| 확인 | 기대값 |
|---|---|
| `/v3/version` | `3.1.0a6` |
| admin/`<GNS3_PASSWORD>` 로그인 | `access_token` 발급 |
| admin/admin | `401` |
| `GET /v3/mcp/` (Bearer) | `GNS3 MCP Server` |
| SSE 무인증 | `401` |
| SSE + `Host: evil.com:3080` | `421` |
| `/v3/computes/local` | `connected: true` |

lab-assistant VM에서도 `curl -s http://<GNS3_LAB_IP>:3080/v3/version`이 응답해야 합니다.

## 트러블슈팅 (gotchas)

- **`ModuleNotFoundError: No module named 'langchain'`**: `fastmcp`만 따로 설치하면 부족합니다. MCP 모듈이 langchain을 import하므로 **`gns3-server[ai-features]` extra로 설치**해야 합니다.
- **`Path does not point to a directory` (설정 검증 실패)**: `secrets_dir`가 없어서입니다. 3단계의 `mkdir`를 먼저 하세요.
- **`default_admin_password`가 안 먹음**: 이 값은 **컨트롤러 DB가 처음 만들어질 때만** 적용됩니다. 설정 전에 서버를 한 번 띄웠다면 기본값(admin/admin)으로 DB가 생성된 상태이니, GUI/API로 비밀번호를 바꾸거나 새 DB로 다시 시작하세요.
- **원격 GUI에서 장비 콘솔이 안 열림**: 3.x는 `allow_remote_console` 기본값이 `False`입니다.
- **정상 MCP 클라이언트도 421**: 클라이언트가 쓰는 `호스트:포트`가 `mcp_allowed_hosts`에 없을 때입니다. Floating IP와 lab-net IP를 모두 넣으세요.
- **`GET /v3/computes`가 `[]`**: 로컬 compute는 목록에 안 나옵니다. `/v3/computes/local`로 확인하세요.
- **QEMU 노드가 시작 안 됨 (`require_hardware_acceleration`)**: `gns3` 사용자가 `kvm` 그룹인지, `/dev/kvm`이 있는지 확인. 그룹 변경 후에는 서비스 재시작 필요.
- **WebWireshark**: docker가 필요해서 비활성화했습니다. 패킷 캡처는 Windows GUI 쪽 Wireshark로 합니다.
