# 05. MCP 서버 연결 (GNS3 · Windows-MCP · mcp-vnc · netmiko) + websocat

## 목적

`lab-assistant`의 Hermes **ops 프로필**(= 기본 프로필)에 MCP 서버 4개를 붙입니다.

| 이름 | 서버 | 전송 | 역할 | 노출/제외 |
|---|---|---|---|---|
| `gns3` | GNS3 server 3.1.0a6 내장 MCP | SSE `:3080` + API 키 | 토폴로지·노드·콘솔 부트스트랩 | 76개 중 **65개 노출 / 11개 제외** |
| `windows` | [Windows-MCP](https://github.com/CursorTouch/Windows-MCP) 0.8.8 | streamable-http `:8000` + Bearer | Windows 데스크톱 주 조작 수단 | 전부(로그온 후 확인 필요, 아래 참고) |
| `vnc` | [@hrrrsn/mcp-vnc](https://github.com/hrrrsn/mcp-vnc) 1.0.2 | stdio → VNC `:5900` | 로그인/UAC 화면용 폴백 | 6개 |
| `netmiko` | [netmiko-mcp](https://github.com/ktbyers/netmiko_mcp) 0.2.0 | stdio | 장비 show 명령(기본 거부 allowlist) | 7개 |

장비 설정 방침: **콘솔(GNS3 `device_config_send`/websocat)은 초기 부트스트랩에만**, 이후 조회는 netmiko(allowlist)로.

## 사전조건

- [04 문서](04-hermes-agent.md) 완료
- 자리표시자: `<GNS3_LAB_IP>`(예: 10.10.0.x), `<WIN_LAB_IP>`, `<ASSISTANT_LAB_IP>`, `<ASSISTANT_FIP>`, `<GNS3_FIP>`, `<KOLLA_HOST>`
- 비밀값 보관 규칙
  - lab-assistant: `~/.hermes/.env` (600) — `GNS3_API_KEY`, `WINDOWS_MCP_AUTH_KEY`, `VNC_PASSWORD`
  - Kolla 호스트: `~/lab-secrets.env` (600) — `GNS3_HERMES_API_KEY`, `WINDOWS_MCP_AUTH_KEY` 추가
  - Windows: `C:\Users\Admin\.windows-mcp\config.toml` (ACL 제한)
  - **저장소에는 절대 넣지 않음** (예시 파일은 전부 자리표시자)

## 절차

### 1. 공통 도구 (lab-assistant)

```bash
sudo apt-get install -y python3-venv python3-pip git jq xz-utils

# Node.js LTS (24.x) — 공식 tarball + SHA256 검증
V=v24.22.0; D=$(mktemp -d); cd $D
curl -fsSLO https://nodejs.org/dist/$V/node-$V-linux-x64.tar.xz
curl -fsSLO https://nodejs.org/dist/$V/SHASUMS256.txt
grep " node-$V-linux-x64.tar.xz\$" SHASUMS256.txt | sha256sum -c -
sudo mkdir -p /usr/local/lib/nodejs && sudo tar -xJf node-$V-linux-x64.tar.xz -C /usr/local/lib/nodejs
for b in node npm npx; do sudo ln -sf /usr/local/lib/nodejs/node-$V-linux-x64/bin/$b /usr/local/bin/$b; done
cd / && rm -rf $D && node --version

# websocat (GNS3 콘솔 웹소켓용). 릴리스에 체크섬이 없으므로 받은 해시를 기록해 둠
curl -fsSL -o /tmp/websocat https://github.com/vi/websocat/releases/download/v1.14.1/websocat.x86_64-unknown-linux-musl
sha256sum /tmp/websocat   # 이 환경: 66f8dd3a0394761556339117f8bb5123bddefd44e087af2a72ec22b0bd08d514
sudo install -m 755 /tmp/websocat /usr/local/bin/websocat && rm /tmp/websocat
websocat --version        # websocat 1.14.1
```

`node_console` 도구가 짧은 토큰이 들어간 `websocat` 명령을 돌려주므로, ops의 terminal(수동 승인)로 콘솔에 붙을 수 있습니다.

### 2. GNS3 MCP

API 키 발급(한 번만 보임). lab-gns3에서 관리자 계정으로 로그인 후 생성합니다.

```bash
# lab-gns3에서 (비밀번호는 read로 입력)
read -rs GNS3_PASSWORD
TOKEN=$(jq -n --arg p "$GNS3_PASSWORD" '{username:"admin",password:$p}' \
  | curl -s -X POST http://127.0.0.1:3080/v3/access/users/authenticate -H 'Content-Type: application/json' -d @- | jq -r .access_token)
curl -s -X POST http://127.0.0.1:3080/v3/access/api-keys -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{"name":"hermes"}' | jq -r .api_key > ~/.gns3_hermes_key && chmod 600 ~/.gns3_hermes_key
# → lab-assistant ~/.hermes/.env 의 GNS3_API_KEY= 와 Kolla ~/lab-secrets.env 의 GNS3_HERMES_API_KEY= 에 옮긴 뒤 파일 삭제
```

> 비밀 파일에 `>>`로 덧붙일 때 **마지막 줄에 개행이 없으면 앞 줄에 붙어 버립니다.** `tail -c1 file | od -c`로 확인하거나 `printf '\n'`을 먼저 넣으세요.

Hermes 설정(ops `config.yaml`):

```yaml
mcp_servers:
  gns3:
    url: http://<GNS3_LAB_IP>:3080/v3/mcp/transport/sse
    transport: sse
    headers: {Authorization: "Bearer ${GNS3_API_KEY}"}
    trust: untrusted
    tools:
      exclude: ['*_delete', image_prune, snapshot_restore, node_file_write]
      resources: false
      prompts: false
```

제외한 11개: `project_delete, node_delete, link_delete, template_delete, node_file_delete, snapshot_delete, drawing_delete, image_delete`(모든 `*_delete`), `image_prune`(이미지 일괄 삭제), `snapshot_restore`(현재 프로젝트 상태 덮어씀), `node_file_write`(기존 파일 덮어씀). `project_close`는 유지했습니다.

### 3. Windows-MCP (lab-windows)

README 기준 요구사항: **Python 3.14+**, `uv`. `windows-mcp install`은 사용자별 예약 작업 `windows-mcp-server`(트리거 **AtLogOn**, LogonType **Interactive**, RunLevel Limited)를 만듭니다. 즉 **사용자가 데스크톱에 로그온해 있어야** 서버가 뜹니다(0.8.8은 시작 시 "interactive desktop"이 없으면 종료하며, `--no-control` 옵션도 없음).

lab-assistant를 점프 호스트로 Windows에 SSH(기본 셸 PowerShell):

```powershell
# 1) uv (공식 설치 스크립트, 실행 정책은 이 프로세스에만 Bypass)
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://astral.sh/uv/install.ps1 | iex"
$env:Path = "$env:USERPROFILE\.local\bin;$env:Path"
# 2) Python 3.14 + windows-mcp 고정 설치
uv python install 3.14
uv tool install --python 3.14 "windows-mcp==0.8.8"
```

인증 키 생성 → 3곳에 저장(값은 출력하지 않음):

```bash
# lab-assistant
printf 'WINDOWS_MCP_AUTH_KEY=%s\n' "$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))')" >> ~/.hermes/.env
# Kolla 호스트 ~/lab-secrets.env 에도 같은 값을 WINDOWS_MCP_AUTH_KEY= 로 추가 (ssh 파이프로 전달)
```

설정·예약 작업·방화벽: [scripts/hermes/windows-mcp-setup.ps1](../scripts/hermes/windows-mcp-setup.ps1) (`-WinIp`, `-AssistantIp` 인자, 키는 stdin)

```bash
# lab-assistant에서 스크립트 복사 후, 키를 stdin으로 넘겨 실행
scp scripts/hermes/windows-mcp-setup.ps1 Admin@<WIN_LAB_IP>:
grep '^WINDOWS_MCP_AUTH_KEY=' ~/.hermes/.env | cut -d= -f2- | ssh Admin@<WIN_LAB_IP> \
  '$input | powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\Admin\windows-mcp-setup.ps1 -WinIp <WIN_LAB_IP> -AssistantIp <ASSISTANT_LAB_IP>'
```

스크립트가 하는 일:

1. `~/.windows-mcp/config.toml`: `transport=streamable-http`, `host=<WIN_LAB_IP>`(lab IP에만 바인드), `port=8000`, `auth_key`, `ip_allowlist=["<ASSISTANT_LAB_IP>/32"]` — 예시: [windows-mcp.config.example.toml](../scripts/hermes/windows-mcp.config.example.toml)
2. `windows-mcp install --transport streamable-http --host <WIN_LAB_IP> --port 8000 --force`
3. `start-server.cmd`에 `PYTHONUTF8=1`(한국어 cp949 콘솔 오류 방지), `ANONYMIZED_TELEMETRY=false` 추가
4. 방화벽 규칙 `windows-mcp-8000`: TCP 8000, 원격 주소 lab-assistant만

OpenStack 보안 그룹(Kolla 호스트):

```bash
source /tmp/osenv.sh
A=$(os security group show sg-assistant -f value -c id)
os security group rule create sg-windows --ingress --ethertype IPv4 --protocol tcp --dst-port 8000 \
  --remote-group "$A" --description "Windows-MCP (streamable-http) from lab-assistant"
```

Hermes 설정:

```yaml
  windows:
    url: http://<WIN_LAB_IP>:8000/mcp
    headers: {Authorization: "Bearer ${WINDOWS_MCP_AUTH_KEY}"}
    trust: untrusted
    timeout: 180
    tools: {resources: false, prompts: false}
```

#### 자동 로그온 (켜면 Windows-MCP가 저절로 뜨게)

Windows-MCP는 데스크톱 세션이 있어야 동작합니다. 예약 작업은 Admin이 로그온할 때 실행되므로, 아무도 로그온하지 않으면 8000 포트가 열리지 않습니다. 이때 `hermes mcp test windows`는 30초 타임아웃으로 실패하고, 서버 로그에는 `No active interactive desktop`이 남습니다.

스크립트: [scripts/windows-autologon.ps1](../scripts/windows-autologon.ps1). MS 문서의 기본 방식인 Winlogon 레지스트리 `DefaultPassword`를 씁니다.

| 방식 | 재부팅 (`shutdown /r`) | 전원 끄고 켜기 (`nova stop/start`) |
|---|---|---|
| LSA 비밀 (Sysinternals Autologon 방식) | 됨. 실제로는 Windows 11의 ARSO(재시작 후 자동 로그인) 덕분으로 보임 | **안 됨.** `AutoAdminLogon`이 0으로 되돌아가기도 함 |
| 레지스트리 `DefaultPassword` | 됨 | **됨 (39초)** |

2026-10-21, Windows 11 build 26200에서 확인했습니다.

스크립트가 하는 일:
- 저장하기 전에 비밀번호가 맞는지 검사합니다. 틀린 값으로 저장하면 부팅이 로그온 실패 화면에 멈춥니다.
- `DevicePasswordLessBuildVersion=0`으로 Windows Hello 전용 로그인 요구를 끕니다.
- 화면 보호기 잠금을 끕니다.

**트레이드오프**: 비밀번호가 HKLM Winlogon 키에 평문으로 남습니다. 사용자가 Admin 하나뿐이고 보안 그룹으로 접근이 막힌 실습용 VM이라 감수합니다.

실행 (Kolla 호스트의 비밀값 파일에서 비밀번호를 파이프로 넘깁니다):

```bash
scp -o ProxyJump=ubuntu@<ASSISTANT_FIP> scripts/windows-autologon.ps1 Admin@<WIN_LAB_IP>:C:/Windows/Temp/
```

```bash
ssh master@<KOLLA_HOST> 'grep ^WIN_ADMIN_PASSWORD= ~/lab-secrets.env | cut -d= -f2-' | ssh -J ubuntu@<ASSISTANT_FIP> Admin@<WIN_LAB_IP> 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\windows-autologon.ps1 -User Admin; Remove-Item C:\Windows\Temp\windows-autologon.ps1'
```

#### RDP 창을 그냥 닫아도 되게

RDP로 접속하면 데스크톱 세션이 RDP로 넘어갑니다. 창을 닫으면 세션이 "연결 끊김"이 되어 데스크톱이 없어지고, Windows-MCP가 멈춥니다.

스크립트 [scripts/windows-rdp-autoconsole.ps1](../scripts/windows-rdp-autoconsole.ps1)는 두 가지를 해서 이 문제를 없앱니다.

1. 예약 작업 `rdp-disconnect-to-console`을 만듭니다. RDP 연결이 끊기는 순간(이벤트 24, `TerminalServices-LocalSessionManager/Operational`) SYSTEM 권한으로 `tscon <세션ID> /dest:console`을 실행해 세션을 콘솔로 돌려보냅니다. 사용자는 **RDP 창을 그냥 닫으면 됩니다.**
2. Windows-MCP 시작 스크립트를 "끝나면 15초 뒤 다시 시작" 루프로 감쌉니다. 세션이 잠깐 끊긴 순간 시작돼 바로 죽어도 저절로 살아납니다.

#### 평소에는 꺼 두기 (전원 제어 전용 명령)

윈도우 VM은 평소 꺼 두고, 봇이 필요할 때 켜고 끕니다. 봇에게 OpenStack 관리자 권한을 주지 않으려고 **Kolla 호스트에 켜기·끄기·상태만 하는 명령**을 두고, 비서 VM에는 그 명령만 실행되는 SSH 키를 줍니다.

- 명령: [scripts/lab-windows-power](../scripts/lab-windows-power) → Kolla 호스트 `/usr/local/bin/lab-windows-power` (root 소유, 755). `start | stop | status`만 받고 그 밖의 입력은 거부합니다.
- 비서 VM 전용 키 `~/.ssh/kolla_power`를 Kolla 호스트 `~/.ssh/authorized_keys`에 강제 명령으로 등록합니다.

  ```
  command="/usr/local/bin/lab-windows-power",from="<ASSISTANT_FIP>",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA... lab-windows-power@lab-assistant
  ```

  비서 VM이 외부로 나갈 때는 Floating IP로 SNAT되므로 `from=`에는 Floating IP를 씁니다.
- 비서 VM `~/.ssh/config`에 `Host winpower`(Kolla 호스트, `IdentityFile ~/.ssh/kolla_power`)를 둡니다. 사용법은 `ssh winpower status|start|stop`입니다.
- 검증 (2026-10-21):
  - 다른 명령(`ssh winpower "cat /etc/kolla/passwords.yml"`)은 `usage`로 거부됩니다.
  - 셸 접속은 `PTY allocation request failed`로 막힙니다.
  - `stop`은 87초 걸리고 Windows 이벤트에 정상 종료(1074 → 109 → 13)가 남습니다.
  - `start` 후 `ssh win`은 약 30초, Windows-MCP 8000 포트는 39초 뒤 열립니다.
- Hermes는 끊긴 MCP 서버를 5분마다 다시 연결합니다(`_PARKED_RETRY_INTERVAL = 300`). 켠 직후에는 `ssh win`을 먼저 쓰고, GUI 도구는 몇 분 뒤에 씁니다. 바로 쓰려면 Discord에서 `/reload-mcp`를 보냅니다.
- 봇 규칙(SOUL.md, CLAUDE.md):
  - 작업 전에 `status`를 보고 꺼져 있으면 `start`합니다.
  - 작업이 끝나면 `query user`로 RDP 세션을 확인해 없으면 `stop`, 있으면 끌지 묻습니다.

#### Windows-MCP 도구 21개와 승인

`trust: untrusted`로 등록하면 읽기 전용이 아닌 호출(`readOnlyHint`가 정확히 true가 아닌 것)은 **실행 전에 매번 승인**을 받습니다(Hermes `tools/mcp_tool.py`의 trust-tier gating).

주의: Windows-MCP 도구의 인자는 `approvals.deny` 패턴 검사를 거치지 않습니다. deny 패턴은 Hermes 자체 터미널 명령에만 적용됩니다.

그래서 **명령 실행은 SSH로만** 하도록 바꿨습니다.

| 구분 | 경로 | 거치는 검사 |
|---|---|---|
| 명령 실행 | 터미널에서 `ssh win "<PowerShell>"` | `approvals.deny` 패턴 + 위험 명령 승인 |
| 화면 확인·클릭·입력 | Windows-MCP (19개, `PowerShell`·`Registry` 제외) | 쓰기 호출마다 승인 (`trust: untrusted`) |
| 로그온·UAC 화면 | `vnc` | 쓰기 호출마다 승인 |

1. 비서 VM에 전용 키를 만듭니다. 에이전트가 무인으로 써야 하므로 암호 없음.

   ```bash
   ssh-keygen -t ed25519 -N "" -C "hermes-ops@lab-assistant" -f ~/.ssh/win_ops
   ```

2. 윈도우의 `C:\ProgramData\ssh\administrators_authorized_keys`에 공개키를 **`from="<ASSISTANT_LAB_IP>"` 조건을 붙여** 추가하고 ACL을 다시 잡습니다. 이 키는 비서 VM 주소에서만 통합니다.

   ```powershell
   Add-Content C:\ProgramData\ssh\administrators_authorized_keys 'from="<ASSISTANT_LAB_IP>" ssh-ed25519 AAAA... hermes-ops@lab-assistant' -Encoding ascii
   icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"
   ```

3. 비서 VM `~/.ssh/config`에 별칭을 둡니다. 그다음 `ssh-keyscan -t ed25519 <WIN_LAB_IP> >> ~/.ssh/known_hosts`로 호스트 키를 등록합니다.

   ```
   Host win
     HostName <WIN_LAB_IP>
     User Admin
     IdentityFile ~/.ssh/win_ops
     IdentitiesOnly yes
   ```

4. `config.yaml`의 `windows` 서버에 `tools.exclude: [PowerShell, Registry]`를 넣습니다. `hermes mcp list`에 `-2 excluded`로 보이면 적용된 것입니다. `hermes mcp test windows`는 서버의 원래 목록(21개)을 보여 주므로 확인용이 아닙니다.

#### 봇이 규칙을 알게 하기 (SOUL.md)

도구를 빼는 것만으로도 강제는 되지만, 봇이 어떤 경로를 써야 하는지 알아야 헤매지 않습니다.

- Hermes가 **모든 세션에서 항상 읽는 파일은 `~/.hermes/SOUL.md`뿐**입니다. `AGENTS.md`는 작업 디렉터리 기준이라 Discord 세션에서는 보장되지 않습니다.
- `SOUL.md` 끝에 운영 규칙을 붙였습니다: [scripts/hermes/SOUL.ops.rules.example.md](../scripts/hermes/SOUL.ops.rules.example.md).
- reader 프로필의 SOUL.md에는 넣지 않습니다. reader에게 내부망 구조를 알려줄 이유가 없습니다.
- 수정한 뒤 `systemctl --user restart hermes-gateway`로 재시작합니다.

검증 (2026-10-21): "윈도우 VM 호스트 이름과 버전 알려줘"라고 물으면 봇이 `ssh win`으로 `hostname`과 `Get-ComputerInfo`를 실행해 답합니다.

`Get-ComputerInfo`의 `WindowsProductName`은 Windows 11에서도 "Windows 10 Pro"로 나옵니다. 빌드 번호(26200 이상)로 판단하세요.

### 4. mcp-vnc 폴백 (lab-assistant)

```bash
sudo npm i -g --no-fund --no-audit @hrrrsn/mcp-vnc@1.0.2
sudo ln -sf /usr/local/lib/nodejs/node-v24.22.0-linux-x64/bin/mcp-vnc /usr/local/bin/mcp-vnc
# ~/.hermes/.env 에 VNC_PASSWORD= (Kolla lab-secrets.env 의 값)
```

README의 환경변수: `VNC_HOST`, `VNC_PORT`(기본 5900), `VNC_PASSWORD`.

```yaml
  vnc:
    command: /usr/local/bin/mcp-vnc
    env: {VNC_HOST: "<WIN_LAB_IP>", VNC_PORT: "5900", VNC_PASSWORD: "${VNC_PASSWORD}"}
    trust: untrusted
    tools: {resources: false, prompts: false}
```

Hermes는 stdio MCP 자식에게 `PATH/HOME` 등 안전 변수와 `env:`에 적은 것만 넘깁니다(다른 키는 전달 안 됨).

### 5. netmiko-mcp (lab-assistant)

자체 venv에 설치합니다. **PyPI 0.2.0은 `mcp` 2.x와 호환되지 않으므로 `mcp<2`로 고정**합니다.

```bash
python3 -m venv ~/.venvs/netmiko-mcp
~/.venvs/netmiko-mcp/bin/pip install "netmiko-mcp==0.2.0" "mcp>=1.27.1,<2"
mkdir -p -m 700 ~/.config/netmiko-mcp
cp scripts/hermes/netmiko-mcp.example.yml       ~/.config/netmiko-mcp/netmiko-mcp.yml
cp scripts/hermes/netmiko-commands.example.yml  ~/.config/netmiko-mcp/commands.yml
cp scripts/hermes/netmiko-inventory.example.yml ~/.config/netmiko-mcp/inventory.yml   # 지금은 장비 없음
chmod 600 ~/.config/netmiko-mcp/*
```

- `commands.yml`: **기본 거부**. `show …`/`display …` 조회 명령만 개별 glob으로 허용, `show running-config`/`startup`/`tech`, `configure*`, `reload*`, `erase*`, `clear*`, `debug*` 등은 deny가 우선. 파이프는 `include/exclude/section/begin/count`만.
- netmiko-mcp 0.2.0에는 **설정 모드 도구가 없습니다**(`send_show_command*`, 목록/출력 조회, ping뿐). 그래서 "명시적 설정 명령"은 allowlist에 주석 예시로만 두었고, 설정 변경은 콘솔 부트스트랩 또는 사람이 합니다.
- 장비를 추가할 때는 비밀번호를 `netmiko-encrypt`로 암호화하고 `NETMIKO_TOOLS_KEY`를 Hermes `env:`에 `${NETMIKO_TOOLS_KEY}`로 넘기세요. 장비 쪽 AAA(읽기 전용 계정)도 권장(README).

```yaml
  netmiko:
    command: /home/ubuntu/.venvs/netmiko-mcp/bin/netmiko-mcp
    env: {NETMIKO_MCP_CONFIG: /home/ubuntu/.config/netmiko-mcp/netmiko-mcp.yml}
    trust: untrusted
    timeout: 300
    tools: {resources: false, prompts: false}
```

감사 로그: `~/.netmiko_mcp_audit.log`(600).

## 검증

```bash
# Hermes 자체 테스트
hermes mcp list
hermes mcp test gns3      # ✓ Connected, Tools discovered: 76 (등록 시 11개 제외 → 65)
hermes mcp test vnc       # ✓ 6
hermes mcp test netmiko   # ✓ 7
hermes mcp test windows   # 사용자 로그온 상태에서만 ✓

# 독립 클라이언트 (임시 venv, 키는 env에서 읽고 출력 안 함)
python3 -m venv /tmp/mcpcli && /tmp/mcpcli/bin/pip install -q mcp
set -a; . <(grep -E '^(GNS3_API_KEY|WINDOWS_MCP_AUTH_KEY)=' ~/.hermes/.env); set +a
/tmp/mcpcli/bin/python scripts/hermes/mcp_list.py sse  http://<GNS3_LAB_IP>:3080/v3/mcp/transport/sse GNS3_API_KEY
/tmp/mcpcli/bin/python scripts/hermes/mcp_list.py http http://<WIN_LAB_IP>:8000/mcp WINDOWS_MCP_AUTH_KEY
NETMIKO_MCP_CONFIG=~/.config/netmiko-mcp/netmiko-mcp.yml \
  /tmp/mcpcli/bin/python scripts/hermes/mcp_list.py stdio ~/.venvs/netmiko-mcp/bin/netmiko-mcp
rm -rf /tmp/mcpcli

# 네트워크 경로: 8000은 비서에서만 열려야 함
nc -vz -w3 <WIN_LAB_IP> 8000          # lab-assistant: 서버가 떠 있으면 성공
nc -vz -w3 <FLOATING_IP_WINDOWS> 8000 # LAN/Kolla 호스트: 타임아웃이어야 함
```

이 환경의 결과(2026-10-21):

| 항목 | 결과 |
|---|---|
| GNS3 MCP | 연결 ✓, 76개 발견, 패턴 4개로 11개 제외 → 65개 |
| mcp-vnc | 6개 ✓, `vnc_screenshot` 1280x800 캡처 성공(VNC 인증 정상) |
| netmiko-mcp | 7개 ✓ (`list_groups, list_devices, send_show_command, send_show_command_to_group, list_device_outputs, read_device_output, ping`) |
| Windows-MCP | 설치·config·예약 작업(Ready)·방화벽·SG 완료. 임시 리스너로 8000 경로 확인(비서 ✓ / LAN ✗). **도구 목록은 미확인** — 로그온한 사용자가 없어 서버가 "No active interactive desktop"으로 종료 |

## 트러블슈팅 (gotchas)

- **Windows-MCP가 안 뜸 / `hermes mcp test windows` 타임아웃**: 로그온 세션이 없으면 정상입니다. `query user`로 확인하고 RDP로 로그온하세요. 로그: `C:\Users\Admin\.windows-mcp\server.error.log`.
- **`UnicodeEncodeError: 'cp949'`**: 한국어 Windows에서 `windows-mcp --help`/`install` 출력 시 발생. `$env:PYTHONUTF8="1"` 후 실행. `install`이 트레이스백을 내도 작업은 등록됩니다.
- **`windows-mcp install --force`를 다시 하면** `start-server.cmd`가 재생성되어 `PYTHONUTF8`/텔레메트리 줄이 사라집니다. 설정 스크립트를 다시 실행하세요.
- **README와 0.8.8 차이**: README의 `--no-control`, `[control] enabled=false`는 0.8.8에 없습니다.
- **원격 PowerShell에 stdin 넘기기**: 기본 셸이 PowerShell이면 `ssh … '$input | powershell -File …'`처럼 `$input`으로 파이프해야 합니다. 여러 줄 here-string은 `-Command -`(stdin 스크립트)에서 깨지므로 `.ps1` 파일로 복사해 `-File`로 실행하세요.
- **netmiko-mcp `No module named 'mcp.server.fastmcp'`**: `mcp` 2.x가 깔린 것. `pip install "mcp<2"`.
- **GNS3 MCP 421**: `mcp_allowed_hosts`에 `<GNS3_LAB_IP>:*`가 있어야 합니다([02 문서](02-gns3-server.md)).
- **`trust: untrusted`라 조회도 승인 요청**: 서버들이 `readOnlyHint`를 주지 않아서입니다. 불편하면 서버별로 `trust: full`로 낮추되, 그러면 GNS3 제외 목록과 netmiko allowlist만 남는다는 점을 감안하세요.
- **OpenStack SG 표시**: `rule list`에서 remote-group 규칙도 IP Range가 `0.0.0.0/0`으로 보이지만 실제로는 `Remote Security Group`(sg-assistant)으로 제한됩니다.
