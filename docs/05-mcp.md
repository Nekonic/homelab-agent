# 05. MCP 서버 연결 (GNS3 · Windows-MCP · mcp-vnc · netmiko) + websocat

## 목적

`lab-assistant`의 Hermes **ops 프로필**(= 기본 프로필)에 MCP 서버 4개를 붙입니다.

| 이름 | 서버 | 전송 | 역할 | 노출/제외 |
|---|---|---|---|---|
| `gns3` | GNS3 server 3.1.0a6 내장 MCP | SSE `:3080` + API 키 | 토폴로지·노드·콘솔 부트스트랩 | 76개 중 **65개 노출 / 11개 제외** |
| `windows` | [Windows-MCP](https://github.com/CursorTouch/Windows-MCP) 0.8.8 | streamable-http `:8000` + Bearer | Windows 화면 확인·클릭·입력 (명령 실행은 `ssh win`) | 21개 중 **19개 노출 / `PowerShell`·`Registry` 제외** |
| `vnc` | [@hrrrsn/mcp-vnc](https://github.com/hrrrsn/mcp-vnc) 1.0.2 | stdio → VNC `:5900` | 로그인/UAC 화면용 폴백 | 6개 |
| `netmiko` | [netmiko-mcp](https://github.com/ktbyers/netmiko_mcp) 0.2.0 | stdio | 장비 show 명령(기본 거부 allowlist) | 7개 |

장비 설정 방침: **콘솔(GNS3 `device_config_send`/websocat)은 초기 부트스트랩에만**, 이후 조회는 netmiko(allowlist)로.

## 사전조건

- [04 문서](04-hermes-agent.md) 완료. 비서 VM에 레포(`$REPO`)와 `setenv` 함수, Kolla 호스트에 레포·`~/lab-secrets.env`·`sec`/`setenv` 함수([README](../README.md#비밀값-관리))
- Kolla 호스트 `~/.ssh/config`에 [01 문서 D-5](01-openstack-reset-and-base.md#d-5-kolla-호스트-ssh-별칭)의 별칭 `lab-assistant`, `lab-windows`, `lab-gns3`이 있을 것(`lab-key` 사용)
- **Hermes `mcp_servers` 블록은 이 문서에서만 넣습니다.** 아래 각 절의 YAML은 [scripts/hermes/config.ops.example.yaml](../scripts/hermes/config.ops.example.yaml)(전체 최종본)의 해당 서버 블록과 **글자 그대로 같습니다**(timeout·connect_timeout 포함). `hermes config edit`로 `~/.hermes/config.yaml`의 `mcp_servers:` 아래에 서버마다 붙이고, 자리표시자(`<GNS3_LAB_IP>`, `<WIN_LAB_IP>`)를 실제 lab-net IP로 바꿉니다(확인: Kolla 호스트에서 `os server show <VM> -c addresses`). `${...}`는 `.env`에서 읽는 값이므로 그대로 둡니다.
- 자리표시자: `<GNS3_LAB_IP>`(예: 10.10.0.x), `<WIN_LAB_IP>`, `<ASSISTANT_LAB_IP>`, `<ASSISTANT_FIP>`, `<GNS3_FIP>`, `<WIN_FIP>`, `<KOLLA_HOST>`, `<KOLLA_USER>`(Kolla 호스트의 sudo 사용자)
- Kolla 호스트에서 쓰는 `os`는 [00 문서](00-host-check.md)의 admin 헬퍼입니다(`kolla_toolbox` 안의 `openstack`을 admin openrc로 실행).
- 명령마다 실행하는 머신을 `# (비서 VM)`, `# (Kolla 호스트)`, `# (lab-gns3)`, `# (Windows, PowerShell)`로 표시했습니다.
- 비밀값 보관 규칙
  - 비서 VM: `~/.hermes/.env` (600) — `GNS3_API_KEY`, `WINDOWS_MCP_AUTH_KEY`, `VNC_PASSWORD`
  - Kolla 호스트: `~/lab-secrets.env` (600) — `GNS3_HERMES_API_KEY`, `WINDOWS_MCP_AUTH_KEY` 추가
  - Windows: `C:\Users\Admin\.windows-mcp\config.toml` (ACL 제한)
  - env 파일에는 `>>`로 붙이지 않고 `setenv`로 **있으면 바꾸고 없으면 추가**합니다(04에서 빈 값으로 넣어 둔 키를 채움). 값은 파이프로만 옮기고 화면에 출력하지 않습니다.
  - **저장소에는 절대 넣지 않음** (예시 파일은 전부 자리표시자)

## 절차

### 1. 공통 도구 (비서 VM)

```bash
# (비서 VM)
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

API 키 `hermes`를 만듭니다(키는 발급 때 한 번만 보임). Claude Code용 키는 [06 문서](06-claude-code.md#3-gns3-mcp-연결-claude-code-전용-api-키)에서 따로 만듭니다.

```bash
# (lab-gns3) 관리자 로그인 → API 키 생성 (비밀번호는 read로 입력)
read -rs GNS3_PASSWORD
TOKEN=$(jq -n --arg p "$GNS3_PASSWORD" '{username:"admin",password:$p}' \
  | curl -s -X POST http://127.0.0.1:3080/v3/access/users/authenticate -H 'Content-Type: application/json' -d @- | jq -r .access_token)
(umask 077; curl -s -X POST http://127.0.0.1:3080/v3/access/api-keys -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{"name":"hermes"}' | jq -r .api_key > ~/.gns3_hermes_key)
unset GNS3_PASSWORD TOKEN
```

키를 Kolla 호스트 `~/lab-secrets.env`(`GNS3_HERMES_API_KEY`)와 비서 VM `~/.hermes/.env`(`GNS3_API_KEY`)에 옮기고 원본 파일을 지웁니다.

```bash
# (Kolla 호스트)
ssh lab-gns3 cat .gns3_hermes_key | setenv GNS3_HERMES_API_KEY - ~/lab-secrets.env
sec GNS3_HERMES_API_KEY | ssh lab-assistant "$(declare -f setenv); setenv GNS3_API_KEY -"
ssh lab-gns3 shred -u .gns3_hermes_key
```

Hermes 설정(ops `config.yaml`). 템플릿에 `mcp_servers:` 줄이 없으면 그 줄도 넣고, `<GNS3_LAB_IP>`를 채웁니다:

```yaml
mcp_servers:
  gns3:
    url: http://<GNS3_LAB_IP>:3080/v3/mcp/transport/sse
    transport: sse
    headers:
      Authorization: Bearer ${GNS3_API_KEY}
    trust: untrusted              # every non-readOnly tool call needs approval
    timeout: 120
    connect_timeout: 30
    tools:
      exclude: ['*_delete', image_prune, snapshot_restore, node_file_write]
      resources: false
      prompts: false
```

제외한 11개: `project_delete, node_delete, link_delete, template_delete, node_file_delete, snapshot_delete, drawing_delete, image_delete`(모든 `*_delete`), `image_prune`(이미지 일괄 삭제), `snapshot_restore`(현재 프로젝트 상태 덮어씀), `node_file_write`(기존 파일 덮어씀). `project_close`는 유지했습니다.

### 3. Windows-MCP (lab-windows)

README 기준 요구사항: **Python 3.14+**, `uv`. `windows-mcp install`은 사용자별 예약 작업 `windows-mcp-server`(트리거 **AtLogOn**, LogonType **Interactive**, RunLevel Limited)를 만듭니다. 즉 **사용자가 데스크톱에 로그온해 있어야** 서버가 뜹니다(0.8.8은 시작 시 "interactive desktop"이 없으면 종료하며, `--no-control` 옵션도 없음).

이 절은 lab-windows가 켜져 있어야 합니다. 꺼져 있으면 Kolla 호스트에서 `os server start lab-windows`(전원 전용 명령 `ssh winpower`는 아래에서 만듭니다).

#### 3-0. 비서 VM에서 Windows로 SSH 경로 만들기

처음 Windows는 Kolla 호스트의 `lab-key`만 신뢰합니다([01 문서 D-2](01-openstack-reset-and-base.md#d-2-windows-user_data-채우기)). 봇이 쓸 전용 키를 비서 VM에 만들고, Kolla 호스트에서(비서 VM을 점프 호스트로) Windows에 등록합니다. 이 단계가 끝나야 비서 VM의 `ssh win`/`scp ... win:`이 동작하며, 이 문서의 나머지 Windows 명령은 모두 그 뒤에 합니다.

1. 전용 키를 만듭니다. 에이전트가 무인으로 써야 하므로 암호 없음.

   ```bash
   # (비서 VM)
   ssh-keygen -t ed25519 -N "" -C "hermes-ops@lab-assistant" -f ~/.ssh/win_ops
   ```

2. 공개키를 `C:\ProgramData\ssh\administrators_authorized_keys`에 **`from="<ASSISTANT_LAB_IP>"` 조건을 붙여** 추가하고 ACL을 다시 잡습니다. 이 키는 비서 VM 주소에서만 통합니다.

   ```bash
   # (Kolla 호스트) 01 문서 D-5의 lab-assistant / lab-windows 별칭 사용
   PUB=$(ssh lab-assistant cat .ssh/win_ops.pub)
   printf 'from="%s" %s\n' "<ASSISTANT_LAB_IP>" "$PUB" | ssh lab-windows \
     "\$input | Add-Content -Path C:\ProgramData\ssh\administrators_authorized_keys -Encoding ascii; icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F'"
   ssh lab-windows 'Get-Content C:\ProgramData\ssh\administrators_authorized_keys'   # lab-key 줄 + from="..." 줄
   ```

   `icacls`는 이름 대신 SID(Administrators `S-1-5-32-544`, SYSTEM `S-1-5-18`)를 씁니다. 한국어 Windows에서도 그대로 동작합니다.

3. 비서 VM `~/.ssh/config`에 별칭을 두고 호스트 키를 등록합니다.

   ```
   # (비서 VM) ~/.ssh/config
   Host win
     HostName <WIN_LAB_IP>
     User Admin
     IdentityFile ~/.ssh/win_ops
     IdentitiesOnly yes
     ConnectTimeout 10
   ```

   ```bash
   # (비서 VM)
   ssh-keyscan -t ed25519 <WIN_LAB_IP> >> ~/.ssh/known_hosts
   ssh win hostname           # Windows 호스트 이름이 나오면 됨
   ```

#### 3-1. uv와 windows-mcp 설치

```bash
# (비서 VM)
ssh win
```

```powershell
# (Windows, PowerShell — 비서 VM에서 ssh win 으로 접속한 상태)
# 1) uv (공식 설치 스크립트, 실행 정책은 이 프로세스에만 Bypass)
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://astral.sh/uv/install.ps1 | iex"
$env:Path = "$env:USERPROFILE\.local\bin;$env:Path"
# 2) Python 3.14 + windows-mcp 고정 설치
uv python install 3.14
uv tool install --python 3.14 "windows-mcp==0.8.8"
exit
```

#### 3-2. 인증 키, 설정 스크립트, 방화벽

인증 키를 만들어 비서 VM `.env`에 넣고, 같은 값을 Kolla 호스트 `~/lab-secrets.env`에도 둡니다(값은 출력하지 않음).

```bash
# (비서 VM)
setenv WINDOWS_MCP_AUTH_KEY "$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))')"
grep -c '^WINDOWS_MCP_AUTH_KEY=' ~/.hermes/.env      # 1 이어야 함
```

```bash
# (Kolla 호스트)
ssh lab-assistant "grep -m1 '^WINDOWS_MCP_AUTH_KEY=' ~/.hermes/.env | cut -d= -f2-" \
  | setenv WINDOWS_MCP_AUTH_KEY - ~/lab-secrets.env
```

설정·예약 작업·방화벽: [scripts/hermes/windows-mcp-setup.ps1](../scripts/hermes/windows-mcp-setup.ps1) (`-WinIp`, `-AssistantIp` 인자, 키는 stdin 첫 줄 하나만 읽음)

```bash
# (비서 VM) 스크립트를 Windows 홈(C:\Users\Admin)에 복사한 뒤, 키 한 줄을 stdin으로 넘겨 실행
scp "$REPO/scripts/hermes/windows-mcp-setup.ps1" win:
grep -m1 '^WINDOWS_MCP_AUTH_KEY=' ~/.hermes/.env | cut -d= -f2- | ssh win \
  'powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\Admin\windows-mcp-setup.ps1 -WinIp <WIN_LAB_IP> -AssistantIp <ASSISTANT_LAB_IP>'
```

스크립트가 하는 일:

1. `~/.windows-mcp/config.toml`: `transport=streamable-http`, `host=<WIN_LAB_IP>`(lab IP에만 바인드), `port=8000`, `auth_key`, `ip_allowlist=["<ASSISTANT_LAB_IP>/32"]` — 예시: [windows-mcp.config.example.toml](../scripts/hermes/windows-mcp.config.example.toml). ACL은 사용자·SYSTEM·Administrators만(SID로 지정)
2. 옛 `start-server.cmd`를 지운 뒤 `windows-mcp install --transport streamable-http --host <WIN_LAB_IP> --port 8000 --force`. 출력은 변수에 다 받은 뒤 앞 12줄만 보여 주고, 설치가 `start-server.cmd`를 새로 만들지 않았으면 오류로 멈춥니다. `icacls`가 실패해도 멈춥니다
3. `start-server.cmd`에 `PYTHONUTF8=1`(한국어 cp949 콘솔 오류 방지), `ANONYMIZED_TELEMETRY=false` 추가
4. 방화벽 규칙 `windows-mcp-8000`: TCP 8000, 원격 주소 lab-assistant만

OpenStack 보안 그룹:

```bash
# (Kolla 호스트) os 헬퍼가 정의된 셸에서
A=$(os security group show sg-assistant -f value -c id)
os security group rule create sg-windows --ingress --ethertype IPv4 --protocol tcp --dst-port 8000 \
  --remote-group "$A" --description "Windows-MCP (streamable-http) from lab-assistant"
```

Hermes 설정 (`mcp_servers:` 아래에 추가, `<WIN_LAB_IP>`를 채움):

```yaml
  windows:
    url: http://<WIN_LAB_IP>:8000/mcp   # Windows-MCP streamable-http
    headers:
      Authorization: Bearer ${WINDOWS_MCP_AUTH_KEY}
    trust: untrusted
    timeout: 180
    connect_timeout: 30
    tools:
      exclude: [PowerShell, Registry]   # commands go through `ssh win` so approvals.deny applies
      resources: false
      prompts: false
```

명령 실행은 `ssh win`으로 하므로 `PowerShell`·`Registry`는 뺍니다(아래 [도구 21개와 승인](#windows-mcp-도구-21개와-승인)).

#### 자동 로그온 (켜면 Windows-MCP가 저절로 뜨게)

Windows-MCP는 데스크톱 세션이 있어야 동작합니다. 예약 작업은 Admin이 로그온할 때 실행되므로, 아무도 로그온하지 않으면 8000 포트가 열리지 않습니다. 이때 `hermes mcp test windows`는 30초 타임아웃으로 실패하고, 서버 로그에는 `No active interactive desktop`이 남습니다.

스크립트: [scripts/windows-autologon.ps1](../scripts/windows-autologon.ps1). MS 문서의 기본 방식인 Winlogon 레지스트리 `DefaultPassword`를 씁니다.

| 방식 | 재부팅 (`shutdown /r`) | 전원 끄고 켜기 (`nova stop/start`) |
|---|---|---|
| LSA 비밀 (Sysinternals Autologon 방식) | 됨. 실제로는 Windows 11의 ARSO(재시작 후 자동 로그인) 덕분으로 보임 | **안 됨.** `AutoAdminLogon`이 0으로 되돌아가기도 함 |
| 레지스트리 `DefaultPassword` | 됨 | **됨 (39초)** |

(Windows 11 build 26200, 2026-10-21 확인)

스크립트가 하는 일:
- 저장하기 전에 비밀번호가 맞는지 검사합니다. 틀린 값으로 저장하면 부팅이 로그온 실패 화면에 멈춥니다.
- `DevicePasswordLessBuildVersion=0`으로 Windows Hello 전용 로그인 요구를 끕니다.
- 화면 보호기 잠금을 끕니다.

**트레이드오프**: 비밀번호가 HKLM Winlogon 키에 평문으로 남습니다. 사용자가 Admin 하나뿐이고 보안 그룹으로 접근이 막힌 실습용 VM이라 감수합니다.

실행: 비밀번호가 있는 **Kolla 호스트**에서, `lab-windows` 별칭(비서 VM 경유)으로 복사하고 비밀번호는 파이프로 넘깁니다.

```bash
# (Kolla 호스트)
scp "$REPO/scripts/windows-autologon.ps1" lab-windows:C:/Windows/Temp/
sec WIN_ADMIN_PASSWORD | ssh lab-windows 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\windows-autologon.ps1 -User Admin; Remove-Item C:\Windows\Temp\windows-autologon.ps1'
```

#### RDP 창을 그냥 닫아도 되게

RDP로 접속하면 데스크톱 세션이 RDP로 넘어갑니다. 창을 닫으면 세션이 "연결 끊김"이 되어 데스크톱이 없어지고, Windows-MCP가 멈춥니다.

스크립트 [scripts/windows-rdp-autoconsole.ps1](../scripts/windows-rdp-autoconsole.ps1)는 두 가지를 해서 이 문제를 없앱니다.

1. 예약 작업 `rdp-disconnect-to-console`을 만듭니다. "연결 끊김" 이벤트(24, `TerminalServices-LocalSessionManager/Operational`)가 나면 SYSTEM 권한으로 세션 상태를 확인합니다. 상태(`WTSConnectState`)가 **정말 Disconnected(4)일 때만** `tscon <세션ID> /dest:console`로 콘솔에 돌려보냅니다. 사용자는 **RDP 창을 그냥 닫으면 됩니다.**
   - 주의: 이벤트 24는 RDP로 **접속하는 순간**에도 납니다. 원래 콘솔 쪽 연결이 끊기기 때문입니다. 이벤트만 보고 `tscon`하면 방금 접속한 RDP 세션을 빼앗아 RDP 창이 몇 초 만에 꺼집니다. 2026-10-21에 실제로 이런 일이 났습니다. 그래서 상태를 확인하고, 접속 중(Active, 0)이면 건드리지 않습니다.
   - 판단 결과는 `C:\ProgramData\lab\rdp-to-console.log`에 한 줄씩 남습니다(`left alone` 또는 `tscon to console`).
2. Windows-MCP 시작 스크립트를 "끝나면 15초 뒤 다시 시작" 루프로 감쌉니다. 세션이 잠깐 끊긴 순간 시작돼 바로 죽어도 저절로 살아납니다.

**언제 실행하나**: Windows-MCP 설정([windows-mcp-setup.ps1](../scripts/hermes/windows-mcp-setup.ps1))을 처음 한 뒤 한 번, 그리고 **`windows-mcp install --force`를 다시 할 때마다(설정 스크립트 재실행 포함)** 다시 실행합니다. `install --force`가 `start-server.cmd`를 새로 만들면서 2번의 재시작 루프가 사라지기 때문입니다.

**실행** (`Admin`은 Administrators 그룹이라 SSH 세션이 관리자 권한입니다. 파일은 UTF-8 BOM을 유지해야 하므로 그대로 복사합니다):

```bash
# (비서 VM)
scp "$REPO/scripts/windows-rdp-autoconsole.ps1" win:C:/Windows/Temp/
ssh win 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\windows-rdp-autoconsole.ps1; Remove-Item C:\Windows\Temp\windows-rdp-autoconsole.ps1'
```

**확인**: `ssh win 'Get-ScheduledTask rdp-disconnect-to-console | Select TaskName,State; Select-String -Path C:\Users\Admin\.windows-mcp\start-server.cmd -Pattern ":loop"'` → 작업이 `Ready`, `:loop` 한 줄이 보이면 됩니다.

**Windows-MCP 창 숨기기**: `windows-mcp install`이 만든 예약 작업은 `start-server.cmd`를 보이는 콘솔로 실행해서 데스크톱에 cmd 창이 계속 떠 있습니다. 설정 스크립트가 작업 동작을 `conhost.exe --headless cmd.exe /c "...start-server.cmd"`로 바꿉니다. 같은 사용자 세션에서 돌기 때문에 UI 자동화는 그대로 동작합니다. 확인은 `ssh win "(Get-ScheduledTask windows-mcp-server).Actions | % Execute"` → `conhost.exe`입니다.

> 참고: 스크립트의 정규식 치환(`(?m)^(.*windows_mcp serve.*)$`)은 CRLF 파일에서 줄 끝 `\r`까지 잡기 때문에, 감싼 `windows_mcp serve` 줄 뒤에 빈 `\r`이 하나 더 생깁니다(`\r\r\n`). cmd는 이를 무시하므로 동작에는 영향이 없는 겉모양 문제입니다.

#### 평소에는 꺼 두기 (전원 제어 전용 명령)

윈도우 VM은 평소 꺼 두고, 봇이 필요할 때 켜고 끕니다. 전원 조작을 **단순하고 범위가 좁은 한 가지 명령**으로 두려고, Kolla 호스트에 켜기·끄기·상태만 하는 명령을 두고 비서 VM에는 그 명령만 실행되는 SSH 키를 줍니다. 봇은 이와 별도로 감사 로그가 남는 OpenStack 관리자 래퍼 `osadmin`도 갖게 됩니다([07 문서](07-openstack-agent.md#전체-admin-권한-주기-이-구성의-최종-선택)). 전원은 `osadmin` 대신 이 명령을 쓰게 해서, 기다리기·상태 확인까지 한 번에 끝나고 규칙도 간단해집니다.

- 명령: [scripts/lab-windows-power](../scripts/lab-windows-power) → Kolla 호스트 `/usr/local/bin/lab-windows-power` (root 소유, 755). `start | stop | status`만 받고 그 밖의 입력은 거부합니다.
  - 스크립트는 **Kolla 사용자(`<KOLLA_USER>`)의 비밀번호 없는 sudo**에 기댑니다(`sudo -n cat /etc/kolla/admin-openrc.sh`, `sudo -n docker exec`). sudo가 비밀번호를 물으면 실패합니다.
  - admin 자격증명은 `docker exec` 인자(ps로 보임)가 아니라 권한 600 임시 env-file(`--env-file`, 끝나면 삭제)로 넘깁니다.

설치 순서:

1. 전용 키를 만듭니다. 무인으로 써야 하므로 암호 없음.

   ```bash
   # (비서 VM)
   ssh-keygen -t ed25519 -N "" -C "lab-windows-power@lab-assistant" -f ~/.ssh/kolla_power
   ```

2. 명령을 설치하고 sudo를 확인합니다.

   ```bash
   # (Kolla 호스트)
   sudo install -o root -g root -m 755 "$REPO/scripts/lab-windows-power" /usr/local/bin/lab-windows-power
   sudo -n true && echo "passwordless sudo OK"
   ```

3. 공개키를 Kolla 호스트 `~/.ssh/authorized_keys`에 **강제 명령 + `restrict`**로 등록합니다. `restrict`는 포트·agent·X11 포워딩, pty, `~/.ssh/rc`를 모두 끕니다. 비서 VM이 LAN으로 나갈 때는 Floating IP로 SNAT되므로 `from=`에는 비서 VM의 Floating IP를 씁니다.

   ```bash
   # (Kolla 호스트) 공개키는 비밀이 아님
   printf 'restrict,command="/usr/local/bin/lab-windows-power",from="%s" %s\n' \
     "<ASSISTANT_FIP>" "$(ssh lab-assistant cat .ssh/kolla_power.pub)" >> ~/.ssh/authorized_keys
   tail -n1 ~/.ssh/authorized_keys     # restrict,command="/usr/local/bin/lab-windows-power",from="..." ssh-ed25519 AAAA... lab-windows-power@lab-assistant
   ```

4. 비서 VM `~/.ssh/config`에 별칭을 두고 호스트 키를 등록합니다.

   ```
   # (비서 VM) ~/.ssh/config
   Host winpower
     HostName <KOLLA_HOST>
     User <KOLLA_USER>
     IdentityFile ~/.ssh/kolla_power
     IdentitiesOnly yes
     ConnectTimeout 10
   ```

   ```bash
   # (비서 VM)
   ssh-keyscan -t ed25519 <KOLLA_HOST> >> ~/.ssh/known_hosts
   ssh winpower status        # lab-windows: SHUTOFF 또는 ACTIVE
   ```

- 사용법: `ssh winpower status|start|stop`
- `start` 후 `ssh win`은 약 30초, Windows-MCP 8000 포트는 약 40초 뒤 열립니다. Hermes는 끊긴 MCP 서버를 5분마다 다시 연결하므로(`_PARKED_RETRY_INTERVAL = 300`) 켠 직후에는 `ssh win`을 먼저 쓰고, GUI 도구는 몇 분 뒤에 씁니다. 바로 쓰려면 Discord에서 `/reload-mcp`를 보냅니다.
- 봇 규칙(SOUL.md, CLAUDE.md): 작업 전에 `status`를 보고 꺼져 있으면 `start`, 끝나면 `query user`로 RDP 세션을 확인해 없으면 `stop`, 있으면 끌지 묻습니다.
- 검증 (2026-10-21): 다른 명령(`ssh winpower "cat /etc/kolla/passwords.yml"`, `"bash -c id"`)은 `usage`로 거부, 셸은 `PTY allocation request failed`, `ssh -L`은 `administratively prohibited`. `stop` 87초(Windows 이벤트 1074 → 109 → 13 정상 종료), `start` 후 `ssh win` 약 30초·8000 포트 39초.

#### Windows-MCP 도구 21개와 승인

`trust: untrusted`로 등록하면 읽기 전용이 아닌 호출(`readOnlyHint`가 정확히 true가 아닌 것)은 **실행 전에 매번 승인**을 받습니다(Hermes `tools/mcp_tool.py`의 trust-tier gating).

주의: Windows-MCP 도구의 인자는 `approvals.deny` 패턴 검사를 거치지 않습니다. deny 패턴은 Hermes 자체 터미널 명령에만 적용됩니다.

그래서 **명령 실행은 SSH로만** 하도록 바꿨습니다.

| 구분 | 경로 | 거치는 검사 |
|---|---|---|
| 명령 실행 | 터미널에서 `ssh win "<PowerShell>"` (3-0에서 만든 별칭) | `approvals.deny` 패턴 + 위험 명령 승인 |
| 화면 확인·클릭·입력 | Windows-MCP (19개, `PowerShell`·`Registry` 제외) | 쓰기 호출마다 승인 (`trust: untrusted`) |
| 로그온·UAC 화면 | `vnc` | 쓰기 호출마다 승인 |

`PowerShell`·`Registry` 제외는 위 Hermes 설정(`tools.exclude`)에 이미 들어 있습니다. `hermes mcp list`에 `-2 excluded`로 보이는지만 확인합니다. `hermes mcp test windows`는 서버의 원래 목록(21개)을 보여 주므로 확인용이 아닙니다.

#### 봇이 규칙을 알게 하기 (SOUL.md)

도구를 빼는 것만으로도 강제는 되지만, 봇이 어떤 경로를 써야 하는지 알아야 헤매지 않습니다.

- Hermes가 **모든 세션에서 항상 읽는 파일은 `~/.hermes/SOUL.md`뿐**입니다. `AGENTS.md`는 작업 디렉터리 기준이라 Discord 세션에서는 보장되지 않습니다.
- 예시 [scripts/hermes/SOUL.ops.rules.example.md](../scripts/hermes/SOUL.ops.rules.example.md)는 **최종 규칙**입니다. 07·08에서 생기는 `osadmin`·`oslab`·`ccproj`, `lab-bridge`, `kali-cloud`도 미리 들어 있습니다. 지금 붙여 두면 그 도구가 생기기 전에는 봇이 명령을 찾지 못할 뿐이고, 07·08에서 규칙을 다시 고칠 필요가 없습니다.
- 자리표시자 `<WIN_LAB_IP>`, `<GNS3_LAB_IP>`, `<WIN_FIP>`를 실제 값으로 바꿔 `SOUL.md` 끝에 붙입니다. 아래 `sed`의 오른쪽 값(예시)을 자기 값으로 고친 뒤 실행합니다.

  ```bash
  # (비서 VM) 백업 후, 규칙이 아직 없을 때만 붙임
  cp -p ~/.hermes/SOUL.md ~/.hermes/SOUL.md.bak-$(date +%Y%m%d%H%M)
  if grep -q '^## 홈랩 운영 규칙 (ops)' ~/.hermes/SOUL.md; then
    echo "이미 있음: 붙이지 말고 바뀐 줄만 고치세요"
  else
    printf '\n' >> ~/.hermes/SOUL.md
    sed -e 's/<WIN_LAB_IP>/10.10.0.38/g' -e 's/<GNS3_LAB_IP>/10.10.0.242/g' -e 's/<WIN_FIP>/192.168.0.203/g' \
      "$REPO/scripts/hermes/SOUL.ops.rules.example.md" >> ~/.hermes/SOUL.md
  fi
  grep -c '<[A-Z_]*>' ~/.hermes/SOUL.md     # 0 이어야 함
  ```

- reader 프로필의 SOUL.md에는 넣지 않습니다. reader에게 내부망 구조를 알려줄 이유가 없습니다.
- 수정한 뒤 `systemctl --user restart hermes-gateway`로 재시작합니다.
- 검증 (2026-10-21): "윈도우 VM 호스트 이름과 버전 알려줘" → 봇이 `ssh win`으로 `hostname`, `Get-ComputerInfo`를 실행해 답함. `WindowsProductName`은 Windows 11에서도 "Windows 10 Pro"로 나오므로 빌드 번호(26200 이상)로 판단합니다.

### 4. mcp-vnc 폴백 (비서 VM)

```bash
# (비서 VM)
sudo npm i -g --no-fund --no-audit @hrrrsn/mcp-vnc@1.0.2
sudo ln -sf /usr/local/lib/nodejs/node-v24.22.0-linux-x64/bin/mcp-vnc /usr/local/bin/mcp-vnc
```

```bash
# (Kolla 호스트) VNC_PASSWORD 를 비서 VM ~/.hermes/.env 로 (있으면 교체)
sec VNC_PASSWORD | ssh lab-assistant "$(declare -f setenv); setenv VNC_PASSWORD -"
```

README의 환경변수: `VNC_HOST`, `VNC_PORT`(기본 5900), `VNC_PASSWORD`.

`mcp_servers:` 아래에 추가하고 `<WIN_LAB_IP>`를 채웁니다:

```yaml
  vnc:                            # fallback for login/UAC/secure-desktop screens
    command: /usr/local/bin/mcp-vnc
    env:
      VNC_HOST: "<WIN_LAB_IP>"
      VNC_PORT: "5900"
      VNC_PASSWORD: ${VNC_PASSWORD}
    trust: untrusted
    timeout: 120
    tools: {resources: false, prompts: false}
```

Hermes는 stdio MCP 자식에게 `PATH/HOME` 등 안전 변수와 `env:`에 적은 것만 넘깁니다(다른 키는 전달 안 됨).

### 5. netmiko-mcp (비서 VM)

자체 venv에 설치합니다. **PyPI 0.2.0은 `mcp` 2.x와 호환되지 않으므로 `mcp<2`로 고정**합니다.

```bash
# (비서 VM)
python3 -m venv ~/.venvs/netmiko-mcp
~/.venvs/netmiko-mcp/bin/pip install "netmiko-mcp==0.2.0" "mcp>=1.27.1,<2"
mkdir -p -m 700 ~/.config/netmiko-mcp
cp "$REPO/scripts/hermes/netmiko-mcp.example.yml"       ~/.config/netmiko-mcp/netmiko-mcp.yml
cp "$REPO/scripts/hermes/netmiko-commands.example.yml"  ~/.config/netmiko-mcp/commands.yml
cp "$REPO/scripts/hermes/netmiko-inventory.example.yml" ~/.config/netmiko-mcp/inventory.yml   # 지금은 장비 없음
chmod 600 ~/.config/netmiko-mcp/*
```

- `commands.yml`: **기본 거부**. `show …`/`display …` 조회 명령만 개별 glob으로 허용, `show running-config`/`startup`/`tech`, `configure*`, `reload*`, `erase*`, `clear*`, `debug*` 등은 deny가 우선. 파이프는 `include/exclude/section/begin/count`만.
- netmiko-mcp 0.2.0에는 **설정 모드 도구가 없습니다**(`send_show_command*`, 목록/출력 조회, ping뿐). 그래서 "명시적 설정 명령"은 allowlist에 주석 예시로만 두었고, 설정 변경은 콘솔 부트스트랩 또는 사람이 합니다.
- 장비를 추가할 때는 비밀번호를 `netmiko-encrypt`로 암호화하고 `NETMIKO_TOOLS_KEY`를 Hermes `env:`에 `${NETMIKO_TOOLS_KEY}`로 넘기세요. 장비 쪽 AAA(읽기 전용 계정)도 권장(README).

`mcp_servers:` 아래에 추가합니다(자리표시자 없음):

```yaml
  netmiko:
    command: /home/ubuntu/.venvs/netmiko-mcp/bin/netmiko-mcp
    env:
      NETMIKO_MCP_CONFIG: /home/ubuntu/.config/netmiko-mcp/netmiko-mcp.yml
    trust: untrusted
    timeout: 300
    tools: {resources: false, prompts: false}
```

감사 로그: `~/.netmiko_mcp_audit.log`(600).

## 검증

```bash
# (비서 VM) Hermes 자체 테스트
hermes mcp list
hermes mcp test gns3      # ✓ Connected, Tools discovered: 76 (등록 시 11개 제외 → 65)
hermes mcp test vnc       # ✓ 6
hermes mcp test netmiko   # ✓ 7
hermes mcp test windows   # VM이 켜져 있으면 ✓ (자동 로그온). 꺼져 있으면 먼저 ssh winpower start 후 1~5분 대기

# 독립 클라이언트 (임시 venv, 키는 env에서 읽고 출력 안 함)
python3 -m venv /tmp/mcpcli && /tmp/mcpcli/bin/pip install -q 'mcp==1.30.0'   # 2026-10-21 확인 버전
set -a; . <(grep -E '^(GNS3_API_KEY|WINDOWS_MCP_AUTH_KEY)=' ~/.hermes/.env); set +a
/tmp/mcpcli/bin/python "$REPO/scripts/hermes/mcp_list.py" sse  http://<GNS3_LAB_IP>:3080/v3/mcp/transport/sse GNS3_API_KEY
/tmp/mcpcli/bin/python "$REPO/scripts/hermes/mcp_list.py" http http://<WIN_LAB_IP>:8000/mcp WINDOWS_MCP_AUTH_KEY
NETMIKO_MCP_CONFIG=~/.config/netmiko-mcp/netmiko-mcp.yml \
  /tmp/mcpcli/bin/python "$REPO/scripts/hermes/mcp_list.py" stdio ~/.venvs/netmiko-mcp/bin/netmiko-mcp
rm -rf /tmp/mcpcli

# 네트워크 경로: 8000은 비서에서만 열려야 함
nc -vz -w3 <WIN_LAB_IP> 8000          # (비서 VM) 서버가 떠 있으면 성공
nc -vz -w3 <WIN_FIP> 8000             # (Kolla 호스트 또는 LAN PC) 타임아웃이어야 함
```

검증 (2026-10-21):
- GNS3 MCP 76개 발견, 11개 제외 → 65개. mcp-vnc 6개(`vnc_screenshot` 1280x800 성공). netmiko-mcp 7개(`list_groups, list_devices, send_show_command, send_show_command_to_group, list_device_outputs, read_device_output, ping`).
- Windows-MCP: 자동 로그온 후 기동, 21개 중 19개 노출(`-2 excluded`). 8000 경로는 비서 ✓ / LAN ✗.

## 트러블슈팅 (gotchas)

- **Windows-MCP가 안 뜸 / `hermes mcp test windows` 타임아웃**: 먼저 `ssh winpower status`로 VM이 켜져 있는지 봅니다. 꺼져 있으면 `ssh winpower start` 후 기다립니다(`ssh win` 약 30초, 자동 로그온·8000 포트 약 40초, Hermes 재연결 최대 5분 또는 Discord `/reload-mcp`). 켜져 있는데도 안 뜨면 `ssh win 'query user'`로 콘솔 세션이 있는지 보고, 없으면 [자동 로그온](#자동-로그온-켜면-windows-mcp가-저절로-뜨게) 설정을 확인합니다. 로그: `C:\Users\Admin\.windows-mcp\server.error.log`.
- **`UnicodeEncodeError: 'cp949'`**: 한국어 Windows에서 `windows-mcp --help`/`install` 출력 시 발생. `$env:PYTHONUTF8="1"` 후 실행. `install`이 트레이스백을 내도 작업은 등록됩니다.
- **`windows-mcp install --force`를 다시 하면** `start-server.cmd`가 재생성되어 `PYTHONUTF8`/텔레메트리 줄과 재시작 루프가 사라집니다. 설정 스크립트(windows-mcp-setup.ps1)를 다시 실행한 **다음** [windows-rdp-autoconsole.ps1](#rdp-창을-그냥-닫아도-되게)도 다시 실행하세요.
- **README와 0.8.8 차이**: README의 `--no-control`, `[control] enabled=false`는 0.8.8에 없습니다.
- **원격 PowerShell에 stdin(비밀값) 넘기기**: 이 레포는 한 가지 방법만 씁니다. `.ps1`을 복사한 뒤 `<값> | ssh <win> 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\...\x.ps1 …'`로 실행하고, 스크립트 안에서 `[Console]::In.ReadLine()`으로 첫 줄을 읽습니다(자식 `powershell`이 ssh 세션의 stdin을 그대로 물려받음; windows-mcp-setup.ps1·windows-autologon.ps1). 앞에 `$input |`를 붙이지 않습니다. `$input`은 스크립트 파일 없이 ssh 명령 문자열 안에서 cmdlet에 바로 파이프할 때만 씁니다(3-0의 `\$input | Add-Content …`). 여러 줄 스크립트를 `-Command -`(stdin)로 보내면 here-string이 깨지므로 항상 `.ps1` 파일 + `-File`로 실행합니다.
- **netmiko-mcp `No module named 'mcp.server.fastmcp'`**: `mcp` 2.x가 깔린 것. `pip install "mcp<2"`.
- **GNS3 MCP 421**: `mcp_allowed_hosts`에 `<GNS3_LAB_IP>:*`가 있어야 합니다([02 문서](02-gns3-server.md)).
- **`trust: untrusted`라 조회도 승인 요청**: 서버들이 `readOnlyHint`를 주지 않아서입니다. 불편하면 서버별로 `trust: full`로 낮추되, 그러면 GNS3 제외 목록과 netmiko allowlist만 남는다는 점을 감안하세요.
- **OpenStack SG 표시**: `rule list`에서 remote-group 규칙도 IP Range가 `0.0.0.0/0`으로 보이지만 실제로는 `Remote Security Group`(sg-assistant)으로 제한됩니다.
