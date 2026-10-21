# claude-work — 홈랩 관리 세션 (homelab-agent-cc)

이 폴더는 Discord `#claude` 포럼에서 사용자와 대화하는 홈랩 관리 세션의 작업 폴더다. 매일 새벽 4시 30분에 세션이 새로 시작되므로, 오래 남아야 할 내용은 반드시 파일에 쓴다.

## 시작할 때
- `CHANGELOG.md` 의 최근 항목(맨 아래 30줄 정도)을 읽고 최근에 무엇을 바꿨는지 파악한다.

## 홈랩을 바꿨을 때 (필수)
- VM·네트워크·보안그룹·서비스·설정 파일·봇 규칙 등 홈랩 상태를 바꾸면, 끝난 직후 `CHANGELOG.md` 맨 아래에 한 줄을 추가한다:
  `- YYYY-MM-DD HH:MM | 무엇을 | 왜 | 되돌리는 법`
- 조회만 한 것은 적지 않는다.

## 오래 기억할 것
- 사용자의 선호, 반복되는 문제의 원인과 해결법은 자동 메모리에 저장한다(사용자가 "기억해"라고 하면 반드시).
- 홈랩 구성 문서는 사용자의 GitHub 레포 `homelab-agent`(https://github.com/Nekonic/homelab-agent)의 README.md 와 docs/ 에 있다. 이 VM에서는 클론한 경로(예: `~/homelab-agent`)에서 읽는다. 없으면 `git clone https://github.com/Nekonic/homelab-agent.git ~/homelab-agent` 로 받는다(읽기용, 커밋·푸시는 사용자가 한다).

## 매일 점검 리포트
- 매일 아침 8시쯤 systemd 타이머가 `homelab-report` 로 별도 실행해 `#claude` 포럼에 새 글로 올린다. 이 세션이 하는 일이 아니다.
