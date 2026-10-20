# 셀프호스트 AI 비서 에이전트 조사 (2026-10)

홈랩에서 상시 구동할 AI 비서 에이전트를 고르기 위해 2026-10-21 기준으로 조사한 결과입니다.
스타 수와 릴리스는 GitHub API로 직접 조회했고, 1차 출처로 확인하지 못한 내용은 **[미검증]**으로 표시했습니다.

## 요구사항

- Ubuntu 24.04 VM에서 헤드리스 상시 구동 (systemd)
- Discord 봇 + 사용자 허용 목록
- MCP 클라이언트 (원격 SSE/HTTP + 커스텀 헤더, stdio)
- OpenRouter / OpenCode Zen 모델 (구독 OAuth는 쓰지 않음, 아래 정책 참고)
- 위험 명령 사람 승인, Gmail·캘린더·Notion 연동

## 결론

**Hermes Agent를 유지합니다.** 갈아탈 결정적 이유가 없습니다.

- 최근 5개월 성장세가 가장 큽니다 (스타 +60%, PyPI 주간 다운로드 약 3.4배, OpenRouter 앱 사용량 일간 2위).
- 문서화된 기본값 기준으로 OpenClaw보다 안전합니다 (OpenClaw는 exec full / ask off / sandbox off가 기본).
- OpenRouter와 OpenCode Zen을 기본 공급자로 지원하고, `fallback_providers`로 폴백 체인을 구성할 수 있습니다.

대안을 시험해 본다면 **ZeroClaw**를 권합니다. Rust 단일 바이너리이고, 기본이 supervised(승인 필요) 모드이며, MCP가 기본 거부입니다.

## 인기 순위 (개인 비서 범주)

| 프로젝트 | ★ (10/20) | 5/21 대비 | 최신 릴리스 | 비고 |
|---|---|---|---|---|
| openclaw/openclaw | 392,969 | +5% | v2026.10.5 (10-18) | 가장 크지만 정체. 보안 사고 이력이 큼 |
| NousResearch/hermes-agent | 255,486 | **+60%** | v0.22.2 (10-15) | 급상승. 실사용량은 OpenClaw를 추월 |
| HKUDS/nanobot | 49,217 | +15% | v0.3.5 (09-15) | 가벼움. 위험 명령 승인 기능이 약함 |
| zeroclaw-labs/zeroclaw | 33,016 | +5% | v0.8.6 (10-18) | 보안 기본값이 엄격함. 유력한 대안 |
| nanocoai/nanoclaw | 30,981 | +6% | v2026.10.0 (10-09) | 컨테이너 격리 최고 수준. Claude SDK 중심 |
| sipeed/picoclaw | 30,083 | +3% | v0.3.1 (07-03) | 둔화 |
| NVIDIA/NemoClaw | 22,776 | +11% | 없음 | 독립 에이전트가 아니라 OpenClaw·Hermes용 보안 래퍼 (알파) |
| nearai/ironclaw | 12,668 | +3% | v1.4.1 (09-29) | WASM 샌드박스. Gmail·Notion 통합 |

트렌드:

- 경량 *Claw 포크들의 성장은 +3~7%에 그칩니다.
- 관심은 보안·격리 레이어(NemoClaw, OpenShell 등)와 메모리 레이어로 옮겨 가고 있습니다.

## 보안 사건 (2025–2026)

- **OpenClaw**
  - CVE-2026-25253 (8.8, 원클릭 RCE): 2026.1.29에서 수정.
  - 인터넷 노출 인스턴스 4만~13.5만 개.
  - ClawHub 악성 스킬 341개 이상 (ClawHavoc, 2026-01~02).
- **Hermes**
  - CVE-2026-9353 (0.15.0에서 수정).
  - CVE-2026-14625 (≤0.15.2): 현재 버전에서 해결됐는지는 **[미검증]**.
  - SECURITY.md는 프롬프트 인젝션 단독 공격과 서드파티 스킬을 보안 범위 밖으로 명시합니다.
- **구독 OAuth 계정 정지**
  - Google: 2026-02부터 서드파티 도구에서 Antigravity OAuth를 쓴 계정을 대량 정지했습니다.
  - Anthropic: 2026-04부터 서드파티 하네스 사용분을 별도 과금합니다.

## 정책 (1차 출처)

- **Google**: 서드파티 도구로 Antigravity에 접근하면 ToS 위반이고 계정 정지 사유입니다. 대신 AI Studio·Enterprise API 키를 쓰라고 권합니다 ([FAQ](https://antigravity.google/docs/faq)).
- **Anthropic**: 구독 OAuth는 Claude Code와 자사 앱에서만 쓸 수 있습니다. 개발자는 API 키를 써야 합니다 ([법무 페이지](https://code.claude.com/docs/en/legal-and-compliance)).
- **Claude Code의 Discord Channels**는 claude.ai 계정 또는 Console 키가 필요합니다. OpenRouter 인증으로는 쓸 수 없습니다.

## 무료 모델 현실

- **OpenRouter `:free`**
  - 분당 20회.
  - 하루 50회. 누적 크레딧을 $10 이상 구매하면 하루 1,000회로 늘어납니다 ([한도 문서](https://openrouter.ai/docs/api/reference/limits)).
- **OpenCode Zen 무료 모델**
  - 기간 한정이고 결제 정보 등록이 필요합니다.
  - 모델마다 데이터 정책이 다릅니다 ([Zen 문서](https://opencode.ai/docs/zen)).
    - 보관·학습 안 함: GLM / DeepSeek / MiniMax Flash Free 등
    - 학습에 쓰일 수 있음: Big Pickle, MiMo 등
  - 메일·메신저 원문은 데이터를 보관하지 않는 모델에만 보내세요.
- 무료·소형 모델은 도구 호출 형식 준수와 인젝션 저항력이 약합니다. 실행 권한이 있는 작업에는 유료 모델을 권합니다.

## 이 구성에 반영할 것

| 영역 | 기존 계획 | 변경·추가 |
|---|---|---|
| 비서 | Hermes + ChatGPT OAuth | Hermes + ChatGPT Plus(주) + OpenRouter 무료 모델(폴백). `auth.adopt_external_logins: false`. OpenCode Zen은 제외(키 없는 무료 사용은 OpenCode 앱 전용, API 키는 결제 등록 필요) |
| 역할 분리 | Bot Mode | Bot Mode는 분리 기능이 아님. 읽기 전용 프로필(실행 toolset 끔)과 실행 프로필(manual 승인, 본인 DM만)을 따로 구성하고, 둘 사이 `message_agent`로 원문을 넘기지 않음 |
| GNS3 | 서드파티 MCP | 내장 MCP(3.1). 내장 GNS3 Copilot은 HITL이 없는 알파라 GUI 보조로만 사용 |
| 장비 설정 | 콘솔에 `device_config_send` | 콘솔로는 IP·SSH만 부트스트랩. 이후 설정은 [netmiko_mcp](https://github.com/ktbyers/netmiko_mcp)(명령 허용 목록 기반) |
| 윈도우 조작 | mcp-vnc | [Windows-MCP](https://github.com/CursorTouch/Windows-MCP)(★9.7k, UI Automation 기반, `--auth-key`)를 주로 쓰고, mcp-vnc는 로그인·UAC 화면용 예비로 둠 |
| Claude Code | Max 구독 + Discord Channels | Max 구독을 쓸 때만 유효. OpenRouter로 통일하려면 OpenCode + [kimaki](https://github.com/remorses/kimaki)(Discord)로 대체 |

## 출처

- GitHub API, [GitHub trending](https://github.com/trending?since=monthly), [OpenRouter apps](https://openrouter.ai/apps), [pypistats](https://pypistats.org/api/packages/hermes-agent/recent)
- Hermes:
  - [보안](https://hermes-agent.nousresearch.com/docs/user-guide/security/)
  - [공급자](https://hermes-agent.nousresearch.com/docs/integrations/providers)
  - [폴백](https://hermes-agent.nousresearch.com/docs/user-guide/features/fallback-providers)
  - [Bot Mode](https://hermes-agent.nousresearch.com/docs/user-guide/bot-mode)
- OpenClaw:
  - [보안](https://docs.openclaw.ai/gateway/security)
  - [exec 승인](https://docs.openclaw.ai/tools/exec-approvals)
- 사건:
  - [CVE-2026-25253](https://thehackernews.com/2026/02/openclaw-bug-enables-one-click-remote.html)
  - [ClawHub 악성 스킬](https://thehackernews.com/2026/02/researchers-find-341-malicious-clawhub.html)
  - [Google 계정 정지](https://gigazine.net/gsc_news/en/20260224-google-gemini-openclaw-accounts-banned)
  - [Hermes CVE-2026-9353](https://advisories.gitlab.com/pypi/hermes-agent/CVE-2026-9353/)
- 비교:
  - [glukhov.org 인기 비교](https://www.glukhov.org/ai-systems/comparisons/openclaw-hermes-alternatives-popularity/)
  - [Kilo: Reddit 의견](https://kilo.ai/articles/openclaw-vs-hermes-what-reddit-says)
- 한국:
  - [GeekNews 28605](https://news.hada.io/topic?id=28605)
  - [위키독스 Hermes 설정](https://wikidocs.net/346252)
- 네트워크·윈도우 도구:
  - [GNS3 AI 어시스턴트](https://docs.gns3.com/docs-3.1-en/ai-tools/use-ai-assistant)
  - [netbox-mcp-server](https://github.com/netboxlabs/netbox-mcp-server)
  - [mcp-server-vyos](https://github.com/cacack/mcp-server-vyos)
