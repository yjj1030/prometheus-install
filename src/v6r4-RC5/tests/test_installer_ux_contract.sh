#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${SCRIPT_DIR}/.."
I="${ROOT}/installers"
P="${I}/common/platform.sh"
formal=(
  alertmanager_installer_v2.0.0.sh blackbox_exporter_installer_v2.0.0.sh
  grafana_installer_v1.0.0.sh node_exporter_installer_v4.0.0.sh
  prometheus_installer_v6.0.0.sh snmp_exporter_installer_v1.0.0.sh
  victoriametrics_installer_v2.0.0.sh
)

pass=0
for n in "${formal[@]}"; do
  f="${I}/${n}"
  bash -n "${f}"
  TERM=xterm bash "${f}" help >/dev/null
  out="$(printf '\n' | TERM=xterm timeout 3 bash "${f}" 2>&1)"
  grep -q '^退出$' <<<"${out}"
  pass=$((pass+1))
done

# q 在向导内必须退出整个安装器，而不是退回主菜单。
out="$(printf '1\nq\n' | TERM=xterm timeout 3 bash "${I}/grafana_installer_v1.0.0.sh" 2>&1 || true)"
[[ "$(grep -c 'grafana 安装器 v' <<<"${out}")" -eq 1 ]]
grep -q '^退出$' <<<"${out}"

# 安装最终确认必须使用清晰序号菜单。
grep -q '1) 确认以上信息，立即开始安装 \[默认\]' "${P}"
grep -q '2) 返回重新修改安装参数' "${P}"
grep -q '3) 取消本次安装，返回主菜单' "${P}"

# 卸载菜单：1/2/3/q，默认完整卸载。
grep -q '1) 完整卸载 \[默认\]' "${P}"
grep -q '2) 保留实例目录卸载' "${P}"
grep -q '3) 取消并返回主菜单' "${P}"

# 任何正式组件不得再把持久化下载缓存写到 /var/cache。
for n in "${formal[@]}"; do
  ! grep -q '/var/cache' "${I}/${n}"
done
# 公共库不得硬编码内网地址。
grep -q '^INTERNAL_MIRROR="${INTERNAL_MIRROR:-}"' "${P}"
! grep -q '100\.127\.' "${P}"

# 角色/单节点契约。
grep -q 'ROLE="${ROLE:-center}"' "${I}/prometheus_installer_v6.0.0.sh"
grep -q 'RETENTION_TIME="${RETENTION_TIME:-7d}"' "${I}/prometheus_installer_v6.0.0.sh"
grep -q 'CLUSTER_ENABLED="${CLUSTER_ENABLED:-0}"' "${I}/alertmanager_installer_v2.0.0.sh"
grep -q -- '--cluster.listen-address=${cluster_listen}' "${I}/alertmanager_installer_v2.0.0.sh"
# VM 单节点只暴露 HTTP 端口，不应存在 8480/8481 INSERT/SELECT 伪端口。
! grep -Eq 'INSERT_PORT|SELECT_PORT|8480|8481' "${I}/victoriametrics_installer_v2.0.0.sh"

# platform family 映射。
bash -c 'source "$1"; PLATFORM_ID=debian12; [[ $(detect_platform) == debian ]]; PLATFORM_ID=rocky9; [[ $(detect_platform) == rhel ]]; PLATFORM_ID=opensuse15; [[ $(detect_platform) == suse ]]' _ "${P}"

# 安全删除只允许组件根目录下实例，不允许删组件根本身。
tmp="$(mktemp -d)"; mkdir -p "${tmp}/component/instance/data"
bash -c 'source "$1"; safe_remove_instance_root "$2/component/instance" "$2/component"' _ "${P}" "${tmp}"
[[ ! -e "${tmp}/component/instance" ]]
if bash -c 'source "$1"; safe_remove_instance_root "$2/component" "$2/component"' _ "${P}" "${tmp}" >/dev/null 2>&1; then
  echo "FAIL: safe_remove_instance_root allowed component root" >&2; exit 1
fi
rm -rf "${tmp}"

echo "PASS installer UX contract: ${pass}/7 installers"
