# 08. Hermes → Claude Code 프로젝트 위임 (`ccproj`)

## 목적

- 디스코드에서는 Hermes(ops)에게만 말하고, 큰 코딩·문서·스크립트 작업은 Hermes가 **Claude Code(Claude Max 구독)**에 맡깁니다.
- 프로젝트마다 폴더 `~/projects/<이름>`과 **Claude의 대화 기억이 따로** 유지됩니다. 상시 Claude 디스코드 봇은 세션 하나에 모든 대화가 섞이는데, 그 문제가 없습니다.
- 약관: 수정하지 않은 공식 `claude` 프로그램에 본인 구독 계정으로 로그인해서 쓰는 방식이라 허용 범위입니다([Claude Code 법무·인증 정책](https://code.claude.com/docs/en/legal-and-compliance)). 사용량은 구독 한도에서 빠집니다.

## 사전조건

- [04](04-hermes-agent.md)의 Hermes(ops)
- [06](06-claude-code.md)의 Claude Code 로그인
  - `claude auth status`에서 `authMethod: claude.ai`, `subscriptionType: max` 확인
  - `~/.claude/settings.json`의 권한 설정(auto 모드, deny 목록)이 그대로 적용됩니다.

## 구조

```
Discord ─@멘션/DM→ Hermes(ops) ─ ccproj run <프로젝트> "<작업>" → cd ~/projects/<프로젝트> && claude -c -p "<작업>"
                         ↑                                                │
                         └──────────── Claude 최종 답(텍스트) ←───────────┘  → Hermes가 요약해 스레드에 답장
```

- `claude -c`: 그 폴더의 마지막 대화를 이어갑니다. 이것으로 프로젝트별 기억이 생깁니다. 대화 기록은 `~/.claude/projects/-home-ubuntu-projects-<이름>/`에 쌓입니다.
- Hermes는 디스코드 스레드마다 세션이 따로입니다. **프로젝트마다 스레드를 하나씩** 쓰면 깔끔합니다.

## 절차

1. 래퍼 [scripts/claude-projects/ccproj](../scripts/claude-projects/ccproj) → `~/.local/bin/ccproj` (755)

   | 명령 | 동작 |
   |---|---|
   | `ccproj list` | 프로젝트 목록 |
   | `ccproj new <이름>` | `~/projects/<이름>` 생성 + `git init`. 이름은 `[a-z0-9-]`만 허용 |
   | `ccproj run <이름> "<작업>"` | 실행하고 끝날 때까지 기다립니다. 기본 최대 30분, 60턴 |
   | `ccproj bg <이름> "<작업>"` | 백그라운드로 실행합니다 |
   | `ccproj log <이름>` | 결과를 봅니다 |
   | `ccproj status <이름>` | running / idle |

   - 같은 프로젝트를 동시에 두 번 돌리지 않게 `flock`으로 잠급니다.
   - 실행 기록은 `~/.local/state/ccproj/<이름>.log`에 남습니다.
   - 시간·턴 제한은 `CCPROJ_TIMEOUT`, `CCPROJ_MAX_TURNS` 환경변수로 바꿉니다.
2. Hermes 스킬 [scripts/claude-projects/SKILL.md](../scripts/claude-projects/SKILL.md) → `~/.hermes/skills/autonomous-ai-agents/claude-projects/SKILL.md`. ops에만 넣고 reader에는 넣지 않습니다.
3. `~/.hermes/SOUL.md`에 규칙 한 줄을 추가합니다. 큰 작업은 `ccproj`로 맡기고, `claude`는 직접 부르지 않는다는 내용입니다.
4. `~/.claude/CLAUDE.md`의 "Discord reply 도구로 답한다"는 **채널 세션에서만** 적용되게 고칩니다. `-p` 실행에서는 텍스트로 답합니다.
5. `systemctl --user restart hermes-gateway`

### 왜 공식 `claude-code` 스킬을 그대로 쓰지 않나

Hermes에는 `skills/autonomous-ai-agents/claude-code/SKILL.md`(754줄)가 들어 있습니다.

- 범용 안내서라 `--dangerously-skip-permissions` 사용법과 tmux로 권한 대화상자를 자동으로 누르는 방법까지 담고 있습니다. Snyk가 Critical로 표시한 이유로 보입니다.
- 여기서는 프로젝트 폴더 고정, 디스코드 플러그인 끄기, 동시 실행 방지, 로그만 하는 작은 래퍼로 대신합니다.

## 검증 (2026-10-21)

- 1회차: `ccproj run cc-test "hello.txt에 hi 쓰기"` → 파일이 생성됐습니다.
- 2회차: "지난번에 만든 파일은?" → `hello.txt`라고 답했습니다. 프로젝트별 기억이 유지됩니다.
- 3회차: "bye 줄 추가" → 10초 만에 완료됐습니다.
- `ccproj run ../etc ...` → 이름 규칙으로 거부됩니다.
- 실행 중에도 디스코드 플러그인(bun) 프로세스는 상시 채널 세션의 1개뿐입니다. 토큰 충돌이 없습니다.
- `hermes chat -q "claude-projects 스킬 보이니?"` → 스킬을 인식하고 `ccproj list`를 실행했습니다.

## 트러블슈팅

- **`Warning: no stdin data received in 3s`**: `claude -p`가 표준입력을 기다린 것입니다. `ccproj`는 `< /dev/null`로 막습니다.
- **`-p` 실행이 디스코드 플러그인을 띄우려 함**: 플러그인이 사용자 범위로 켜져 있으면 `-p`에서도 로드됩니다. 같은 봇 토큰으로 두 번째 연결이 생기면 상시 세션과 충돌합니다. `ccproj`는 `--settings '{"enabledPlugins":{"discord@claude-plugins-official":false}}'`로 그 실행에서만 끕니다.
- **Claude가 "Discord로 보내지 못했다"고 답함**: `~/.claude/CLAUDE.md`가 디스코드 답장을 지시하고 있는 것입니다. 4단계처럼 고칩니다.
- **Hermes 터미널 타임아웃**: 오래 걸리는 작업은 `ccproj bg`로 돌리고 `ccproj log`로 확인하게 스킬에 적어 두었습니다.
