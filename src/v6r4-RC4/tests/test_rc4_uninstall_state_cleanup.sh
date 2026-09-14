#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${SCRIPT_DIR}/.."
COMMON="${ROOT}/installers/common/platform.sh"
pass=0; fail=0
ok(){ echo "[PASS] $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; fail=$((fail+1)); }

# shellcheck disable=SC1090
source "${COMMON}"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
base="${tmp}/prometheus"
mkdir -p "${base}/state/prometheus-29090" "${base}/state/prometheus-9090"
printf x > "${base}/state/prometheus-29090/access-request.md"
printf y > "${base}/state/prometheus-9090/access-request.md"
printf 'registry\n' > "${base}/state/ownership.tsv"

if safe_remove_instance_state_dir "${base}/state/prometheus-29090" "${base}" >/dev/null; then
  [[ ! -e "${base}/state/prometheus-29090" ]] && ok "full uninstall state dir removed" || bad "target state dir still exists"
else bad "safe state cleanup rejected valid instance state"; fi
[[ -e "${base}/state/prometheus-9090/access-request.md" ]] && ok "sibling instance state preserved" || bad "sibling instance state was removed"
[[ -e "${base}/state/ownership.tsv" ]] && ok "shared ownership registry preserved" || bad "shared ownership registry was removed"

if safe_remove_instance_state_dir "${base}/state" "${base}" >/dev/null 2>&1; then bad "state root deletion was allowed"; else ok "state root deletion rejected"; fi
if safe_remove_instance_state_dir "${base}" "${base}" >/dev/null 2>&1; then bad "component root deletion was allowed"; else ok "component root deletion rejected"; fi
if safe_remove_instance_state_dir "${tmp}/outside" "${base}" >/dev/null 2>&1; then bad "outside deletion was allowed"; else ok "outside deletion rejected"; fi
mkdir -p "${base}/state/nested/child"
if safe_remove_instance_state_dir "${base}/state/nested/child" "${base}" >/dev/null 2>&1; then bad "nested state deletion was allowed"; else ok "nested state deletion rejected"; fi
mkdir -p "${tmp}/escape-target"
ln -s "${tmp}/escape-target" "${base}/state/prometheus-escape"
if safe_remove_instance_state_dir "${base}/state/prometheus-escape" "${base}" >/dev/null 2>&1; then bad "symlink state deletion was allowed"; else ok "symlink state deletion rejected"; fi
[[ -d "${tmp}/escape-target" ]] && ok "symlink escape target preserved" || bad "symlink escape target was damaged"

# 6 shared-state installers must clean instance state only in remove branch.
for f in \
  alertmanager_installer_v2.0.0.sh \
  blackbox_exporter_installer_v2.0.0.sh \
  node_exporter_installer_v4.0.0.sh \
  prometheus_installer_v6.0.0.sh \
  snmp_exporter_installer_v1.0.0.sh \
  victoriametrics_installer_v2.0.0.sh; do
  path="${ROOT}/installers/${f}"
  if grep -A4 'UNINSTALL_MODE:-remove.*== remove' "${path}" | grep -q 'safe_remove_instance_state_dir "$(INSTANCE_STATE_DIR)"'; then
    ok "${f} full uninstall cleans instance state"
  else
    bad "${f} missing full-uninstall state cleanup"
  fi
done

# Grafana keeps access-request under instance_root/state and must not gain shared-state cleanup.
grafana="${ROOT}/installers/grafana_installer_v1.0.0.sh"
if grep -q 'acl_emit "$(instance_root)/state/access-request.md"' "${grafana}" && ! grep -q 'safe_remove_instance_state_dir' "${grafana}"; then
  ok "Grafana state remains instance-local and covered by instance removal"
else
  bad "Grafana state cleanup semantics unexpectedly changed"
fi

echo "pass=${pass} fail=${fail}"
[[ "${fail}" -eq 0 ]]
