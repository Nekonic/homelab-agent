---
name: claude-projects
description: 프로젝트별로 Claude Code(사용자의 Claude Max 구독, 공식 claude 프로그램)에 코딩·문서·스크립트 작업을 맡긴다. `ccproj` 명령을 쓴다. 프로젝트마다 ~/projects/<이름> 폴더와 Claude의 대화 기억이 따로 유지된다. 사용자가 "○○ 프로젝트에서 ~해줘", "클로드한테 시켜" 라고 하거나 코드 작성·리팩터링·문서 작성처럼 큰 작업일 때 쓴다.
version: 1.0.0
platforms: [linux]
metadata:
  hermes:
    category: autonomous-ai-agents
    tags: [claude-code, projects, delegation]
---

# claude-projects

## 명령

```bash
ccproj list                         # 프로젝트 목록
ccproj new <이름>                   # ~/projects/<이름> 생성 (git init). 이름은 소문자·숫자·하이픈
ccproj run <이름> "<작업 설명>"      # 실행하고 끝날 때까지 기다림 (최대 30분). Claude의 최종 답이 출력됨
ccproj bg  <이름> "<작업 설명>"      # 오래 걸릴 작업은 백그라운드로
ccproj log <이름> [줄 수]            # 실행 기록 보기 (bg 결과 확인)
ccproj status <이름>                 # running / idle
ccproj reset <이름>                  # 그 프로젝트의 Claude 대화를 새로 시작 (사용자가 원할 때만)
```

## 규칙

- 같은 프로젝트에서 다시 `run` 하면 Claude가 그 프로젝트의 지난 대화를 이어서 기억한다. 프로젝트를 섞지 않는다.
- 사용자가 프로젝트 이름을 말하지 않았으면 `ccproj list` 를 보여주고 어느 프로젝트인지 묻는다. 새 프로젝트는 사용자가 원할 때만 만든다.
- 작업 설명은 Claude가 맥락 없이도 알 수 있게 구체적으로 쓴다(목표, 대상 파일, 끝났을 때의 상태).
- 5분 넘게 걸릴 것 같으면 `bg` 로 돌리고, 사용자에게 시작했다고 알린 뒤 `ccproj log` 로 결과를 확인해 요약한다.
- Claude의 답을 그대로 붙여넣지 말고, 무엇을 바꿨는지 짧게 요약해서 사용자에게 전한다.
- `claude` 를 직접 부르지 않는다(`ccproj` 가 디스코드 플러그인을 끄고, 기록을 남기고, 동시 실행을 막는다).
- 사용량은 사용자의 Claude Max 한도에서 빠진다. 짧은 질문은 Claude에 넘기지 말고 직접 답한다.
