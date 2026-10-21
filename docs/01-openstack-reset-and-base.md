# 01. OpenStack 테넌트 초기화와 기본 구성

## 목적

- (A, 선택) Kolla 배포는 유지한 채 기존 테넌트 자원(서버·네트워크·이미지 등)을 전부 지우고 깨끗한 상태에서 시작
- (B) 실습망, 라우터, flavor, keypair, 보안 그룹 생성
- (C) Ubuntu / Windows 11 이미지 업로드
- (D) VM 3대(`lab-gns3`, `lab-assistant`, `lab-windows`) 생성 및 Floating IP 연결

## 사전 요구사항

- [00-host-check.md](00-host-check.md) 완료. 이 문서의 명령은 모두 **Kolla 호스트**에서 실행합니다.
- Repo가 Kolla 호스트에 clone되어 있고 `REPO=~/homelab-agent`가 지정돼 있을 것([00 문서 0단계](00-host-check.md#0-작업-환경-준비))
- `~/lab-secrets.env`(600)에 `WIN_ADMIN_PASSWORD`, `VNC_PASSWORD`가 있고, [README](../README.md#secret-관리)의 `setenv`·`sec` 함수가 현재 셸에 정의되어 있을 것(D-2에서 사용)
- `os` helper 함수가 현재 셸에 정의되어 있을 것

  ```bash
  set -a; source <(sudo cat /etc/kolla/admin-openrc.sh); set +a
  E=$(env | grep ^OS_ | sed "s/^/-e /" | tr "\n" " ")
  os(){ sudo docker exec $E kolla_toolbox openstack "$@"; }
  ```

- 이 문서의 주소는 예시입니다. 자기 환경에 맞게 바꾸세요.

  | 항목 | 예시 값 |
  |---|---|
  | 홈 LAN / provider | `192.168.0.0/24`, 게이트웨이 `192.168.0.1` |
  | Floating IP 풀 | `192.168.0.200` ~ `192.168.0.230` |
  | lab-net | `10.10.0.0/24`, 게이트웨이 `10.10.0.1` |
  | FIP 할당(예) | gns3 `.201`, assistant `.202`, windows `.203` |
  | WireGuard 클라이언트 대역 `<WG_SUBNET>` | `10.158.157.0/24` |

---

## 절차

### A. (선택) 기존 테넌트 리소스 초기화

> **경고: 되돌릴 수 없습니다.** 모든 서버·네트워크·이미지가 삭제됩니다. 필요한 Glance 이미지는 먼저 백업하세요.
> `admin`/`service` 프로젝트와 Kolla 서비스 사용자(nova, neutron, glance 등)는 **절대 지우지 마세요.**

#### A-0. provider 네트워크 설정 기록

provider 네트워크를 다시 만들 때 필요하므로 먼저 기록합니다.

```bash
os network list --external
os network show <provider-net> -f yaml | tee ~/provider-net.yaml
os subnet show  provider -f yaml | tee ~/provider-subnet.yaml   # 서브넷 이름 (이 홈랩은 네트워크와 같은 provider)
# physnet ↔ 브리지 매핑 확인
sudo grep -rE 'bridge_mappings|flat_networks' /etc/kolla/neutron-*/ 2>/dev/null
```

예시 환경의 값:

| 항목 | 값 |
|---|---|
| 타입 / physnet | `flat` / `physnet1` (`physnet1:br-ex`) |
| 서브넷 | `192.168.0.0/24`, gw `192.168.0.1`, DHCP 없음 |
| 할당 풀 | `192.168.0.200-192.168.0.230` |
| 속성 | `--external` (재생성할 때 `--share`는 **붙이지 않음**, B-1 참고) |

#### A-1. (필요 시) 커스텀 이미지 백업

`kolla_toolbox`에서는 호스트 홈 디렉터리가 보이지 않으므로 일회용 컨테이너로 저장합니다.

```bash
mkdir -p ~/image-backup
sudo docker run --rm --user 0 --network host $E \
  -v /home/<KOLLA_USER>/image-backup:/w \
  --entrypoint bash quay.io/openstack.kolla/kolla-toolbox:2026.1-ubuntu-noble \
  -c 'openstack image save --file /w/<image-name>.qcow2 <image-id>'
```

#### A-2. 리소스 삭제 (순서대로)

```bash
# 1) 서버 (전체 프로젝트)
for id in $(os server list --all-projects -f value -c ID); do os server delete --wait "$id"; done

# 2) Floating IP
for id in $(os floating ip list -f value -c ID); do os floating ip delete "$id"; done

# 3) 라우터: 인터페이스 제거 → 게이트웨이 해제 → 삭제
for r in $(os router list -f value -c ID); do
  for p in $(os port list --router "$r" --device-owner network:router_interface -f value -c ID); do
    os router remove port "$r" "$p"
  done
  os router unset --external-gateway "$r"
  os router delete "$r"
done

# 4) DHCP 포트 외 남은 포트
os port list -f value -c ID -c device_owner | awk '$2!="network:dhcp"{print $1}' \
  | while read -r p; do os port delete "$p"; done

# 5) 네트워크 (provider 포함)
for id in $(os network list -f value -c ID); do os network delete "$id"; done

# 6) 이미지
for id in $(os image list -f value -c ID); do os image delete "$id"; done

# 7) default 이외 보안 그룹
os security group list -f value -c ID -c Name | awk '$2!="default"{print $1}' \
  | while read -r sg; do os security group delete "$sg"; done

# 8) keypair (현재 사용자 기준)
for k in $(os keypair list -f value -c Name); do os keypair delete "$k"; done

# 9) 직접 만든 프로젝트/사용자만 (목록을 확인하고 수동으로 삭제)
os project list
os user list
# os user delete <내가-만든-사용자>
# os project delete <내가-만든-프로젝트>
```

> `while read` 루프 안에서는 `os` 함수가 정상 동작합니다. `xargs`는 셸 함수를 호출할 수 없으므로 쓰지 마세요.

---

### B. 기본 구성

#### B-1. provider 네트워크 재생성

```bash
os network create provider \
  --external \
  --provider-network-type flat --provider-physical-network physnet1

os subnet create provider \
  --network provider \
  --subnet-range 192.168.0.0/24 --gateway 192.168.0.1 --no-dhcp \
  --allocation-pool start=192.168.0.200,end=192.168.0.230
```

> Floating IP 풀(`.200-.230`)은 **공유기 DHCP 범위와 겹치지 않게** 하세요.
> 서브넷 이름은 이 홈랩처럼 네트워크와 같은 `provider`로 둡니다(네트워크와 서브넷은 종류가 달라 이름이 겹쳐도 됩니다). 다른 이름(예: `provider-subnet`)을 써도 되지만 그러면 A-0의 `os subnet show` 등에서 이름을 바꿔 쓰세요.

> **`--share`를 붙이지 않는 이유**: 외부 네트워크(`--external`)는 공유하지 않아도 모든 프로젝트가 라우터 게이트웨이와 Floating IP로 쓸 수 있습니다. 반대로 공유하면 Nova의 `network:attach_external_network` 검사가 적용되지 않아, 관리자가 아닌 프로젝트(예: 봇용 `lab-agent`)도 VM을 홈 LAN에 직접 붙일 수 있습니다. 검증 결과는 [07 문서의 잔여 위험](07-openstack-agent.md#잔여-위험)에 있습니다. 이미 `--share`로 만들었다면 `os network set --no-share provider`로 해제합니다.

#### B-2. lab-net / 라우터

```bash
os network create lab-net
os subnet create lab-subnet \
  --network lab-net \
  --subnet-range 10.10.0.0/24 --gateway 10.10.0.1 \
  --dns-nameserver 1.1.1.1 --dns-nameserver 8.8.8.8

os router create lab-router
os router set --external-gateway provider lab-router
os router add subnet lab-router lab-subnet
```

#### B-3. Flavor

| Flavor | vCPU | RAM | 디스크 |
|---|---|---|---|
| `lab.assistant` | 4 | 8GB | 40GB |
| `lab.gns3` | 6 | 24GB | 120GB |
| `lab.windows16` | 4 | 16GB | 150GB |
| **합계** | **14** | **48GB** | **310GB** |

```bash
os flavor create lab.assistant --vcpus 4 --ram 8192  --disk 40
os flavor create lab.gns3      --vcpus 6 --ram 24576 --disk 120
os flavor create lab.windows16 --vcpus 4 --ram 16384 --disk 150
```

> Windows는 GNS3 GUI와 브라우저를 함께 쓰므로 16GB/150GB로 만듭니다(8GB/80GB는 메모리가 빠듯하고 C: 여유가 약 44GB뿐). 이미 작은 flavor로 만든 VM을 늘리는 방법은 [03 문서 4단계](03-windows-vm.md#4-ram디스크-resize와-c-드라이브-확장)에 있습니다.

#### B-4. Keypair

Kolla 호스트에서 관리자용 키 `lab-key`를 만들고 공개키만 컨테이너에 복사해 OpenStack keypair로 등록합니다. 개인키 `~/.ssh/lab-key`는 **Kolla 호스트에만** 둡니다. Ubuntu VM 2대(keypair)와 Windows(첫 부팅 user_data의 `<SSH_PUBLIC_KEY>`)가 이 키를 신뢰하고, VM을 만든 뒤 [D-5](#d-5-kolla-호스트-ssh-별칭-설정)의 SSH 별칭이 이 키를 씁니다. 봇(`lab-assistant`)용 키는 05·07 문서에서 따로 만듭니다.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/lab-key -N '' -C lab-key

sudo docker exec -u 0 kolla_toolbox mkdir -p /tmp/lab
sudo docker cp ~/.ssh/lab-key.pub kolla_toolbox:/tmp/lab/lab-key.pub
sudo docker exec -u 0 kolla_toolbox chmod -R a+rX /tmp/lab

os keypair create --public-key /tmp/lab/lab-key.pub lab-key
```

#### B-5. 보안 그룹

| SG | 허용 |
|---|---|
| `sg-assistant` | 22/tcp ← LAN, ICMP ← LAN |
| `sg-gns3` | 22/tcp ← LAN; 3080/tcp(API·MCP), 5000-5100/tcp(장비 콘솔), 5900-5999/tcp(장비 VNC 콘솔) ← LAN + `sg-assistant` + `sg-windows`; ICMP ← LAN + `sg-assistant` |
| `sg-windows` | 22/tcp, 5900/tcp ← **`sg-assistant`만**; 3389/tcp ← LAN; ICMP ← LAN |

원격 그룹 참조를 위해 SG 3개를 먼저 모두 만든 뒤 규칙을 추가합니다.

```bash
LAN=192.168.0.0/24
for sg in sg-assistant sg-gns3 sg-windows; do os security group create "$sg"; done
rule(){ os security group rule create --ingress "$@"; }

# sg-assistant
rule --protocol tcp  --dst-port 22 --remote-ip $LAN sg-assistant
rule --protocol icmp               --remote-ip $LAN sg-assistant

# sg-gns3
rule --protocol tcp  --dst-port 22 --remote-ip $LAN sg-gns3
for port in 3080 5000:5100 5900:5999; do   # 5900-5999: gns3_server.conf 의 vnc_console 범위
  rule --protocol tcp --dst-port $port --remote-ip $LAN               sg-gns3
  rule --protocol tcp --dst-port $port --remote-group sg-assistant    sg-gns3
  rule --protocol tcp --dst-port $port --remote-group sg-windows      sg-gns3
done
rule --protocol icmp --remote-ip $LAN            sg-gns3
rule --protocol icmp --remote-group sg-assistant sg-gns3

# sg-windows
rule --protocol tcp  --dst-port 22   --remote-group sg-assistant sg-windows
rule --protocol tcp  --dst-port 5900 --remote-group sg-assistant sg-windows
rule --protocol tcp  --dst-port 3389 --remote-ip $LAN            sg-windows
rule --protocol icmp                 --remote-ip $LAN            sg-windows
```

> **WireGuard 대역도 허용해야 합니다.** 공유기 WireGuard 클라이언트는 별도 대역(`<WG_SUBNET>`, 사전 요구사항 표의 예시 참고)에서 들어오고 공유기가 NAT하지 않습니다. 따라서 LAN만 허용하면 VPN으로는 VM에 접속할 수 없습니다. Kolla 호스트에는 보안 그룹이 적용되지 않으므로 호스트 접속은 됩니다. LAN 규칙과 같은 포트에 WG 대역을 추가합니다.
>
> ```bash
> WG=<WG_SUBNET>
> rule --protocol tcp --dst-port 22        --remote-ip $WG sg-assistant
> rule --protocol tcp --dst-port 22        --remote-ip $WG sg-gns3
> rule --protocol tcp --dst-port 3080      --remote-ip $WG sg-gns3
> rule --protocol tcp --dst-port 5000:5100 --remote-ip $WG sg-gns3
> rule --protocol tcp --dst-port 5900:5999 --remote-ip $WG sg-gns3
> rule --protocol tcp --dst-port 3389      --remote-ip $WG sg-windows
> for g in sg-assistant sg-gns3 sg-windows; do rule --protocol icmp --remote-ip $WG $g; done
> ```

> **`default` 보안 그룹은 쓰지 않습니다.** 프로젝트마다 자동으로 생기는 `default` SG에는 22/tcp·ICMP를 `0.0.0.0/0`에서 허용하는 규칙이 있을 수 있습니다. 이 홈랩의 admin 프로젝트도 그랬습니다. 이 구성의 VM은 모두 위 `sg-*`만 쓰고 `default`는 어떤 포트에도 붙어 있지 않습니다. 프로젝트마다 `default`가 있어 이름으로는 구분되지 않으므로, `os security group list --project admin`으로 `default`의 ID를 찾고 `os port list --security-group <ID>` 결과가 비어 있는지 확인합니다. `os server create`에서 `--security-group`을 빠뜨리면 `default`가 붙으므로 항상 지정하세요. 쓸 일이 없으면 `default`의 0.0.0.0/0 ingress 규칙을 삭제해도 됩니다.

---

### C. 이미지 업로드

호스트 홈 디렉터리의 파일은 `kolla_toolbox`에서 보이지 않으므로, 같은 이미지로 일회용 컨테이너를 실행해 업로드합니다.

#### C-1. Ubuntu 24.04 (noble)

```bash
mkdir -p ~/lab-images && cd ~/lab-images      # 이미지 파일은 모두 ~/lab-images 에 둡니다
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

sudo docker run --rm --user 0 --network host $E \
  -v /home/<KOLLA_USER>:/w:ro \
  --entrypoint bash quay.io/openstack.kolla/kolla-toolbox:2026.1-ubuntu-noble \
  -c 'openstack image create ubuntu-24.04 \
        --disk-format qcow2 --container-format bare \
        --file /w/lab-images/noble-server-cloudimg-amd64.img \
        --property os_distro=ubuntu \
        --property hw_qemu_guest_agent=yes'
```

#### C-2. Windows 11

Cloudbase-Init + virtio 드라이버 + QEMU guest agent가 들어간 Windows 11 qcow2를 미리 준비해 `~/lab-images/<WIN11_QCOW2>.qcow2`에 둡니다(예: cloudbase `windows-imaging-tools`로 빌드. `<WIN11_QCOW2>`는 확장자를 뺀 파일 이름). 이미지 내부 확인 방법은 [03-windows-vm.md](03-windows-vm.md)에 있습니다.

호스트에 `enable_nova_swtpm: "yes"`가 켜져 있어야 vTPM 2.0이 붙습니다(Windows 11 요구사항).

```bash
sudo docker run --rm --user 0 --network host $E \
  -v /home/<KOLLA_USER>:/w:ro \
  --entrypoint bash quay.io/openstack.kolla/kolla-toolbox:2026.1-ubuntu-noble \
  -c 'openstack image create win11 \
        --disk-format qcow2 --container-format bare \
        --file /w/lab-images/<WIN11_QCOW2>.qcow2 \
        --property os_type=windows \
        --property os_distro=windows \
        --property hw_firmware_type=uefi \
        --property hw_machine_type=q35 \
        --property hw_disk_bus=virtio \
        --property hw_vif_model=virtio \
        --property hw_qemu_guest_agent=yes \
        --property hw_tpm_version=2.0 \
        --property hw_tpm_model=tpm-crb \
        --property hw_video_model=virtio'
```

> Kolla가 TLS를 쓰고 `OS_CACERT`가 설정돼 있다면 해당 CA 파일도 `-v`로 같은 경로에 마운트해야 합니다.

---

### D. 서버 생성

순서가 중요합니다. Windows user_data에 **lab-assistant의 lab-net IP**(`<ASSISTANT_LAB_IP>`)를 넣어야 하므로, Ubuntu VM 2대를 먼저 만들고 그 IP를 확인한 뒤 Windows를 만듭니다. 모두 Kolla 호스트에서 실행합니다.

#### D-1. Ubuntu VM 2대 (lab-gns3, lab-assistant)

```bash
# (Kolla 호스트) 템플릿에는 secret이 없으므로 그대로 컨테이너에 넣습니다
sudo docker exec -u 0 kolla_toolbox mkdir -p /tmp/lab
sudo docker cp "$REPO/scripts/ubuntu-cloud-config.yaml" kolla_toolbox:/tmp/lab/
sudo docker exec -u 0 kolla_toolbox chmod -R a+rX /tmp/lab

os server create lab-gns3 \
  --flavor lab.gns3 --image ubuntu-24.04 --network lab-net \
  --security-group sg-gns3 --key-name lab-key \
  --user-data /tmp/lab/ubuntu-cloud-config.yaml --wait

os server create lab-assistant \
  --flavor lab.assistant --image ubuntu-24.04 --network lab-net \
  --security-group sg-assistant --key-name lab-key \
  --user-data /tmp/lab/ubuntu-cloud-config.yaml --wait
```

#### D-2. Windows user_data 준비

스크립트: [scripts/windows-userdata.ps1](../scripts/windows-userdata.ps1). 스크립트가 무엇을 하는지는 [03 문서 2단계](03-windows-vm.md#2-첫-부팅-스크립트)에 있습니다. 여기서는 placeholder 5개를 채웁니다.

| Placeholder | 넣을 값 | 어디서 |
|---|---|---|
| `<WIN_ADMIN_PASSWORD>` | `Admin` 계정 비밀번호 (복잡도 정책 충족, 작은따옴표 없이) | `~/lab-secrets.env`의 `WIN_ADMIN_PASSWORD` |
| `<VNC_PASSWORD>` | TightVNC 비밀번호 (최대 8자) | `~/lab-secrets.env`의 `VNC_PASSWORD` |
| `<SSH_PUBLIC_KEY>` | Windows가 처음 신뢰할 SSH 공개키 한 줄 | B-4에서 만든 Kolla 호스트의 `~/.ssh/lab-key.pub`. 개인키는 Kolla 호스트에만 있으므로 처음에는 Kolla 호스트에서 `lab-assistant`를 거쳐서만 접속합니다. `lab-assistant`(봇)용 키는 [05 문서 3단계](05-mcp.md#3-0-lab-assistant에서-windows로-ssh-접속-설정)에서 따로 등록합니다 |
| `<ASSISTANT_LAB_IP>` | lab-assistant의 lab-net IP. VNC(5900)를 이 주소에서만 허용 | 아래 명령 (D-1에서 만든 VM) |
| `<TIGHTVNC_MSI_SHA256>` | TightVNC 2.8.90 64-bit MSI의 SHA256 (16진수 64자). 비워 두면 VNC 설치만 건너뜁니다 | 아래 명령으로 직접 다운로드해 계산하고, 가능하면 tightvnc.com 다운로드 페이지의 표기와 대조 |

```bash
# (Kolla 호스트) README의 setenv·sec 함수가 정의된 셸에서
ASSISTANT_LAB_IP=$(os server show lab-assistant -f json -c addresses \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["addresses"]["lab-net"][0])')
echo "$ASSISTANT_LAB_IP"                      # 예: 10.10.0.52

curl -fsSLo /tmp/tightvnc.msi https://www.tightvnc.com/download/2.8.90/tightvnc-2.8.90-gpl-setup-64bit.msi
TIGHTVNC_MSI_SHA256=$(sha256sum /tmp/tightvnc.msi | cut -d' ' -f1); rm /tmp/tightvnc.msi
echo "$TIGHTVNC_MSI_SHA256"                   # tightvnc.com 표기와 대조

# repo 밖(~/lab, 700)에 사본을 만들고 placeholder를 채웁니다. secret은 화면에 출력되지 않습니다
mkdir -p -m 700 ~/lab
WIN_ADMIN_PASSWORD=$(sec WIN_ADMIN_PASSWORD) VNC_PASSWORD=$(sec VNC_PASSWORD) \
SSH_PUBLIC_KEY=$(cat ~/.ssh/lab-key.pub) ASSISTANT_LAB_IP=$ASSISTANT_LAB_IP TIGHTVNC_MSI_SHA256=$TIGHTVNC_MSI_SHA256 \
python3 - "$REPO/scripts/windows-userdata.ps1" ~/lab/windows.ps1 <<'PY'
import os, sys
s = open(sys.argv[1], encoding="utf-8").read()
for k in ("WIN_ADMIN_PASSWORD", "VNC_PASSWORD", "SSH_PUBLIC_KEY", "ASSISTANT_LAB_IP", "TIGHTVNC_MSI_SHA256"):
    v = os.environ.get(k, "")
    if "'" in v:
        sys.exit(k + ": 작은따옴표(')가 있으면 PowerShell 문자열이 깨집니다")
    if not v and k != "TIGHTVNC_MSI_SHA256":
        sys.exit(k + " 이(가) 비어 있습니다")
    s = s.replace("<" + k + ">", v)
os.umask(0o077)
open(sys.argv[2], "w", encoding="utf-8").write(s)
print("written", sys.argv[2])
PY
grep -c '<[A-Z_]*>' ~/lab/windows.ps1        # 0 이어야 함 (남은 placeholder 없음)
```

#### D-3. lab-windows 생성

```bash
# (Kolla 호스트)
sudo docker cp ~/lab/windows.ps1 kolla_toolbox:/tmp/lab/
sudo docker exec -u 0 kolla_toolbox chmod -R a+rX /tmp/lab

os server create lab-windows \
  --flavor lab.windows16 --image win11 --network lab-net \
  --security-group sg-windows --key-name lab-key \
  --config-drive true --user-data /tmp/lab/windows.ps1 --wait
```

생성 후 비밀번호가 담긴 사본은 지웁니다.

```bash
sudo docker exec -u 0 kolla_toolbox rm -rf /tmp/lab
shred -u ~/lab/windows.ps1
```

첫 부팅은 Windows 기능 설치 때문에 수 분 이상 걸립니다. 진행 상황은 `os console log show lab-windows | tail`로 봅니다.

#### D-4. Floating IP

```bash
# (Kolla 호스트) 주소는 예시
for pair in lab-gns3:192.168.0.201 lab-assistant:192.168.0.202 lab-windows:192.168.0.203; do
  srv=${pair%%:*}; fip=${pair##*:}
  os floating ip create --floating-ip-address "$fip" provider
  os server add floating ip "$srv" "$fip"
done
os server list -c Name -c Status -c Networks
```

#### D-5. Kolla 호스트 SSH 별칭 설정

02~07 문서는 Kolla 호스트에서 `ssh lab-gns3`, `ssh lab-assistant`, `ssh lab-windows` 별칭을 씁니다. 모두 B-4의 `lab-key`를 씁니다. Windows의 22번은 `sg-assistant`에서만 열려 있으므로(B-5) `lab-windows`는 `lab-assistant`를 점프 호스트로 거칩니다.

각 VM의 lab-net 주소(`<GNS3_LAB_IP>`, `<ASSISTANT_LAB_IP>`, `<WIN_LAB_IP>`)는 이렇게 확인합니다.

```bash
# (Kolla 호스트)
for vm in lab-gns3 lab-assistant lab-windows; do
  printf '%s ' "$vm"; os server show "$vm" -f json -c addresses \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["addresses"]["lab-net"][0])'
done
```

`~/.ssh/config`에 추가합니다(주소는 D-4의 Floating IP와 위 결과로 바꿈).

```
# (Kolla 호스트) ~/.ssh/config
Host lab-gns3
  HostName <GNS3_FIP>
  User ubuntu
  IdentityFile ~/.ssh/lab-key
  IdentitiesOnly yes
Host lab-assistant
  HostName <ASSISTANT_FIP>
  User ubuntu
  IdentityFile ~/.ssh/lab-key
  IdentitiesOnly yes
Host lab-windows
  HostName <WIN_LAB_IP>
  User Admin
  IdentityFile ~/.ssh/lab-key
  IdentitiesOnly yes
  ProxyJump lab-assistant
```

```bash
# (Kolla 호스트)
chmod 600 ~/.ssh/config
ssh lab-assistant hostname       # 첫 접속 때 호스트 키 확인(yes)
ssh lab-gns3 hostname
ssh lab-windows hostname         # Windows 첫 부팅 설정(수 분)이 끝난 뒤에 접속됨. 확인은 03 문서 검증
```

## 검증

```bash
# cloud-init 완료 대기 후 KVM / vmx 확인 (lab-gns3)
# (Kolla 호스트)
ssh lab-gns3 'cloud-init status --wait; ls -l /dev/kvm; grep -c vmx /proc/cpuinfo'
```

| 확인 | 기대값 |
|---|---|
| `/dev/kvm` | 존재 (`crw-rw---- root kvm`) |
| `grep -c vmx /proc/cpuinfo` | vCPU 수 (lab.gns3는 `6`) |
| `os server list` | 3대 모두 `ACTIVE` |
| `ssh lab-assistant` (D-5 별칭) | 로그인 성공 |

포트 열림 확인은 **lab-assistant VM 안에서** 합니다.

```bash
# (Kolla 호스트) → lab-assistant로 접속
ssh lab-assistant
# (lab-assistant)
ping -c2 <GNS3_LAB_IP>           # ICMP ← sg-assistant
nc -zv <GNS3_LAB_IP> 3080      # GNS3 설치 후
nc -zv <WIN_LAB_IP> 22
nc -zv <WIN_LAB_IP> 5900
```

## Troubleshooting

- qrouter 네임스페이스에서 포트를 테스트하면 실패합니다. `ip netns exec qrouter-... nc ...`의 출발지는 라우터 IP(`10.10.0.1`)라 어떤 SG에도 허용되지 않습니다. SG 문제로 오해하지 말고 `lab-assistant`에서 테스트하세요.
- **`--file` / `--user-data` / `--public-key` 경로는 컨테이너 내부 경로**입니다. 호스트 파일은 `docker cp`로 넣거나 일회용 컨테이너에 `-v`로 마운트하세요.
- **`Permission denied`로 user_data를 읽지 못함**: `umask 077` 상태에서 만든 디렉터리(700)를 `docker cp`하면 권한이 그대로 넘어가 컨테이너 사용자가 읽을 수 없습니다. `docker exec -u 0 kolla_toolbox chmod -R a+rX /tmp/lab`로 해결합니다.
- cinder가 없으므로 볼륨 부팅 옵션은 쓰지 마세요. 루트 디스크 크기는 flavor의 `--disk`로 결정됩니다.
- Windows user_data에는 비밀번호가 평문으로 들어가고 메타데이터/config drive에 남습니다. 첫 부팅 후 비밀번호를 바꾸길 권장합니다.
