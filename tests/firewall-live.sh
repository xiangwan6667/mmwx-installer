#!/usr/bin/env bash
# Changes networking: run only on a disposable GitHub-hosted CI runner.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted ]] || exit 77
cd "$(dirname "$0")/.."
source ./install.sh
[[ ! -e $ROOT ]] || die 'Firewall test directory already exists.'
mkdir -m 700 "$ROOT"
mkdir -p "$ROOT/config" "$ROOT/state"
printf '173.245.48.0/20\n' > "$ROOT/state/cloudflare-v4.txt"
cleanup() {
  docker rm -f mmwx-firewall-test >/dev/null 2>&1 || true
  docker network rm mmwx-firewall-test >/dev/null 2>&1 || true
  ip netns del mmwx-client 2>/dev/null || true
}
trap cleanup EXIT
configure_timezone
[[ $(timedatectl show --property=Timezone --value) == Asia/Shanghai ]]
ip netns add mmwx-client
ip link add mmwx-host type veth peer name mmwx-peer
ip link set mmwx-peer netns mmwx-client
ip addr add 198.18.0.1/30 dev mmwx-host
ip link set mmwx-host up
ip netns exec mmwx-client ip link set lo up
ip netns exec mmwx-client ip link set mmwx-peer up
ip netns exec mmwx-client ip addr add 198.18.0.2/30 dev mmwx-peer
ip netns exec mmwx-client ip addr add 173.245.48.10/32 dev mmwx-peer
ip netns exec mmwx-client ip route add default via 198.18.0.1
ip route add 173.245.48.10/32 dev mmwx-host
docker network create --opt com.docker.network.bridge.name=br-mmwx-front mmwx-firewall-test
docker run -d --name mmwx-firewall-test --restart unless-stopped --network mmwx-firewall-test -p 80:80 -p 443:80 nginx:alpine
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment mmwx-ssh
ufw allow from 173.245.48.0/20 to any port 80,443 proto tcp comment mmwx-cf
ufw --force enable
apply_firewall
remove_legacy_cf_rules
[[ $(ufw status | grep -c '# mmwx-cf' || true) == 0 ]]
assert_access() {
  local port
  for port in 80 443; do
    ip netns exec mmwx-client curl --noproxy '*' --interface 173.245.48.10 --retry 5 --retry-connrefused --retry-delay 1 -fsS --max-time 3 "http://198.18.0.1:$port/" -o /dev/null
    if ip netns exec mmwx-client curl --noproxy '*' --interface 198.18.0.2 -fsS --max-time 2 "http://198.18.0.1:$port/" -o /dev/null 2>/dev/null; then
      die "Non-Cloudflare source reached published port $port"
    fi
  done
}
assert_access
ufw reload
assert_access
install_units
systemctl restart docker
assert_access
printf '{"stage":1}' > "$ROOT/progress.json"
# A stopped/interrupted legacy task must not leave the daily refresh timer stopped.
ensure_layout
systemctl is-active --quiet mmwx-cf-sync.timer
# Removing the manager must retain operational boot and refresh hooks.
confirm() { return 0; }
uninstall_script
[[ ! -e /usr/local/bin/mmwx && ! -e /usr/local/sbin/mmwx-installer ]]
[[ -x /usr/local/lib/mmwx-installer/runtime.sh ]]
if bash /usr/local/lib/mmwx-installer/runtime.sh >/dev/null 2>&1; then die 'Backend reopened management menu'; fi
if bash /usr/local/lib/mmwx-installer/runtime.sh firewall-apply status >/dev/null 2>&1; then die 'Backend accepted a management action'; fi
systemctl restart docker
assert_access
# Simulate a user launching a downloaded copy and exiting the initial menu.
cp ./install.sh /root/mmwx-install.sh
python3 - <<'PY'
import os, pty, select, time
pid, fd = pty.fork()
if pid == 0:
    os.execl('/bin/bash', 'bash', '/root/mmwx-install.sh')
buffer = b''
deadline = time.monotonic() + 20
while time.monotonic() < deadline:
    ready, _, _ = select.select([fd], [], [], 0.2)
    if ready:
        try:
            data = os.read(fd, 4096)
        except OSError:
            break
        if not data:
            break
        buffer += data
        if '选择：'.encode() in buffer:
            os.write(fd, b'0\n')
            buffer = b''
else:
    os.kill(pid, 15)
    raise RuntimeError('Initial management menu did not exit')
_, status = os.waitpid(pid, 0)
assert os.waitstatus_to_exitcode(status) == 0
PY
[[ -x /usr/local/bin/mmwx && ! -f /root/mmwx-install.sh ]]
/usr/local/bin/mmwx --version
# Old recognized copies are also removed when uninstalling the manager.
cp ./install.sh /root/mmwx-install.sh
uninstall_script
[[ ! -e /root/mmwx-install.sh && ! -e /usr/local/bin/mmwx && ! -e /usr/local/sbin/mmwx-installer ]]
echo 'PASS: only permitted sources reach Docker through ipset, including after UFW reload and Docker restart'
