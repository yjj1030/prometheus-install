#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${SCRIPT_DIR}/.."
DIST="${ROOT}/installers_dist"

bash "${SCRIPT_DIR}/build_self_contained.sh" >/dev/null

pass=0
for f in "${DIST}"/*installer*.sh; do
  base="$(basename "${f}")"
  tmp="$(mktemp -d)"
  cp "${f}" "${tmp}/${base}"
  chmod 0755 "${tmp}/${base}"

  # 模式 A：真正单文件，无 common/。
  out="$("${tmp}/${base}" help 2>&1)"
  [[ $? -eq 0 ]]
  grep -q '用法\|Usage\|install' <<<"${out}"

  # 模式 B：旁边故意放一个有毒的 common/platform.sh。
  # 正式 self-contained 产物必须完全忽略它。
  mkdir -p "${tmp}/common"
  cat >"${tmp}/common/platform.sh" <<'POISON'
echo 'POISON_COMMON_SHOULD_NOT_RUN' >&2
exit 77
POISON
  out="$("${tmp}/${base}" help 2>&1)"
  [[ $? -eq 0 ]]
  ! grep -q 'POISON_COMMON_SHOULD_NOT_RUN' <<<"${out}"
  rm -rf "${tmp}"
  pass=$((pass+1))
done

[[ "${pass}" -eq 7 ]]
echo "PASS self-contained help: ${pass}/7, sibling common ignored"
