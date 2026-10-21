# 08. Hermes → Claude Code 프로젝트 위임 (`ccproj`)

## 목적

- Discord에서는 Hermes(ops)에게만 요청하고, 큰 코딩·문서·스크립트 작업은 Hermes가 Claude Code(Claude 구독 Pro 또는 Max, 이 구성은 Max)에 위임합니다.
- 프로젝트마다 폴더 `~/projects/<이름>`과 Claude 대화 기록이 따로 유지됩니다. 상시 Claude Discord 봇은 세션 하나에 모든 대화가 섞이지만, 이 방식은 프로젝트끼리 섞이지 않습니다.
- 약관: 수정하지 않은 공식 `claude` 프로그램에 본인 구독 계정으로 로그인해서 쓰는 방식이라 허용 범위입니다([Claude Code 법무·인증 정책](https://code.claude.com/docs/en/legal-and-compliance)). 사용량은 구독 한도에서 차감됩니다.

## 사전 요구사항

- [04](04-hermes-agent.md)의 Hermes(ops)
- [06](06-claude-code.md)의 Claude Code 로그인
  - `claude auth status`에서 `authMethod: claude.ai`, `subscriptionType`이 `pro` 또는 `max`인지 확인(Pro도 가능, 사용량 한도만 다름)
  - `~/.claude/settings.json`의 권한 설정(auto 모드, deny 목록)이 그대로 적용됩니다.

## 구조

```
Discord ─@멘션/DM→ Hermes(ops) ─ ccproj run <프로젝트> "<작업>" → cd ~/projects/<프로젝트> && claude -c -p "<작업>"
                         ↑                                                │
                         └──────────── Claude 최종 답(텍스트) ←───────────┘  → Hermes가 요약해 스레드에 답장
```

- `claude -c`: 그 폴더의 마지막 대화를 이어갑니다. 이 옵션으로 프로젝트별 대화 맥락이 유지됩니다. 대화 기록은 `~/.claude/projects/-home-ubuntu-projects-<이름>/`에 쌓입니다.
- Hermes는 Discord 스레드마다 별도 세션을 씁니다. 서버 채널에서 ops를 `@멘션`하면 스레드가 새로 생기므로([04 문서](04-hermes-agent.md#discord-봇-만들기-ops--reader)의 `discord.auto_thread`, 기본 `true`), 프로젝트마다 스레드를 하나씩 쓰면 대화가 섞이지 않습니다. 이어서 작업할 때는 그 스레드 안에서 요청합니다.

## 절차

명령은 모두 `lab-assistant`에서 실행합니다(repo `$REPO`).

1. Wrapper [scripts/claude-projects/ccproj](../scripts/claude-projects/ccproj) → `~/.local/bin/ccproj` (755)

   ```bash
   # (lab-assistant)
   install -m 755 "$REPO/scripts/claude-projects/ccproj" ~/.local/bin/ccproj
   ```

   | 명령 | 동작 |
   |---|---|
   | `ccproj list` | 프로젝트 목록 |
   | `ccproj new <이름>` | `~/projects/<이름>` 생성 + `git init`. 이름은 `[a-z0-9-]`만 허용 |
   | `ccproj run <이름> "<작업>"` | 실행하고 끝날 때까지 기다립니다. 기본 최대 30분, 60턴 |
   | `ccproj bg <이름> "<작업>"` | 백그라운드로 실행합니다 |
   | `ccproj log <이름>` | 결과를 봅니다 |
   | `ccproj status <이름>` | running / idle |
   | `ccproj reset <이름>` | 그 프로젝트의 대화 기록을 `~/.local/state/ccproj/archive/`로 옮김. 다음 실행은 새 대화로 시작 |

   - 같은 프로젝트가 동시에 두 번 실행되지 않도록 `flock`으로 잠금을 겁니다.
   - 실행 기록은 `~/.local/state/ccproj/<이름>.log`에 남습니다.
   - 시간·턴 제한은 `CCPROJ_TIMEOUT`, `CCPROJ_MAX_TURNS` 환경변수로 바꿉니다.
   - 작업 내용은 옵션 뒤 `--` 다음에 넘기므로, `update`·`doctor`처럼 `claude` 하위 명령과 같은 한 단어여도 하위 명령이 아니라 프롬프트로 처리됩니다(2.1.306에서 확인).
2. Hermes 스킬 [scripts/claude-projects/SKILL.md](../scripts/claude-projects/SKILL.md) → `~/.hermes/skills/autonomous-ai-agents/claude-projects/SKILL.md`. ops에만 넣고 reader에는 넣지 않습니다.

   ```bash
   # (lab-assistant)
   install -D -m 644 "$REPO/scripts/claude-projects/SKILL.md" ~/.hermes/skills/autonomous-ai-agents/claude-projects/SKILL.md
   ```

3. 규칙은 05·06에서 적용한 예시에 이미 들어 있으므로 확인만 합니다.
   - `~/.hermes/SOUL.md`: "큰 작업은 `ccproj`로 맡기고 `claude`는 직접 부르지 않는다" (`grep -n ccproj ~/.hermes/SOUL.md`)
   - `~/.claude/CLAUDE.md`: "Discord reply 도구로 답한다"는 채널 세션(`--channels`)에서만, `claude -p` 실행에서는 텍스트로 답한다 (`grep -n 'claude -p' ~/.claude/CLAUDE.md`)
4. `systemctl --user restart hermes-gateway`

### 공식 `claude-code` 스킬을 쓰지 않는 이유

Hermes에는 `skills/autonomous-ai-agents/claude-code/SKILL.md`(754줄)가 들어 있습니다.

- 범용 안내서라 `--dangerously-skip-permissions` 사용법과 tmux로 권한 대화상자를 자동으로 누르는 방법까지 담고 있습니다. 스킬 레지스트리(tessl)에서도 Snyk 보안 등급 Critical로 표시돼 있습니다.
- 이 구성은 프로젝트 폴더 고정, Discord 플러그인 비활성화, 동시 실행 방지, 로그 기록만 하는 작은 wrapper로 대체합니다.

## 검증 (2026-10-21)

- 1회차: `ccproj run cc-test "hello.txt에 hi 쓰기"` → 파일이 생성됐습니다.
- 2회차: "지난번에 만든 파일은?" → `hello.txt`라고 답했습니다. 프로젝트별 대화 맥락이 유지됩니다.
- 3회차: "bye 줄 추가" → 10초 만에 완료됐습니다.
- `ccproj run ../etc ...` → 이름 규칙으로 거부됩니다.
- 실행 중에도 Discord 플러그인(bun) 프로세스는 상시 채널 세션의 1개뿐이며, 토큰 충돌이 없습니다.
- `hermes chat -q "claude-projects 스킬 보이니?"` → 스킬을 인식하고 `ccproj list`를 실행했습니다.

## Troubleshooting

- **`Warning: no stdin data received in 3s`**: `claude -p`가 표준입력을 기다리다 낸 경고입니다. `ccproj`는 `< /dev/null`로 표준입력을 막습니다.
- **`-p` 실행이 Discord 플러그인을 로드하려 함**: 플러그인이 사용자 범위로 켜져 있으면 `-p`에서도 로드됩니다. 같은 봇 토큰으로 두 번째 연결이 생기면 상시 세션과 충돌합니다. `ccproj`는 `--settings '{"enabledPlugins":{"discord@claude-plugins-official":false}}'`로 해당 실행에서만 플러그인을 끕니다.
- **Claude가 "Discord로 보내지 못했다"고 답함**: `~/.claude/CLAUDE.md`가 `-p` 실행에서도 Discord로 답하라고 지시하는 경우입니다. 3단계의 줄(예시 파일 첫 문단)이 있는지 확인합니다.
- **Hermes 터미널 timeout**: 오래 걸리는 작업은 `ccproj bg`로 실행하고 `ccproj log`로 확인하도록 스킬에 적혀 있습니다.
