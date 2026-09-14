#!/usr/bin/env bash
# ==============================================================================
# static_check.sh
#
# 目的：
#   对所有 installer 脚本 + common/platform.sh 做"不上机"的静态质量门禁：
#     Gate 1: bash -n        —— 语法检查（不执行，只解析）
#     Gate 2: shellcheck     —— 静态分析（-S warning，warning 及以上才算问题）
#
# 用法：
#   bash static_check.sh
#   （可在任意目录执行；脚本自动定位 ../installers/）
#
# 报告：
#   ./reports/static_check_report_YYYYMMDD_HHMMSS.txt
#   （带时间戳，多次运行不互相覆盖；v3.0.0-rc4 起新增）
#
# 退出码：
#   0 = 两门禁全 PASS
#   1 = 任一文件 bash -n 失败，或 shellcheck 有 warning 及以上输出
#
# 注意：
#   - shellcheck 未安装时 Gate 2 记 SKIP（不 FAIL），但会明确提示
#   - 本脚本只做静态检查，不执行任何 installer；运行时问题请用
#     dry_run_node_exporter.sh 等生命周期脚本验证
# ==============================================================================

set -uo pipefail
# 不设 -e：收集所有文件的结果后再统一判定，避免第一个失败就看不到全貌

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLERS_DIR="${SCRIPT_DIR}/../installers"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
REPORT_DIR="${SCRIPT_DIR}/reports"
REPORT="${REPORT_DIR}/static_check_report_${TIMESTAMP}.txt"

mkdir -p "${REPORT_DIR}"

# 所有输出同时 tee 到报告文件
exec > >(tee "${REPORT}") 2>&1

echo "=============================================================================="
echo "v6r4-RC7 静态检查"
echo "时间: $(date -Iseconds)"
echo "主机: $(hostname 2>/dev/null || echo unknown)"
echo "目录: ${INSTALLERS_DIR}"
echo "报告: ${REPORT}"
echo "=============================================================================="
echo

FAIL=0

# ------------------------------------------------------------------------------
# 收集待检查文件清单：10 个 installer + common/platform.sh
# glob 动态展开，新增 installer 无需改本脚本
# ------------------------------------------------------------------------------
FILES=()
for f in "${INSTALLERS_DIR}"/*.sh "${INSTALLERS_DIR}"/common/*.sh; do
  [[ -f "${f}" ]] && FILES+=("${f}")
done

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "[FAIL] 未找到任何待检查脚本（${INSTALLERS_DIR} 为空？）"
  exit 1
fi

echo "待检查文件数: ${#FILES[@]}"
echo

# ------------------------------------------------------------------------------
# Gate 1: bash -n 语法检查
# 只解析不执行；能抓出括号不配对、heredoc 未闭合、关键字拼错等硬伤
# ------------------------------------------------------------------------------
echo "=============================================================================="
echo "Gate 1: bash -n 语法检查"
echo "=============================================================================="
GATE1_FAIL=0
for f in "${FILES[@]}"; do
  if bash -n "${f}" 2>&1; then
    echo "[OK]   bash -n: $(basename "${f}")"
  else
    echo "[FAIL] bash -n: $(basename "${f}")"
    GATE1_FAIL=1
  fi
done
if [[ ${GATE1_FAIL} -ne 0 ]]; then
  FAIL=1
fi
echo

# ------------------------------------------------------------------------------
# Gate 2: shellcheck 静态分析（-S warning）
# 抓 set -u 下 unbound variable、SC2155 local 掩盖返回值、SC2086 未引用展开等
# shellcheck 未安装时记 SKIP 而非 FAIL（环境差异容忍），但明确提示
# ------------------------------------------------------------------------------
echo "=============================================================================="
echo "Gate 2: shellcheck -S warning"
echo "=============================================================================="
if ! command -v shellcheck >/dev/null 2>&1; then
  echo "[SKIP] shellcheck 未安装，跳过 Gate 2"
  echo "       安装: apt-get install -y shellcheck / dnf install -y ShellCheck"
else
  echo "shellcheck 版本: $(shellcheck --version | awk '/^version:/{print $2}')"
  echo
  GATE2_FAIL=0
  for f in "${FILES[@]}"; do
    OUT="$(shellcheck -S warning "${f}" 2>&1)"
    if [[ -z "${OUT}" ]]; then
      echo "[OK]   shellcheck: $(basename "${f}")"
    else
      echo "[FAIL] shellcheck: $(basename "${f}")"
      echo "${OUT}" | sed 's/^/       /'
      GATE2_FAIL=1
    fi
  done
  if [[ ${GATE2_FAIL} -ne 0 ]]; then
    FAIL=1
  fi
fi
echo

# ------------------------------------------------------------------------------
# 汇总
# ------------------------------------------------------------------------------
echo "=============================================================================="
echo "总结"
echo "=============================================================================="
echo "时间: $(date -Iseconds)"
echo "报告: ${REPORT}"
if [[ ${FAIL} -eq 0 ]]; then
  echo "结论: PASS — 静态检查全通过（可进入 dry-run 阶段）"
  exit 0
else
  echo "结论: FAIL — 见上方 [FAIL] 行，修复后重跑"
  exit 1
fi
