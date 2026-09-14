#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok(){ echo "PASS: $*"; pass=$((pass+1)); }
bad(){ echo "FAIL: $*"; fail=$((fail+1)); }

assert_contains(){ local f="$1" p="$2" n="$3"; if grep -Fq -- "$p" "$f"; then ok "$n"; else bad "$n"; fi; }
assert_not_contains(){ local f="$1" p="$2" n="$3"; if grep -Fq -- "$p" "$f"; then bad "$n"; else ok "$n"; fi; }

PROM="$ROOT/installers/prometheus_installer_v6.0.0.sh"
AM="$ROOT/installers/alertmanager_installer_v2.0.0.sh"
VM="$ROOT/installers/victoriametrics_installer_v2.0.0.sh"
NODE="$ROOT/installers/node_exporter_installer_v4.0.0.sh"
GRAF="$ROOT/installers/grafana_installer_v1.0.0.sh"

assert_contains "$PROM" 'ReadWritePaths=${inst}/data ${inst}/logs' 'Prometheus rhel hardening 精确放行 data/logs'
assert_contains "$AM" 'ReadWritePaths=${inst}/data ${inst}/logs' 'Alertmanager rhel hardening 精确放行 data/logs'
assert_contains "$VM" 'ReadWritePaths=${STORAGE_PATH} ${inst}/logs' 'VictoriaMetrics rhel hardening 精确放行 storage/logs'
assert_contains "$PROM" 'ProtectSystem=full' 'Prometheus 保留 ProtectSystem=full'
assert_contains "$AM" 'ProtectSystem=full' 'Alertmanager 保留 ProtectSystem=full'
assert_contains "$VM" 'ProtectSystem=full' 'VictoriaMetrics 保留 ProtectSystem=full'
assert_contains "$PROM" 'if [[ "${PLATFORM_ID}" == "rhel" ]]' 'Prometheus 仅 rhel-family 应用该放行'
assert_contains "$AM" 'if [[ "${PLATFORM_ID}" == "rhel" ]]' 'Alertmanager 仅 rhel-family 应用该放行'
assert_contains "$VM" 'if [[ "${PLATFORM_ID}" == "rhel" ]]' 'VictoriaMetrics 仅 rhel-family 应用该放行'
assert_contains "$NODE" 'ReadWritePaths=${TEXTFILE_DIR}' 'Node Exporter 原 hardening 保持'
assert_not_contains "$GRAF" 'ProtectSystem=full' 'Grafana 未被误加 RC7 rhel hardening'

# No broad writable root such as /usr/local or component root.
for f in "$PROM" "$AM" "$VM"; do
  if grep -Eq '^ReadWritePaths=/usr/local([[:space:]]|$)' "$f"; then bad "$(basename "$f") 不得放行整个 /usr/local"; else ok "$(basename "$f") 未放行整个 /usr/local"; fi
done

echo "PASS=${pass} FAIL=${fail}"
(( fail == 0 ))
