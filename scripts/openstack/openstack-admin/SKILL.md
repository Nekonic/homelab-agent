---
name: openstack-admin
description: 홈랩 OpenStack 전체를 admin 권한으로 다루는 방법. `osadmin` 명령(= openstack --os-cloud lab-admin, 감사 로그 남김)을 쓴다. VM·네트워크·이미지·flavor·프로젝트 생성/변경/삭제, 다른 프로젝트 리소스 관리. 보호 리소스(아래 목록)를 변경·삭제하기 전에는 사용자에게 먼저 확인한다.
version: 1.0.0
platforms: [linux]
metadata:
  hermes:
    category: devops
    tags: [openstack, admin, homelab]
---

# openstack-admin

## 사용법

- 모든 OpenStack 작업은 `osadmin <openstack 하위 명령>` 으로 한다. 예: `osadmin server list --all-projects`, `osadmin server create ...`.
- `openstack` 을 직접 호출하지 않는다. `osadmin` 만 감사 로그(`~/.local/state/osadmin/audit.log`)를 남긴다.
- Credential 파일(`~/.config/openstack/clouds.yaml`)은 읽지 않는다.
- 실습 VM(Kali 등)은 기존처럼 `oslab server create ...` 로 `lab-agent` 프로젝트에 만들면 quota 안에서 관리된다. admin 프로젝트에 직접 만들 때도 이름은 `lab-` 로 시작한다.

## 보호 리소스 (변경·삭제 전 반드시 사용자에게 확인)

auto 모드여도 아래는 실행 전에 채팅으로 무엇을 할지 말하고 사용자의 "응/해" 답을 받는다.

| 종류 | 이름 |
|---|---|
| VM (Nova lock 걸려 있음) | `lab-gns3`, `lab-assistant`(이 봇이 실행되는 VM), `lab-windows` |
| 네트워크 | `provider`(외부망), `lab-net`, `lab-bridge`, 라우터 `lab-router` |
| 보안 그룹 | `sg-assistant`, `sg-gns3`, `sg-windows` |
| Keystone | 사용자·역할·프로젝트·application credential 전부 |
| 이미지 | `ubuntu-24.04`, `win11`, `kali-cloud` |

- 잠긴 VM의 `server unlock` 도 위 목록과 같이 사용자에게 확인한 뒤 실행한다.
- `lab-assistant` 를 끄거나 지우면 이 봇 자신이 멈춘다.

## 자주 쓰는 명령

```bash
osadmin server list --all-projects
osadmin server show <이름>
osadmin server create --flavor lab.small --image kali-cloud --network lab-bridge --key-name lab-key lab-kali-1
osadmin server stop|start <이름>
osadmin server delete <이름>            # lab- 로 시작하고 내가 만든 실습 VM만. 보호 리소스는 확인 후
osadmin hypervisor stats show            # 생성 전 남은 메모리/디스크 확인
osadmin quota show lab-agent
```

- 메모리 여유가 적다(중지된 VM도 flavor만큼 메모리를 예약). 생성 전에 `hypervisor stats show` 의 free_ram_mb 를 본다.
- Windows VM 전원은 `ssh winpower start|stop|status` 를 그대로 써도 된다.
