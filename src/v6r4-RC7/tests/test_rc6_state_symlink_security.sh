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
outside="${tmp}/outside"
mkdir -p "${base}" "${outside}"
INST_ROOT="${base}"

# 0) RC5 实机 P0 回归：首次安装时 component root 尚不存在必须可安全创建。
fresh_parent="${tmp}/fresh-parent"
fresh_base="${fresh_parent}/prometheus"
mkdir -p "${fresh_parent}"
set +e
secure_validate_dir_under_root "${fresh_base}/state/prometheus-29099" "${fresh_base}" >/dev/null 2>&1
fresh_validate_rc=$?
set -e
[[ "${fresh_validate_rc}" -eq 2 ]] && ok "missing component root classified as creatable" || bad "missing component root not classified as creatable (rc=${fresh_validate_rc})"
if secure_ensure_dir_under_root "${fresh_base}/state/prometheus-29099" "${fresh_base}" 0755 root root; then
  ok "first-install creates missing component root safely"
else
  bad "first-install rejected missing component root"
fi
[[ -d "${fresh_base}" && ! -L "${fresh_base}" ]] && ok "first-install component root is a real directory" || bad "first-install component root invalid"
[[ -d "${fresh_base}/state/prometheus-29099" ]] && ok "first-install nested state created" || bad "first-install nested state missing"

# 0b) component root 本身为 symlink（含 pre-existing attack）必须 fail closed。
rm -rf "${fresh_base}"
ln -s "${outside}" "${fresh_base}"
if secure_ensure_dir_under_root "${fresh_base}/state/prometheus-29099" "${fresh_base}" 0755 root root >/dev/null 2>&1; then
  bad "symlink component root accepted"
else
  ok "symlink component root rejected"
fi
[[ ! -e "${outside}/state/prometheus-29099" ]] && ok "symlink component root external target unchanged" || bad "symlink component root wrote outside"
rm -f "${fresh_base}"

# 0c) 不允许为了首次安装递归创建不存在的 component-root 父目录。
missing_parent_base="${tmp}/missing-parent/sub/prometheus"
if secure_ensure_dir_under_root "${missing_parent_base}/state/prometheus-29099" "${missing_parent_base}" 0755 root root >/dev/null 2>&1; then
  bad "missing parent hierarchy implicitly created"
else
  ok "missing parent hierarchy rejected"
fi
[[ ! -e "${tmp}/missing-parent" ]] && ok "missing parent hierarchy left unchanged" || bad "missing parent hierarchy was created"

# 1) 正常 shared state 可创建并写入。
if secure_ensure_dir_under_root "${base}/state/prometheus-29090" "${base}" 0755 root root; then
  ok "normal state path accepted"
else
  bad "normal state path rejected"
fi
[[ -d "${base}/state/prometheus-29090" ]] && ok "normal instance state created" || bad "normal instance state missing"
rm -rf "${base}/state"

# 2) P0 回归：state 根是 symlink 时，ACL 写入必须拒绝且外部目标不得产生文件。
ln -s "${outside}" "${base}/state"
_ACL_REQUESTS=()
acl_request "test" "127.0.0.1" "127.0.0.1" tcp "29090" ingress "test" no "uat"
if acl_emit "${base}/state/prometheus-29090/access-request.md" >/dev/null 2>&1; then
  bad "acl_emit allowed symlink state root"
else
  ok "acl_emit rejects symlink state root"
fi
[[ ! -e "${outside}/prometheus-29090/access-request.md" ]] && ok "symlink escape target not written by acl_emit" || bad "acl_emit wrote outside component root"

# 3) ownership registry 也必须拒绝 symlink state 根。
if ownership_register "prometheus-29090" "29090" "prometheus" "prometheus-29090.service" \
  "${base}/prometheus-29090/etc/prometheus.yml" "${base}/prometheus-29090/data" "${base}/prometheus-29090/log" >/dev/null 2>&1; then
  bad "ownership_register allowed symlink state root"
else
  ok "ownership_register rejects symlink state root"
fi
[[ ! -e "${outside}/ownership.tsv" ]] && ok "ownership registry not written outside component root" || bad "ownership registry escaped component root"
rm "${base}/state"

# 4) 实例 state 本身为 symlink 时拒绝写入。
mkdir -p "${base}/state"
ln -s "${outside}" "${base}/state/prometheus-29090"
if acl_emit "${base}/state/prometheus-29090/access-request.md" >/dev/null 2>&1; then
  bad "acl_emit allowed symlink instance state"
else
  ok "acl_emit rejects symlink instance state"
fi
[[ ! -e "${outside}/access-request.md" ]] && ok "instance symlink escape target not written" || bad "instance symlink allowed outside write"
rm "${base}/state/prometheus-29090"

# 5) Grafana instance-local state 也应受同一保护；正常路径必须可写。
mkdir -p "${base}/grafana-33000"
if secure_ensure_dir_under_root "${base}/grafana-33000/state" "${base}" 0755 root root; then
  ok "instance-local Grafana state accepted"
else
  bad "instance-local Grafana state rejected"
fi
rm -rf "${base}/grafana-33000"
mkdir -p "${outside}/grafana-33000"
ln -s "${outside}/grafana-33000" "${base}/grafana-33000"
if secure_ensure_dir_under_root "${base}/grafana-33000/state" "${base}" 0755 root root >/dev/null 2>&1; then
  bad "symlink instance root allowed state creation"
else
  ok "symlink instance root rejected"
fi
[[ ! -e "${outside}/grafana-33000/state" ]] && ok "Grafana symlink escape target not modified" || bad "Grafana state escaped component root"
rm "${base}/grafana-33000"

# 6) ownership read/write paths must fail closed on symlink state root.
rm -rf "${base}/state"
ln -s "${outside}" "${base}/state"
printf 'prometheus-29090\t29090\tprometheus\tprometheus-29090.service\t/x\t/y\t/z\n' > "${outside}/ownership.tsv"
if ownership_belongs_to "prometheus-29090.service" "prometheus-29090" >/dev/null 2>&1; then
  bad "ownership_belongs_to trusted symlink state root"
else
  ok "ownership_belongs_to fails closed on symlink state root"
fi
before="$(sha256sum "${outside}/ownership.tsv" | awk '{print $1}')"
if ownership_forget "prometheus-29090" >/dev/null 2>&1; then
  bad "ownership_forget accepted symlink state root"
else
  ok "ownership_forget rejects symlink state root"
fi
after="$(sha256sum "${outside}/ownership.tsv" | awk '{print $1}')"
[[ "${before}" == "${after}" ]] && ok "ownership file outside component root unchanged" || bad "ownership_forget modified outside file"

echo "pass=${pass} fail=${fail}"
[[ "${fail}" -eq 0 ]]
