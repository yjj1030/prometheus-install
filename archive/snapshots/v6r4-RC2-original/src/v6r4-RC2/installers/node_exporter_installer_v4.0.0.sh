#!/usr/bin/env bash
# ==============================================================================
# node_exporter_installer_v4.0.0.sh
#
# Node Exporter 1.12.1 跨平台一键安装器 (v3 系列)
#
# ------------------------------------------------------------------------------
# 模块概述
# ------------------------------------------------------------------------------
# 职责：
#   - 下载 release tarball，落地到 instance_root/bin/
#   - 启用 node_exporter 默认 collector 集（cpu/meminfo/diskstats/netdev 等 27+），
#     仅显式禁用高基数 collector：processes / systemd
#   - textfile collector 路径默认每实例独立（避免多实例争用）
#   - 写入 systemd unit 并附 hardening（NoNewPrivileges / ProtectSystem=strict / ReadWritePaths=textfile）
#
# 关键设计：
#   - 配置目录：${inst}/etc/（ADR-10）
#   - textfile：${inst}/textfile/（每实例独立；不在 /var/lib 共用）
#   - hardening：ProtectSystem=strict（全盘只读，API VFS 可用）+ ReadWritePaths=textfile_dir
#
# 关联 ADR / 审核:
#   - ADR-10 路径命名规范
#   - P1-24 Node Exporter 采集器治理 + unit hardening
# ==============================================================================

set -euo pipefail

SCRIPT_VERSION="4.0.0"
DEFAULT_VERSION="1.12.1"
INSTALL_ROOT="/usr/local/node_exporter"
GITHUB_BASE="https://github.com/prometheus/node_exporter/releases/download"
SERVICE_NAME_PREFIX="node_exporter"

# ------------------------------------------------------------------------------
# 平台抽象层 source
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common/platform.sh"
export INST_ROOT="${INST_ROOT:-${INSTALL_ROOT}}"

# ------------------------------------------------------------------------------
# 环境变量兼容垫片（旧 NE_* → 新 NODE_EXPORTER_*）
# ------------------------------------------------------------------------------
NE_USER="${NE_USER:-node_exporter}"
NE_GROUP="${NE_GROUP:-node_exporter}"
[[ -n "${NE_USER:-}"  && -z "${NODE_EXPORTER_USER:-}"  ]] && NODE_EXPORTER_USER="${NE_USER}"
[[ -n "${NE_GROUP:-}" && -z "${NODE_EXPORTER_GROUP:-}" ]] && NODE_EXPORTER_GROUP="${NE_GROUP}"
NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-${DEFAULT_VERSION}}"
NODE_EXPORTER_USER="${NODE_EXPORTER_USER:-node_exporter}"
NODE_EXPORTER_GROUP="${NODE_EXPORTER_GROUP:-node_exporter}"
PORT="${PORT:-9102}"
EXTRA_FLAGS="${EXTRA_FLAGS:-}"

# ------------------------------------------------------------------------------
# 实例目录与 unit 派生（必须在 TEXTFILE_DIR 等顶层默认值之前定义，
# 否则顶层 ${TEXTFILE_DIR:-$(instance_root)/textfile} 调用会 command not found）
# ------------------------------------------------------------------------------
instance_root()      { echo "${INSTALL_ROOT}/${SERVICE_NAME_PREFIX}-${PORT}"; }
instance_bin()       { echo "$(instance_root)/bin/node_exporter"; }
instance_etc()       { echo "$(instance_root)/etc"; }
instance_logs()      { echo "$(instance_root)/logs"; }
service_unit()       { echo "${SERVICE_NAME_PREFIX}-${PORT}.service"; }
# INSTANCE_STATE_DIR 是函数（与其他 installer 一致）；调用处必须写 $(INSTANCE_STATE_DIR)
# 而不是 ${INSTANCE_STATE_DIR}（后者在 set -u 下会报 unbound variable）
INSTANCE_STATE_DIR() { echo "${INSTALL_ROOT}/state/${SERVICE_NAME_PREFIX}-${PORT}"; }

# TEXTFILE_DIR 默认值在 CLI 解析之后由 instance_root() 派生；
# 顶层就展开会用默认 PORT=9102，--port 9100 改端口后路径里仍带 9102（C12 类 bug）。
TEXTFILE_DIR="${TEXTFILE_DIR:-}"

# ------------------------------------------------------------------------------
# 默认禁用的 collector 名单（node_exporter 1.12.x）
#
# 设计（v3.0.0-rc4 修复）：
#   - node_exporter 的默认 enabled 集合已经覆盖我们想要的 cpu/meminfo/filesystem/
#     diskstats/netdev/netstat/nfs/nfsd/hwmon/conntrack/mdadm/logind/ntp/sockstat 等
#     27+ 个常用 collector，**无需**逐个 --collector.X 显式开
#   - 只通过 --no-collector.X 关掉高基数 / 高风险的：
#       processes  (每进程 metric，pid 维度，基数极高；默认本就不开，双保险)
#       systemd    (每 unit 状态 + task，unit 数大时基数失控)
#   - 想加额外 collector 用 EXTRA_FLAGS 追加（如 EXTRA_FLAGS="--collector.processes"）
#
# 历史 bug 记录（v3.0.0-rc4 之前）：
#   - 误用了不存在的 --collectors.enabled=a,b,c（node_exporter 没有这个聚合 flag）
#   - 拼错了几个不存在的 collector 名（filesystemstat / cpu_vulnerabilities /
#     systemd_unit_lites / systemd_lites / syscall），导致进程 status=1/FAILURE 启动失败
#   - 教训：collector 名必须以目标版本二进制的 --help 输出为准，不能凭记忆写
# ------------------------------------------------------------------------------
DEFAULT_DISABLED_COLLECTORS="processes systemd"

# ------------------------------------------------------------------------------
# 用法
# ------------------------------------------------------------------------------
usage() {
  cat <<EOF
node_exporter_installer v${SCRIPT_VERSION}

用法:
  $0 install [--port 9102] [--version ${DEFAULT_VERSION}] [--textfile DIR]
  $0 status  --port 9102
  $0 reload  --port 9102     # node_exporter 无热加载，实际执行 restart
  $0 uninstall --port 9102
EOF
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "必须以 root 运行" >&2; exit 1
  fi
}

# ------------------------------------------------------------------------------
# download_node_exporter: 下载 + 落地二进制到 ${inst}/bin/
# DOWNLOAD_CACHE 共享；第二次 install 不会重复下载。
# ------------------------------------------------------------------------------
download_node_exporter() {
  local dl_cache="${DOWNLOAD_CACHE:-${INSTALL_ROOT}/cache}"
  mkdir -p "${dl_cache}"
  local ver="${NODE_EXPORTER_VERSION}"
  local archive="node_exporter-${ver}.linux-amd64.tar.gz"
  local url="${GITHUB_BASE}/v${ver}/${archive}"
  local dst="${dl_cache}/${archive}"

  if [[ ! -s "${dst}" || "${DOWNLOAD_SOURCE_MODE:-auto}" =~ ^(internal|internet|url|file)$ ]]; then
    echo "[download] ${url}"
    download "${url}" "${dst}" || { echo "下载失败" >&2; exit 2; }
  fi

  local tmp; tmp="$(mktemp -d)"
  archive_extract "${dst}" "${tmp}"

  local src="${tmp}/node_exporter-${ver}.linux-amd64"
  local inst; inst="$(instance_root)"
  mkdir -p "${inst}/bin" "${inst}/etc" "${inst}/logs"
  install -m 0755 "${src}/node_exporter" "${inst}/bin/node_exporter"
  rm -rf "${tmp}"
}

# ------------------------------------------------------------------------------
# prepare_dirs: 建用户 + 4 类目录（textfile 单独 ensure_dir，路径每实例独立）
# ------------------------------------------------------------------------------
prepare_dirs() {
  sys_user_add "${NODE_EXPORTER_USER}" "${NODE_EXPORTER_GROUP}"
  local inst; inst="$(instance_root)"
  ensure_dir "${inst}" 0755 "${NODE_EXPORTER_USER}" "${NODE_EXPORTER_GROUP}"
  ensure_dir "${inst}/etc" 0750 "${NODE_EXPORTER_USER}" "${NODE_EXPORTER_GROUP}"
  ensure_dir "${inst}/logs" 0750 "${NODE_EXPORTER_USER}" "${NODE_EXPORTER_GROUP}"
  ensure_dir "${TEXTFILE_DIR}" 0755 "${NODE_EXPORTER_USER}" "${NODE_EXPORTER_GROUP}"
}

# ------------------------------------------------------------------------------
# write_systemd_unit: 写 node_exporter-${PORT}.service
# hardening 完整：
#   - NoNewPrivileges / ProtectSystem=strict / ProtectHome / PrivateTmp
#   - ReadWritePaths=${TEXTFILE_DIR}（唯一可写目录）
#   - CapabilityBoundingSet=（无 cap）
#   - MemoryDenyWriteExecute
# 注意：collector 开关变更需要 restart（命令行参数不重读），非 reload。
# ------------------------------------------------------------------------------
write_systemd_unit() {
  local inst; inst="$(instance_root)"
  local user_directive="User=${NODE_EXPORTER_USER}
Group=${NODE_EXPORTER_GROUP}"

  # hardening 说明（v3.0.0-rc4 修复）：
  #   - ProtectSystem=strict：整个文件系统只读，但 /dev /proc /sys /run 等 API VFS
  #     保持可用 —— node_exporter 全部数据来源就是对它们的只读读取
  #   - ReadWritePaths=${TEXTFILE_DIR}：唯一放行写权限的目录（textfile 投递目录，
  #     供外部 cron/脚本写入 .prom 文件，exporter 自身只读）
  #   - 旧版用 ReadOnlyPaths=/ + ReadWritePaths=/proc /sys，语义错误：
  #       * node_exporter 只"读"/proc /sys，旧写法反而把它们放开为可写（安全降级）
  #       * ReadOnlyPaths=/ 连带把 /run /tmp 也锁死，属于过度约束
  #   - centos7 (systemd 219) 不认识的新指令会被忽略并告警，不影响 unit 启动
  local sandbox="NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
CapabilityBoundingSet=
AmbientCapabilities=
ReadWritePaths=${TEXTFILE_DIR}"

  # 把空格分隔的"要禁用的 collector"名单转成 "--no-collector.X --no-collector.Y ..."
  # node_exporter 的关闭 flag 是 --no-collector.<name>（与 --collector.<name> 对偶）
  # 默认 enabled 集合已经覆盖我们想要的 27+ 个 collector，无需显式 --collector.X
  local disable_flags=""
  local c
  for c in ${DEFAULT_DISABLED_COLLECTORS}; do
    disable_flags="${disable_flags} --no-collector.${c}"
  done
  # shellcheck disable=SC2086  # 故意做 word-split，每个 flag 一个独立 token

  local unit_file; unit_file="/etc/systemd/system/$(service_unit)"
  # 注意：--collector.netclass.ignored-devices 正则含 | 字符，heredoc 用未引用 EOF
  # 会让 bash 展开 ${...}，所以以下变量 ${PORT} ${inst} 等都会被展开。
  # 而 netclass 的 (veth.*|docker.*|br-.*) 中没有 ${...}，不会被 bash 误展开。
  #
  # ExecStart 布局：disable_flags 拼到 textfile 同一行，行尾 \ 续行合法
  # （反斜杠必须是行尾最后一个字符，前面不能有空格）
  cat > "${unit_file}" <<EOF
[Unit]
Description=Node Exporter ${NODE_EXPORTER_VERSION} (port ${PORT})
Documentation=https://prometheus.io/docs/guides/node-exporter/
After=network-online.target

[Service]
${user_directive}
${sandbox}
ExecStart=${inst}/bin/node_exporter \\
  --web.listen-address=0.0.0.0:${PORT} \\
  --collector.cpu.info \\
  --collector.netclass.ignored-devices=^(veth.*|docker.*|br-.*) \\
  --collector.textfile.directory=${TEXTFILE_DIR}${disable_flags} ${EXTRA_FLAGS}
Restart=always
RestartSec=5
LimitNOFILE=65536
StandardOutput=append:${inst}/logs/node_exporter.out.log
StandardError=append:${inst}/logs/node_exporter.err.log

[Install]
WantedBy=multi-user.target
EOF

  chmod 0644 "${unit_file}"
  systemctl daemon-reload
}

cmd_install() {
  require_root
  if platform_init; then
    :
  else
    local rc=$?
    echo "[ERROR] 平台初始化失败；安装未进入持久化变更阶段。" >&2
    return "${rc}"
  fi
  # 打印安装器版本：dry-run 排障时据此确认服务器上的文件确实是本次上传的版本
  echo "[init] node_exporter_installer v${SCRIPT_VERSION} (node_exporter ${NODE_EXPORTER_VERSION})"

  # 审核 P0-02：注册访问申请清单（被 Prometheus 抓取）
  local instance_id="${SERVICE_NAME_PREFIX}-${PORT}"
  acl_request "${instance_id}-web" \
    "src=prometheus" "dst=${instance_id}" "proto=tcp" "port=${PORT}" \
    "direction=in" "purpose=scrape_node_metrics" "cross_room=no" \
    "owner=monitoring-team"
  acl_emit "$(INSTANCE_STATE_DIR)/access-request.md"

  fw_open_port "${PORT}" tcp
  echo "[init] $(platform_summary)"

  download_node_exporter
  prepare_dirs
  write_systemd_unit

  ownership_register "${instance_id}" "${PORT}" "${NODE_EXPORTER_USER}" \
    "$(service_unit)" "$(instance_root)/etc" \
    "$(instance_root)/data" "$(instance_root)/logs"

  svc_enable "$(service_unit)"
  sleep 1
  cmd_status
  echo "[done] node_exporter ${NODE_EXPORTER_VERSION} @ ${PORT}"
}

cmd_status() {
  local unit; unit="$(service_unit)"
  systemctl --no-pager --full status "${unit}" 2>&1 || true
  echo "----- /metrics head -----"
  curl --noproxy '*' -fsS "http://127.0.0.1:${PORT}/metrics" 2>&1 | head -n 8 || true
}

cmd_reload() {
  # node_exporter 没有可热加载的配置：collector 开关是 CLI flag（变更必须重启），
  # exporter-toolkit 的 SIGHUP 仅热加载 TLS web config（本安装器未启用），
  # 且 Go 进程默认收到 SIGHUP 会退出 —— 发 HUP 等于杀进程。
  # 因此 reload 语义 = systemctl restart，保证"配置变更已应用"的用户预期成立。
  systemctl restart "$(service_unit)"
  echo "[reload] node_exporter 不支持热加载，已 restart 应用变更"
}

cmd_uninstall() {
  require_root
  local unit; unit="$(service_unit)"
  local instance_id="${SERVICE_NAME_PREFIX}-${PORT}"
  if ownership_belongs_to "/etc/systemd/system/${unit}" "${instance_id}"; then
    if systemctl list-unit-files "${unit}" >/dev/null 2>&1; then
      svc_disable "${unit}" || true
      rm -f "/etc/systemd/system/${unit}"
      systemctl daemon-reload
    fi
  else
    echo "[uninstall] 未找到 ${instance_id} 的托管归属记录；拒绝按托管实例删除。" >&2
    echo "            请从交互菜单选择该外部实例，使用外部实例卸载流程。" >&2
    return 1
  fi
  fw_close_port "${PORT}" tcp || true
  ownership_forget "${instance_id}"
  if [[ "${UNINSTALL_MODE:-remove}" == remove ]]; then
    safe_remove_instance_root "$(instance_root)" "${INSTALL_ROOT}" || return 1
  else
    echo "[uninstall] 已保留实例目录: $(instance_root)"
  fi
  echo "[uninstall] 完成: ${unit}"
}

# ------------------------------------------------------------------------------
# wizard_install: 交互式安装向导（无参数运行时由 interactive_loop 调用）
# 回车=默认值，q=放弃；TEXTFILE_DIR 默认值在 PORT 确定后动态推导
# ------------------------------------------------------------------------------
wizard_install() {
  local archive upstream platform_preview
  while true; do
    ui_ask_port PORT "监听端口" "${PORT}" "node_exporter HTTP/metrics 端口；已占用时必须换用空闲端口" || return 1
    ui_ask NODE_EXPORTER_VERSION "node_exporter 版本" "${NODE_EXPORTER_VERSION}" "改版本需对应软件包存在" || return 1
    ui_ask TEXTFILE_DIR "textfile 收集目录" "$(instance_root)/textfile" "供脚本投递 .prom 文件；每实例独立" || return 1
    archive="node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"; upstream="${GITHUB_BASE}/v${NODE_EXPORTER_VERSION}/${archive}"
    ui_choose_download_source "${archive}" "${DOWNLOAD_CACHE:-${INSTALL_ROOT}/cache}" "${upstream}" "${INTERNAL_MIRROR:-}" || return 1
    platform_preview="$(detect_platform)"
    ui_print_plan "安装确认" "组件" "node_exporter ${NODE_EXPORTER_VERSION}" "平台" "${platform_preview}" "实例" "${SERVICE_NAME_PREFIX}-${PORT}" "端口" "${PORT}" "textfile" "${TEXTFILE_DIR}" "安装根目录" "$(instance_root)" "软件来源" "$(download_source_summary)"
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
  interactive_loop "node_exporter 安装器 v${SCRIPT_VERSION}" \
    "${SERVICE_NAME_PREFIX}" "PORT" wizard_install
  exit 0
fi

ACTION="${1:-help}"; shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --version) NODE_EXPORTER_VERSION="$2"; shift 2 ;;
    --textfile) TEXTFILE_DIR="$2"; shift 2 ;;
    --extra) EXTRA_FLAGS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 64 ;;
  esac
done

# 派生默认值必须在 PORT 解析后回填；--textfile 显式传值则保留
if [[ -z "${TEXTFILE_DIR}" ]]; then
  TEXTFILE_DIR="$(instance_root)/textfile"
fi

case "${ACTION}" in
  install)   cmd_install ;;
  status)    cmd_status ;;
  reload)    cmd_reload ;;
  uninstall) cmd_uninstall ;;
  help|-h|--help) usage ;;
  *) echo "未知动作: ${ACTION}" >&2; usage; exit 64 ;;
esac
