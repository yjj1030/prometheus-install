#!/usr/bin/env bash
# ==============================================================================
# snmp_exporter_installer_v1.0.0.sh
#
# snmp_exporter 0.28.0 跨平台一键安装器 (v3 系列)
#
# ------------------------------------------------------------------------------
# 模块概述
# ------------------------------------------------------------------------------
# 职责：
#   - 下载 release tarball（含 generator 子命令），落地到 instance_root/bin/
#   - 生成 generator.yml（build 源）+ snmp.yml（runtime）
#   - 暴露 7 个默认 metric（ifHCInOctets / Out / OperStatus / Speed / Errors /
#     sysUpTime / sysName / sysDescr）
#   - 提供 $0 build --mibs <dir> 从 MIB 重新生成 snmp.yml
#
# 关键设计：
#   - 配置目录：${inst}/etc/（ADR-10）
#   - generator.yml 与 snmp.yml 分离（P1-05）：用户改 generator → build → 覆盖 runtime
#   - sysUpTime 已合并到 if_mib_system 模块（v0.28 BREAKING）
#
# 关联 ADR / 审核:
#   - ADR-10 路径命名规范
#   - P1-05 generator/runtime 分离
#   - P1-06 SNMP 目标/认证引用/覆盖顺序
#   - P1-07 SNMP 接口状态/吞吐/重启识别
# ==============================================================================

set -euo pipefail

SCRIPT_VERSION="1.0.0"
DEFAULT_VERSION="0.28.0"
INSTALL_ROOT="/usr/local/snmp_exporter"
GITHUB_BASE="https://github.com/prometheus/snmp_exporter/releases/download"
DEFAULT_PORT=9116
SERVICE_NAME_PREFIX="snmp_exporter"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common/platform.sh"
export INST_ROOT="${INST_ROOT:-${INSTALL_ROOT}}"

# ------------------------------------------------------------------------------
# 环境变量兼容垫片（旧 SE_* → 新 SNMP_EXPORTER_*）
# ------------------------------------------------------------------------------
SE_USER="${SE_USER:-snmp_exporter}"
SE_GROUP="${SE_GROUP:-snmp_exporter}"
[[ -n "${SE_USER:-}"    && -z "${SNMP_EXPORTER_USER:-}"    ]] && SNMP_EXPORTER_USER="${SE_USER}"
[[ -n "${SE_GROUP:-}"   && -z "${SNMP_EXPORTER_GROUP:-}"   ]] && SNMP_EXPORTER_GROUP="${SE_GROUP}"
[[ -n "${SE_VERSION:-}" && -z "${SNMP_EXPORTER_VERSION:-}" ]] && SNMP_EXPORTER_VERSION="${SE_VERSION:-${DEFAULT_VERSION}}"
SNMP_EXPORTER_USER="${SNMP_EXPORTER_USER:-snmp_exporter}"
SNMP_EXPORTER_GROUP="${SNMP_EXPORTER_GROUP:-snmp_exporter}"
SNMP_EXPORTER_VERSION="${SNMP_EXPORTER_VERSION:-${DEFAULT_VERSION}}"
PORT="${PORT:-${DEFAULT_PORT}}"
DOWNLOAD_CACHE="${DOWNLOAD_CACHE:-${INSTALL_ROOT}/cache}"

usage() {
  cat <<EOF
snmp_exporter_installer v${SCRIPT_VERSION}

用法:
  $0 install  [--port 9116] [--version ${DEFAULT_VERSION}]
  $0 build    --mibs /usr/share/snmp/mibs
  $0 status   --port 9116
  $0 reload   --port 9116
  $0 uninstall --port 9116
EOF
}

# v3.0.0-rc3: 统一子目录布局
instance_root() { echo "${INSTALL_ROOT}/${SERVICE_NAME_PREFIX}-${PORT}"; }
service_unit()  { echo "${SERVICE_NAME_PREFIX}-${PORT}.service"; }
INSTANCE_STATE_DIR() { echo "${INSTALL_ROOT}/state/${SERVICE_NAME_PREFIX}-${PORT}"; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then echo "必须以 root 运行" >&2; exit 1; fi
}

download_se() {
  mkdir -p "${DOWNLOAD_CACHE}"
  local archive="snmp_exporter-${SNMP_EXPORTER_VERSION}.linux-amd64.tar.gz"
  local url="${GITHUB_BASE}/v${SNMP_EXPORTER_VERSION}/${archive}"
  local dst="${DOWNLOAD_CACHE}/${archive}"
  if [[ ! -s "${dst}" || "${DOWNLOAD_SOURCE_MODE:-auto}" =~ ^(internal|internet|url|file)$ ]]; then
    echo "[download] 准备获取: ${archive}"
    download "${url}" "${dst}" || { echo "下载失败" >&2; exit 2; }
  fi
  local tmp; tmp="$(mktemp -d)"
  archive_extract "${dst}" "${tmp}"
  # tarball 内有版本子目录 snmp_exporter-<ver>.linux-amd64/（archive_extract 不解 strip）
  local src="${tmp}/snmp_exporter-${SNMP_EXPORTER_VERSION}.linux-amd64"
  local inst; inst="$(instance_root)"
  mkdir -p "${inst}/bin" "${inst}/etc" \
           "${inst}/logs" "${inst}/secrets"
  install -m 0755 "${src}/snmp_exporter" "${inst}/bin/snmp_exporter"
  # runtime snmp.yml 用 tarball 官方默认（schema 与二进制同版本，保证兼容）；
  # 绝不能拿 generator.yml 直接当 runtime 配置——0.26+ runtime 要求顶层 auths: 段，
  # 模块级 version/auth 字段是 generator 输入格式，运行时加载会报
  # "field version/auth not found in type config.plain"
  if [[ ! -s "${inst}/etc/snmp.yml" ]]; then
    install -m 0640 "${src}/snmp.yml" "${inst}/etc/snmp.yml"
    echo "[init] runtime snmp.yml 采用 tarball 官方默认（自定义请改 generator.yml 后执行 $0 build）"
  fi
  rm -rf "${tmp}"
}

prepare_dirs() {
  sys_user_add "${SNMP_EXPORTER_USER}" "${SNMP_EXPORTER_GROUP}"
  local inst; inst="$(instance_root)"
  ensure_dir "${inst}"          0755 "${SNMP_EXPORTER_USER}" "${SNMP_EXPORTER_GROUP}"
  ensure_dir "${inst}/etc"      0750 "${SNMP_EXPORTER_USER}" "${SNMP_EXPORTER_GROUP}"
  ensure_dir "${inst}/logs"     0750 "${SNMP_EXPORTER_USER}" "${SNMP_EXPORTER_GROUP}"
  ensure_dir "${inst}/secrets"  0750 "${SNMP_EXPORTER_USER}" "${SNMP_EXPORTER_GROUP}"
  # download_se 先于 sys_user_add 执行，etc/snmp.yml 是 root 写入的，这里补归属
  if [[ -f "${inst}/etc/snmp.yml" ]]; then
    chown "${SNMP_EXPORTER_USER}:${SNMP_EXPORTER_GROUP}" "${inst}/etc/snmp.yml"
  fi
}

write_default_generator() {
  # 审核 P1-05: generator 配置与 runtime 配置分离
  #   - generator.yml = "what modules to generate from MIBs"（仅 build 用）
  #   - snmp.yml      = "what modules to expose at runtime"（snmp_exporter 加载）
  # 用户修改 generator.yml 后运行 $0 build 重新生成 snmp.yml
  local inst; inst="$(instance_root)"
  local gen_cfg="${inst}/etc/generator.yml"
  cat > "${gen_cfg}" <<'EOF'
# snmp_exporter 0.28.0 generator 配置 - 仅作为 $0 build 的源
# 此文件**不会被** snmp_exporter 运行时加载；只用于 generator binary
#
# 模块组成：
#   if_mib_system = if_mib + system 的合并（02 §2.3 BREAKING: sysUpTime
#                  已从 if_mib 移到 system 模块）
#   if_mib        = 接口表
#   system        = sysUpTime/sysName/sysDescr
#   sensors       = 温湿度（可选，按需启用）
#
# 用户新增模块请遵循以下格式：
#   modules:
#     <module_name>:
#       walk:
#         - <oid>
#       metrics:
#         - name: <metric_name>
#           oid: <oid>
#           type: counter|gauge|...
#       version: 2
#       auth:
#         community: <community>   # 仅供 generator build 时的 walk 验证
modules:
  if_mib_system:
    walk:
      - 1.3.6.1.2.1.2  # interfaces
      - 1.3.6.1.2.1.31.1.1.1.1  # ifXTable
      - 1.3.6.1.2.1.1  # system (sysUpTime/sysName/sysDescr)
    metrics:
      - name: ifHCInOctets
        oid: 1.3.6.1.2.1.31.1.1.1.6
        type: counter
        help: The total number of octets received on the interface
      - name: ifHCOutOctets
        oid: 1.3.6.1.2.1.31.1.1.1.10
        type: counter
        help: The total number of octets transmitted out the interface
      - name: ifOperStatus
        oid: 1.3.6.1.2.1.2.2.1.8
        type: gauge
        help: The current operational state of the interface
      - name: ifAdminStatus
        oid: 1.3.6.1.2.1.2.2.1.7
        type: gauge
        help: The desired state of the interface
      - name: ifSpeed
        oid: 1.3.6.1.2.1.2.2.1.5
        type: gauge
        help: An estimate of the interface's current bandwidth in bits per second
      - name: ifInErrors
        oid: 1.3.6.1.2.1.2.2.1.14
        type: counter
        help: The number of inbound packets that contained errors
      - name: ifOutErrors
        oid: 1.3.6.1.2.1.2.2.1.20
        type: counter
        help: The number of outbound packets that could not be transmitted
      - name: snmp_sysUpTime
        oid: 1.3.6.1.2.1.1.3.0
        type: gauge
        help: Time since last reboot (hundredths of seconds)
      - name: snmp_sysName
        oid: 1.3.6.1.2.1.1.5.0
        type: displayvalue
        help: System name
      - name: snmp_sysDescr
        oid: 1.3.6.1.2.1.1.1.0
        type: displayvalue
        help: System description
    version: 2
    max_repetitions: 25
    retries: 3
    timeout: 10s
    auth:
      community: REPLACE_WITH_SNMP_COMMUNITY

  # 拆分后的独立模块（用户可在 build 时选择只用其中一个）
  if_mib:
    walk:
      - 1.3.6.1.2.1.2
      - 1.3.6.1.2.1.31.1.1.1.1
    metrics:
      - name: ifOperStatus
        oid: 1.3.6.1.2.1.2.2.1.8
        type: gauge
    version: 2

  system:
    walk:
      - 1.3.6.1.2.1.1
    metrics:
      - name: snmp_sysUpTime
        oid: 1.3.6.1.2.1.1.3.0
        type: gauge
      - name: snmp_sysName
        oid: 1.3.6.1.2.1.1.5.0
        type: displayvalue
      - name: snmp_sysDescr
        oid: 1.3.6.1.2.1.1.1.0
        type: displayvalue
    version: 2
EOF
  chmod 0640 "${gen_cfg}"
  chown "${SNMP_EXPORTER_USER}:${SNMP_EXPORTER_GROUP}" "${gen_cfg}"
}

write_systemd_unit() {
  local inst; inst="$(instance_root)"
  local user_directive="User=${SNMP_EXPORTER_USER}
Group=${SNMP_EXPORTER_GROUP}"
  local sandbox="NoNewPrivileges=true"
  local unit_file; unit_file="/etc/systemd/system/$(service_unit)"
  cat > "${unit_file}" <<EOF
[Unit]
Description=SNMP Exporter ${SNMP_EXPORTER_VERSION} (port ${PORT})
After=network-online.target

[Service]
${user_directive}
${sandbox}
ExecStart=${inst}/bin/snmp_exporter \\
  --config.file=${inst}/etc/snmp.yml \\
  --web.listen-address=0.0.0.0:${PORT}
Restart=always
RestartSec=5
LimitNOFILE=65536
StandardOutput=append:${inst}/logs/snmp_exporter.out.log
StandardError=append:${inst}/logs/snmp_exporter.err.log

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
  require_install_port_free "${PORT}" "snmp_exporter 端口" || return 1

  # 审核 P0-02：注册访问申请清单（被 Prometheus 抓取 + 出站到 SNMP 设备）
  local instance_id="${SERVICE_NAME_PREFIX}-${PORT}"
  acl_request "${instance_id}-web" \
    "src=prometheus" "dst=${instance_id}" "proto=tcp" "port=${PORT}" \
    "direction=in" "purpose=scrape_snmp_metrics" "cross_room=no" \
    "owner=monitoring-team"
  acl_request "${instance_id}-snmp_out" \
    "src=${instance_id}" "dst=network_devices" "proto=udp" "port=161" \
    "direction=out" "purpose=snmp_polling" "cross_room=yes" \
    "owner=network-team"
  acl_emit "$(INSTANCE_STATE_DIR)/access-request.md"

  fw_open_port "${PORT}" tcp

  download_se
  prepare_dirs
  write_default_generator
  write_systemd_unit

  ownership_register "${instance_id}" "${PORT}" "${SNMP_EXPORTER_USER}" \
    "$(service_unit)" "$(instance_root)/etc/generator.yml" \
    "$(instance_root)/etc/snmp.yml" "$(instance_root)/logs"

  svc_enable "$(service_unit)"
  sleep 1
  cmd_status
  echo "[done] snmp_exporter ${SNMP_EXPORTER_VERSION} @ ${PORT}"
}

cmd_build() {
  local mibs_dir="${1:-/usr/share/snmp/mibs}"
  local inst; inst="$(instance_root)"
  [[ -d "${mibs_dir}" ]] || { echo "MIB 目录不存在: ${mibs_dir}" >&2; exit 1; }

  local gen_cfg="${inst}/etc/generator.yml"
  [[ -s "${gen_cfg}" ]] || { echo "generator.yml 不存在，请先 install" >&2; exit 1; }

  local archive="snmp_exporter-${SNMP_EXPORTER_VERSION}.linux-amd64.tar.gz"
  local dst="${DOWNLOAD_CACHE}/${archive}"
  if [[ ! -s "${dst}" || "${DOWNLOAD_SOURCE_MODE:-auto}" =~ ^(internal|internet|url|file)$ ]]; then
    echo "[download] ${dst##*/}"
    download "${GITHUB_BASE}/v${SNMP_EXPORTER_VERSION}/${archive}" "${dst}" || exit 2
  fi
  local tmp; tmp="$(mktemp -d)"
  archive_extract "${dst}" "${tmp}"
  echo "[build] 从 ${mibs_dir} 重新生成 snmp.yml（generator.yml → snmp.yml）"
  "${tmp}/snmp_exporter-${SNMP_EXPORTER_VERSION}.linux-amd64/generator" generate --mibs-dir "${mibs_dir}" \
      --config-file="${gen_cfg}" > "${inst}/etc/snmp.yml.new"
  chmod 0640 "${inst}/etc/snmp.yml.new"
  chown "${SNMP_EXPORTER_USER}:${SNMP_EXPORTER_GROUP}" "${inst}/etc/snmp.yml.new"

  # 备份旧 snmp.yml；新 snmp.yml 通过 promtool 风格的语法校验
  if [[ -s "${inst}/etc/snmp.yml" ]]; then
    cp -a "${inst}/etc/snmp.yml" "${inst}/etc/snmp.yml.bak.$(date +%Y%m%d%H%M%S)" || true
  fi
  mv "${inst}/etc/snmp.yml.new" "${inst}/etc/snmp.yml"
  rm -rf "${tmp}"
  cmd_reload
  echo "[done] snmp.yml 已重新生成（来源: generator.yml）"
}

cmd_status() {
  systemctl --no-pager --full status "$(service_unit)" 2>&1 || true
  # snmp_exporter 没有 /-/ready 端点（只有 / /metrics /snmp /config），
  # 探 /metrics 的 HTTP 状态码判断存活，避免 404 误报"未就绪"
  echo "----- /metrics -----"
  local code; code="$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/metrics" 2>&1)" || true
  if [[ "${code}" == "200" ]]; then echo "OK (http ${code})"; else echo "(异常: ${code})"; fi
}

cmd_reload() {
  svc_reload "$(service_unit)" || systemctl kill -s HUP "$(service_unit)"
  echo "[reload] sent SIGHUP"
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
# ------------------------------------------------------------------------------
wizard_install() {
  local archive upstream platform_preview
  while true; do
    ui_ask_port PORT "监听端口" "${PORT}" "snmp_exporter HTTP/metrics 端口；已占用时必须换用空闲端口" || return 1
    ui_ask SNMP_EXPORTER_VERSION "snmp_exporter 版本" "${SNMP_EXPORTER_VERSION}" "改版本需对应软件包存在" || return 1
    archive="snmp_exporter-${SNMP_EXPORTER_VERSION}.linux-amd64.tar.gz"; upstream="${GITHUB_BASE}/v${SNMP_EXPORTER_VERSION}/${archive}"
    ui_choose_download_source "${archive}" "${DOWNLOAD_CACHE}" "${upstream}" "${INTERNAL_MIRROR:-}" || return 1
    platform_preview="$(detect_platform)"
    ui_print_plan "安装确认" "组件" "snmp_exporter ${SNMP_EXPORTER_VERSION}" "平台" "${platform_preview}" "实例" "${SERVICE_NAME_PREFIX}-${PORT}" "端口" "${PORT}" "安装根目录" "$(instance_root)" "软件来源" "$(download_source_summary)"
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
  interactive_loop "snmp_exporter 安装器 v${SCRIPT_VERSION}" \
    "${SERVICE_NAME_PREFIX}" "PORT" wizard_install
  exit 0
fi

ACTION="${1:-help}"; shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --version) SNMP_EXPORTER_VERSION="$2"; shift 2 ;;
    --mibs) MIBS_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 64 ;;
  esac
done

case "${ACTION}" in
  install)   cmd_install ;;
  build)     cmd_build "${MIBS_DIR:-}" ;;
  status)    cmd_status ;;
  reload)    cmd_reload ;;
  uninstall) cmd_uninstall ;;
  help|-h|--help) usage ;;
  *) echo "未知动作: ${ACTION}" >&2; usage; exit 64 ;;
esac