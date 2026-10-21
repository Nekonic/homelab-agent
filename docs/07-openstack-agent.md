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

> 이 3중 방어는 **lab-agent 경로**에 대한 것입니다. 최종 구성은 봇에게 admin 키(`osadmin`)도 함께 줬으므로([전체 admin 권한 주기](#전체-admin-권한-주기-이-구성의-최종-선택)), 실제로는 감사 로그와 실수 방지 장치에 기댑니다. 한계는 [알려진 한계](#알려진-한계)에 정리했습니다.

- lab-agent 경로(`oslab`)로는 삭제할 수 없습니다. 봇이 만든 `lab-` 실습 리소스는 admin 경로(`osadmin`)로 봇이 정리하고, 그 밖의 삭제는 사람이 확인합니다.
- 이 문서의 값(2026-10-21 구축 기준): Kolla-Ansible 2026.1 (kolla-ansible 22.2.x, Nova 33.0.x), python-openstackclient 10.4.0, Kali 2026.2.

- **외부 통신(egress)은 제한하지 않습니다(사용자 선택).** 비서 VM에서 나가는 연결을 허용된 API(Discord, 모델 API 등)로만 좁히는 방식은 적용하지 않았습니다. 봇이 sudo와 OpenStack admin을 가진 상태에서는 비서 VM 안의 방화벽이나 보안그룹 egress 규칙은 봇이 스스로 풀 수 있어 실효가 낮다고 판단했습니다. 필요해지면 방화벽을 봇이 건드릴 수 없는 곳(예: Kolla 호스트의 프록시 + 허용 목록)에 두고, 승인은 봇이 모르는 비밀번호로 하는 방식을 권합니다.

## 사전조건

- [01](01-openstack-reset-and-base.md)~[06](06-claude-code.md) 완료. admin CLI를 쓸 수 있는 Kolla 호스트.
- 외부망 `provider`(router:external), 실습망 `lab-net`, VM lab-gns3 / lab-assistant 가 있음.
- 레포가 Kolla 호스트와 비서 VM 양쪽에 클론돼 있고 `$REPO`가 지정돼 있음([README](../README.md#시작하기-레포-받기)). 양쪽 셸에 [README](../README.md#비밀값-관리)의 `setenv`(Kolla 호스트는 `sec`도) 함수, Kolla 호스트 `~/.ssh/config`에 [01 문서 D-5](01-openstack-reset-and-base.md#d-5-kolla-호스트-ssh-별칭)의 `lab-assistant`/`lab-gns3` 별칭.
- 비밀값은 Kolla 호스트의 `~/lab-secrets.env`(권한 600)에만 둡니다. 저장소에는 넣지 않습니다.
- 명령마다 실행하는 머신을 `# (Kolla 호스트)`, `# (비서 VM)`, `# (lab-gns3)`로 표시했습니다.
- 자리표시자

| 자리표시자 | 예 (이 홈랩) |
|---|---|
| `<VIP>` | Kolla 내부 VIP `192.168.0.110` |
| `<PROVIDER_NET_ID>` | `os network show provider -f value -c id` |
| `<BRIDGE_PORT_MAC>` | `os port show lab-gns3-bridge -f value -c mac_address` |
| `<KOLLA_VENV>` | kolla-ansible을 설치한 venv 경로 (예: `/root/kolla-venv`) |
| `<INVENTORY>` | kolla-ansible 인벤토리 파일 (예: `/root/all-in-one`) |

아래에서 `os` 는 Kolla 호스트에서 admin 권한으로 `kolla_toolbox` 안의 `openstack` 을 부르는 셸 함수입니다.

```bash
set -a; source <(sudo cat /etc/kolla/admin-openrc.sh); set +a
E=$(env | grep ^OS_ | sed "s/^/-e /" | tr "\n" " ")
os(){ sudo docker exec $E kolla_toolbox openstack "$@"; }
```

## 절차

### 1. 프로젝트 · 사용자 · 역할 · 쿼터 (1층)

```bash
# (Kolla 호스트) 비밀번호를 만들어 lab-secrets.env 에 (있으면 교체)
openssl rand -base64 30 | tr -d '/+=' | cut -c1-32 | setenv LAB_AGENT_OS_PASSWORD - ~/lab-secrets.env
PW=$(sec LAB_AGENT_OS_PASSWORD)

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
# (Kolla 호스트)
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
# (Kolla 호스트) <KOLLA_VENV>, <INVENTORY> 는 자기 kolla-ansible 설치에 맞게
sudo mkdir -p /root/backups
sudo tar czf /root/backups/kolla-config-$(date +%Y%m%d-%H%M%S).tgz -C /etc/kolla config
sudo install -D -m 644 "$REPO/scripts/openstack/nova-policy.yaml" /etc/kolla/config/nova/policy.yaml
sudo -i bash -c 'source <KOLLA_VENV>/bin/activate && \
  kolla-ansible reconfigure -i <INVENTORY> --tags nova > /root/backups/reconfigure-nova.log 2>&1; echo rc=$?'
```

- `<KOLLA_VENV>`·`<INVENTORY>`는 kolla-ansible을 처음 배포할 때 쓴 venv와 인벤토리입니다(공식 quickstart 기본은 venv 아래 `share/kolla-ansible/ansible/inventory/all-in-one`를 복사해 쓴 파일). root로 배포했다면 `sudo -i`, 일반 사용자로 했다면 그 사용자로 실행합니다.

- Kolla는 `/etc/kolla/config/nova/policy.yaml` 이 있으면 nova-api·nova-metadata(와 nova-compute)에 복사하고 `[oslo_policy] policy_file = policy.yaml` 을 넣습니다.
- 확인: `sudo ls /etc/kolla/nova-api/policy.yaml`, `sudo docker ps | grep nova` 가 모두 healthy.
- 이 홈랩에서는 nova_api·nova_metadata·nova_compute 컨테이너가 재시작됐고, 돌던 VM은 영향이 없었습니다(PLAY RECAP failed=0).

### 3. 애플리케이션 크리덴셜 + access rules (3층)

먼저 각 서비스의 `[keystone_authtoken]` 에 `service_type` 이 있어야 access rules가 적용됩니다. Kolla는 기본으로 넣습니다.

```bash
# (Kolla 호스트)
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
# (Kolla 호스트) 1절의 PW 가 정의된 셸에서
openssl rand -base64 48 | tr -d '/+=' | cut -c1-48 | setenv LAB_AGENT_APPCRED_SECRET - ~/lab-secrets.env
SEC=$(sec LAB_AGENT_APPCRED_SECRET)
la(){ sudo docker exec -e OS_AUTH_URL=http://<VIP>:5000 -e OS_IDENTITY_API_VERSION=3 \
  -e OS_USERNAME=lab-agent -e OS_PASSWORD="$PW" -e OS_PROJECT_NAME=lab-agent \
  -e OS_USER_DOMAIN_NAME=Default -e OS_PROJECT_DOMAIN_NAME=Default kolla_toolbox openstack "$@"; }
umask 077
la application credential create lab-agent-bot --secret "$SEC" --role member --role lab-agent \
  --expiration 2027-10-21T00:00:00 --access-rules "$(cat "$REPO/scripts/openstack/access_rules.json")" \
  -f json > ~/lab-agent-cred.json
# id 를 lab-secrets.env 에 (JSON 키가 ID/id 어느 쪽이어도 되게 소문자로 읽음)
python3 -c 'import json,sys; print({k.lower(): v for k, v in json.load(open(sys.argv[1])).items()}["id"])' ~/lab-agent-cred.json \
  | setenv LAB_AGENT_APPCRED_ID - ~/lab-secrets.env
unset SEC
# ~/lab-agent-cred.json 은 6절에서 비서 VM clouds.yaml 을 쓴 뒤 지웁니다
```

- `--unrestricted` 를 주지 않습니다(기본 false). 그래서 이 크리덴셜로 다른 크리덴셜을 만들거나 지울 수 없습니다.
- 만료는 1년. 갱신 절차는 트러블슈팅 참고.

### 4. GNS3용 브리지 네트워크 `lab-bridge`

GNS3 Cloud 노드는 lab-gns3 VM의 NIC로 실제 프레임을 내보냅니다. GNS3 장비의 MAC/IP는 Neutron이 모르는 값이라 **port security를 꺼야** 통과합니다.

```bash
# (Kolla 호스트)
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
| 10.20.30.10–99 | OpenStack 할당 풀. 첫 주소 `.10`은 Neutron DHCP 포트가 가져가므로 봇이 만드는 VM은 `.11`부터 받습니다 |
| 10.20.30.100–250 | GNS3 장비 고정 IP |

- **게이트웨이 없음**: 인터넷·다른 망으로 새는 길이 없습니다. 격리된 실습 L2입니다.
- **DHCP 켬**: Kali VM이 IP와 메타데이터(cloud-init)를 받게 하려고 켰습니다. Neutron의 dnsmasq는 자기가 만든 포트의 MAC에만 응답하므로 GNS3 장비의 DHCP 요청과 섞이지 않습니다. 메타데이터는 DHCP 네임스페이스(`force_metadata = true`)가 169.254.169.254로 제공합니다.
- RBAC는 `lab-agent` 프로젝트에만 공유합니다(`shared=True` 아님).
- VXLAN이라 MTU는 1450입니다. GNS3 장비 MTU도 1450 이하로 두세요.

lab-gns3 안에서 NIC를 올립니다. 기본 경로는 ens3에 그대로 둡니다. 파일: [`scripts/openstack/netplan-60-lab-bridge.yaml`](../scripts/openstack/netplan-60-lab-bridge.yaml). `<BRIDGE_PORT_MAC>`을 채워 Kolla 호스트에서 lab-gns3로 복사합니다(lab-gns3에는 레포가 없음).

```bash
# (Kolla 호스트)
MAC=$(os port show lab-gns3-bridge -f value -c mac_address)
sed "s/<BRIDGE_PORT_MAC>/$MAC/" "$REPO/scripts/openstack/netplan-60-lab-bridge.yaml" > /tmp/60-lab-bridge.yaml
scp /tmp/60-lab-bridge.yaml lab-gns3: && rm /tmp/60-lab-bridge.yaml
ssh lab-gns3
```

```bash
# (lab-gns3)
ip -br link                                   # 새 NIC 이름 확인 (이 홈랩: ens8). 다르면 파일의 ens8 을 바꿈
sudo install -m 600 60-lab-bridge.yaml /etc/netplan/60-lab-bridge.yaml && rm 60-lab-bridge.yaml
sudo netplan generate && sudo netplan apply
ip -br addr show ens8; ip route | grep default # default 는 ens3 하나뿐이어야 함
```

GNS3가 Cloud 노드에 이 NIC를 보여 주도록 허용 목록에 추가하고 재시작합니다.

```bash
# (lab-gns3)
sudo sed -i 's/^allowed_interfaces = ens3,virbr0$/allowed_interfaces = ens3,virbr0,ens8/' \
  /home/gns3/.config/GNS3/3.1/gns3_server.conf
sudo systemctl restart gns3server
```

### 5. 이미지와 플레이버

**Kali**: 공식 **Generic Cloud Image (x64)** 가 있습니다(kali.org → Get Kali → Cloud). `tar.xz` 안에 `disk.raw`(GPT, 25 GiB, sparse) 하나가 들어 있고, cloud-init이 설치돼 있으며 기본 사용자는 `kali`(비밀번호 잠김, sudo NOPASSWD)입니다.

```bash
# (Kolla 호스트)
mkdir /var/tmp/kali-dl && cd /var/tmp/kali-dl
curl -fLO https://kali.download/cloud-images/kali-2026.2/SHA256SUMS
curl -fLO https://kali.download/cloud-images/kali-2026.2/kali-linux-2026.2-cloud-genericcloud-amd64.tar.xz
grep 'genericcloud-amd64.tar.xz$' SHA256SUMS | sha256sum -c -
```

- 검증: `cloud-images/` 디렉터리에는 `SHA256SUMS` 만 있고 GPG 서명(`SHA256SUMS.gpg`)이 없습니다. 그래서 **두 출처의 SHA256을 대조**했습니다. kali.download의 `SHA256SUMS` 와 https://www.kali.org/get-kali/ 페이지의 값이 같고(`3f4ca86a…0604f3e`, 2026.2 amd64), 다운로드 파일도 일치합니다.
- arm64 해시와 헷갈리지 않게 파일 이름으로 grep 하세요.

`qemu-img`는 Kolla 호스트의 `qemu-utils` 패키지에 있습니다(없으면 `sudo apt install -y qemu-utils`).

```bash
# (Kolla 호스트)
command -v qemu-img || sudo apt install -y qemu-utils
mkdir x && tar -xJf kali-linux-2026.2-cloud-genericcloud-amd64.tar.xz -C x --no-same-owner
qemu-img convert -O qcow2 x/disk.raw kali-2026.2-cloud-amd64.qcow2      # 25 GiB raw → 약 1 GiB
sudo docker cp kali-2026.2-cloud-amd64.qcow2 kolla_toolbox:/tmp/kali.qcow2
sudo docker exec -u 0 kolla_toolbox chmod a+r /tmp/kali.qcow2    # umask 077 셸에서 만든 파일은 0600 그대로 복사됨
os image create --disk-format qcow2 --container-format bare --public --min-disk 25 --min-ram 2048 \
  --property os_distro=kali --property os_version=2026.2 --property os_type=linux \
  --property os_admin_user=kali --property hw_disk_bus=virtio --property hw_vif_model=virtio \
  --property source_url=https://kali.download/cloud-images/kali-2026.2/kali-linux-2026.2-cloud-genericcloud-amd64.tar.xz \
  --property source_sha256="$(grep 'genericcloud-amd64.tar.xz$' SHA256SUMS | cut -d' ' -f1)" \
  --file /tmp/kali.qcow2 kali-cloud
sudo docker exec -u 0 kolla_toolbox rm -f /tmp/kali.qcow2
```

- 속성: `os_distro`/`os_version`/`os_type`는 이미지 식별용, `os_admin_user=kali`는 기본 사용자 안내, `hw_disk_bus`/`hw_vif_model=virtio`는 디스크·NIC를 virtio로, `source_url`/`source_sha256`은 출처와 원본 tar.xz의 SHA256 기록용입니다. `min_disk 25`(GB)는 압축 전 raw 크기, `min_ram 2048`(MB)는 최소 메모리입니다.
- `Permission denied`로 `--file`을 못 읽으면 위 `chmod a+r`을 빠뜨린 것입니다(컨테이너 안 `openstack`은 root가 아닌 사용자로 돔).

연결 테스트용으로 CirrOS 0.6.3도 올렸습니다(`SHA256SUMS` 로 검증, 이름 `cirros-0.6.3`, public).

플레이버:

```bash
# (Kolla 호스트)
os flavor create --vcpus 2 --ram 4096 --disk 40 --public lab.small
os flavor create --vcpus 2 --ram 8192 --disk 60 --public lab.medium
```

### 6. lab-assistant: 클라이언트 · `oslab` · 스킬

API 도달 확인(비서 VM `<ASSISTANT_LAB_IP>` → VIP는 lab-router SNAT을 거쳐 닿습니다):

```bash
# (비서 VM)
for p in 5000 8774 9292 9696; do curl -s -o /dev/null -w "$p %{http_code}\n" http://<VIP>:$p/; done
```

클라이언트는 전용 venv에 설치합니다.

```bash
# (비서 VM)
python3 -m venv ~/.venvs/openstack
~/.venvs/openstack/bin/pip install python-openstackclient
```

`~/.config/openstack/clouds.yaml` (권한 600, 디렉터리 700). 이 단계에서는 **`lab-agent` 항목 하나**를 둡니다(`lab-admin`은 아래 admin 절에서 추가). 3절에서 만든 크리덴셜 JSON을 비서 VM으로 옮겨, 아래 함수로 clouds.yaml에 씁니다. 비밀값은 화면에 나오지 않고, 임시 JSON은 `shred`로 지웁니다.

```bash
# (Kolla 호스트) 3절의 JSON을 비서 VM으로 옮기고 원본 삭제
ssh lab-assistant 'mkdir -p -m 700 ~/.config/openstack'
scp ~/lab-agent-cred.json lab-assistant:.config/openstack/lab-agent-cred.json && shred -u ~/lab-agent-cred.json
```

```bash
# (비서 VM) addcloud <cloud 이름> <크리덴셜 JSON> <auth_url> : clouds.yaml 에 그 항목을 쓰거나 교체하고 JSON 은 shred
addcloud() {
  ~/.venvs/openstack/bin/python - "$1" "$2" "$3" <<'PY'
import json, os, sys, yaml
name, src, url = sys.argv[1:4]
d = {k.lower(): v for k, v in json.load(open(src)).items()}   # -f json 의 키는 ID/Secret 처럼 대문자일 수 있음
path = os.path.expanduser("~/.config/openstack/clouds.yaml")
conf = (yaml.safe_load(open(path)) if os.path.exists(path) else None) or {}
conf.setdefault("clouds", {})[name] = {
    "auth_type": "v3applicationcredential",
    "auth": {"auth_url": url,
             "application_credential_id": d["id"],
             "application_credential_secret": d["secret"]},
    "region_name": "RegionOne", "interface": "public", "identity_api_version": 3}
os.umask(0o077)
with open(path + ".tmp", "w") as f:
    yaml.safe_dump(conf, f, default_flow_style=False, sort_keys=False)
os.replace(path + ".tmp", path)
print("clouds.yaml:", name, "written")
PY
  shred -u "$2"
}
addcloud lab-agent ~/.config/openstack/lab-agent-cred.json http://<VIP>:5000
chmod 700 ~/.config/openstack; ls -l ~/.config/openstack     # clouds.yaml 600, *.json 없음
```

결과 형식:

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

래퍼 `~/.local/bin/oslab` (파일: [`scripts/openstack/oslab`](../scripts/openstack/oslab), Python, 설치할 때 `<PROVIDER_NET_ID>`를 실제 ID로 바꿈):

- 허용: `server list|show|create|start|stop|reboot`(create는 `--config-drive` 포함), `console log show`, `network|subnet|port|router|security group|security group rule|floating ip` 의 `list|show|create`, `router add subnet`, `router set <r> --external-gateway provider`, `image|flavor list|show`, `quota show`, `limits show`.
- 거부: 그 밖의 모든 명령(delete, rebuild, resize, set, unset, keypair, image create …).
- 만드는 리소스 이름은 `lab-` 로 시작해야 합니다.
- 항상 `--os-cloud lab-agent` 를 붙이고, `--os-*`, `--debug`, `--log-file` 같은 전역 옵션은 **줄임형까지** 거부합니다(argparse가 `--deb` 같은 접두어를 받아 주기 때문).
- `server create` 는 네트워크(`--network`, `--nic net-id=`, `--port`)를 반드시 하나 이상 적어야 합니다(없으면 Nova가 네트워크를 알아서 고를 수 있음). `--file`, `--host`, `--hint` 등은 거부하고, `--user-data` 는 `~/lab-userdata/` 안의 파일만 받습니다(`--u` 같은 줄임형 포함).
- 서버/포트를 외부망 `provider` 에 직접 붙이는 것을 거부합니다(아래 "남은 위험" 참고).
- `os.execve()` 에 인자 배열로 넘깁니다. 셸·eval을 쓰지 않고 환경 변수도 정리합니다(`OS_*` 제거, `OS_CLIENT_CONFIG_FILE` 고정).

```bash
# (Kolla 호스트) provider 네트워크 ID 확인 → 아래 <PROVIDER_NET_ID> 자리에
os network show provider -f value -c id
```

```bash
# (비서 VM)
mkdir -p ~/.local/bin && mkdir -m 700 -p ~/lab-userdata
sed 's/<PROVIDER_NET_ID>/<위에서 확인한 ID>/' "$REPO/scripts/openstack/oslab" > /tmp/oslab \
  && install -m 755 /tmp/oslab ~/.local/bin/oslab && rm /tmp/oslab
grep '^EXTERNAL_NET_ID' ~/.local/bin/oslab        # 실제 UUID 가 들어갔는지
```

스킬 [`scripts/openstack/SKILL.md`](../scripts/openstack/SKILL.md) (Agent Skills 형식, frontmatter `name`/`description`)를 두 곳에 설치합니다. **reader 프로필에는 넣지 않습니다**(reader는 터미널 도구도 꺼져 있음).

```bash
# (비서 VM)
install -D -m 644 "$REPO/scripts/openstack/SKILL.md" ~/.hermes/skills/devops/openstack-lab/SKILL.md   # Hermes ops (HERMES_HOME=~/.hermes)
install -D -m 644 "$REPO/scripts/openstack/SKILL.md" ~/.claude/skills/openstack-lab/SKILL.md          # Claude Code
```

**봇 규칙**: 05·06에서 붙인 예시 규칙([SOUL.ops.rules.example.md](../scripts/hermes/SOUL.ops.rules.example.md), [CLAUDE.md.example](../scripts/claude-code/CLAUDE.md.example))이 이미 최종본이라 OpenStack 규칙(`osadmin`/`oslab`, 핵심 리소스는 묻기)이 들어 있습니다. 새로 붙이지 않고 들어 있는지만 확인합니다.

**명령 차단 패턴**도 예시 파일에 이미 들어 있습니다. 확인만 합니다.

- Hermes `approvals.deny` ([config.ops.example.yaml](../scripts/hermes/config.ops.example.yaml), reader도 같은 목록 [config.reader.example.yaml](../scripts/hermes/config.reader.example.yaml)): `'*openstack *'`, `'*openstack'`, `'*/.venvs/openstack/*'`, `'*.config/openstack*'`, `'*clouds.yaml*'`
- Claude Code `permissions.deny` ([settings.permissions.example.json](../scripts/claude-code/settings.permissions.example.json)): `Bash(openstack *)`, `Bash(*/openstack *)`, `Bash(*/.venvs/openstack/*)`, `Read`/`Edit(~/.config/openstack/**)`, `Bash(*clouds.yaml*)`, 래퍼·감사 로그 `Edit(~/.local/bin/oslab)`, `Edit(~/.local/bin/osadmin)`, `Edit(~/.local/bin/ccproj)`, `Edit(~/.local/bin/homelab-report)`, `Edit(~/.local/state/osadmin/**)`

```bash
# (비서 VM) 확인
grep -c 'openstack\|clouds.yaml' ~/.hermes/config.yaml                 # 0 이 아니어야 함
grep -o '"Bash(openstack \*)"' ~/.claude/settings.json                  # 한 줄 나와야 함
grep -c 'osadmin' ~/.hermes/SOUL.md ~/.claude/CLAUDE.md                # 둘 다 0 이 아니어야 함
```

- Claude Code에서 `Bash(openstack:*)` 와 `Bash(openstack *)` 는 같은 뜻입니다. 문서는 공백 형식을 권장합니다.
- 이 패턴들은 봇이 흔히 쓰는 형태만 막습니다. 공식 문서도 "보안 경계가 아니다"라고 합니다. lab-agent 키에 대한 진짜 경계는 1~3층입니다(admin 경로는 [알려진 한계](#알려진-한계) 참고).
- 적용: `systemctl --user restart hermes-gateway`. 확인: `hermes skills list | grep openstack-lab`는 한 줄 나오고, `hermes -p reader skills list | grep openstack`는 아무것도 나오지 않아야 합니다.

## 검증

검증 (2026-10-21) 결과입니다.

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

**래퍼 거부 예**: `server delete`, `server set`, `--os-cloud admin`, `--deb`, `--log-f`, 이름 `kali`(접두어 없음), `--file`, `--user-data /etc/passwd`(`--u /etc/passwd` 포함), `keypair create`, `--network provider`, 네트워크 없는 `server create` → 모두 실행 전에 거부. `--config-drive true`가 붙은 `server create ... --network lab-bridge`는 통과(만든 뒤 admin으로 삭제).

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
| `osadmin` 래퍼 | `openstack --os-cloud lab-admin` 에 인자를 그대로 넘기고 **감사 로그** `~/.local/state/osadmin/audit.log` 를 남김 (시간, 호출자, 작업 폴더, 인자, 종료 코드). 비밀 옵션 값은 `***`로 가림(아래) |
| 핵심 VM Nova **lock** | `lab-gns3`, `lab-assistant`, `lab-windows`. admin은 풀 수 있으므로 실수 방지용 한 겹 |
| 규칙 (SOUL.md / CLAUDE.md / 스킬) | 핵심 리소스(위 VM, provider·lab-net·lab-bridge·lab-router, sg-*, Keystone, 기본 이미지)는 바꾸거나 지우기 전에 사용자에게 묻기. `lab-` 실습 리소스는 묻지 않고 정리 가능 |
| `openstack` 직접 호출 차단 | Hermes `approvals.deny` 의 `*openstack *` 패턴, Claude Code `Bash(openstack *)` deny → 반드시 로그가 남는 `osadmin` 경유 |

**절차**

1. admin 키를 만들어 `~/lab-secrets.env`에 보관하고, JSON을 비서 VM으로 옮깁니다. 출력 JSON의 키 이름이 `ID`·`Secret`처럼 대문자일 수 있으니 소문자로 바꿔 읽습니다.

   ```bash
   # (Kolla 호스트) os 헬퍼(admin)와 setenv 가 정의된 셸에서
   umask 077
   os application credential create lab-admin-bot --role admin --expiration 2027-10-21T00:00:00 -f json > ~/lab-admin-cred.json
   for k in id secret; do
     python3 -c 'import json,sys; print({k.lower(): v for k, v in json.load(open(sys.argv[1])).items()}[sys.argv[2]])' ~/lab-admin-cred.json $k \
       | setenv LAB_ADMIN_APPCRED_$(echo $k | tr a-z A-Z) - ~/lab-secrets.env
   done
   scp ~/lab-admin-cred.json lab-assistant:.config/openstack/lab-admin-cred.json && shred -u ~/lab-admin-cred.json
   ```

2. 비서 VM `clouds.yaml`에 `lab-admin` 항목을 추가합니다. 6절의 `addcloud` 함수를 그대로 씁니다(새 셸이면 함수를 다시 붙여 넣음). JSON은 함수가 `shred`로 지웁니다.

   ```bash
   # (비서 VM)
   addcloud lab-admin ~/.config/openstack/lab-admin-cred.json http://<VIP>:5000
   ~/.venvs/openstack/bin/openstack --os-cloud lab-admin token issue -f value -c expires   # 동작 확인 (사람이 직접)
   ```

3. 래퍼 [scripts/openstack/osadmin](../scripts/openstack/osadmin) → `~/.local/bin/osadmin` (755)

   ```bash
   # (비서 VM)
   install -m 755 "$REPO/scripts/openstack/osadmin" ~/.local/bin/osadmin
   ```

   - 감사 로그 `~/.local/state/osadmin/audit.log`(600, 디렉터리 700)는 래퍼가 처음 실행될 때 만듭니다.
   - **비밀값 가림**: 이름에 `pass`·`secret`·`token`이 들어간 옵션의 값, 그리고 옵션 이름(`--` 뒤, `=` 앞)이 비밀 옵션 이름(`password`, `original-password`, `new-password`, `secret`, `admin-pass`, `os-password`, `os-token`, `os-access-token`, `os-client-secret`, `os-passcode`, `os-application-credential-secret`)의 **앞부분과 한 글자라도 일치**하면(argparse 줄임형: `--p`, `--or`, `--se`, `--os-to` …) 그 값을 로그에 `***`로 남깁니다. `credential create`/`credential set` 뒤의 위치 인자(크리덴셜 내용)도 가립니다. `--opt X`, `--opt=X` 두 형태 모두입니다. `--o`, `--s`처럼 짧은 줄임형은 비밀이 아닌 옵션까지 가리지만(과하게 가리는 쪽을 택함), 실제 명령에는 원래 값이 그대로 넘어갑니다.
   - 인자는 `printf %q` 로 따옴표 처리해 한 줄에 남기므로, 줄바꿈이 든 인자로 로그 줄을 꾸며 넣을 수 없습니다.
   - 확인 (없는 사용자라 명령은 실패하고 아무것도 바뀌지 않지만, 로그 형식과 종료 코드는 확인됨):

     ```bash
     # (비서 VM)
     osadmin --se test-only-value user show nonexistent-user; echo "rc=$?"         # rc=2 (openstack 의 종료 코드 그대로)
     osadmin user show --password=test-only-value nonexistent-user; echo "rc=$?"
     tail -n 4 ~/.local/state/osadmin/audit.log    # --se *** / --password=*** , exit=2
     grep -c test-only-value ~/.local/state/osadmin/audit.log    # 0
     ```

4. 스킬 [scripts/openstack/openstack-admin/SKILL.md](../scripts/openstack/openstack-admin/SKILL.md)를 설치합니다. reader 프로필에는 넣지 않습니다.

   ```bash
   # (비서 VM)
   install -D -m 644 "$REPO/scripts/openstack/openstack-admin/SKILL.md" ~/.hermes/skills/devops/openstack-admin/SKILL.md
   install -D -m 644 "$REPO/scripts/openstack/openstack-admin/SKILL.md" ~/.claude/skills/openstack-admin/SKILL.md
   ```

5. 핵심 VM을 잠급니다.

   ```bash
   # (비서 VM)
   for vm in lab-gns3 lab-assistant lab-windows; do
     osadmin server lock --reason "core homelab VM - ask user before unlock/delete" "$vm"
   done
   ```

6. 규칙 파일은 05·06에서 붙인 최종 예시([SOUL.ops.rules.example.md](../scripts/hermes/SOUL.ops.rules.example.md), [CLAUDE.md.example](../scripts/claude-code/CLAUDE.md.example))에 admin 규칙이 이미 있습니다. 확인만 하고 Hermes 게이트웨이를 재시작합니다(`systemctl --user restart hermes-gateway`).
7. 06에서 미뤄 둔 매일 점검 타이머를 켭니다(`osadmin`이 생겼으므로).

   ```bash
   # (비서 VM)
   systemctl --user enable --now homelab-report.timer
   systemctl --user list-timers     # 04:30 claude-discord-restart, 08:03 homelab-report
   ```

**검증 (2026-10-21)**
- `osadmin server list --all-projects` → 세 VM 모두 보이고, 감사 로그에 기록이 남습니다.
- 세 VM 모두 `locked=True` 입니다.
- 잠긴 상태에서도 `ssh winpower start/stop` 은 정상입니다. 전원 명령은 admin 권한으로 실행되기 때문입니다.
- lab-agent 키로는 핵심 VM이 보이지 않습니다(`No Server found`).

**폐기**: 키가 유출됐거나 봇을 믿기 어려워지면 아래 한 줄로 끊습니다. lab-agent 경로는 계속 동작합니다.

```bash
# (Kolla 호스트) admin 헬퍼
os application credential delete lab-admin-bot
```

## 남은 위험 (알고 쓰기)

- **왜 외부망 `provider`를 공유하지 않는가**
  - 외부망을 공유(`shared=True`)하면 Nova의 `network:attach_external_network` 검사가 적용되지 않습니다. 그러면 래퍼를 거치지 않은 lab-agent 키로도 VM을 사용자 LAN에 **직접** 붙일 수 있습니다.
  - 그래서 `provider`는 `router:external=True`만 두고 공유하지 않습니다([01 문서 B-1](01-openstack-reset-and-base.md#b-1-provider-네트워크-재생성)). 이미 공유돼 있다면 `os network set --no-share provider`.
    - 외부망은 공유하지 않아도 모든 프로젝트가 라우터 게이트웨이와 Floating IP로 쓸 수 있습니다.
    - 핵심 VM은 provider에 직접 붙지 않고 Floating IP만 씁니다(provider 포트는 `network:floatingip`와 `network:router_gateway`뿐).
  - 검증 (2026-10-21, 앱 크리덴셜로 래퍼 없이 직접 호출):
    - `port create --network provider` → `403 ... not allowed to create port on this network`
    - `server create --network provider` → `ERROR: Failed to allocate the network(s)`
    - `network list --external` → provider가 보임 (라우터 게이트웨이용)
    - 기존 Floating IP와 VM 접속은 정상입니다.
  - 대안: Neutron 정책으로 `role:lab-agent`의 provider 포트 생성을 막는 방법도 있습니다([`scripts/openstack/neutron-policy.proposed.yaml`](../scripts/openstack/neutron-policy.proposed.yaml), `reconfigure --tags neutron` 필요). 공유하지 않는 것만으로 충분해서 적용하지 않았습니다.
- **라우터 외부 게이트웨이의 고정 IP는 Neutron 기본 정책에 기댑니다.** `oslab router create lab-<이름> …`은 옵션을 거의 그대로 넘기므로 `--external-gateway provider --fixed-ip subnet=provider,ip-address=…`처럼 LAN 주소를 골라 달라는 요청도 Neutron까지 갑니다. 이를 막는 것은 Neutron 기본 정책(`create_router:external_gateway_info:external_fixed_ips`는 admin 전용)입니다. 래퍼는 이 옵션을 따로 검사하지 않으므로, Neutron 정책을 바꿀 때는 이 규칙을 유지하세요.
- 쿼터 안에서는 VM을 계속 만들 수 있습니다(최대 3대/12 GB). `oslab`으로는 지울 수 없으므로, 남은 `lab-` VM은 봇이 `osadmin`으로 정리하거나 사람이 지웁니다. 매일 점검 리포트가 남은 `lab-` VM을 알려 줍니다.
- Hermes의 기존 차단 패턴 `*reboot*` 때문에 Hermes에서 `oslab server reboot` 은 막힙니다(stop/start로 대신). `*authorized_keys*` 때문에 터미널 명령으로 `ssh_authorized_keys` 가 든 user-data 파일을 쓰는 것도 막힙니다(파일 도구로 쓰거나 사람이 준비).

## 알려진 한계

- **봇은 `ubuntu` 사용자로 돌고, 이 사용자는 비밀번호 없는 sudo를 갖고, OpenStack admin 키도 갖습니다.**
  - Hermes(ops)와 Claude Code가 모두 lab-assistant의 `ubuntu`로 실행됩니다. 이 사용자는 Ubuntu 클라우드 이미지 기본값대로 `sudo` 에 비밀번호가 없습니다.
  - `~/.config/openstack/clouds.yaml` 에는 `lab-admin`(admin 역할) 키가 있습니다. 봇의 셸에서 이 파일을 읽거나 `~/.venvs/openstack/bin/openstack --os-cloud lab-admin` 을 직접 부르는 것은 **차단 패턴(Hermes `approvals.deny`, Claude Code deny 규칙)과 봇 규칙으로만** 막혀 있습니다. 둘 다 문자열 패턴이라 우회할 수 있습니다(예: 다른 이름의 스크립트, 인코딩된 명령).
  - 그래서 `oslab` 과 `osadmin` 은 **가드레일과 감사 기록**이지, 하드 경계가 아닙니다. `osadmin` 감사 로그도 같은 사용자가 쓰는 파일이라 봇이 지우거나 고칠 수 있습니다.
  - Nova lock도 admin이면 풀 수 있으므로 실수 방지용일 뿐입니다.
- **진짜 경계를 만들려면** (이 구성에서는 **선택에 따라 하지 않았습니다**)
  - 봇 전용 리눅스 계정을 따로 만들고 sudo를 주지 않거나 필요한 명령만 허용합니다(`sudoers` 의 명령 제한).
  - admin 키는 그 계정이 읽을 수 없는 곳(다른 사용자 소유, 600)에 두고, `osadmin` 을 `sudo -u <키 소유자> osadmin ...` 처럼 정해진 명령으로만 부르게 합니다. 감사 로그도 그 소유자만 쓸 수 있게 합니다.
  - 또는 admin 경로를 없애고 lab-agent 경로(1~3층)만 씁니다. 이 경우 위의 1~3층은 실제 경계로 동작합니다(lab-agent 키는 admin이 아님).
- **사고가 났을 때**: [폐기](#전체-admin-권한-주기-이-구성의-최종-선택) 절의 `os application credential delete lab-admin-bot` 으로 admin 키를 끊고, 비서 VM의 `osadmin` 감사 로그와 Kolla 호스트의 `os server event list <서버>` 를 대조합니다. 감사 로그는 봇이 고칠 수 있으므로 OpenStack 쪽 기록이 기준입니다.

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
