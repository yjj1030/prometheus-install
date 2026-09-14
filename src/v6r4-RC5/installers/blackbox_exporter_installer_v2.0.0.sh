#!/usr/bin/env bash
# ==============================================================================
# blackbox_exporter_installer_v2.0.0.sh
#
# Blackbox Exporter 0.28.0 跨平台一键安装器 (v3 系列)
#
# 差异:
#   - source common/platform.sh
#   - 默认模块: http_2xx / https_2xx / tcp_connect / tcp_tls / icmp / dns_*
#   - ICMP: setcap cap_net_raw+ep
#   - basic_auth 默认黑盒账号 blackbox / 自动生成密码
#   - v3.0.0-rc3: unit 名 blackbox_exporter-${PORT}.service
#                  子目录统一 ${INSTALL_ROOT}/blackbox_exporter-${PORT}/
# ==============================================================================

set -euo pipefail

SCRIPT_VERSION="2.0.0"
DEFAULT_VERSION="0.28.0"
INSTALL_ROOT="/usr/local/blackbox_exporter"
GITHUB_BASE="https://github.com/prometheus/blackbox_exporter/releases/download"
BB_USER="${BB_USER:-blackbox_exporter}"
BB_GROUP="${BB_GROUP:-blackbox_exporter}"
DEFAULT_PORT=9115
DEFAULT_BASIC_USER="blackbox"
SERVICE_NAME_PREFIX="blackbox_exporter"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common/platform.sh"
export INST_ROOT="${INST_ROOT:-${INSTALL_ROOT}}"

BB_VERSION="${BB_VERSION:-${DEFAULT_VERSION}}"
# v3.0.0-rc4: 旧 BB_* 前缀保留为兼容垫片；新名 BLACKBOX_EXPORTER_* 优先
[[ -n "${BB_USER:-}"    && -z "${BLACKBOX_EXPORTER_USER:-}"    ]] && BLACKBOX_EXPORTER_USER="${BB_USER}"
[[ -n "${BB_GROUP:-}"   && -z "${BLACKBOX_EXPORTER_GROUP:-}"   ]] && BLACKBOX_EXPORTER_GROUP="${BB_GROUP}"
[[ -n "${BB_VERSION:-}" && -z "${BLACKBOX_EXPORTER_VERSION:-}" ]] && BLACKBOX_EXPORTER_VERSION="${BB_VERSION}"
# 默认值
BLACKBOX_EXPORTER_USER="${BLACKBOX_EXPORTER_USER:-blackbox_exporter}"
BLACKBOX_EXPORTER_GROUP="${BLACKBOX_EXPORTER_GROUP:-blackbox_exporter}"
PORT="${PORT:-${DEFAULT_PORT}}"
BASIC_USER="${BASIC_USER:-${DEFAULT_BASIC_USER}}"
DOWNLOAD_CACHE="${DOWNLOAD_CACHE:-${INSTALL_ROOT}/cache}"

usage() {
  cat <<EOF
blackbox_exporter_installer v${SCRIPT_VERSION}

用法:
  $0 install [--port 9115] [--version ${DEFAULT_VERSION}] [--basic-user blackbox]
  $0 status  --port 9115
  $0 reload  --port 9115
  $0 uninstall --port 9115
EOF
}

# v3.0.0-rc3: 统一子目录布局
instance_root() { echo "${INSTALL_ROOT}/${SERVICE_NAME_PREFIX}-${PORT}"; }
service_unit()  { echo "${SERVICE_NAME_PREFIX}-${PORT}.service"; }
INSTANCE_STATE_DIR() { echo "${INSTALL_ROOT}/state/${SERVICE_NAME_PREFIX}-${PORT}"; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then echo "必须以 root 运行" >&2; exit 1; fi
}

download_bb() {
  mkdir -p "${DOWNLOAD_CACHE}"
  local archive="blackbox_exporter-${BLACKBOX_EXPORTER_VERSION}.linux-amd64.tar.gz"
  local url="${GITHUB_BASE}/v${BLACKBOX_EXPORTER_VERSION}/${archive}"
  local dst="${DOWNLOAD_CACHE}/${archive}"
  if [[ ! -s "${dst}" || "${DOWNLOAD_SOURCE_MODE:-auto}" =~ ^(internal|internet|url|file)$ ]]; then
    echo "[download] 准备获取: ${archive}"
    download "${url}" "${dst}" || { echo "下载失败" >&2; exit 2; }
  fi

  local tmp; tmp="$(mktemp -d)"
  archive_extract "${dst}" "${tmp}"
  local src="${tmp}/blackbox_exporter-${BLACKBOX_EXPORTER_VERSION}.linux-amd64"
  local inst; inst="$(instance_root)"
  mkdir -p "${inst}/bin" "${inst}/etc" \
           "${inst}/logs" "${inst}/secrets"
  install -m 0755 "${src}/blackbox_exporter" "${inst}/bin/blackbox_exporter"
  rm -rf "${tmp}"
}

prepare_dirs() {
  sys_user_add "${BLACKBOX_EXPORTER_USER}" "${BLACKBOX_EXPORTER_GROUP}"
  local inst; inst="$(instance_root)"
  ensure_dir "${inst}"          0755 "${BLACKBOX_EXPORTER_USER}" "${BLACKBOX_EXPORTER_GROUP}"
  ensure_dir "${inst}/etc"      0750 "${BLACKBOX_EXPORTER_USER}" "${BLACKBOX_EXPORTER_GROUP}"
  ensure_dir "${inst}/logs"     0750 "${BLACKBOX_EXPORTER_USER}" "${BLACKBOX_EXPORTER_GROUP}"
  ensure_dir "${inst}/secrets"  0750 "${BLACKBOX_EXPORTER_USER}" "${BLACKBOX_EXPORTER_GROUP}"
  cap_net_raw_for_binary "${inst}/bin/blackbox_exporter" || true
}

write_blackbox_yml() {
  local inst; inst="$(instance_root)"
  local cfg="${inst}/etc/blackbox.yml"
  cat > "${cfg}" <<'EOF'
modules:
  http_2xx:
    prober: http
    timeout: 10s
    http:
      valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
      valid_status_codes: [200]
      method: GET
      preferred_ip_protocol: ip4
      enable_http2: true
      fail_if_ssl: false
      fail_if_not_ssl: false

  https_2xx:
    prober: http
    timeout: 10s
    http:
      valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
      valid_status_codes: [200]
      method: GET
      preferred_ip_protocol: ip4
      enable_http2: true
      fail_if_not_ssl: true

  tcp_connect:
    prober: tcp
    timeout: 5s

  tcp_tls:
    prober: tcp
    timeout: 5s
    tcp:
      tls: true
      tls_config:
        insecure_skip_verify: false

  icmp:
    prober: icmp
    timeout: 5s
    icmp:
      preferred_ip_protocol: ip4

  dns_udp:
    prober: dns
    timeout: 5s
    dns:
      preferred_ip_protocol: ip4
      query_name: example.com
      query_type: A

  dns_tcp:
    prober: dns
    timeout: 5s
    dns:
      preferred_ip_protocol: ip4
      transport_protocol: tcp
      query_name: example.com
      query_type: A
EOF
  chmod 0640 "${cfg}"
  chown "${BLACKBOX_EXPORTER_USER}:${BLACKBOX_EXPORTER_GROUP}" "${cfg}"
}

write_web_config() {
  local inst; inst="$(instance_root)"
  local pwd_file="${inst}/secrets/blackbox_exporter_password"
  if [[ ! -s "${pwd_file}" ]]; then
    head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20 > "${pwd_file}"
    chmod 0640 "${pwd_file}"
    chown "${BLACKBOX_EXPORTER_USER}:${BLACKBOX_EXPORTER_GROUP}" "${pwd_file}"
  fi

  local wc="${inst}/etc/web-config.yml"
  # -n stdout / -b batch / -B bcrypt / -C 10 cost；stdin 重定向会让 htpasswd 进入交互提示，必须用 -b 且与 -n 合并。
  # htpasswd 输出格式为 "user:hash"，web-config.yml 只取 hash 部分。
  cat > "${wc}" <<EOF
basic_auth_users:
  ${BASIC_USER}: $(htpasswd -nbB -C 10 "${BASIC_USER}" "$(cat "${pwd_file}")" | sed 's/^[^:]*://' | tr -d '\n')
EOF
  chmod 0640 "${wc}"
  chown "${BLACKBOX_EXPORTER_USER}:${BLACKBOX_EXPORTER_GROUP}" "${wc}"
}

write_systemd_unit() {
  local inst; inst="$(instance_root)"
  local user_directive="User=${BLACKBOX_EXPORTER_USER}
Group=${BLACKBOX_EXPORTER_GROUP}"
  local sandbox=""
  if [[ "${PLATFORM_ID}" == "rhel" ]]; then
    sandbox="NoNewPrivileges=true"
  else
    sandbox="AmbientCapabilities=CAP_NET_RAW CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_RAW CAP_NET_ADMIN"
  fi

  local unit_file; unit_file="/etc/systemd/system/$(service_unit)"
  cat > "${unit_file}" <<EOF
[Unit]
Description=Blackbox Exporter ${BLACKBOX_EXPORTER_VERSION} (port ${PORT})
After=network-online.target

[Service]
${user_directive}
${sandbox}
ExecStart=${inst}/bin/blackbox_exporter \\
  --config.file=${inst}/etc/blackbox.yml \\
  --web.listen-address=0.0.0.0:${PORT} \\
  --web.config.file=${inst}/etc/web-config.yml
Restart=always
RestartSec=5
LimitNOFILE=65536
StandardOutput=append:${inst}/logs/blackbox_exporter.out.log
StandardError=append:${inst}/logs/blackbox_exporter.err.log

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
  require_install_port_free "${PORT}" "blackbox_exporter 端口" || return 1
  pkg_install apache2-utils 2>/dev/null || pkg_install httpd-tools 2>/dev/null || true

  # 审核 P0-02：注册访问申请清单
  local instance_id="${SERVICE_NAME_PREFIX}-${PORT}"
  acl_request "${instance_id}-web" \
    "src=prometheus" "dst=${instance_id}" "proto=tcp" "port=${PORT}" \
    "direction=in" "purpose=scrape_probe_metrics" "cross_room=no" \
    "owner=monitoring-team"
  acl_emit "$(INSTANCE_STATE_DIR)/access-request.md"

  fw_open_port "${PORT}" tcp

  download_bb
  prepare_dirs
  write_blackbox_yml
  write_web_config
  write_systemd_unit

  ownership_register "${instance_id}" "${PORT}" "${BLACKBOX_EXPORTER_USER}" \
    "$(service_unit)" "$(instance_root)/etc/blackbox.yml" \
    "$(instance_root)/data" "$(instance_root)/logs"

  svc_enable "$(service_unit)"
  sleep 1
  cmd_status
  echo "[done] blackbox_exporter ${BLACKBOX_EXPORTER_VERSION} @ ${PORT}"
}

cmd_status() {
  local inst; inst="$(instance_root)"
  systemctl --no-pager --full status "$(service_unit)" 2>&1 || true
  echo "----- /-/ready -----"
  curl --noproxy '*' -fsS -u "${BASIC_USER}:$(cat ${inst}/secrets/blackbox_exporter_password)" \
    "http://127.0.0.1:${PORT}/-/ready" 2>&1 || echo "(未就绪)"
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
    ui_ask_port PORT "监听端口" "${PORT}" "blackbox_exporter HTTP/metrics 端口；已占用时必须换用空闲端口" || return 1
    ui_ask BLACKBOX_EXPORTER_VERSION "blackbox_exporter 版本" "${BLACKBOX_EXPORTER_VERSION}" "改版本需对应软件包存在" || return 1
    ui_ask BASIC_USER "Web basic auth 用户名" "${BASIC_USER}" "访问 /metrics 与 /probe 的用户名；密码安装后生成" || return 1
    archive="blackbox_exporter-${BLACKBOX_EXPORTER_VERSION}.linux-amd64.tar.gz"; upstream="${GITHUB_BASE}/v${BLACKBOX_EXPORTER_VERSION}/${archive}"
    ui_choose_download_source "${archive}" "${DOWNLOAD_CACHE}" "${upstream}" "${INTERNAL_MIRROR:-}" || return 1
    platform_preview="$(detect_platform)"
    ui_print_plan "安装确认" "组件" "blackbox_exporter ${BLACKBOX_EXPORTER_VERSION}" "平台" "${platform_preview}" "实例" "${SERVICE_NAME_PREFIX}-${PORT}" "端口" "${PORT}" "安装根目录" "$(instance_root)" "软件来源" "$(download_source_summary)"
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
# （v3.0.0-rc4 修复：补回 ACTION 赋值 —— 原文件缺失，set -u 下任何调用都会崩）
if [[ -z "${1:-}" ]]; then
  interactive_loop "blackbox_exporter 安装器 v${SCRIPT_VERSION}" \
    "${SERVICE_NAME_PREFIX}" "PORT" wizard_install
  exit 0
fi

ACTION="${1:-help}"; shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --version) BLACKBOX_EXPORTER_VERSION="$2"; shift 2 ;;
    --basic-user) BASIC_USER="$2"; shift 2 ;;
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