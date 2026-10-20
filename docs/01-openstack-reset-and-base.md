# 01. OpenStack 테넌트 초기화와 기본 구성

## 목적

- (A, 선택) Kolla 배포는 유지한 채 기존 테넌트 자원(서버·네트워크·이미지 등)을 전부 지우고 깨끗한 상태에서 시작
- (B) 실습용 네트워크, 라우터, flavor, 키페어, 보안 그룹 생성
- (C) Ubuntu / Windows 11 이미지 업로드
- (D) VM 3대(`lab-gns3`, `lab-assistant`, `lab-windows`) 생성 및 Floating IP 연결

## 사전조건

- [00-host-check.md](00-host-check.md) 완료, `os` 헬퍼 함수가 현재 셸에 정의되어 있을 것

  ```bash
  set -a; source <(sudo cat /etc/kolla/admin-openrc.sh); set +a
  E=$(env | grep ^OS_ | sed "s/^/-e /" | tr "\n" " ")
  os(){ sudo docker exec $E kolla_toolbox openstack "$@"; }
  ```

- 이 문서의 주소는 **예시**입니다. 자기 환경에 맞게 바꾸세요.

  | 항목 | 예시 값 |
  |---|---|
  | 홈 LAN / provider | `192.168.0.0/24`, 게이트웨이 `192.168.0.1` |
  | Floating IP 풀 | `192.168.0.200` ~ `192.168.0.230` |
  | lab-net | `10.10.0.0/24`, 게이트웨이 `10.10.0.1` |
  | FIP 할당(예) | gns3 `.201`, assistant `.202`, windows `.203` |

---

## 절차

### A. (선택) 기존 테넌트 자원 전체 초기화

> **경고: 되돌릴 수 없습니다.** 모든 서버·네트워크·이미지가 삭제됩니다. 필요한 Glance 이미지는 먼저 백업하세요.
> `admin`/`service` 프로젝트와 Kolla 서비스 사용자(nova, neutron, glance 등)는 **절대 지우지 마세요.**

#### A-0. provider 네트워크 설정 기록

provider 네트워크를 다시 만들 때 필요하므로 먼저 기록합니다.

```bash
os network list --external
os network show <provider-net> -f yaml | tee ~/provider-net.yaml
os subnet show  <provider-subnet> -f yaml | tee ~/provider-subnet.yaml
# physnet ↔ 브리지 매핑 확인
sudo grep -rE 'bridge_mappings|flat_networks' /etc/kolla/neutron-*/ 2>/dev/null
```

예시 환경의 값:

| 항목 | 값 |
|---|---|
| 타입 / physnet | `flat` / `physnet1` (`physnet1:br-ex`) |
| 서브넷 | `192.168.0.0/24`, gw `192.168.0.1`, **DHCP 없음** |
| 할당 풀 | `192.168.0.200-192.168.0.230` |
| 속성 | `--external`, `--share` |

#### A-1. (필요 시) 커스텀 이미지 백업

`kolla_toolbox`는 호스트 홈 디렉터리를 못 보므로 일회용 컨테이너로 저장합니다.

```bash
mkdir -p ~/image-backup
sudo docker run --rm --user 0 --network host $E \
  -v /home/<user>/image-backup:/w \
  --entrypoint bash quay.io/openstack.kolla/kolla-toolbox:2026.1-ubuntu-noble \
  -c 'openstack image save --file /w/<image-name>.qcow2 <image-id>'
```

#### A-2. 삭제 (이 순서대로)

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

# 8) 키페어 (현재 사용자 기준)
for k in $(os keypair list -f value -c Name); do os keypair delete "$k"; done

# 9) 직접 만든 프로젝트/사용자만 (목록 확인 후 수동으로!)
os project list
os user list
# os user delete <내가-만든-사용자>
# os project delete <내가-만든-프로젝트>
```

> `while read` 루프 안에서는 `os` 함수가 정상 동작합니다. `xargs`는 셸 함수를 못 부르므로 쓰지 마세요.

---

### B. 기본 구성

#### B-1. provider 네트워크 재생성

```bash
os network create provider \
  --external --share \
  --provider-network-type flat --provider-physical-network physnet1

os subnet create provider-subnet \
  --network provider \
  --subnet-range 192.168.0.0/24 --gateway 192.168.0.1 --no-dhcp \
  --allocation-pool start=192.168.0.200,end=192.168.0.230
```

> Floating IP 풀(`.200-.230`)은 **공유기 DHCP 범위와 겹치지 않게** 하세요.

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

#### B-3. flavor

| flavor | vCPU | RAM | 디스크 |
|---|---|---|---|
| `lab.assistant` | 4 | 8GB | 40GB |
| `lab.gns3` | 6 | 24GB | 120GB |
| `lab.windows` | 4 | 8GB | 80GB |

```bash
os flavor create lab.assistant --vcpus 4 --ram 8192  --disk 40
os flavor create lab.gns3      --vcpus 6 --ram 24576 --disk 120
os flavor create lab.windows   --vcpus 4 --ram 8192  --disk 80
```

#### B-4. 키페어

호스트에서 키를 만들고 공개키만 컨테이너에 복사해 등록합니다.

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
| `sg-gns3` | 22/tcp ← LAN; 3080/tcp, 5000-5100/tcp ← LAN + `sg-assistant` + `sg-windows`; ICMP |
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
for port in 3080 5000:5100; do
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

> WireGuard 클라이언트가 별도 대역(예: `10.6.0.0/24`)을 쓰고 공유기가 NAT하지 않는다면, 그 대역도 `--remote-ip`에 추가해야 합니다.

---

### C. 이미지 업로드

호스트 홈 디렉터리의 파일은 `kolla_toolbox`에서 보이지 않으므로, 같은 이미지로 **일회용 컨테이너**를 띄워 업로드합니다.

#### C-1. Ubuntu 24.04 (noble)

```bash
mkdir -p ~/images && cd ~/images
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

sudo docker run --rm --user 0 --network host $E \
  -v /home/<user>:/w:ro \
  --entrypoint bash quay.io/openstack.kolla/kolla-toolbox:2026.1-ubuntu-noble \
  -c 'openstack image create ubuntu-24.04 \
        --disk-format qcow2 --container-format bare \
        --file /w/images/noble-server-cloudimg-amd64.img \
        --property os_distro=ubuntu \
        --property hw_qemu_guest_agent=yes'
```

#### C-2. Windows 11

Cloudbase-Init + virtio 드라이버 + QEMU guest agent가 들어간 Windows 11 qcow2를 미리 준비합니다(예: cloudbase `windows-imaging-tools`로 빌드). 이미지 내부 확인 방법은 [03-windows-vm.md](03-windows-vm.md)에 있습니다.

호스트에 `enable_nova_swtpm: "yes"`가 켜져 있어야 vTPM 2.0이 붙습니다(Windows 11 요구사항).

```bash
sudo docker run --rm --user 0 --network host $E \
  -v /home/<user>:/w:ro \
  --entrypoint bash quay.io/openstack.kolla/kolla-toolbox:2026.1-ubuntu-noble \
  -c 'openstack image create windows-11 \
        --disk-format qcow2 --container-format bare \
        --file /w/images/<windows-11>.qcow2 \
        --property os_type=windows \
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

#### D-1. user_data 파일을 컨테이너에 복사

```bash
# 저장소의 템플릿을 저장소 밖에 복사해 자리표시자를 채운 뒤 사용 (저장소 루트에서 실행)
mkdir -p -m 700 ~/lab
cp scripts/ubuntu-cloud-config.yaml ~/lab/ubuntu-cloud-config.yaml
cp scripts/windows-userdata.ps1     ~/lab/windows.ps1   # <WIN_ADMIN_PASSWORD> 등 채우기

sudo docker exec -u 0 kolla_toolbox mkdir -p /tmp/lab
sudo docker cp ~/lab/ubuntu-cloud-config.yaml kolla_toolbox:/tmp/lab/
sudo docker cp ~/lab/windows.ps1              kolla_toolbox:/tmp/lab/
sudo docker exec -u 0 kolla_toolbox chmod -R a+rX /tmp/lab
```

#### D-2. 서버 3대

```bash
os server create lab-gns3 \
  --flavor lab.gns3 --image ubuntu-24.04 --network lab-net \
  --security-group sg-gns3 --key-name lab-key \
  --user-data /tmp/lab/ubuntu-cloud-config.yaml --wait

os server create lab-assistant \
  --flavor lab.assistant --image ubuntu-24.04 --network lab-net \
  --security-group sg-assistant --key-name lab-key \
  --user-data /tmp/lab/ubuntu-cloud-config.yaml --wait

os server create lab-windows \
  --flavor lab.windows --image windows-11 --network lab-net \
  --security-group sg-windows --key-name lab-key \
  --config-drive true --user-data /tmp/lab/windows.ps1 --wait
```

생성 후 비밀번호가 담긴 사본은 지웁니다.

```bash
sudo docker exec -u 0 kolla_toolbox rm -rf /tmp/lab
shred -u ~/lab/windows.ps1
```

#### D-3. Floating IP

```bash
for pair in lab-gns3:192.168.0.201 lab-assistant:192.168.0.202 lab-windows:192.168.0.203; do
  srv=${pair%%:*}; fip=${pair##*:}
  os floating ip create --floating-ip-address "$fip" provider
  os server add floating ip "$srv" "$fip"
done
os server list -c Name -c Status -c Networks
```

## 검증

```bash
# 클라우드 이니트 완료 대기 후 KVM / vmx 확인 (lab-gns3)
ssh -i ~/.ssh/lab-key ubuntu@<FLOATING_IP_GNS3> \
  'cloud-init status --wait; ls -l /dev/kvm; grep -c vmx /proc/cpuinfo'
```

| 확인 | 기대값 |
|---|---|
| `/dev/kvm` | 존재 (`crw-rw---- root kvm`) |
| `grep -c vmx /proc/cpuinfo` | vCPU 수 (lab.gns3는 `6`) |
| `os server list` | 3대 모두 `ACTIVE` |
| `ssh ubuntu@<FLOATING_IP_ASSISTANT>` | 로그인 성공 |

포트 열림 확인은 **lab-assistant VM 안에서** 합니다.

```bash
ssh -i ~/.ssh/lab-key ubuntu@<FLOATING_IP_ASSISTANT>
nc -zv <GNS3_LAB_IP> 3080      # GNS3 설치 후
nc -zv <WIN_LAB_IP> 22
nc -zv <WIN_LAB_IP> 5900
```

## 트러블슈팅 (gotchas)

- **qrouter 네임스페이스에서 포트 테스트하면 실패합니다.** `ip netns exec qrouter-... nc ...`의 출발지는 라우터 IP(`10.10.0.1`)라 어떤 SG에도 허용되지 않습니다. SG 문제로 오해하지 말고 assistant VM에서 테스트하세요.
- **`--file` / `--user-data` / `--public-key` 경로는 컨테이너 내부 경로**입니다. 호스트 파일은 `docker cp`로 넣거나 일회용 컨테이너에 `-v`로 마운트하세요.
- **`Permission denied`로 user_data를 못 읽음**: `umask 077` 상태에서 만든 디렉터리(700)를 `docker cp`하면 권한이 그대로 넘어가 컨테이너 사용자가 못 읽습니다. `docker exec -u 0 kolla_toolbox chmod -R a+rX /tmp/lab`로 해결.
- **cinder가 없음**: 볼륨 부팅 옵션은 쓰지 마세요. 루트 디스크 크기는 flavor의 `--disk`로 결정됩니다.
- Windows user_data에는 비밀번호가 평문으로 들어갑니다. 메타데이터/config drive에 남으므로, 첫 부팅 후 비밀번호를 바꾸는 것을 권장합니다.
