# 07. 운영 봇에 OpenStack 권한 주기 (3중 방어 + GNS3 브리지 + Kali)

## 목적

- 운영 봇(Hermes ops 프로필, Claude Code)이 **실습용 VM을 직접 만들고 켜고 끌 수 있게** 합니다. 예: "Kali 하나 만들어서 GNS3 토폴로지에 붙여 줘".
- 봇이 실수하거나 프롬프트 인젝션을 당해도 기존 VM(lab-gns3, lab-assistant, lab-windows)과 네트워크를 지우거나 망가뜨리지 못하게 **세 겹으로** 막습니다.

| 층 | 무엇으로 | 막는 것 |
|---|---|---|
| 1 | 전용 프로젝트 `lab-agent` + 사용자 + 쿼터 | 다른 프로젝트 리소스는 보이지도 않음. 자원 사용량 상한 |
| 2 | Nova 정책 (`role:lab-agent` 거부 규칙) | 서버 삭제·rebuild·resize·스냅샷·lock·migrate·rescue·관리자 API |
| 3 | 애플리케이션 크리덴셜 access rules | 허용 목록에 없는 API 경로·메서드 전부(**DELETE는 어디에도 없음**), Keystone API도 차단 |
| (+) | 래퍼 `oslab` + 봇 규칙 + 명령 차단 패턴 | 봇이 실수로 위험한 명령을 시도하는 것 자체를 줄임 (보안 경계는 1~3) |

- 삭제는 **사람이 합니다**(Horizon 또는 admin CLI).
- 이 문서의 값(2026-10-21 구축 기준): Kolla-Ansible 2026.1 (kolla-ansible 22.2.x, Nova 33.0.x), python-openstackclient 10.4.0, Kali 2026.2.

## 사전조건

- [01](01-openstack-reset-and-base.md)~[06](06-claude-code.md) 완료. admin CLI를 쓸 수 있는 Kolla 호스트.
- 외부망 `provider`(router:external), 실습망 `lab-net`, VM lab-gns3 / lab-assistant 가 있음.
- 비밀값은 Kolla 호스트의 `~/lab-secrets.env`(권한 600)에만 둡니다. 저장소에는 넣지 않습니다.
- 자리표시자

| 자리표시자 | 예 (이 홈랩) |
|---|---|
| `<VIP>` | Kolla 내부 VIP `192.168.0.110` |
| `<PROVIDER_NET_ID>` | `openstack network show provider -f value -c id` |
| `<BRIDGE_PORT_MAC>` | `openstack port show lab-gns3-bridge -f value -c mac_address` |

아래에서 `os` 는 Kolla 호스트에서 admin 권한으로 `kolla_toolbox` 안의 `openstack` 을 부르는 셸 함수입니다.

```bash
set -a; source <(sudo cat /etc/kolla/admin-openrc.sh); set +a
E=$(env | grep ^OS_ | sed "s/^/-e /" | tr "\n" " ")
os(){ sudo docker exec $E kolla_toolbox openstack "$@"; }
```

## 절차

### 1. 프로젝트 · 사용자 · 역할 · 쿼터 (1층)

```bash
echo "LAB_AGENT_OS_PASSWORD=$(openssl rand -base64 30 | tr -d '/+=' | cut -c1-32)" >> ~/lab-secrets.env
PW=$(grep '^LAB_AGENT_OS_PASSWORD=' ~/lab-secrets.env | cut -d= -f2-)

os project create --domain default --description "AI ops bots sandbox" lab-agent
os role create lab-agent                      # 정책에서 "봇 토큰"을 식별하는 표시용 역할
os user create --domain default --project lab-agent --password "$PW" lab-agent
os role add --project lab-agent --user lab-agent member
os role add --project lab-agent --user lab-agent lab-agent
os quota set --instances 3 --cores 8 --ram 12288 --networks 3 --subnets 3 --ports 20 \
  --routers 1 --floating-ips 1 --secgroups 5 --secgroup-rules 50 lab-agent
```

- 쿼터는 하이퍼바이저 여유 RAM(약 14 GB)에 맞췄습니다. 여유에 맞게 조정하세요.

### 2. Nova 정책 (2층)

규칙 이름은 추측하지 말고 **돌아가는 서비스에서** 뽑습니다.

```bash
sudo docker exec nova_api oslopolicy-sample-generator --namespace nova --output-file /tmp/s.yaml
sudo docker exec nova_api grep -E '^#"os_compute_api:servers:(delete|rebuild|resize)' /tmp/s.yaml
```

각 규칙을 `<기본값> and not role:lab-agent` 로 덮어씁니다. 기본값을 그대로 두고 조건만 덧붙이므로 admin/member 동작은 바뀌지 않습니다. 전체 파일: [`scripts/openstack/nova-policy.yaml`](../scripts/openstack/nova-policy.yaml)

| 묶음 | 규칙 (모두 `... and not role:lab-agent`) |
|---|---|
| 관리자 전반 | `context_is_admin` = `role:admin and not role:lab-agent` (관리자 전용 API 전부) |
| 삭제 | `servers:delete`, `os-deferred-delete:force` |
| 재구성/이미지 | `servers:rebuild`, `servers:rebuild:trusted_certs`, `servers:create_image`, `servers:create_image:allow_volume_backed`, `os-create-backup`, `os-shelve:shelve`, `os-shelve:unshelve`, `servers:trigger_crash_dump` |
| resize | `servers:resize`, `servers:confirm_resize`, `servers:revert_resize` |
| lock | `os-lock-server:lock`, `os-lock-server:unlock` |
| 이동 | `os-migrate-server:migrate`, `os-migrate-server:migrate_live`, `servers:migrations:force_complete`, `servers:migrations:delete`, `os-evacuate` |
| rescue | `os-rescue`, `os-unrescue` |
| 관리 동작 | `os-admin-actions:reset_state`, `os-admin-actions:inject_network_info` |
| 분리 | `os-attach-interfaces:delete`, `os-volumes-attachments:delete` |

적용 전 백업하고, nova 태그만 reconfigure 합니다(다른 서비스 deploy/upgrade/prechecks 금지).

```bash
sudo mkdir -p /root/backups
sudo tar czf /root/backups/kolla-config-$(date +%Y%m%d-%H%M%S).tgz -C /etc/kolla config
sudo install -D -m 644 nova-policy.yaml /etc/kolla/config/nova/policy.yaml
sudo -i bash -c 'source /root/kolla-venv/bin/activate && \
  kolla-ansible reconfigure -i /root/all-in-one --tags nova > /root/backups/reconfigure-nova.log 2>&1; echo rc=$?'
```

- Kolla는 `/etc/kolla/config/nova/policy.yaml` 이 있으면 nova-api·nova-metadata(와 nova-compute)에 복사하고 `[oslo_policy] policy_file = policy.yaml` 을 넣습니다.
- 확인: `sudo ls /etc/kolla/nova-api/policy.yaml`, `sudo docker ps | grep nova` 가 모두 healthy.
- 이 홈랩에서는 nova_api·nova_metadata·nova_compute 컨테이너가 재시작됐고, 돌던 VM은 영향이 없었습니다(PLAY RECAP failed=0).

### 3. 애플리케이션 크리덴셜 + access rules (3층)

먼저 각 서비스의 `[keystone_authtoken]` 에 `service_type` 이 있어야 access rules가 적용됩니다. Kolla는 기본으로 넣습니다.

```bash
for f in nova-api/nova.conf neutron-server/neutron.conf glance-api/glance-api.conf; do
  sudo awk '/^\[keystone_authtoken\]/{p=1;next} /^\[/{p=0} p' /etc/kolla/$f | grep ^service_type; done
# service_type = compute / network / image
```

허용 목록: [`scripts/openstack/access_rules.json`](../scripts/openstack/access_rules.json)

| 서비스 | 메서드 | 경로 |
|---|---|---|
| compute | GET | `/v2.1/**` |
| compute | POST | `/v2.1/servers`, `/v2.1/servers/*/action` |
| image | GET | `/v2/**` |
| network | GET | `/v2.0/**` |
| network | POST | `/v2.0/networks`, `subnets`, `ports`, `routers`, `security-groups`, `security-group-rules`, `floatingips` |
| network | PUT | `/v2.0/routers/*/add_router_interface`, `/v2.0/routers/*` (외부 게이트웨이 설정) |

- `*` 는 경로 한 칸, `**` 는 여러 칸입니다. 경로는 버전 접두어(`/v2.1`)를 포함합니다.
- 버전 탐색(`GET /`, `GET :9292`)은 인증 없는 요청이라 따로 규칙이 필요 없었습니다(`--debug` 로 확인).
- `servers/*/action` 은 start/stop/reboot/콘솔 로그에 필요합니다. 같은 경로로 들어오는 rebuild/resize/lock 등은 2층(Nova 정책)이 막습니다.

크리덴셜은 **lab-agent 사용자 자신**이 만듭니다(비밀값은 직접 생성해 출력에 남지 않게).

```bash
echo "LAB_AGENT_APPCRED_SECRET=$(openssl rand -base64 48 | tr -d '/+=' | cut -c1-48)" >> ~/lab-secrets.env
SEC=$(grep '^LAB_AGENT_APPCRED_SECRET=' ~/lab-secrets.env | cut -d= -f2-)
la(){ sudo docker exec -e OS_AUTH_URL=http://<VIP>:5000 -e OS_IDENTITY_API_VERSION=3 \
  -e OS_USERNAME=lab-agent -e OS_PASSWORD="$PW" -e OS_PROJECT_NAME=lab-agent \
  -e OS_USER_DOMAIN_NAME=Default -e OS_PROJECT_DOMAIN_NAME=Default kolla_toolbox openstack "$@"; }
sudo docker cp access_rules.json kolla_toolbox:/tmp/access_rules.json
la application credential create lab-agent-bot --secret "$SEC" --role member --role lab-agent \
  --expiration 2027-10-21T00:00:00 --access-rules "$(cat access_rules.json)" -f value -c id
# 나온 id 를 LAB_AGENT_APPCRED_ID= 로 ~/lab-secrets.env 에 추가
```

- `--unrestricted` 를 주지 않습니다(기본 false). 그래서 이 크리덴셜로 다른 크리덴셜을 만들거나 지울 수 없습니다.
- 만료는 1년. 갱신 절차는 트러블슈팅 참고.

### 4. GNS3용 브리지 네트워크 `lab-bridge`

GNS3 Cloud 노드는 lab-gns3 VM의 NIC로 실제 프레임을 내보냅니다. GNS3 장비의 MAC/IP는 Neutron이 모르는 값이라 **port security를 꺼야** 통과합니다.

```bash
os network create --project admin --disable-port-security lab-bridge
os subnet create --network lab-bridge --subnet-range 10.20.30.0/24 --gateway none --dhcp \
  --allocation-pool start=10.20.30.10,end=10.20.30.99 lab-bridge-subnet
os network rbac create --target-project lab-agent --action access_as_shared --type network lab-bridge
os port create --network lab-bridge --disable-port-security \
  --fixed-ip subnet=lab-bridge-subnet,ip-address=10.20.30.5 lab-gns3-bridge
os server add port lab-gns3 lab-gns3-bridge          # 켜진 채로 NIC 추가(hot-plug)
```

주소 계획과 결정:

| 범위 | 용도 |
|---|---|
| 10.20.30.5 | lab-gns3 의 두 번째 NIC (`ens8`) |
| 10.20.30.10–99 | OpenStack DHCP (봇이 만드는 VM) |
| 10.20.30.100–250 | GNS3 장비 고정 IP |

- **게이트웨이 없음**: 인터넷·다른 망으로 새는 길이 없습니다. 격리된 실습 L2입니다.
- **DHCP 켬**: Kali VM이 IP와 메타데이터(cloud-init)를 받게 하려고 켰습니다. Neutron의 dnsmasq는 자기가 만든 포트의 MAC에만 응답하므로 GNS3 장비의 DHCP 요청과 섞이지 않습니다. 메타데이터는 DHCP 네임스페이스(`force_metadata = true`)가 169.254.169.254로 제공합니다.
- RBAC는 `lab-agent` 프로젝트에만 공유합니다(`shared=True` 아님).
- VXLAN이라 MTU는 1450입니다. GNS3 장비 MTU도 1450 이하로 두세요.

lab-gns3 안에서 NIC를 올립니다. 기본 경로는 ens3에 그대로 둡니다. 파일: [`scripts/openstack/netplan-60-lab-bridge.yaml`](../scripts/openstack/netplan-60-lab-bridge.yaml)

```bash
ip -br link                                   # 새 NIC 이름 확인 (이 홈랩: ens8)
sudo install -m 600 netplan-60-lab-bridge.yaml /etc/netplan/60-lab-bridge.yaml
sudo netplan generate && sudo netplan apply
ip -br addr show ens8; ip route | grep default # default 는 ens3 하나뿐이어야 함
```

GNS3가 Cloud 노드에 이 NIC를 보여 주도록 허용 목록에 추가하고 재시작합니다.

```bash
sudo sed -i 's/^allowed_interfaces = ens3,virbr0$/allowed_interfaces = ens3,virbr0,ens8/' \
  /home/gns3/.config/GNS3/3.1/gns3_server.conf
sudo systemctl restart gns3server
```

### 5. 이미지와 플레이버

**Kali**: 공식 **Generic Cloud Image (x64)** 가 있습니다(kali.org → Get Kali → Cloud). `tar.xz` 안에 `disk.raw`(GPT, 25 GiB, sparse) 하나가 들어 있고, cloud-init이 설치돼 있으며 기본 사용자는 `kali`(비밀번호 잠김, sudo NOPASSWD)입니다.

```bash
mkdir /var/tmp/kali-dl && cd /var/tmp/kali-dl
curl -fLO https://kali.download/cloud-images/kali-2026.2/SHA256SUMS
curl -fLO https://kali.download/cloud-images/kali-2026.2/kali-linux-2026.2-cloud-genericcloud-amd64.tar.xz
grep 'genericcloud-amd64.tar.xz$' SHA256SUMS | sha256sum -c -
```

- 검증: `cloud-images/` 디렉터리에는 `SHA256SUMS` 만 있고 GPG 서명(`SHA256SUMS.gpg`)이 없습니다. 그래서 **두 출처의 SHA256을 대조**했습니다. kali.download의 `SHA256SUMS` 와 https://www.kali.org/get-kali/ 페이지의 값이 같고(`3f4ca86a…0604f3e`, 2026.2 amd64), 다운로드 파일도 일치합니다.
- arm64 해시와 헷갈리지 않게 파일 이름으로 grep 하세요.

```bash
mkdir x && tar -xJf kali-linux-2026.2-cloud-genericcloud-amd64.tar.xz -C x --no-same-owner
qemu-img convert -O qcow2 x/disk.raw kali-2026.2-cloud-amd64.qcow2      # 25 GiB raw → 약 1 GiB
sudo docker cp kali-2026.2-cloud-amd64.qcow2 kolla_toolbox:/tmp/kali.qcow2
os image create --disk-format qcow2 --container-format bare --public --min-disk 25 --min-ram 2048 \
  --property os_distro=kali --property os_admin_user=kali --file /tmp/kali.qcow2 kali-cloud
sudo docker exec -u root kolla_toolbox rm -f /tmp/kali.qcow2
```

연결 테스트용으로 CirrOS 0.6.3도 올렸습니다(`SHA256SUMS` 로 검증, 이름 `cirros-0.6.3`, public).

플레이버:

```bash
os flavor create --vcpus 2 --ram 4096 --disk 40 --public lab.small
os flavor create --vcpus 2 --ram 8192 --disk 60 --public lab.medium
```

### 6. lab-assistant: 클라이언트 · `oslab` · 스킬

API 도달 확인(비서 VM 10.10.0.52 → VIP는 lab-router SNAT을 거쳐 닿습니다):

```bash
for p in 5000 8774 9292 9696; do curl -s -o /dev/null -w "$p %{http_code}\n" http://<VIP>:$p/; done
```

클라이언트는 전용 venv에 설치합니다.

```bash
python3 -m venv ~/.venvs/openstack
~/.venvs/openstack/bin/pip install python-openstackclient
```

`~/.config/openstack/clouds.yaml` (권한 600, 디렉터리 700). **`lab-agent` 항목 하나만** 둡니다. 비밀값은 Kolla 호스트에서 파이프로 바로 써서 화면에 남기지 않았습니다.

```yaml
clouds:
  lab-agent:
    auth_type: v3applicationcredential
    auth:
      auth_url: http://<VIP>:5000
      application_credential_id: "<LAB_AGENT_APPCRED_ID>"
      application_credential_secret: "<LAB_AGENT_APPCRED_SECRET>"
    region_name: RegionOne
    interface: public
    identity_api_version: 3
```

래퍼 `~/.local/bin/oslab` (파일: [`scripts/openstack/oslab`](../scripts/openstack/oslab), Python, `<PROVIDER_NET_ID>` 를 바꿔 넣으세요):

- 허용: `server list|show|create|start|stop|reboot`, `console log show`, `network|subnet|port|router|security group|security group rule|floating ip` 의 `list|show|create`, `router add subnet`, `router set <r> --external-gateway provider`, `image|flavor list|show`, `quota show`, `limits show`.
- 거부: 그 밖의 모든 명령(delete, rebuild, resize, set, unset, keypair, image create …).
- 만드는 리소스 이름은 `lab-` 로 시작해야 합니다.
- 항상 `--os-cloud lab-agent` 를 붙이고, `--os-*`, `--debug`, `--log-file` 같은 전역 옵션은 **줄임형까지** 거부합니다(argparse가 `--deb` 같은 접두어를 받아 주기 때문).
- `server create` 의 `--file`, `--host`, `--hint` 등은 거부하고, `--user-data` 는 `~/lab-userdata/` 안의 파일만 받습니다.
- 서버/포트를 외부망 `provider` 에 직접 붙이는 것을 거부합니다(아래 "남은 위험" 참고).
- `os.execve()` 에 인자 배열로 넘깁니다. 셸·eval을 쓰지 않고 환경 변수도 정리합니다(`OS_*` 제거, `OS_CLIENT_CONFIG_FILE` 고정).

```bash
install -m 755 oslab ~/.local/bin/oslab
mkdir -m 700 -p ~/lab-userdata
```

스킬 [`scripts/openstack/SKILL.md`](../scripts/openstack/SKILL.md) (Agent Skills 형식, frontmatter `name`/`description`)를 두 곳에 설치합니다. **reader 프로필에는 넣지 않습니다**(reader는 터미널 도구도 꺼져 있음).

```bash
install -D -m 644 SKILL.md ~/.hermes/skills/devops/openstack-lab/SKILL.md   # Hermes ops (HERMES_HOME=~/.hermes)
install -D -m 644 SKILL.md ~/.claude/skills/openstack-lab/SKILL.md          # Claude Code
```

봇 규칙에 한 단락씩 추가합니다.

- `~/.hermes/SOUL.md` (ops): "OpenStack 작업은 `oslab` 으로만 한다. `openstack` 을 직접 부르거나 `clouds.yaml` 을 읽지 않는다. 삭제·rebuild·resize·스냅샷은 사람이 한다. 새 리소스 이름은 `lab-`. 실습 VM은 끝나면 stop."
- `~/.claude/CLAUDE.md`: 같은 내용 한 줄.

명령 차단 패턴:

```yaml
# ~/.hermes/config.yaml → approvals.deny 에 추가 (fnmatch, 대소문자 무시)
    - '*openstack *'
    - '*openstack'
    - '*/.venvs/openstack/*'
    - '*.config/openstack*'
    - '*clouds.yaml*'
```

```json
// ~/.claude/settings.json → permissions.deny 에 추가
"Bash(openstack *)", "Bash(*/openstack *)", "Bash(*/.venvs/openstack/*)",
"Read(~/.config/openstack/**)", "Edit(~/.config/openstack/**)", "Edit(~/.local/bin/oslab)"
```

- Claude Code에서 `Bash(openstack:*)` 와 `Bash(openstack *)` 는 같은 뜻입니다. 문서는 공백 형식을 권장합니다.
- 이 패턴들은 봇이 흔히 쓰는 형태만 막습니다. 공식 문서도 "보안 경계가 아니다"라고 합니다. 진짜 경계는 1~3층입니다.
- 적용: `systemctl --user restart hermes-gateway`. 확인: `hermes skills list | grep openstack-lab` (ops에는 있고 `reader skills list` 에는 없어야 함).

## 검증

이 홈랩에서 2026-10-21에 실제로 돌린 결과입니다.

**허용되는 것** (lab-assistant에서 `oslab`)

| 명령 | 결과 |
|---|---|
| `oslab server list` | 빈 목록(자기 프로젝트만 보임. lab-gns3 등은 안 보임) |
| `oslab server create lab-test --image cirros-0.6.3 --flavor lab.small --network lab-bridge --wait` | ACTIVE, 10.20.30.78 (DHCP + 메타데이터 OK) |
| `oslab server stop lab-test` / `start` | SHUTOFF → ACTIVE |
| `oslab console log show lab-test` | 출력됨 |
| lab-gns3에서 `ping 10.20.30.78` | 0% loss (lab-bridge L2 동작) |
| network/subnet/router 생성, `router add subnet`, `router set --external-gateway provider`, SG·SG rule 생성, `floating ip create provider` | 모두 성공 |

**거부되는 것** (래퍼 없이 `~/.venvs/openstack/bin/openstack --os-cloud lab-agent` 로 직접)

| 시도 | 응답 | 막은 층 |
|---|---|---|
| `server delete` | 401 | access rules (DELETE 없음) |
| `server set --name` (PUT) | 401 | access rules |
| `network delete`, `subnet delete`, `port delete`, `image delete` | 401 | access rules |
| `keypair create`, `application credential list`, `user list` | 401 | access rules (Keystone 포함) |
| `server rebuild`, `resize`, `lock`, `rescue`, `server image create` | 403 Policy doesn't allow … | Nova 정책 |
| `server list --all-projects` | 403 | Nova 정책 |

**정책만으로도 막히는지** (access rules가 없는 lab-agent 비밀번호 로그인): `server delete`, `server lock`, `server migrate` → 모두 403. 2층이 따로 동작합니다.

**래퍼 거부 예**: `server delete`, `server set`, `--os-cloud admin`, `--deb`, `--log-f`, 이름 `kali`(접두어 없음), `--file`, `--user-data /etc/passwd`, `keypair create`, `--network provider` → 모두 실행 전에 거부.

**admin은 그대로**: `os server list --all-projects`, `os hypervisor list` 정상. 테스트 리소스는 admin으로 정리했습니다.

**GNS3**: `GET /v3/computes/local/network/interfaces` 응답에 `ens8`(10.20.30.5)가 나옵니다. `GET /v3/version` → 3.1.0a6.

## 전체 admin 권한 주기 (이 구성의 최종 선택)

위의 lab-agent 구성은 "봇은 자기 프로젝트에서만, 삭제 불가"인 최소 권한입니다. 실제 운영에서는 봇이 기존 VM 관리와 정리까지 해야 해서, **admin 권한도 함께** 줬습니다. lab-agent·`oslab`은 그대로 두고, admin 경로를 하나 더 둡니다.

**판단 근거**
- Claude Code는 auto 모드로 씁니다. 읽기·조회 명령은 묻지 않고, 위험해 보이는 것만 묻습니다. 모든 명령에 Allow를 누르는 방식은 실사용이 불가능합니다.
- 대신 되돌릴 수 없는 사고를 줄이는 장치를 둡니다.

| 장치 | 내용 |
|---|---|
| admin **application credential** | 사용자 비밀번호 대신 폐기 가능한 키. `lab-admin-bot`, 역할 admin, 만료 1년 |
| `osadmin` 래퍼 | `openstack --os-cloud lab-admin` 에 인자를 그대로 넘기고 **감사 로그** `~/.local/state/osadmin/audit.log` 를 남김 (시간, 호출자, 인자, 종료 코드) |
| 핵심 VM Nova **lock** | `lab-gns3`, `lab-assistant`, `lab-windows`. admin은 풀 수 있으므로 실수 방지용 한 겹 |
| 규칙 (SOUL.md / CLAUDE.md / 스킬) | 핵심 리소스(위 VM, provider·lab-net·lab-bridge·lab-router, sg-*, Keystone, 기본 이미지)는 바꾸거나 지우기 전에 사용자에게 묻기. `lab-` 실습 리소스는 묻지 않고 정리 가능 |
| `openstack` 직접 호출 차단 | Hermes `approvals.deny` 의 `*openstack *` 패턴, Claude Code `Bash(openstack *)` deny → 반드시 로그가 남는 `osadmin` 경유 |

**절차**

1. admin 키를 만듭니다. Kolla 호스트에서 admin으로 실행합니다. 출력 JSON의 키 이름이 `ID`·`Secret`처럼 대문자일 수 있으니 소문자로 바꿔 읽습니다.

   ```bash
   openstack application credential create lab-admin-bot --role admin --expiration 2027-10-21T00:00:00 -f json > /tmp/cred.json
   ```

2. 비서 VM `~/.config/openstack/clouds.yaml`(600)에 `lab-admin` 클라우드를 추가합니다. 형식은 `lab-agent`와 같고 `auth_type: v3applicationcredential` 입니다. 임시 파일은 `shred -u`로 지웁니다.
3. 래퍼 [scripts/openstack/osadmin](../scripts/openstack/osadmin) → `~/.local/bin/osadmin` (755)
4. 스킬 [scripts/openstack/openstack-admin/SKILL.md](../scripts/openstack/openstack-admin/SKILL.md) → Hermes `~/.hermes/skills/devops/openstack-admin/`, Claude Code `~/.claude/skills/openstack-admin/`. reader 프로필에는 넣지 않습니다.
5. 핵심 VM을 잠급니다.

   ```bash
   osadmin server lock --reason "core homelab VM - ask user before unlock/delete" lab-gns3
   ```

   `lab-assistant`, `lab-windows` 도 같은 명령으로 잠급니다.
6. 규칙 파일을 갱신하고 Hermes 게이트웨이를 재시작합니다: [scripts/hermes/SOUL.ops.rules.example.md](../scripts/hermes/SOUL.ops.rules.example.md), [scripts/claude-code/CLAUDE.md.example](../scripts/claude-code/CLAUDE.md.example)

**검증 (2026-10-21)**
- `osadmin server list --all-projects` → 세 VM 모두 보이고, 감사 로그에 기록이 남습니다.
- 세 VM 모두 `locked=True` 입니다.
- 잠긴 상태에서도 `ssh winpower start/stop` 은 정상입니다. 전원 명령은 admin 권한으로 실행되기 때문입니다.
- lab-agent 키로는 핵심 VM이 보이지 않습니다(`No Server found`).

**폐기**: 키가 유출됐거나 봇을 믿기 어려워지면 아래 한 줄로 끊습니다. lab-agent 경로는 계속 동작합니다.

```bash
openstack application credential delete lab-admin-bot
```

## 남은 위험 (알고 쓰기)

- **외부망 직접 연결 → 해결함 (provider 공유 해제)**
  - 문제: 처음에는 `provider`가 `shared=True`였습니다. Nova의 `network:attach_external_network` 검사는 공유된 외부망에는 적용되지 않아서, 래퍼를 거치지 않으면 lab-agent가 사용자 LAN(192.168.0.0/24)에 VM을 바로 붙일 수 있었습니다.
  - 조치: `openstack network set --no-share provider`.
    - 기존 VM들은 provider에 직접 붙지 않고 Floating IP만 씁니다. provider 포트는 `network:floatingip` 3개와 `network:router_gateway` 1개뿐입니다.
    - 외부망(`router:external=True`)은 공유하지 않아도 모든 프로젝트가 라우터 게이트웨이와 Floating IP로 쓸 수 있습니다.
  - 검증 (2026-10-21, 앱 크리덴셜로 래퍼 없이 직접 호출):
    - `port create --network provider` → `403 ... not allowed to create port on this network`
    - `server create --network provider` → `ERROR: Failed to allocate the network(s)`
    - `network list --external` → provider가 보임 (라우터 게이트웨이용)
    - 기존 Floating IP와 VM 접속은 정상입니다.
  - 대안: Neutron 정책으로 `role:lab-agent`의 provider 포트 생성을 막는 방법도 있습니다([`scripts/openstack/neutron-policy.proposed.yaml`](../scripts/openstack/neutron-policy.proposed.yaml), `reconfigure --tags neutron` 필요). 공유 해제만으로 충분해서 적용하지 않았습니다.
- 쿼터 안에서는 VM을 계속 만들 수 있습니다(최대 3대/12 GB). 지우는 것은 사람이 해야 하므로 주기적으로 `os server list --project lab-agent` 를 확인하세요.
- Hermes의 기존 차단 패턴 `*reboot*` 때문에 Hermes에서 `oslab server reboot` 은 막힙니다(stop/start로 대신). `*authorized_keys*` 때문에 터미널 명령으로 `ssh_authorized_keys` 가 든 user-data 파일을 쓰는 것도 막힙니다(파일 도구로 쓰거나 사람이 준비).

## 트러블슈팅

| 증상 | 원인 / 해결 |
|---|---|
| 허용했어야 할 명령이 401 | access rules에 없는 경로입니다. `~/.venvs/openstack/bin/openstack --os-cloud lab-agent --debug <명령> 2>&1 \| grep -E '^REQ: curl\|^RESP:'` 로 메서드·경로를 보고 **최소 규칙만** 추가합니다. 기존 크리덴셜의 규칙은 바꿀 수 없으니 새 크리덴셜을 만들고 clouds.yaml을 바꾼 뒤 옛 것을 지웁니다(사람이, 비밀번호 로그인으로). |
| 401인데 경로는 맞음 | 해당 서비스 `[keystone_authtoken]` 에 `service_type` 이 없으면 규칙이 맞지 않습니다. |
| 403 Policy doesn't allow … | 2층이 막은 것입니다. 의도한 동작이면 사람에게 넘깁니다. |
| reconfigure 후 nova 컨테이너 unhealthy | `/root/backups/reconfigure-nova*.log` 확인. 되돌리기: `/etc/kolla/config/nova/policy.yaml` 삭제(또는 백업 tgz 복원) 후 다시 `reconfigure --tags nova`. |
| oslo.policy 문법 확인 | `oslopolicy-validator` 는 2026.1에서 `--policy` 옵션이 없습니다. 컨테이너 안에서 `oslo_policy.Enforcer` 로 규칙을 불러 `enforce()` 를 직접 시험하는 편이 확실합니다. |
| VM이 DHCP를 못 받음 | 서브넷 DHCP가 켜져 있는지, 포트가 10.20.30.10–99에서 잡혔는지 확인. |
| GNS3 Cloud 노드에 ens8 이 안 보임 | `allowed_interfaces` 에 넣고 `gns3server` 를 재시작했는지 확인. |
| GNS3 장비 ↔ Kali 통신 안 됨 | port security가 꺼졌는지(`os port show <포트> -c port_security_enabled`), MTU 1450, 장비 IP가 .100–.250 인지 확인. |
| 크리덴셜 만료(1년) | lab-agent 비밀번호로 로그인해 새 크리덴셜을 만들고(3절) clouds.yaml 교체. |
| `hermes skills list` 에 안 보임 | 경로가 `~/.hermes/skills/<카테고리>/<이름>/SKILL.md` 인지, frontmatter `name`/`description` 이 있는지 확인. 대화 중이면 `/reload-skills`. |

## 출처

- Keystone Application Credentials (access rules 형식, 와일드카드, `service_type` 요구): https://docs.openstack.org/keystone/latest/user/application_credentials.html
- oslo.policy 정책 파일 문법(`and`, `not`, `role:`): https://docs.openstack.org/oslo.policy/latest/admin/policy-yaml-file.html
- Nova 정책 기본값: https://docs.openstack.org/nova/latest/configuration/policy.html
- Kolla-Ansible 정책 덮어쓰기(`/etc/kolla/config/<서비스>/policy.yaml`): https://docs.openstack.org/kolla-ansible/latest/admin/advanced-configuration.html
- Neutron RBAC (`access_as_shared`): https://docs.openstack.org/neutron/latest/admin/config-rbac.html
- Kali 다운로드(Cloud 이미지, SHA256): https://www.kali.org/get-kali/#kali-cloud , https://kali.download/cloud-images/
- CirrOS: https://download.cirros-cloud.net/0.6.3/
- Hermes Agent Skills: https://hermes-agent.nousresearch.com/docs/user-guide/features/skills
- Claude Code 권한 규칙: https://code.claude.com/docs/en/permissions , 스킬: https://code.claude.com/docs/en/skills
