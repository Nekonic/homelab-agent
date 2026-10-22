# 04. Hermes Agent hardening과 reader/ops 분리

## 목적

- `lab-assistant`의 Hermes Agent v0.22.2를 실습망 운영용으로 hardening합니다.
- 모델: ChatGPT 구독(Codex OAuth, `openai-codex`)을 기본으로 쓰고, OpenRouter 무료 모델로 fallback
- 승인: `manual` + 사용자 정의 차단 목록(`approvals.deny`), cron/단발/무인 세션은 전부 거부
- reader / ops 두 봇으로 분리
  - `reader`: 웹·비전만. 셸·파일·코드 실행·브라우저·MCP 없음 → 프롬프트 인젝션을 당해도 실행할 수 있는 도구가 없음
  - `ops`: GNS3·Windows·VNC·netmiko MCP, 수동 승인, 소유자만 사용(DM 또는 서버 채널 `@멘션`)
- Discord 게이트웨이는 사용자 서비스로 설치만 하고, 토큰을 넣기 전까지 시작하지 않음

MCP 서버(GNS3, Windows-MCP, mcp-vnc, netmiko) 설치·검증은 [05 문서](05-mcp.md)에 있습니다.

## 사전 요구사항

- [01](01-openstack-reset-and-base.md)~[03](03-windows-vm.md) 완료 (`lab-assistant` VM이 실행 중이고 SSH 접속 가능). Hermes는 아래 1단계에서 설치합니다.
- Placeholder
  - `<ASSISTANT_FIP>`: lab-assistant Floating IP (예: `192.168.0.202`)
  - `<YOUR_DISCORD_USER_ID>`: 본인 Discord 사용자 ID(숫자)
  - `<OPENROUTER_API_KEY>`, `<OPS_DISCORD_BOT_TOKEN>`, `<READER_DISCORD_BOT_TOKEN>`
- 설정 키는 설치된 v0.22.2에 번들된 문서(`~/.hermes/hermes-agent/website/docs/`)와 설정 템플릿, 소스로 확인했습니다. 온라인 문서(hermes-agent.nousresearch.com)는 버전이 달라 `auth.adopt_external_logins` 같은 항목이 빠져 있을 수 있습니다.

## 프로필 구조

| 프로필 | 위치 | 역할 | Secret(.env) |
|---|---|---|---|
| `default` (= **ops**) | `~/.hermes/` | 운영 봇. multiplex 게이트웨이의 호스트 | 모델 키, ops 봇 토큰, `GNS3_API_KEY`, `WINDOWS_MCP_AUTH_KEY`, `VNC_PASSWORD` |
| `reader` | `~/.hermes/profiles/reader/` | 읽기 전용 대화/조사 봇 | 모델 키, reader 봇 토큰만 |

- v0.22는 게이트웨이 하나가 모든 프로필을 처리(multiplex, 기본값)합니다. 프로필마다 `.env`, MCP 연결, 허용 사용자, 승인 기록이 분리되고, MCP 자식 프로세스는 자기 프로필의 secret만 받습니다.
- 봇 토큰은 프로필마다 **서로 다른 Discord 봇**이어야 합니다(같은 토큰이면 두 번째가 `duplicate_credential`로 정지).
- **주의: 프로필은 샌드박스가 아닙니다.** 같은 리눅스 사용자로 실행되므로 reader는 도구를 아예 주지 않는 방식으로 격리합니다(`platform_toolsets` + `agent.disabled_toolsets` + `no_mcp`).

## 절차

별도 표시가 없으면 모든 명령은 `lab-assistant`의 `ubuntu` 사용자로 실행합니다.

```bash
# (Kolla 호스트) 01 문서 D-5의 별칭. 없으면: ssh -i ~/.ssh/lab-key ubuntu@<ASSISTANT_FIP>
ssh lab-assistant
```

### 0. 작업 환경 준비 (lab-assistant)

04~08의 설정 예시와 wrapper 스크립트를 `lab-assistant`에서 씁니다([README의 시작하기](../README.md#시작하기)). `git`은 cloud-init으로 이미 설치돼 있습니다.

```bash
# (lab-assistant)
git clone https://github.com/Nekonic/homelab-agent.git ~/homelab-agent
echo 'REPO=$HOME/homelab-agent' >> ~/.bashrc; REPO=$HOME/homelab-agent   # 이후 문서의 $REPO
```

[README](../README.md#secret-관리)의 `setenv` 함수(env 파일의 키를 있으면 바꾸고 없으면 추가)도 이 셸에 붙여 넣습니다. 5·6단계와 05·07 문서에서 씁니다.

### 1. Hermes 설치

[공식 설치 문서](https://hermes-agent.nousresearch.com/docs/getting-started/installation)의 Linux 설치 스크립트를 씁니다. 스크립트는 코드를 `~/.hermes/hermes-agent/`에, 실행 파일(wrapper)을 `~/.local/bin/hermes`에 두고, 사용자 데이터는 `~/.hermes/`에 둡니다. 필요한 것: `git`, `curl`, `tar`, `sha256sum`(Ubuntu 24.04 기본 포함). uv·Python·Node.js 등은 설치 스크립트가 자동으로 설치합니다.

```bash
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
```

> 원격 스크립트를 바로 실행하지 않으려면 먼저 다운로드해 내용을 확인한 뒤 실행합니다: `curl -fsSL https://hermes-agent.nousresearch.com/install.sh -o /tmp/hermes-install.sh && less /tmp/hermes-install.sh && bash /tmp/hermes-install.sh`

현재 셸에 경로를 넣고 확인합니다(새로 로그인하면 `~/.bashrc`가 처리합니다. 안 되면 `source ~/.bashrc`).

```bash
export PATH=$HOME/.local/bin:$PATH
hermes --version      # 이 문서는 v0.22.2 기준
hermes doctor         # 누락된 의존성과 해결 방법을 출력
```

> 설치 스크립트는 실행 시점의 최신 버전을 설치합니다. v0.22.x보다 새 버전이면 아래 설정 키가 바뀌었을 수 있으니 번들 문서(`~/.hermes/hermes-agent/website/docs/`)로 확인하세요.

### 2. 기본 설정 백업

```bash
cp ~/.hermes/config.yaml ~/.hermes/config.yaml.orig-template
cp ~/.hermes/.env ~/.hermes/.env.orig-template && chmod 600 ~/.hermes/.env.orig-template
```

### 3. ops(기본 프로필) 설정

[scripts/hermes/config.ops.example.yaml](../scripts/hermes/config.ops.example.yaml)(`$REPO/scripts/hermes/config.ops.example.yaml`)의 키를 `~/.hermes/config.yaml`에 병합합니다. 템플릿(주석 포함)을 통째로 덮어쓰지 말고 **해당 키만 바꾸세요**(`_config_version` 유지). 스칼라 값은 아래처럼 CLI로도 설정할 수 있습니다.

예시 파일은 05까지 끝낸 최종본 전체입니다. 이 단계에서는 `mcp_servers`를 **뺀 나머지**만 넣습니다. `mcp_servers`의 각 서버 블록(placeholder `<GNS3_LAB_IP>`, `<WIN_LAB_IP>` 포함)은 [05 문서](05-mcp.md)에서 서버를 설치한 뒤 하나씩 넣습니다. 서버가 없는 블록을 미리 넣으면 게이트웨이가 연결 실패를 반복합니다.

```bash
hermes config set model.provider openai-codex
hermes config set model.default gpt-5.6-terra        # placeholder, 로그인 후 확인
hermes config unset model.base_url                    # 템플릿의 openrouter base_url 제거 (중요)
hermes config set auth.adopt_external_logins false
hermes config set approvals.mode manual
hermes config set approvals.cron_mode deny
hermes config set approvals.single_query_mode deny
hermes config set approvals.unattended_mode deny
hermes config set approvals.timeout 300
hermes config set approvals.mcp_reload_confirm true
hermes config set approvals.destructive_slash_confirm true
hermes config set discord.history_backfill false
hermes config set fallback.min_switch_reset_seconds 180
hermes config set security.allow_private_urls false
hermes config set security.allow_lazy_installs false
hermes config set agent.bot_mode_protocol false
hermes config set unauthorized_dm_behavior ignore
hermes config set terminal.cwd /home/ubuntu/hermes-work/ops
mkdir -p ~/hermes-work/ops ~/hermes-work/reader && chmod 700 ~/hermes-work/*
# 그 밖의 키(리스트/맵 포함: fallback_providers, approvals.deny, platform_toolsets, discord 등)는
# 예시 파일과 비교해 `hermes config edit`로 맞춥니다. 예시와 다른 키가 없을 때까지 확인하세요.
# mcp_servers 블록은 여기서 붙이지 않습니다. 05 문서에서 서버를 설치할 때마다 하나씩 붙입니다.
```

주요 값과 설정 이유:

| 키 | 값 | 이유 |
|---|---|---|
| `auth.adopt_external_logins` | `false` | `~/.codex`, Claude Code 로그인을 빌려 쓰지 않음(refresh 토큰 로테이션 충돌 방지). Hermes 자체 로그인만 사용 |
| `model` | `openai-codex` / `gpt-5.6-terra` | ChatGPT Plus 구독. 2026-10-21에 Plus로 응답 확인. 플랜별 사용 가능 모델은 로그인 후 `hermes model`로 확인 |
| `fallback_providers` | openrouter `minimax/minimax-m3.1-flash:free` | Plus는 5시간/주간 사용 한도가 있어 fallback이 필요합니다. OpenRouter는 가입만 하면 카드 없이 키 발급(무료 등급: `:free` 모델 분당 20회·하루 50회, 크레딧 $10 이상 구매 시 하루 1,000회). 도구 호출(`tools`)을 지원하는 `:free` 모델 중에서 선택 |
| `fallback.min_switch_reset_seconds` | `180` | 한도 해제까지 3분 미만이면 전환하지 않고 대기. fallback은 세션당 1회 전환 |
| `approvals.mode` | `manual` | 위험 명령은 항상 사람 승인 |
| `approvals.cron_mode`/`single_query_mode`/`unattended_mode` | `deny` | 사람이 없는 실행 경로는 위험 명령 차단 |
| `approvals.deny` | `*Format-Volume*`, `*diskpart*`, `*Remove-Item*-Recurse*`, `curl\|sh`류, ssh 터널(`-R`/`-D`), `.env`/키 파일 접근 등 | yolo·승인보다 먼저 적용되어 항상 차단(fnmatch, 대소문자 무시). YAML에서는 따옴표 필수 |
| `security.allow_private_urls` | `false` | 웹 도구 SSRF 차단 유지(MCP 서버 연결과는 무관) |
| `security.allow_lazy_installs` | `false` | 채팅 중 패키지 자동 설치 금지 → Discord 의존성은 아래 4단계에서 명시 설치 |
| `agent.bot_mode_protocol` | `false` | `message_agent`(봇 간 메시지) 주입 비활성화 |
| `unauthorized_dm_behavior` | `ignore` | 허용되지 않은 DM에 페어링 코드도 보내지 않음 |
| `discord.require_mention` | `true` | 서버 채널에서는 `@멘션`할 때만 답함. DM은 항상 답함. 서버에 다른 사람이 있다면 `DISCORD_ALLOWED_CHANNELS=<채널ID>`로 전용 채널 하나로 제한하거나, `DISCORD_IGNORED_CHANNELS=*`로 DM 전용으로 만듦 |
| `discord.allow_bots` | `none` | 다른 봇(reader 포함)의 메시지 무시 |
| `discord.auto_thread` | 기본값 `true` (설정하지 않음) | 서버 채널에서 `@멘션`할 때마다 스레드를 만들어 그 안에서 답함. 스레드마다 세션(대화 기록)이 분리되어 주제가 섞이지 않음. DM과 이미 있는 스레드에는 영향 없음. 그래서 두 봇 모두 Discord 스레드 권한이 필요합니다(아래 권한 표) |
| `platform_toolsets.discord` | terminal, file, web, … + `gns3, windows, vnc, netmiko` | MCP 서버 이름을 적으면 그 서버만 허용(allowlist). browser·code_execution·delegation·cronjob 제외 |
| `mcp_servers.*.trust` | `untrusted` | (05에서 넣음) `readOnlyHint`가 없는 MCP 도구 호출은 전부 승인 필요(이 구성의 서버들은 annotation이 없어 사실상 모든 호출이 승인 대상) |

### 4. Discord 의존성 설치

`allow_lazy_installs: false`이므로 discord.py를 미리 설치합니다.

```bash
hermes pm install --extra discord
hermes doctor | grep discord.py      # ✓ discord.py
```

### 5. `.env` 키 등록

[scripts/hermes/ops.env.example](../scripts/hermes/ops.env.example)의 키를 `~/.hermes/.env`에 **빈 값으로** 넣습니다(이미 있는 키는 그대로 둠). 값은 나중에 채웁니다. 토큰·ID는 아래 "수동 작업"에서, MCP secret(`GNS3_API_KEY`, `WINDOWS_MCP_AUTH_KEY`, `VNC_PASSWORD`)은 [05 문서](05-mcp.md)에서 `setenv`로 바꿉니다. `>>`로 같은 키를 중복 추가하지 않습니다.

```bash
# (lab-assistant) setenv 함수가 정의된 셸에서
grep -oE '^[A-Z_]+=' "$REPO/scripts/hermes/ops.env.example" | tr -d = | while read -r k; do
  grep -q "^$k=" ~/.hermes/.env || setenv "$k" ""
done
setenv DISCORD_ALLOW_BOTS none
chmod 600 ~/.hermes/.env
grep -oE '^[A-Z_]+=' ~/.hermes/.env | sort | uniq -d     # 출력이 없어야 함 (중복 키 없음)
```

### 6. reader 프로필 생성

기본 프로필을 **복제하지 않고** 빈 프로필로 만듭니다(복제하면 ops의 MCP secret까지 복사됨).

```bash
hermes profile create reader --no-skills \
  --description "Read-only research/chat bot: web+vision only, no shell/files/code/browser/MCP"
hermes -p reader config unset model.base_url
# $REPO/scripts/hermes/config.reader.example.yaml 의 키를 전부 병합 (ops와 같은 fallback/auth/approvals/security 블록도 파일에 들어 있음)
hermes -p reader config edit
R=~/.hermes/profiles/reader/.env
grep -oE '^[A-Z_]+=' "$REPO/scripts/hermes/reader.env.example" | tr -d = | while read -r k; do
  grep -q "^$k=" "$R" 2>/dev/null || setenv "$k" "" "$R"
done
setenv DISCORD_ALLOW_BOTS none "$R"; chmod 600 "$R"
```

> `--no-skills`로 만들어도 `hermes -p reader skills list`에는 번들 스킬 `hermes-agent`가 보일 수 있습니다. reader는 `skills` toolset이 꺼져 있어(`agent.disabled_toolsets`, `tools list`에서 `✗ disabled skills`) 스킬을 쓰지 못하므로 정상입니다.

reader 제한:

- `platform_toolsets.cli/discord: [web, vision, todo, memory, session_search, clarify, no_mcp]`
- `agent.disabled_toolsets`: terminal, code_execution, browser, file, computer_use, delegation, cronjob, skills, image_gen, video_gen, discord_admin, kanban, connections
- `mcp_servers: {}`

### 7. 게이트웨이 서비스 설치

```bash
sudo loginctl enable-linger ubuntu
hermes gateway install --no-start-now --start-on-login
systemctl --user is-enabled hermes-gateway.service   # enabled
systemctl --user is-active hermes-gateway.service    # inactive (토큰 넣기 전까지 정상)
```

기본 프로필의 게이트웨이 하나가 reader까지 처리합니다(`hermes -p reader gateway install`은 하지 않음). 재부팅되면 토큰이 비어 있어도 서비스는 시작되지만 연결할 플랫폼이 없어 아무 일도 하지 않습니다.

## 수동 작업

1. ChatGPT(Plus) 로그인(기기 코드 방식). 명령이 URL과 코드를 출력하면 브라우저에서 입력합니다.

   ```bash
   hermes auth add openai-codex               # ops(기본 프로필)
   hermes -p reader auth add openai-codex     # reader도 쓰려면 (안 하면 reader는 OpenRouter로 fallback)
   hermes model                               # Plus에서 보이는 모델 확인 후 model.default 교체
   hermes config set model.default <확인한-모델-ID>
   ```

2. OpenRouter 키를 두 프로필의 `.env`에 넣습니다. [openrouter.ai](https://openrouter.ai) 가입 → Keys에서 발급(카드 불필요).

   ```bash
   nano ~/.hermes/.env                         # OPENROUTER_API_KEY=
   nano ~/.hermes/profiles/reader/.env         # 같은 키 (또는 reader 전용 키)
   ```

   Fallback 모델을 바꾸려면 도구 호출을 지원하는 무료 모델 목록을 보고 고릅니다.

   ```bash
   curl -s https://openrouter.ai/api/v1/models | python3 -c 'import json,sys;[print(m["id"]) for m in json.load(sys.stdin)["data"] if m["id"].endswith(":free") and "tools" in (m.get("supported_parameters") or [])]'
   ```

   > OpenCode Zen은 쓰지 않습니다. 외부 도구에서는 무료로 쓸 수 없고, API 키를 받으려면 결제 수단을 등록해야 합니다.

3. Discord 봇 2개 생성. 아래 [Discord 봇 만들기](#discord-봇-만들기-ops--reader) 절차를 ops용, reader용으로 한 번씩 진행합니다.
4. 토큰과 본인 ID 입력. 본인 ID는 Discord 설정 → 고급 → 개발자 모드를 켠 뒤, 내 프로필을 우클릭해서 **ID 복사**로 얻습니다.

   ```bash
   nano ~/.hermes/.env                  # DISCORD_BOT_TOKEN=<OPS_DISCORD_BOT_TOKEN>    DISCORD_ALLOWED_USERS=<YOUR_DISCORD_USER_ID>
   nano ~/.hermes/profiles/reader/.env  # DISCORD_BOT_TOKEN=<READER_DISCORD_BOT_TOKEN> DISCORD_ALLOWED_USERS=<YOUR_DISCORD_USER_ID>
   ```

5. 게이트웨이 시작

   ```bash
   hermes gateway start
   hermes gateway status                # Serves: default, reader
   journalctl --user -u hermes-gateway -f
   ```

6. 두 봇 모두 서버 채널에서는 `@봇이름`으로 멘션해야 답합니다. 멘션하면 봇이 그 메시지에 스레드를 만들고(`auto_thread`) 스레드 안에서 답합니다. 스레드 안에서는 멘션 없이 대화를 이어 갈 수 있습니다. ops는 DM으로도 부를 수 있습니다. 멘션 없이 보낸 채널 메시지는 **로그도 남기지 않고 무시**합니다.

### Discord 봇 만들기 (ops / reader)

[Discord Developer Portal](https://discord.com/developers/applications)에서 봇 두 개를 같은 절차로 만듭니다. 이름은 구분할 수 있게 정합니다(예: `lab-ops`, `lab-reader`). 권한도 같으므로 두 봇은 이름과 토큰만 다릅니다.

화면 이름은 한국어 UI 기준이고, 괄호 안이 영어 UI 이름입니다. 2026-10 기준으로 확인했습니다. 초대 설정은 **OAuth2 메뉴가 아니라 설치(Installation) 메뉴**에서 합니다. OAuth2 메뉴(Client Secret, 리디렉션, URL 생성기)는 설정하지 않습니다.

#### 1) 앱 생성

오른쪽 위 **New Application** → 이름 입력 → 약관 동의 → **Create**.

#### 2) 설치 (Installation) 메뉴

1. **설치 환경 (Installation Contexts)**
   - `길드 설치 (Guild Install)`만 체크합니다.
   - `사용자 설치 (User Install)`는 해제합니다. 새 앱은 기본으로 둘 다 켜져 있습니다.
2. **설치 링크 (Install Link)**: `Discord 제공 링크 (Discord Provided Link)`를 선택합니다.
3. **기본 설치 설정 (Default Install Settings) → 길드 설치**
   - **스코프**: `applications.commands`, `bot` 두 개를 넣습니다. `applications.commands`는 슬래시 명령과 승인 버튼에, `bot`은 봇 사용자에 필요합니다.
   - `bot`을 넣으면 **권한** 칸이 나타납니다. 아래 표의 8개를 고릅니다(두 봇 같음). 칸에 입력하면 목록이 필터링됩니다.
4. 변경 사항을 **저장**합니다.

| 권한 (한국어 UI) | 영어 UI | ops | reader | 용도 |
|---|---|:-:|:-:|---|
| 채널 보기 | View Channels | O | O | 필수 |
| 메시지 보내기 | Send Messages | O | O | 필수 |
| 링크 임베드 | Embed Links | O | O | 필수. 응답과 승인 카드가 임베드로 표시됨 |
| 파일 첨부 | Attach Files | O | O | 필수. 스크린샷 등 파일 전송 |
| 메시지 기록 보기 | Read Message History | O | O | 필수 |
| 공개 스레드 만들기 | Create Public Threads | O | O | 멘션할 때마다 스레드 생성 (`discord.auto_thread`, 기본 `true`) |
| 스레드에서 메시지 보내기 | Send Messages in Threads | O | O | 스레드 안에서 답변 |
| 반응 추가 | Add Reactions | O | O | 처리 상태 표시 👀 ✅ ❌ (`discord.reactions`, 기본 `true`) |

Hermes는 서버 채널에서 `@멘션`을 받으면 기본으로 스레드를 만들어 답합니다(`discord.auto_thread`, 기본 `true`, 번들 문서 `user-guide/messaging/discord.md`). 그래서 ops와 reader 모두 위 8개를 줍니다. [08 문서](08-claude-projects.md)의 "프로젝트마다 스레드 하나"도 이 동작을 전제로 합니다.

> 이미 서버에 추가한 봇이 스레드를 만들지 못하고 로그(`journalctl --user -u hermes-gateway`)에 `50001`(Missing Access)이나 `50013`(Missing Permissions)이 남으면, 서버 설정 → 역할 → 그 봇의 역할에서 **공개 스레드 만들기**, **스레드에서 메시지 보내기**, **반응 추가**를 켭니다. 설치 화면의 권한은 새로 추가할 때만 적용됩니다.

설정 화면(두 봇 공통):

![봇 기본 설치 설정: 스코프 applications.commands, bot / 권한 8개](images/discord-install-reader.png)

**주면 안 되는 권한**

- 관리자 (Administrator)
- 감사 로그 보기
- 메시지 관리, 메시지 고정
- 채널·역할·웹후크·서버 관리 등 "~관리"로 끝나는 권한 전부
- @everyone 멘션
- 추방, 차단
- 말하기, 동영상 등 음성 권한

#### 3) 봇 (Bot) 메뉴

1. **Privileged Gateway Intents**
   - `Message Content Intent`: **켜기(필수).** 꺼져 있으면 Discord가 연결을 거부해서 봇이 오프라인으로 남습니다.
   - `Server Members Intent`: 켜기. Hermes 문서에서 필수로 표시합니다.
   - `Presence Intent`: 끄기.

   ![봇 메뉴: Server Members Intent, Message Content Intent 켬](images/discord-bot-intents.webp)

2. **Reset Token** → 토큰을 복사합니다. 이 화면을 벗어나면 다시 볼 수 없습니다. 이 토큰을 `.env`의 `DISCORD_BOT_TOKEN`에 넣습니다.
   - ops 토큰은 `~/.hermes/.env`, reader 토큰은 `~/.hermes/profiles/reader/.env`에 넣습니다.
   - 같은 토큰을 두 프로필에 넣으면 두 번째 게이트웨이가 `duplicate_credential`로 멈춥니다.

#### 4) 서버에 추가

1. 설치 메뉴의 **설치 링크** 칸에서 링크를 복사해 브라우저로 엽니다.
2. **서버에 추가**를 누르고 내 서버를 고른 뒤 승인합니다.
3. 나만 있는 비공개 서버를 따로 만들어 쓰는 것을 권장합니다.

#### 5) (선택) 공개 설치 차단

다른 사람이 이 봇을 자기 서버에 넣지 못하게 막습니다.

1. 설치 메뉴에서 **설치 링크**를 `없음 (None)`으로 바꿉니다. 이 설정을 먼저 바꿔야 다음 단계를 진행할 수 있습니다.
2. 봇 메뉴에서 **Public Bot**을 끕니다.

#### 6) (선택) reader를 채널 하나로 제한

1. 서버 설정 → 역할에서 reader 봇 역할의 **채널 보기**를 끕니다.
2. `#reader` 채널 → 채널 편집 → 권한에서 그 역할에만 채널 보기, 메시지 보내기, 스레드 권한을 허용합니다.

이렇게 하면 reader는 다른 채널을 아예 읽지 못합니다.

참고: [Discord: Building your first Discord Bot](https://docs.discord.com/developers/quick-start/getting-started) · [Discord: Developing a User-Installable App (설치 환경/설치 링크)](https://docs.discord.com/developers/tutorials/developing-a-user-installable-app) · [Hermes: Discord](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/discord)

## 검증

```bash
hermes auth list                         # "auth.adopt_external_logins is false" 문구
hermes config check                      # Config version ✓
hermes mcp list                          # ops: 지금은 비어 있음 (05 이후: gns3/windows/vnc/netmiko)
hermes -p reader mcp list                # 비어 있어야 함
hermes tools list --platform discord     # ops: terminal/file/web/... (05 이후 MCP 4개 추가), browser/code_execution ✗
hermes -p reader tools list --platform discord   # web, vision, todo, memory, session_search, clarify 만
hermes doctor | grep -E "discord.py|Codex|OpenRouter"
```

- 검증 (2026-10-21): reader는 6개 toolset만 활성, MCP 없음. ops는 MCP 4개 등록, `gns3`는 패턴 4개로 11개 도구 제외.

## Troubleshooting

- **Bot Mode/프로필은 자동 격리가 아님.** 같은 OS 사용자라서 reader에게 `terminal`/`file`을 주면 ops의 `.env`도 읽을 수 있습니다. 도구를 아예 주지 않아야 격리됩니다.
- **ops가 전달(forward)된 원문을 받지 않게 하기**: `message_agent`는 데스크톱 Bot Mode가 `profile.yaml`에 `ui_meta: {hermes-bots: …}` 표식을 쓰고 세션 제목이 정확히 `Bot Chat`일 때만 생깁니다. 헤드리스 설치에서는 그 표식을 만들지 마세요. 추가로 `agent.bot_mode_protocol: false`, `discord.allow_bots: none`으로 봇 경유 입력을 막았습니다. 단, Hermes에는 "다른 봇이 보낸 원문 수신 금지" 같은 별도 스위치는 없습니다(문서상 `message_agent`는 원문이 아니라 보낸 봇이 다시 쓴 메시지를 전달). **사용자가 reader 출력을 복사해 ops에 붙여 넣는 것은 막을 수 없으므로** 그런 붙여넣기는 하지 마세요.
- **봇이 응답하지 않음**
  - 멘션 없이 보낸 채널 메시지와 허용 목록에 없는 사용자의 메시지는 로그도 남기지 않고 무시됩니다.
  - 확인 순서:
    1. `@봇이름`으로 멘션했는지, 또는 DM인지 확인합니다.
    2. `~/.hermes/logs/gateway.log`에 `discord connected`가 프로필 수만큼 찍혔는지 확인합니다.
    3. `DISCORD_ALLOWED_USERS`가 서버 ID나 봇 ID가 아니라 내 사용자 ID인지 확인합니다.
- **DM 전용으로 만들기**: 전용 스위치는 없습니다. `DISCORD_IGNORED_CHANNELS=*`로 모든 서버 채널을 무시하게 하면 DM에만 답합니다. 코드에서 `*`를 지원하며, DM은 이 설정의 적용 대상이 아닙니다.
- **남아 있는 `model.base_url`**: 템플릿/새 프로필에 `https://openrouter.ai/api/v1`이 들어 있습니다. `openai-codex`로 바꿨다면 `config unset model.base_url`로 지워야 합니다.
- **Plus 플랜 모델/한도**: Hermes 문서는 플랜별 모델·quota를 설명하지 않습니다. `hermes model`의 목록이 기준이고, 한도에 걸리면 `fallback_providers`로 넘어갑니다(세션당 1회).
- **`approvals.deny`는 셸 문자열 정책**이지 샌드박스가 아닙니다. `*curl*|*sh*`는 `curl … | sha256sum`도 막습니다(의도된 보수적 설정).
- **`security.allow_lazy_installs: false`** 상태에서 새 플랫폼/기능이 의존성 부족으로 실패하면 `hermes pm install --extra <name>`으로 명시 설치합니다.
- **`hermes update`** 는 multiplex migration 등을 자동으로 수행할 수 있습니다. 업데이트 뒤 `hermes gateway status`와 위 검증을 다시 확인하세요.
