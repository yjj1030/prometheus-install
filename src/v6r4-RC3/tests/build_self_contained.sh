#!/usr/bin/env bash
# ==============================================================================
# build_self_contained.sh — 把 7 个正式 installer 打包成单文件可分发版本
#
# 目的：
#   v3.0.0-rc4 部署时只允许"单 installer 文件"传到目标服务器（不带 common/）。
#   本脚本把 common/platform.sh 内容嵌入每个 installer 末尾，让它们成为
#   自包含的单文件 — 拷一个就能跑。
#
# 工作流：
#   - 开发源码：repo 原 installer source common/platform.sh
#   - 部署产物：本脚本产出 installers_dist/<name>.sh，platform 永久内嵌
#   - 正式产物禁止读取同目录 common/platform.sh，避免旧公共库覆盖已审核代码
#   - 改了 platform.sh：重跑本脚本 → 重新出 installers_dist/
#
# 实现要点：
#   1. installer 顶部 source_platform 只从本文件末尾嵌入块提取公共库
#   2. 嵌入块用 __PLATFORM_EMBED_BEGIN__ / __PLATFORM_EMBED_END__ 行做边界标记
#      （awk 用全行匹配保证唯一，不会误伤）
#   3. 脚本幂等：重跑会先剥掉旧嵌入块再追加新的；source_platform 函数替换也幂等
#
# 用法：
#   bash tests/build_self_contained.sh
#   # 产物：installers_dist/<name>.sh （7 个正式 installer，单文件即可拷即用）
#
# 退出码：0=全成功；1=任一失败
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLERS_DIR="${SCRIPT_DIR}/../installers"
PLATFORM_SH="${INSTALLERS_DIR}/common/platform.sh"
DIST_DIR="${SCRIPT_DIR}/../installers_dist"

MARKER_BEGIN="# __PLATFORM_EMBED_BEGIN__"
MARKER_END="# __PLATFORM_EMBED_END__"

# source_platform 函数：嵌入进每个 installer 顶部 source 行处
# （替换原 `source "${SCRIPT_DIR}/common/platform.sh"`）
read -r -d '' SOURCE_PLATFORM_BLOCK <<'EOF' || true
# ------------------------------------------------------------------------------
# source_platform: 正式 self-contained 适配器
#   - 只读取本文件末尾的嵌入 platform 块
#   - 永不读取 sibling common/platform.sh，避免生产侧旁路覆盖
#   - 临时文件 source 后立即删除
# ------------------------------------------------------------------------------
source_platform() {
  local self="${BASH_SOURCE[0]}"
  local lib
  lib="$(mktemp -t platform.sh.XXXXXX)"
  sed -n '/^# __PLATFORM_EMBED_BEGIN__$/,/^# __PLATFORM_EMBED_END__$/p' "${self}" \
    | sed '1d;$d' > "${lib}"
  [[ -s "${lib}" ]] || { echo "source_platform: 内嵌 platform 块为空" >&2; rm -f "${lib}"; return 1; }
  # shellcheck disable=SC1090
  source "${lib}"
  rm -f "${lib}"
  return 0
}
source_platform
EOF

# 校验源
[[ -f "${PLATFORM_SH}" ]] || { echo "缺源: ${PLATFORM_SH}" >&2; exit 1; }

# 校验嵌入块标记在 platform.sh 里不出现（避免冲突）
if grep -qE '^# __PLATFORM_EMBED_(BEGIN|END)__$' "${PLATFORM_SH}"; then
  echo "ERROR: platform.sh 内含嵌入标记，会被误伤：${PLATFORM_SH}" >&2
  exit 1
fi

mkdir -p "${DIST_DIR}"

# 找出 7 个正式 installer（排除 cadvisor/vmalert/vmauth；glob 自动适配未来新增/改名）
declare -a INSTALLERS=()
for f in "${INSTALLERS_DIR}"/*installer*.sh; do
  case "$(basename "${f}")" in
    cadvisor_installer_*.sh|vmalert_installer_*.sh|vmauth_installer_*.sh) continue ;;
  esac
  INSTALLERS+=("${f}")
done
[[ ${#INSTALLERS[@]} -gt 0 ]] || { echo "未找到任何 installer" >&2; exit 1; }

# awk 脚本：剥掉已有的 __PLATFORM_EMBED_BEGIN__/__END__ 块（重跑幂等）
STRIP_EMBED='
  $0 == "'"${MARKER_BEGIN}"'" { skip=1; next }
  $0 == "'"${MARKER_END}"'"   { skip=0; next }
  skip                        { next }
  { print }
'

for src in "${INSTALLERS[@]}"; do
  base="$(basename "${src}")"
  dst="${DIST_DIR}/${base}"

  # 第一步：剥旧嵌入块（幂等）
  tmp="$(mktemp)"
  awk "${STRIP_EMBED}" "${src}" > "${tmp}"

  # 第二步：替换 source 行（幂等：第一次替换，后续不匹配即跳过）
  if grep -qF 'source "${SCRIPT_DIR}/common/platform.sh"' "${tmp}"; then
    # 把 source 行连同它的 # shellcheck disable=SC1091 上面的注释一起替换掉
    # 用 python3 简单点；没有 python3 时用 awk 多行处理
    if command -v python3 >/dev/null 2>&1; then
      python3 - "${tmp}" "${SOURCE_PLATFORM_BLOCK}" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
block = sys.argv[2]
text = p.read_text()
old = 'source "${SCRIPT_DIR}/common/platform.sh"'
assert old in text, f"source line not found in {p}"
text = text.replace(old, block.rstrip("\n") + "\n", 1)
p.write_text(text)
PY
    else
      # bash 兜底：用 awk 替换（保留其他行；SCRIPT_DIR= 行不动）
      tmp2="$(mktemp)"
      awk -v block="${SOURCE_PLATFORM_BLOCK}" '
        /source "\$\{SCRIPT_DIR\}\/common\/platform\.sh"/ {
          print block
          next
        }
        { print }
      ' "${tmp}" > "${tmp2}"
      mv "${tmp2}" "${tmp}"
    fi
  fi

  # 第三步：追加嵌入块
  {
    cat "${tmp}"
    echo ""
    echo "${MARKER_BEGIN}"
    cat "${PLATFORM_SH}"
    echo "${MARKER_END}"
  } > "${dst}"
  chmod 0755 "${dst}"

  # 校验产物
  if ! bash -n "${dst}"; then
    echo "[FAIL] bash -n 失败: ${dst}" >&2
    exit 1
  fi

  size_src="$(wc -c < "${src}")"
  size_dst="$(wc -c < "${dst}")"
  delta=$(( size_dst - size_src ))
  printf "[OK]   %-45s  %6d → %6d  (+%d 字节)\n" "${base}" "${size_src}" "${size_dst}" "${delta}"

  rm -f "${tmp}"
done

echo
echo "=============================================================================="
echo "产物目录: ${DIST_DIR}"
echo "单文件部署：从此目录拷任一 installer 到目标服务器即可运行（无需带 common/）"
echo "=============================================================================="
