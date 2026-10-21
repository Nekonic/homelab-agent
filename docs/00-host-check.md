# 00. Kolla 호스트 점검

## 목적

VM을 만들기 전에 Kolla-Ansible 호스트가 다음 조건을 만족하는지 확인합니다.

- 중첩 가상화(nested KVM)가 켜져 있고, 인스턴스 CPU에 `vmx`가 전달되는가 → GNS3 안의 QEMU 장비를 KVM 가속으로 돌리기 위해 필요
- 호스트에서 `openstack` CLI를 쓸 수 있는가
- VM 3대를 올릴 용량이 되는가

## 사전조건

- 예시 환경
  - OS: Ubuntu 24.04
  - Kolla-Ansible **2026.1** (이미지 태그 `2026.1-ubuntu-noble`), 단일 노드
  - HW: i3-12100F (4C/8T), RAM 62GB
- 호스트에 sudo 가능한 계정
- `/etc/kolla/admin-openrc.sh` 존재 (Kolla `post-deploy` 결과물)

## 절차

이 문서의 명령은 모두 **Kolla 호스트**(`<KOLLA_USER>@<KOLLA_HOST>`)에서 실행합니다.

### 0. 레포 받기

01~03, 05~07에서 이 레포의 스크립트를 Kolla 호스트에서 씁니다. 먼저 클론해 둡니다([README의 시작하기](../README.md#시작하기-레포-받기)).

```bash
# (Kolla 호스트)
git clone https://github.com/Nekonic/homelab-agent.git ~/homelab-agent
REPO=~/homelab-agent      # 이후 문서의 $REPO / <REPO>. 새 셸마다 다시 지정
```

인터넷이 안 되면 PC에서 받아 `scp -r homelab-agent <KOLLA_USER>@<KOLLA_HOST>:`로 복사합니다. 비서 VM에는 [04 문서](04-hermes-agent.md#0-레포-받기-비서-vm) 시작할 때 따로 받습니다.

비밀값 파일 `~/lab-secrets.env`(600)도 이때 만들어 둡니다([README 비밀값 관리](../README.md#비밀값-관리)).

### 1. 호스트 중첩 가상화 확인

```bash
cat /sys/module/kvm_intel/parameters/nested     # Y 또는 1 이면 OK
# AMD라면
cat /sys/module/kvm_amd/parameters/nested
```

`N`이면 활성화 후 재부팅(또는 모듈 재적재)합니다.

```bash
echo "options kvm_intel nested=1" | sudo tee /etc/modprobe.d/kvm-nested.conf
# 실행 중인 VM이 없을 때
sudo modprobe -r kvm_intel && sudo modprobe kvm_intel
```

### 2. openstack CLI 헬퍼 준비

호스트에는 openstack 클라이언트를 따로 설치하지 않고, Kolla의 `kolla_toolbox` 컨테이너 안의 CLI를 씁니다. admin-openrc의 `OS_*` 변수를 `-e`로 넘기는 함수를 만들어 둡니다.

```bash
set -a; source <(sudo cat /etc/kolla/admin-openrc.sh); set +a
E=$(env | grep ^OS_ | sed "s/^/-e /" | tr "\n" " ")
os(){ sudo docker exec $E kolla_toolbox openstack "$@"; }

os token issue -f value -c expires   # 동작 확인
```

> 새 셸을 열 때마다 위 3줄을 다시 실행해야 합니다. `~/.bashrc`에 넣어도 되지만 비밀번호가 환경변수에 올라간다는 점은 유의하세요.

### 3. 인스턴스 CPU에 vmx가 전달되는지 먼저 확인

흔히 "nested를 쓰려면 nova `cpu_mode=host-passthrough`로 바꿔라"고 하지만, **먼저 현재 상태를 확인하세요.** 예시 환경에서는 기본 설정(custom 모델)에서도 이미 `vmx`가 전달되고 있어서 변경이 필요 없었습니다.

아무 인스턴스나 하나 떠 있는 상태에서:

```bash
sudo docker exec nova_libvirt virsh list --all
sudo docker exec nova_libvirt virsh dumpxml <domain-name> | sed -n '/<cpu/,/<\/cpu>/p'
```

예시 출력(요약):

```xml
<cpu mode='custom' match='exact' check='partial'>
  <model fallback='forbid'>Skylake-Client-IBRS</model>
  ...
  <feature policy='require' name='vmx'/>
</cpu>
```

- `<feature policy='require' name='vmx'/>`가 있으면 **변경 불필요**.
- 없을 때만 `/etc/kolla/config/nova/nova-compute.conf`에 아래를 넣고 `kolla-ansible reconfigure -t nova` 하세요.

  ```ini
  [libvirt]
  cpu_mode = host-passthrough
  ```

  (host-passthrough는 라이브 마이그레이션 호환성을 잃지만 단일 노드에서는 상관없습니다.)

인스턴스 내부 최종 확인은 [01 문서의 서버 생성 후 검증](01-openstack-reset-and-base.md#검증)에서 합니다.

### 4. 용량 확인

```bash
os hypervisor stats show
os hypervisor list --long
free -g; df -h /var/lib/docker /var/lib/nova 2>/dev/null
```

이 프로젝트의 flavor 합계는 vCPU 14 / RAM 48GB / 디스크 310GB입니다(`lab.gns3` 24GB/120GB, `lab.assistant` 8GB/40GB, `lab.windows16` 16GB/150GB). Windows VM은 평소 꺼 두지만, 꺼진 VM도 flavor만큼 메모리를 예약하므로 합계 기준으로 봅니다. 4C/8T 호스트라면 CPU 오버커밋(기본 `cpu_allocation_ratio` 16)으로 충분하고, RAM은 호스트와 Kolla 컨테이너 몫까지 감안해 여유를 확인하세요.

### 5. 서비스 구성 확인

```bash
os service list
os extension list --network -c Alias -f value | head
```

## 검증

| 항목 | 기대값 |
|---|---|
| `cat /sys/module/kvm_intel/parameters/nested` | `Y` |
| libvirt 도메인 `<cpu>` | `vmx` feature `require` |
| `os token issue` | 토큰 발급 성공 |
| `os hypervisor stats show` | vCPU/RAM/디스크 여유가 flavor 합계 이상 |

## 트러블슈팅 (gotchas)

- **`kolla_toolbox`에는 heat/barbican CLI 플러그인이 없습니다.** `openstack stack ...`, `openstack secret ...`은 동작하지 않으므로 이 문서는 전부 일반 CLI 명령으로 진행합니다.
- **cinder(볼륨 서비스)가 없는 배포**입니다. 서버는 모두 이미지 기반 ephemeral 루트 디스크(flavor 디스크 크기)로 생성합니다. `--boot-from-volume` 같은 옵션은 쓰지 않습니다.
- `os` 함수에서 파일 인자(`--file`, `--user-data`)는 **컨테이너 내부 경로**로 해석됩니다. 호스트 파일을 넘기는 방법은 01 문서의 트러블슈팅을 참고하세요.
- `sudo cat`으로 openrc를 읽는 이유: `/etc/kolla/admin-openrc.sh`는 보통 root만 읽을 수 있습니다.
