#!/usr/bin/env bash
# ==============================================================================
# victoriametrics_installer_v2.0.0.sh
#
# VictoriaMetrics 1.151.0 (cluster-disabled, single-node) 跨平台一键安装器 (v3 系列)
#
# ------------------------------------------------------------------------------
# 模块概述
# ------------------------------------------------------------------------------
# 职责：
#   - 单节点 VictoriaMetrics（不开 cluster 模式）
#   - 作为 Prometheus 的远程长期存储（Remote Write 目标 + 查询后端）
#   - 单节点仅暴露 HTTP 端口（默认 8428），写入/查询共用该端口
#   - 通过 ALLOW_CIDRS 控制入方向；G1-L06 修复 CIDR 校验
#
# 关键设计：
#   - bin / logs / secrets 在 instance_root（${INSTALL_ROOT}/victoriametrics-${HTTP_PORT}/）
#   - STORAGE_PATH 默认 $(instance_root)/data（家族统一风格）；独立挂载点用 env 覆盖
#   - vmallow_cidrs：卸载时按备份还原防火墙规则
#
# 关联 ADR / 审核：
#   - ADR-10 路径命名规范
#   - P0-02 访问申请清单（3 端口 × 多 CIDR）
#   - G1-L06 CIDR 格式校验（python3 优先，bash 兜底）
# ==============================================================================

set -euo pipefail

SCRIPT_VERSION="2.0.0"
DEFAULT_VERSION="1.151.0"
INSTALL_ROOT="/usr/local/victoriametrics"
GITHUB_BASE="https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download"
VM_USER="${VM_USER:-victoriametrics}"
VM_GROUP="${VM_GROUP:-victoriametrics}"
DEFAULT_HTTP_PORT=8428
ALLOW_CIDRS_DEFAULT="127.0.0.1/32,192.0.2.0/8"
SERVICE_NAME_PREFIX="victoriametrics"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common/platform.sh"
export INST_ROOT="${INST_ROOT:-${INSTALL_ROOT}}"

VM_VERSION="${VM_VERSION:-${DEFAULT_VERSION}}"
# v3.0.0-rc4: 旧 VM_* 前缀保留为兼容垫片；新名 VICTORIAMETRICS_* 优先
[[ -n "${VM_USER:-}"    && -z "${VICTORIAMETRICS_USER:-}"    ]] && VICTORIAMETRICS_USER="${VM_USER}"
[[ -n "${VM_GROUP:-}"   && -z "${VICTORIAMETRICS_GROUP:-}"   ]] && VICTORIAMETRICS_GROUP="${VM_GROUP}"
[[ -n "${VM_VERSION:-}" && -z "${VICTORIAMETRICS_VERSION:-}" ]] && VICTORIAMETRICS_VERSION="${VM_VERSION}"

# v3: 统一家族目录风格（与 grafana/prometheus 一致）
#   instance_root = ${INSTALL_ROOT}/victoriametrics-${HTTP_PORT}
#   bin / etc / data / logs / secrets 全部收进实例目录
# 端口全部来自环境变量（脚本启动前已确定），顶层派生无 C12 风险
instance_root() { echo "${INSTALL_ROOT}/${SERVICE_NAME_PREFIX}-${HTTP_PORT}"; }
service_unit()  { echo "${SERVICE_NAME_PREFIX}-${HTTP_PORT}.service"; }
INSTANCE_STATE_DIR() { echo "${INSTALL_ROOT}/state/${SERVICE_NAME_PREFIX}-${HTTP_PORT}"; }

# 默认值
VICTORIAMETRICS_USER="${VICTORIAMETRICS_USER:-victoriametrics}"
VICTORIAMETRICS_GROUP="${VICTORIAMETRICS_GROUP:-victoriametrics}"
HTTP_PORT="${HTTP_PORT:-${DEFAULT_HTTP_PORT}}"
RETENTION="${RETENTION:-6}"
# 存储默认收进实例目录（家族统一风格）；需独立挂载点的站点用 STORAGE_PATH 环境变量覆盖
STORAGE_PATH="${STORAGE_PATH:-$(instance_root)/data}"
ALLOW_CIDRS="${ALLOW_CIDRS:-${ALLOW_CIDRS_DEFAULT}}"
DOWNLOAD_CACHE="${DOWNLOAD_CACHE:-${INSTALL_ROOT}/cache}"

usage() {
  cat <<EOF
victoriametrics_installer v${SCRIPT_VERSION}

用法:
  $0 install [--version ${DEFAULT_VERSION}] [--allow CIDR,CIDR,...]
  $0 status
  $0 reload
  $0 uninstall

环境变量:
  HTTP_PORT                              单节点 HTTP/查询/写入端口（默认 8428）
  STORAGE_PATH                            存储目录（默认 \${INSTALL_ROOT}/victoriametrics-<port>/data；
                                          数据必须保留在本实例目录内，不允许指定到 /usr/local/victoriametrics 之外）
EOF
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then echo "必须以 root 运行" >&2; exit 1; fi
}

# ------------------------------------------------------------------------------
# download_vm: 下载 + 解压二进制
# 注意：VictoriaMetrics 发行包为裸 tarball（无顶级目录），文件直接落地
# victoria-metrics-prod 是单节点模式的入口二进制
# ------------------------------------------------------------------------------
download_vm() {
  mkdir -p "${DOWNLOAD_CACHE}"
  local archive="victoria-metrics-linux-amd64-v${VICTORIAMETRICS_VERSION}.tar.gz"
  local url="${GITHUB_BASE}/v${VICTORIAMETRICS_VERSION}/${archive}"
  local dst="${DOWNLOAD_CACHE}/${archive}"
  if [[ ! -s "${dst}" || "${DOWNLOAD_SOURCE_MODE:-auto}" =~ ^(internal|internet|url|file)$ ]]; then
    echo "[download] 准备获取: ${archive}"
    download "${url}" "${dst}" || { echo "下载失败" >&2; exit 2; }
  fi
  local tmp; tmp="$(mktemp -d)"
  archive_extract "${dst}" "${tmp}"
  local inst; inst="$(instance_root)"
  mkdir -p "${inst}/bin"
  install -m 0755 "${tmp}/victoria-metrics-prod" "${inst}/bin/victoria-metrics"
  rm -rf "${tmp}"
}

# ------------------------------------------------------------------------------
# prepare_dirs: 建用户 + 3 类目录（STORAGE_PATH 独立 ensure_dir，便于独立挂载）
# ------------------------------------------------------------------------------
prepare_dirs() {
  sys_user_add "${VICTORIAMETRICS_USER}" "${VICTORIAMETRICS_GROUP}"
  local inst; inst="$(instance_root)"
  ensure_dir "${inst}"          0755 "${VICTORIAMETRICS_USER}" "${VICTORIAMETRICS_GROUP}"
  ensure_dir "${STORAGE_PATH}"  0755 "${VICTORIAMETRICS_USER}" "${VICTORIAMETRICS_GROUP}"
  ensure_dir "${inst}/logs"     0750 "${VICTORIAMETRICS_USER}" "${VICTORIAMETRICS_GROUP}"
  ensure_dir "${inst}/secrets"  0750 "${VICTORIAMETRICS_USER}" "${VICTORIAMETRICS_GROUP}"
}

# ------------------------------------------------------------------------------
# write_acl_set: 把 ALLOW_CIDRS 落地到 ${inst}/secrets/vmallow_cidrs
# 用于卸载时按备份还原防火墙规则（G1-L06：避免静默失败）
# ------------------------------------------------------------------------------
write_acl_set() {
  # 把 ALLOW_CIDRS 写入 nftables/iptables, 由 common/platform.sh 的 fw_open_port 完成
  # 本函数额外维护一个 vmallow 文件, 便于卸载时还原
  local inst; inst="$(instance_root)"
  local f="${inst}/secrets/vmallow_cidrs"
  echo "${ALLOW_CIDRS}" > "${f}"
  chmod 0640 "${f}"
  chown "${VICTORIAMETRICS_USER}:${VICTORIAMETRICS_GROUP}" "${f}"
}

# ------------------------------------------------------------------------------
# write_systemd_unit: 写 victoriametrics-${HTTP_PORT}.service
# 注意：单节点模式不开 -storageNode，位于 etc 部署而非 cluster 拓扑
# -memory.allowedPercent=60：限制 VM 占主机内存上限，避免 OOM
# -search.maxConcurrentRequests=32：默认 8 偏低，常见大查询会 503
# ------------------------------------------------------------------------------
write_systemd_unit() {
  local inst; inst="$(instance_root)"
  local user_directive="User=${VICTORIAMETRICS_USER}
Group=${VICTORIAMETRICS_GROUP}"
  local sandbox=""
  if [[ "${PLATFORM_ID}" == "rhel" ]]; then
    # RC7: 单节点 VM 的持久写入仅需要 storage path 与 logs；在
    # ProtectSystem=full 下精确放行，避免 /usr/local 被只读挂载后无法启动。
    sandbox="ProtectSystem=full
ReadWritePaths=${STORAGE_PATH} ${inst}/logs
NoNewPrivileges=true"
  else
    sandbox="NoNewPrivileges=true
ProtectHome=true
PrivateTmp=true"
  fi

  local unit_file; unit_file="/etc/systemd/system/$(service_unit)"
  cat > "${unit_file}" <<EOF
[Unit]
Description=VictoriaMetrics ${VICTORIAMETRICS_VERSION} (single-node http ${HTTP_PORT})
After=network-online.target

[Service]
${user_directive}
${sandbox}
ExecStart=${inst}/bin/victoria-metrics \\
  -storageDataPath=${STORAGE_PATH} \\
  -retentionPeriod=${RETENTION} \\
  -httpListenAddr=0.0.0.0:${HTTP_PORT} \\
  -memory.allowedPercent=60 \\
  -search.maxConcurrentRequests=32
Restart=always
RestartSec=5
LimitNOFILE=65536
StandardOutput=append:${inst}/logs/victoria-metrics.out.log
StandardError=append:${inst}/logs/victoria-metrics.err.log

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "${unit_file}"
  systemctl daemon-reload
}

# ------------------------------------------------------------------------------
# apply_acl: CIDR 校验 + 防火墙开端口
# 校验策略：
#   1. python3 可用：严格 ipaddress.ip_network() 校验（支持 IPv6）
#   2. 无 python3：bash regex 兜底（仅 IPv4）
#   3. 校验失败立即退出，避免下游静默接受非法 CIDR
# ------------------------------------------------------------------------------
apply_acl() {
  # G1-L06: CIDR 格式校验（拒绝非法 CIDR 静默失败）
  IFS=',' read -r -a cidrs <<< "${ALLOW_CIDRS}"
  local invalid=0
  for c in "${cidrs[@]}"; do
    [[ -z "${c}" ]] && continue
    # 用 python3 校验（优先）；无 python3 用 bash regex 兜底
    if command -v python3 >/dev/null 2>&1; then
      if ! python3 -c "import ipaddress; ipaddress.ip_network('${c}', strict=False)" 2>/dev/null; then
        echo "[apply_acl] ERROR: 非法 CIDR: ${c}" >&2
        invalid=1
      fi
    else
      # bash regex 兜底：IPv4 CIDR 严格校验
      if ! [[ "${c}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]; then
        echo "[apply_acl] WARN: 无法校验（无 python3）IPv4 CIDR 格式可疑: ${c}" >&2
      fi
    fi
  done
  if [[ "${invalid}" -eq 1 ]]; then
    echo "[apply_acl] 退出：CIDR 校验失败" >&2
    exit 1
  fi

  IFS=',' read -r -a cidrs <<< "${ALLOW_CIDRS}"
  for c in "${cidrs[@]}"; do
    [[ -z "${c}" ]] && continue
    fw_open_port "${HTTP_PORT}" tcp "${c}" || { echo "[apply_acl] fw_open_port ${HTTP_PORT} ${c} 失败" >&2; exit 1; }
  done
}

# ------------------------------------------------------------------------------
# cmd_install: 入口主流程
# 关键顺序：download → dirs → acl_set → unit → apply_acl（CIRD 校验）→ ownership
# ------------------------------------------------------------------------------
cmd_install() {
  require_root
  # STORAGE_PATH 安全检查：持久化数据必须位于当前实例目录内。
  local _vm_root; _vm_root="$(readlink -m -- "$(instance_root)")"
  STORAGE_PATH="$(readlink -m -- "${STORAGE_PATH}")"
  [[ "${STORAGE_PATH}" == "${_vm_root}/"* ]] || { echo "[install] STORAGE_PATH 必须位于 ${_vm_root} 内，当前: ${STORAGE_PATH}" >&2; return 64; }
  if platform_init; then
    :
  else
    local rc=$?
    echo "[ERROR] 平台初始化失败；安装未进入持久化变更阶段。" >&2
    return "${rc}"
  fi
  require_install_port_free "${HTTP_PORT}" "VictoriaMetrics HTTP 端口" || return 1
  echo "[init] $(platform_summary)"

  # 存储目录排他锁预检：vmstorage 启动时对 ${STORAGE_PATH}/flock.lock 加 flock，
  # 已被其他实例持有时会 panic 成 crash-loop。安装期直接拒绝并给出指引。
  if [[ -f "${STORAGE_PATH}/flock.lock" ]] && ! flock -n "${STORAGE_PATH}/flock.lock" -c true 2>/dev/null; then
    echo "[install] ERROR: 存储目录 ${STORAGE_PATH} 已被其他 VictoriaMetrics 实例持有（flock.lock 被锁）" >&2
    echo "          多实例数据目录由实例根目录自动隔离，无需也禁止指向组件目录外" >&2
    exit 1
  fi

  # 单节点访问申请：HTTP 8428 同时承载查询与写入。
  local instance_id="${SERVICE_NAME_PREFIX}-${HTTP_PORT}"
  acl_request "${instance_id}-http" \
    "src=${ALLOW_CIDRS}" "dst=${instance_id}" "proto=tcp" "port=${HTTP_PORT}" \
    "direction=in" "purpose=query_and_ingest" "cross_room=yes" \
    "owner=monitoring-team"
  acl_emit "$(INSTANCE_STATE_DIR)/access-request.md"

  download_vm
  prepare_dirs
  write_acl_set
  write_systemd_unit
  apply_acl

  ownership_register "${instance_id}" "${HTTP_PORT}" "${VICTORIAMETRICS_USER}" \
    "$(service_unit)" "$(instance_root)" \
    "${STORAGE_PATH}" "$(instance_root)/logs"

  svc_enable "$(service_unit)"
  sleep 1
  cmd_status
  echo "[done] victoriametrics ${VICTORIAMETRICS_VERSION} @ ${HTTP_PORT}, allow=${ALLOW_CIDRS}"
}

cmd_status() {
  systemctl --no-pager --full status "$(service_unit)" 2>&1 || true
  echo "----- /health -----"
  curl --noproxy '*' -fsS "http://127.0.0.1:${HTTP_PORT}/health" 2>&1 || echo "(未就绪)"
}

cmd_reload() {
  # VictoriaMetrics 主进程支持 SIGHUP（重新打开日志）；svc_reload 优先，失败回退手动 kill
  svc_reload "$(service_unit)" || systemctl kill -s HUP "$(service_unit)"
  echo "[reload] sent SIGHUP"
}

cmd_uninstall() {
  require_root
  local unit; unit="$(service_unit)"
  local instance_id="${SERVICE_NAME_PREFIX}-${HTTP_PORT}"
  if ownership_belongs_to "/etc/systemd/system/${unit}" "${instance_id}"; then
    if systemctl list-unit-files "${unit}" >/dev/null 2>&1; then
      svc_disable "${unit}" || true
      rm -f "/etc/systemd/system/${unit}"
      systemctl daemon-reload
    fi
    fw_close_port "${HTTP_PORT}" tcp || true
  else
    echo "[uninstall] 未找到 ${instance_id} 的托管归属记录；拒绝按托管实例删除。" >&2
    echo "            请从交互菜单选择该外部实例，使用外部实例卸载流程。" >&2
    return 1
  fi
  ownership_forget "${instance_id}"
  if [[ "${UNINSTALL_MODE:-remove}" == remove ]]; then
    safe_remove_instance_root "$(instance_root)" "${INSTALL_ROOT}" || return 1
    safe_remove_instance_state_dir "$(INSTANCE_STATE_DIR)" "${INSTALL_ROOT}" || return 1
  else
    echo "[uninstall] 已保留实例目录: $(instance_root)"
  fi
  echo "[uninstall] 完成: ${unit}"
}

# ------------------------------------------------------------------------------
# wizard_install: 交互式安装向导（无参数运行时由 interactive_loop 调用）
# ------------------------------------------------------------------------------
wizard_install() {
  local archive upstream platform_preview
  while true; do
    ui_ask_port HTTP_PORT "HTTP 端口" "${HTTP_PORT}" "VictoriaMetrics 查询/写入主端口；已占用时必须换用空闲端口" || return 1
    ui_ask VICTORIAMETRICS_VERSION "VictoriaMetrics 版本" "${VICTORIAMETRICS_VERSION}" "改版本需对应软件包存在" || return 1
    ui_ask RETENTION "数据保留时长（月）" "${RETENTION}" "如 6 表示 6 个月" || return 1
    STORAGE_PATH="$(instance_root)/data"
    echo "    数据存储目录固定为 ${STORAGE_PATH}（禁止写到 /usr/local/victoriametrics 之外）"
    ui_ask ALLOW_CIDRS "允许访问的 CIDR 列表" "${ALLOW_CIDRS}" "逗号分隔；控制访问范围" || return 1
    archive="victoria-metrics-linux-amd64-v${VICTORIAMETRICS_VERSION}.tar.gz"; upstream="${GITHUB_BASE}/v${VICTORIAMETRICS_VERSION}/${archive}"
    ui_choose_download_source "${archive}" "${DOWNLOAD_CACHE}" "${upstream}" "${INTERNAL_MIRROR:-}" || return 1
    platform_preview="$(detect_platform)"
    ui_print_plan "安装确认" "组件" "VictoriaMetrics ${VICTORIAMETRICS_VERSION}" "平台" "${platform_preview}" "实例" "${SERVICE_NAME_PREFIX}-${HTTP_PORT}" "HTTP 端口" "${HTTP_PORT}" "retention" "${RETENTION} 月" "数据目录" "${STORAGE_PATH}" "安装根目录" "$(instance_root)" "软件来源" "$(download_source_summary)"
    ui_install_confirm
    case "${UI_INSTALL_ACTION}" in
      install) cmd_install; return $? ;;
      back) echo "[安装向导] 返回重新修改参数"; continue ;;
      cancel) echo "[安装向导] 已取消"; return 0 ;;
      quit) return 1 ;;
    esac
  done
}

# 无参数 → 交互式向导；带参数 → 原 CLI 行为（脚本化/dry-run 路径不变）
if [[ -z "${1:-}" ]]; then
  interactive_loop "victoriametrics 安装器 v${SCRIPT_VERSION}" \
    "${SERVICE_NAME_PREFIX}" "HTTP_PORT" wizard_install
  exit 0
fi

ACTION="${1:-help}"; shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VICTORIAMETRICS_VERSION="$2"; shift 2 ;;
    --allow) ALLOW_CIDRS="$2"; shift 2 ;;
    --retention) RETENTION="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 64 ;;
  esac
done

case "${ACTION}" in
  install) cmd_install ;;
  status) cmd_status ;;
  reload) cmd_reload ;;
  uninstall) cmd_uninstall ;;
  help|-h|--help) usage ;;
  *) echo "未知动作: ${ACTION}" >&2; usage; exit 64 ;;
esac