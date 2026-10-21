# 02. GNS3 server 3.1.0a6 + 내장 MCP

## 목적

`lab-gns3` VM에 GNS3 server를 설치하고, AI 에이전트가 접속할 수 있도록 내장 MCP 서버를 활성화합니다. MCP 서버에는 인증과 DNS rebinding 보호를 적용합니다.

## 버전 선택

2026-10 기준 상황:

| 버전 | 상태 | MCP |
|---|---|---|
| 3.0.6 | PyPI 최신 안정판 | 없음 |
| 2.2.61 | 2.x 안정판 | 없음 (서드파티 `Wael-Rd/gns3-mcp-server` 필요) |
| 3.1.0a6 | 알파 | 내장 MCP (도구 76개) |

이 구성은 3.1.0a6으로 고정(pin)했습니다. 알파 버전이므로 업그레이드할 때 주의하세요.

> **GUI 버전은 서버와 정확히 같아야 합니다.** Windows에도 GNS3 GUI 3.1.0a6을 설치합니다([03 문서](03-windows-vm.md)).

## 사전 요구사항

- [01 문서](01-openstack-reset-and-base.md)로 `lab-gns3` 생성 완료, `/dev/kvm` 존재와 `vmx` 확인됨
- `sg-gns3`에서 3080, 5000-5100(콘솔), 5900-5999(VNC 콘솔) 허용 ([01 B-5](01-openstack-reset-and-base.md#b-5-보안-그룹))
- Kolla 호스트 `~/.ssh/config`의 `lab-gns3` 별칭 ([01 D-5](01-openstack-reset-and-base.md#d-5-kolla-호스트-ssh-별칭-설정))
- Kolla 호스트에 repo(`$REPO`)와 `~/lab-secrets.env`(`GNS3_PASSWORD`, `GNS3_JWT_SECRET`, `GNS3_COMPUTE_PASSWORD`), [README](../README.md#secret-관리)의 `sec` 함수
- Placeholder
  - `<GNS3_PASSWORD>`: GNS3 관리자 비밀번호
  - `<GNS3_JWT_SECRET>`, `<GNS3_COMPUTE_PASSWORD>`: 컨트롤러 JWT 서명 키, compute 비밀번호 (lab-secrets.env의 같은 이름 키)
  - `<GNS3_FIP>`: lab-gns3 Floating IP (예: `192.168.0.201`)
  - `<GNS3_LAB_IP>`: lab-gns3의 lab-net IP (예: `10.10.0.x`, `os server show lab-gns3 -c addresses`)

## 절차

1~3단계와 5단계는 lab-gns3에서 진행하고, 4단계의 설정 파일 생성은 secret이 있는 Kolla 호스트에서 진행합니다. lab-gns3에는 repo를 clone하지 않고 Kolla 호스트에서 필요한 파일만 복사합니다.

```bash
# (Kolla 호스트) systemd 유닛을 복사하고 lab-gns3에 접속
scp "$REPO/scripts/gns3server.service" lab-gns3:
ssh lab-gns3
```

### 1. 패키지 설치

```bash
# (lab-gns3)
sudo add-apt-repository -y ppa:gns3/ppa
echo "ubridge ubridge/install-setuid boolean true" | sudo debconf-set-selections
sudo apt update
sudo DEBIAN_FRONTEND=noninteractive apt install -y \
  qemu-kvm qemu-utils ovmf dynamips ubridge vpcs cloud-image-utils \
  python3-venv python3-dev build-essential genisoimage telnet \
  libvirt-daemon-system
```

- `libvirt-daemon-system`은 GNS3 NAT 노드가 쓰는 `virbr0`(libvirt default 네트워크)용입니다.

  ```bash
  sudo virsh net-autostart default && sudo virsh net-start default 2>/dev/null; ip -br a show virbr0
  ```

- GNS3 server는 PPA의 `gns3-server` 패키지 대신 pip로 버전을 고정해 설치합니다.

### 2. 서비스 계정과 venv 생성

```bash
# (lab-gns3)
id gns3 2>/dev/null || sudo useradd -m -s /bin/bash gns3
sudo usermod -aG kvm,ubridge gns3

sudo -u gns3 python3 -m venv /home/gns3/venv
sudo -u gns3 /home/gns3/venv/bin/pip install --upgrade pip
sudo -u gns3 /home/gns3/venv/bin/pip install "gns3-server[ai-features]==3.1.0a6"
```

### 3. 디렉터리 생성

`secrets_dir`는 **미리 존재해야** 합니다.

```bash
# (lab-gns3)
sudo -u gns3 mkdir -p -m 700 /home/gns3/.config/GNS3/secrets
sudo -u gns3 mkdir -p /home/gns3/.config/GNS3/3.1
sudo -u gns3 mkdir -p /home/gns3/GNS3/{images,projects,appliances,symbols,configs}
```

### 4. 설정 파일 작성

템플릿 [scripts/gns3_server.conf.example](../scripts/gns3_server.conf.example)을 수정 없이 사용합니다. 각 값과 설정 이유는 파일 주석에 있습니다. 채워야 하는 값은 placeholder 5개이며, 아래 스크립트가 채웁니다.

| 키 | Placeholder | 값 |
|---|---|---|
| `[Controller] jwt_secret_key` | `<GNS3_JWT_SECRET>` | `openssl rand -hex 32` (lab-secrets.env) |
| `[Controller] default_admin_password` | `<GNS3_PASSWORD>` | 관리자 비밀번호. **컨트롤러 DB가 처음 만들어질 때만** 적용 |
| `[Server] compute_password` | `<GNS3_COMPUTE_PASSWORD>` | `openssl rand -hex 16` (lab-secrets.env) |
| `[Server] mcp_allowed_hosts`, `mcp_allowed_origins` | `<GNS3_FIP>`, `<GNS3_LAB_IP>` | MCP 클라이언트가 접속하는 주소(Floating IP와 lab-net IP) |

환경에 따라 확인할 키:

- `allowed_interfaces = ens3,virbr0`: VM의 NIC 이름(`ip -br link`)과 libvirt NAT 브리지
- `console_*_port_range`(5000-5100), `vnc_console_*_port_range`(5900-5999): `sg-gns3`에서 연 범위와 같아야 원격 GUI에서 콘솔이 열립니다
- `allow_remote_console = True`: 3.x 기본값은 `False`
- `[WebWireshark] enabled = False`: Docker가 필요하므로 비활성화

Placeholder를 채운 파일을 Kolla 호스트에서 만들고 lab-gns3로 복사한 뒤 설치합니다. secret은 화면에 출력되지 않습니다.

```bash
# (Kolla 호스트) README의 sec 함수가 정의된 셸에서
GNS3_LAB_IP=$(os server show lab-gns3 -f json -c addresses \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["addresses"]["lab-net"][0])')
mkdir -p -m 700 ~/lab
GNS3_PASSWORD=$(sec GNS3_PASSWORD) GNS3_JWT_SECRET=$(sec GNS3_JWT_SECRET) \
GNS3_COMPUTE_PASSWORD=$(sec GNS3_COMPUTE_PASSWORD) GNS3_FIP='<GNS3_FIP>' GNS3_LAB_IP=$GNS3_LAB_IP \
python3 - "$REPO/scripts/gns3_server.conf.example" ~/lab/gns3_server.conf <<'PY'
import os, sys
s = open(sys.argv[1], encoding="utf-8").read()
for k in ("GNS3_PASSWORD", "GNS3_JWT_SECRET", "GNS3_COMPUTE_PASSWORD", "GNS3_FIP", "GNS3_LAB_IP"):
    if not os.environ.get(k) or os.environ[k].startswith("<"):
        sys.exit(k + " 값이 없습니다")
    s = s.replace("<" + k + ">", os.environ[k])
os.umask(0o077)
open(sys.argv[2], "w", encoding="utf-8").write(s)
PY
scp ~/lab/gns3_server.conf lab-gns3: && shred -u ~/lab/gns3_server.conf
```

```bash
# (lab-gns3)
sudo install -o gns3 -g gns3 -m 600 gns3_server.conf /home/gns3/.config/GNS3/3.1/gns3_server.conf
shred -u gns3_server.conf
```

### 5. systemd 서비스 등록

유닛: [scripts/gns3server.service](../scripts/gns3server.service)

```bash
# (lab-gns3)
sudo install -m 644 gns3server.service /etc/systemd/system/gns3server.service
sudo systemctl daemon-reload
sudo systemctl enable --now gns3server
journalctl -u gns3server -n 50 --no-pager
```

### 6. MCP 접속 정보

JWT는 만료되므로 에이전트에는 API 키를 발급합니다. 키는 **발급 시 한 번만** 표시되며 형식은 `gns3_<uuid>_<secret>`입니다. 키는 언제든 폐기(revoke)할 수 있습니다. 클라이언트마다 키를 따로 만들어 두면 문제가 생겼을 때 해당 키만 폐기하면 됩니다.

| 키 이름 | 쓰는 곳 | 만드는 곳 |
|---|---|---|
| `hermes` | Hermes ops 봇 | [05 문서 2단계](05-mcp.md#2-gns3-mcp) |
| `claude-code` | Claude Code | [06 문서 3단계](06-claude-code.md#3-gns3-mcp-연결-claude-code-전용-api-키) |

키 목록 조회·폐기 endpoint는 `http://<GNS3_LAB_IP>:3080/docs`에서 확인하세요.

MCP 접속 정보:

| 항목 | 값 |
|---|---|
| 전송 | SSE |
| URL | `http://<GNS3_LAB_IP>:3080/v3/mcp/transport/sse` |
| 인증 헤더 | `Authorization: Bearer <JWT 또는 API 키>` |

### 7. (선택) Rocky Linux 템플릿

이번 구성에서는 생략했습니다. 필요하면 [Rocky GenericCloud 이미지](https://dl.rockylinux.org/pub/rocky/9/images/x86_64/)(qcow2)를 `images/QEMU`에 넣습니다. 계정과 SSH 키는 `cloud-localds`(cloud-image-utils)로 만든 cloud-init seed ISO를 QEMU 템플릿의 CD-ROM으로 연결해 주입하는 방식이 간단합니다.

```bash
cloud-localds seed.iso user-data.yaml meta-data.yaml
```

## 검증

```bash
# (lab-gns3)
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

# 4) MCP endpoint → "GNS3 MCP Server"
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

## Troubleshooting

- **`ModuleNotFoundError: No module named 'langchain'`**: `fastmcp`만 설치해서는 동작하지 않습니다. MCP 모듈이 langchain을 import하므로 `gns3-server[ai-features]` extra로 설치해야 합니다.
- **`Path does not point to a directory` (설정 검증 실패)**: `secrets_dir`가 없을 때 발생합니다. 3단계의 `mkdir`를 먼저 실행하세요.
- **`default_admin_password`가 적용되지 않음**: 이 값은 컨트롤러 DB가 처음 만들어질 때만 적용됩니다. 설정 파일을 넣기 전에 서버를 한 번 실행했다면 기본값(admin/admin)으로 DB가 이미 생성된 상태입니다. GUI나 API로 비밀번호를 바꾸거나 새 DB로 다시 시작하세요.
- **원격 GUI에서 장비 콘솔이 안 열림**: 3.x는 `allow_remote_console` 기본값이 `False`입니다.
- **정상 MCP 클라이언트도 421**: 클라이언트가 쓰는 `호스트:포트`가 `mcp_allowed_hosts`에 없을 때입니다. Floating IP와 lab-net IP를 모두 넣으세요.
- **`GET /v3/computes`가 `[]`**: 로컬 compute는 목록에 안 나옵니다. `/v3/computes/local`로 확인하세요.
- **QEMU 노드가 시작되지 않음 (`require_hardware_acceleration`)**: `gns3` 사용자가 `kvm` 그룹에 속하는지, `/dev/kvm`이 있는지 확인하세요. 그룹을 변경한 뒤에는 서비스를 재시작해야 합니다.
- **WebWireshark**: Docker가 필요하므로 비활성화했습니다. 패킷 캡처는 Windows GUI 쪽 Wireshark로 합니다.
