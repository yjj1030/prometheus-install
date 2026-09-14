#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${SCRIPT_DIR}/.."
COMMON="${ROOT}/installers/common/platform.sh"
pass=0; fail=0
ok(){ echo "[PASS] $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; fail=$((fail+1)); }

# 1. 7 个 cmd_install 必须具备非交互端口门禁。
for f in "${ROOT}"/installers/*_installer_*.sh; do
  if grep -q 'require_install_port_free' "$f"; then ok "$(basename "$f") CLI port gate"; else bad "$(basename "$f") missing CLI port gate"; fi
done

# 2. 真实监听端口必须被检测为占用。
# shellcheck disable=SC1090
source "${COMMON}"
python3 - <<'PY2' >/tmp/rc4-port-test.out 2>/dev/null &
import socket,time
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1], flush=True); s.listen(1); time.sleep(20)
PY2
pid=$!
for _ in $(seq 1 50); do [[ -s /tmp/rc4-port-test.out ]] && break; sleep 0.05; done
port="$(cat /tmp/rc4-port-test.out)"
if port_in_use "${port}"; then ok "port_in_use detects live listener"; else bad "port_in_use missed live listener"; fi
if require_install_port_free "${port}" "test" >/tmp/rc4-port-gate.out 2>&1; then bad "require_install_port_free allowed occupied port"; else ok "CLI gate rejects occupied port"; fi
kill "${pid}" 2>/dev/null || true; wait "${pid}" 2>/dev/null || true; rm -f /tmp/rc4-port-test.out /tmp/rc4-port-gate.out

# 3. 状态与监测必须分流。
if grep -q '2) cmd_status' "${COMMON}" && grep -q '3) managed_instance_probe' "${COMMON}" && ! grep -q '2|3) cmd_status' "${COMMON}"; then
  ok "status/probe menu split"
else bad "status/probe still conflated"; fi

# 4. 当前 shell 代码禁止 /var/cache 组件缓存、废弃 monitorSendMsg 和项目禁止网段。
if rg -n '/var/cache/' "${ROOT}/installers" >/dev/null; then bad "active installers contain /var/cache"; else ok "no /var/cache in active installers"; fi
if rg -n 'monitorSendMsg' "${ROOT}/installers" "${ROOT}/config" >/dev/null; then bad "obsolete monitorSendMsg remains"; else ok "obsolete monitorSendMsg removed"; fi
if rg -n '172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[78][0-9]|9[0-9]|1[01][0-9]|12[0-7])\.|10\.64\.' "${ROOT}/installers" >/dev/null; then
  bad "forbidden network range in active installer shell"
else ok "no forbidden network range in active installer shell"; fi

# 5. VM 单节点不得残留 8480/8481。
if rg -n '8480|8481' "${ROOT}/installers/victoriametrics_installer_v2.0.0.sh" >/dev/null; then bad "VM legacy cluster ports remain"; else ok "VM single-node only uses configured HTTP port"; fi

# 6. Grafana 官方源和 provisioning 必须使用当前实例目录。
GRAFANA="${ROOT}/installers/grafana_installer_v1.0.0.sh"
if grep -q 'dl.grafana.com/grafana/release/${GRAFANA_VERSION}/grafana_${GRAFANA_VERSION}_${GRAFANA_BUILD_ID}_linux_amd64.tar.gz' "${GRAFANA}" && grep -q '849b3f17a0a318a2f1a681b663e9feb4e4fc7f70d43bb0b4ea07cd34b1987462' "${GRAFANA}"; then ok "Grafana official URL/SHA256 pinned for default build"; else bad "Grafana official URL/SHA256 stale"; fi
if grep -q '<<EOF' "${GRAFANA}" && grep -q 'path: ${inst}/data/dashboards' "${GRAFANA}" && grep -q 'ensure_dir "${inst}/data/dashboards"' "${GRAFANA}"; then ok "Grafana dashboard provisioning stays inside instance root"; else bad "Grafana dashboard provisioning path not instance-local"; fi

VM="${ROOT}/installers/victoriametrics_installer_v2.0.0.sh"
if grep -q 'DEFAULT_VERSION="1.151.0"' "${VM}"; then ok "VictoriaMetrics security baseline is 1.151.0"; else bad "VictoriaMetrics default version is below RC5 security baseline"; fi

echo "pass=${pass} fail=${fail}"
[[ "${fail}" -eq 0 ]]
