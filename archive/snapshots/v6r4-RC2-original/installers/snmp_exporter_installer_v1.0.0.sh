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
    echo "[download] ${url}"
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

# __PLATFORM_EMBED_BEGIN__
#!/usr/bin/env bash
# ==============================================================================
# common/platform.sh - Prometheus v3 跨平台适配层
#
# 用法:
#   source "$(dirname "${BASH_SOURCE[0]}")/common/platform.sh"
#   platform_init
#   pkg_install curl tar
#   fw_open_port 9115 tcp
#   cap_net_raw_for_binary /usr/local/blackbox_exporter/blackbox_exporter
#
# 约定:
#   - 输出 PLATFORM_* 全局变量
#   - 提供 pkg_* / svc_* / fw_* / sys_* / cap_* / archive_* 抽象函数
#   - 所有动作幂等; 失败必须返回非零
#   - 不引入任何第三方二进制依赖 (仅系统自带工具)
#   - 内部镜像根通过 INTERNAL_MIRROR 环境变量传入；未设置则用默认值
# ==============================================================================

# 内部下载镜像（优先于 GitHub 上游），可通过 env 覆盖
INTERNAL_MIRROR="${INTERNAL_MIRROR:-}"

# ------------------------------------------------------------------------------
# 常量
# ------------------------------------------------------------------------------
: "${PLATFORM_LIB_VERSION:=3.0.0}"

# ------------------------------------------------------------------------------
# 平台检测
# ------------------------------------------------------------------------------
normalize_platform_id() {
  case "${1:-}" in
    debian|debian12|ubuntu|linuxmint|uos|deepin) echo "debian" ;;
    rocky|rocky8|rocky9|rhel|centos|centos7|almalinux|ol|oracle) echo "rhel" ;;
    opensuse15|opensuse16|opensuse-leap|opensuse-tumbleweed|sles|suse) echo "suse" ;;
    openEuler|openeuler) echo "openeuler" ;;
    *) echo "${1:-unknown}" ;;
  esac
}

detect_platform() {
  # 1) 允许外部覆盖；兼容历史 PLATFORM_ID 值
  if [[ -n "${PLATFORM_ID:-}" ]]; then
    normalize_platform_id "${PLATFORM_ID}"
    return 0
  fi

  local os_id="" os_like="" os_ver=""
  if [[ -r /etc/os-release ]]; then
    # 不直接 source 到当前 shell，避免覆盖 installer 的变量
    os_id="$(awk -F= '$1=="ID"{gsub(/^\"|\"$/, "", $2); print tolower($2); exit}' /etc/os-release)"
    os_like="$(awk -F= '$1=="ID_LIKE"{gsub(/^\"|\"$/, "", $2); print tolower($2); exit}' /etc/os-release)"
    os_ver="$(awk -F= '$1=="VERSION_ID"{gsub(/^\"|\"$/, "", $2); print $2; exit}' /etc/os-release)"
  fi

  case "${os_id}" in
    debian|ubuntu|linuxmint|uos|deepin) echo debian; return 0 ;;
    rhel|rocky|almalinux|centos|ol|oracle) echo rhel; return 0 ;;
    opensuse*|sles|suse) echo suse; return 0 ;;
    openeuler) echo openeuler; return 0 ;;
  esac
  case " ${os_like} " in
    *" debian "*) echo debian; return 0 ;;
    *" rhel "*|*" fedora "*|*" centos "*) echo rhel; return 0 ;;
    *" suse "*) echo suse; return 0 ;;
    *" openeuler "*) echo openeuler; return 0 ;;
  esac

  # 2) 国产/定制发行版常出现非标准 ID；以包管理器做最后兜底
  if command -v apt-get >/dev/null 2>&1; then echo debian; return 0; fi
  if command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then echo rhel; return 0; fi
  if command -v zypper >/dev/null 2>&1; then echo suse; return 0; fi

  echo unknown
}

platform_os_release_summary() {
  if [[ -r /etc/os-release ]]; then
    awk -F= '$1=="ID" || $1=="ID_LIKE" || $1=="VERSION_ID" {print "  "$0}' /etc/os-release >&2
  fi
}

# ------------------------------------------------------------------------------
# 初始化: 设置所有 PLATFORM_* 变量并自检
# ------------------------------------------------------------------------------
platform_init() {
  PLATFORM_ID="$(detect_platform)"
  # 先初始化，避免失败路径在 set -u 下再触发 unbound variable
  PLATFORM_PKG_INSTALL="" PLATFORM_PKG_REMOVE="" PLATFORM_PKG_UPDATE=""
  PLATFORM_FW_OPEN="" PLATFORM_FW_RELOAD_CMD="" PLATFORM_FW_PRESENT="false"
  PLATFORM_USERADD="" PLATFORM_GROUPADD="" PLATFORM_NFT_PRESENT="false"
  PLATFORM_SETCAP_FALLBACK="setcap" PLATFORM_ARCHIVE_TOOL="tar" PLATFORM_ARCHIVE_FLAG="-xzf"
  PLATFORM_SYSTEMD_VERSION_MIN=219

  case "${PLATFORM_ID}" in
    debian)
      PLATFORM_PKG_INSTALL="apt-get install -y --no-install-recommends"
      PLATFORM_PKG_REMOVE="apt-get remove -y"
      PLATFORM_PKG_UPDATE="apt-get update"
      PLATFORM_FW_OPEN="ufw allow"
      PLATFORM_FW_PRESENT="command -v ufw >/dev/null 2>&1"
      PLATFORM_USERADD="useradd --system --no-create-home --shell /usr/sbin/nologin"
      PLATFORM_GROUPADD="groupadd --system"
      PLATFORM_NFT_PRESENT="command -v nft >/dev/null 2>&1"
      PLATFORM_SYSTEMD_VERSION_MIN=232
      ;;
    rhel|openeuler)
      if command -v dnf >/dev/null 2>&1; then
        PLATFORM_PKG_INSTALL="dnf install -y"; PLATFORM_PKG_REMOVE="dnf remove -y"; PLATFORM_PKG_UPDATE="dnf makecache"
      else
        PLATFORM_PKG_INSTALL="yum install -y"; PLATFORM_PKG_REMOVE="yum remove -y"; PLATFORM_PKG_UPDATE="yum makecache"
      fi
      PLATFORM_FW_OPEN="firewall-cmd --permanent --add-port"
      PLATFORM_FW_RELOAD_CMD="firewall-cmd --reload"
      PLATFORM_FW_PRESENT="command -v firewall-cmd >/dev/null 2>&1"
      PLATFORM_USERADD="useradd --system --no-create-home --shell /sbin/nologin"
      PLATFORM_GROUPADD="groupadd --system"
      PLATFORM_NFT_PRESENT="command -v nft >/dev/null 2>&1"
      ;;
    suse)
      PLATFORM_PKG_INSTALL="zypper --non-interactive install"
      PLATFORM_PKG_REMOVE="zypper --non-interactive remove"
      PLATFORM_PKG_UPDATE="zypper --non-interactive refresh"
      PLATFORM_FW_OPEN="firewall-cmd --permanent --add-port"
      PLATFORM_FW_RELOAD_CMD="firewall-cmd --reload"
      PLATFORM_FW_PRESENT="command -v firewall-cmd >/dev/null 2>&1"
      PLATFORM_USERADD="useradd --system --no-create-home --shell /usr/sbin/nologin"
      PLATFORM_GROUPADD="groupadd --system"
      PLATFORM_NFT_PRESENT="command -v nft >/dev/null 2>&1"
      PLATFORM_SYSTEMD_VERSION_MIN=232
      ;;
    *)
      echo "platform_init: 未能识别当前平台；安装已中止，未进入变更阶段。" >&2
      platform_os_release_summary
      echo "  可显式设置 PLATFORM_ID=debian|rhel|suse|openeuler 后重试。" >&2
      return 64
      ;;
  esac

  export PLATFORM_ID PLATFORM_PKG_INSTALL PLATFORM_PKG_REMOVE PLATFORM_PKG_UPDATE \
         PLATFORM_FW_OPEN PLATFORM_FW_RELOAD_CMD PLATFORM_FW_PRESENT \
         PLATFORM_USERADD PLATFORM_GROUPADD PLATFORM_NFT_PRESENT \
         PLATFORM_SETCAP_FALLBACK PLATFORM_ARCHIVE_TOOL PLATFORM_ARCHIVE_FLAG \
         PLATFORM_SYSTEMD_VERSION_MIN PLATFORM_LIB_VERSION

  for tool in bash tar systemctl; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
      echo "platform_init: 缺少依赖 ${tool}；安装已中止" >&2
      return 65
    fi
  done
  return 0
}

# ------------------------------------------------------------------------------
# 包管理
# ------------------------------------------------------------------------------
pkg_install() {
  if [[ $# -eq 0 ]]; then return 0; fi
  echo "[pkg] install: $*"
  # shellcheck disable=SC2086
  ${PLATFORM_PKG_INSTALL} "$@"
}

pkg_remove() {
  if [[ $# -eq 0 ]]; then return 0; fi
  echo "[pkg] remove: $*"
  # shellcheck disable=SC2086
  ${PLATFORM_PKG_REMOVE} "$@"
}

pkg_update() {
  echo "[pkg] update index"
  # shellcheck disable=SC2086
  ${PLATFORM_PKG_UPDATE} >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------------------
# systemd 服务
#
# 设计说明（v3.0.0-rc4 修复）：
#   - systemctl 的 reload/enable/disable 子命令在所有目标平台（debian12 / opensuse15/16
#     / rocky9 / centos7 / openeuler）完全一致，**不需要**通过 PLATFORM_SVC_* 变量做
#     平台抽象。
#   - 旧版抽象引入了一个隐蔽 bug：cmd_reload 等入口不调用 platform_init()，
#     导致 PLATFORM_SVC_RELOAD 在 set -u 下未定义 → unbound variable 崩溃。
#   - 因此这里直接调 systemctl，与平台无关；保留函数形式是为了让 installer 端
#     有统一的 hook 点（未来如需注入 sudo / 日志 / 重试可以在此扩展）。
# ------------------------------------------------------------------------------
svc_reload()  { systemctl reload "$@"; }
svc_enable()  { systemctl enable --now "$@"; }
svc_disable() { systemctl disable --now "$@"; }

# 检测当前 systemd 版本; 不存在时返回 0
systemd_version() {
  systemctl --version 2>/dev/null | awk '/^systemd /{print $2; exit}'
}

# ------------------------------------------------------------------------------
# 用户/组
# ------------------------------------------------------------------------------
sys_user_add() {
  local user="$1" group="${2:-$1}"
  if ! getent group "${group}" >/dev/null; then
    ${PLATFORM_GROUPADD} "${group}" || true
  fi
  if ! getent passwd "${user}" >/dev/null; then
    ${PLATFORM_USERADD} -g "${group}" "${user}" || true
  fi
}

# ------------------------------------------------------------------------------
# 防火墙
# ------------------------------------------------------------------------------
# MANAGE_FIREWALL: 显式开关，默认不改防火墙（审核 §12.2 P0-02）
# 用法: MANAGE_FIREWALL=1 fw_open_port 8428 tcp 192.0.2.0/24
MANAGE_FIREWALL="${MANAGE_FIREWALL:-0}"

fw_open_port() {
  local port="$1" proto="${2:-tcp}" source="${3:-}"
  [[ "${MANAGE_FIREWALL}" != "1" ]] && return 0  # 默认不改防火墙
  if eval "${PLATFORM_FW_PRESENT}"; then
    if [[ "${PLATFORM_FW_OPEN}" == *"firewall-cmd"* ]]; then
      if [[ -n "${source}" ]]; then
        firewall-cmd --permanent --new-zone="prometheus-${port}" >/dev/null 2>&1 || true
        firewall-cmd --permanent --zone="prometheus-${port}" --add-source="${source}" || return 1
        firewall-cmd --permanent --zone="prometheus-${port}" --add-port="${port}/${proto}" || return 1
      else
        firewall-cmd --permanent --add-port="${port}/${proto}" || return 1
      fi
      firewall-cmd --reload || return 1
    elif [[ "${PLATFORM_FW_OPEN}" == *"ufw"* ]]; then
      if [[ -n "${source}" ]]; then
        ufw allow from "${source}" to any port "${port}" proto "${proto}" || return 1
      else
        ufw allow "${port}/${proto}" || return 1
      fi
    fi
  fi
  return 0
}

fw_close_port() {
  local port="$1" proto="${2:-tcp}" source="${3:-}"
  [[ "${MANAGE_FIREWALL}" != "1" ]] && return 0  # 默认不改防火墙
  if eval "${PLATFORM_FW_PRESENT}"; then
    if [[ "${PLATFORM_FW_OPEN}" == *"firewall-cmd"* ]]; then
      if [[ -n "${source}" ]]; then
        firewall-cmd --permanent --delete-zone="prometheus-${port}" >/dev/null 2>&1 || true
      else
        firewall-cmd --permanent --remove-port="${port}/${proto}" || return 1
      fi
      firewall-cmd --reload || return 1
    elif [[ "${PLATFORM_FW_OPEN}" == *"ufw"* ]]; then
      if [[ -n "${source}" ]]; then
        ufw delete allow from "${source}" to any port "${port}" proto "${proto}" || return 1
      else
        ufw delete allow "${port}/${proto}" || return 1
      fi
    fi
  fi
  return 0
}

# ------------------------------------------------------------------------------
# 能力 (capabilities) - 主要用于 ICMP / 原始套接字
# ------------------------------------------------------------------------------
cap_net_raw_for_binary() {
  local bin="$1"
  [[ -x "${bin}" ]] || { echo "cap_net_raw_for_binary: ${bin} 不可执行" >&2; return 1; }

  local sv
  sv="$(systemd_version)"
  if [[ -n "${sv}" ]] && (( sv >= 229 )); then
    # 使用 systemd 的 AmbientCapabilities; 安装器不需要在此处写 unit
    :
  fi

  # 兼容路径: setcap cap_net_raw+ep
  if command -v setcap >/dev/null 2>&1; then
    ${PLATFORM_SETCAP_FALLBACK} cap_net_raw+ep "${bin}" || return 1
    echo "[cap] setcap cap_net_raw+ep ${bin}"
  else
    echo "cap_net_raw_for_binary: 需要 setcap 但系统未安装 libcap" >&2
    return 1
  fi
}

# ------------------------------------------------------------------------------
# 归档
# ------------------------------------------------------------------------------
archive_extract() {
  local src="$1" dst="$2"
  case "${src}" in
    *.tar.gz|*.tgz) ${PLATFORM_ARCHIVE_TOOL} ${PLATFORM_ARCHIVE_FLAG} "${src}" -C "${dst}" ;;
    *.tar.xz)       ${PLATFORM_ARCHIVE_TOOL} -xJf "${src}" -C "${dst}" ;;
    *.tar.bz2)      ${PLATFORM_ARCHIVE_TOOL} -xjf "${src}" -C "${dst}" ;;
    *.zip)          command -v unzip >/dev/null || { echo "unzip 未安装" >&2; return 1; }
                    unzip -q "${src}" -d "${dst}" ;;
    *) echo "archive_extract: 不支持的格式 ${src}" >&2; return 1 ;;
  esac
}

# ------------------------------------------------------------------------------
# 工具函数
# ------------------------------------------------------------------------------
ensure_dir() {
  local d="$1" mode="${2:-0755}" owner="${3:-root}" group="${4:-root}"
  # SC2174 说明：mkdir -p -m 只作用最深目录；父目录由 umask 决定。
  # 这里明确策略：父目录权限尊重 umask（不动 /usr /var /etc 等系统目录），
  # 只对最终目标目录 ${d} 强制 chmod + chown。这样不会污染系统目录权限。
  # shellcheck disable=SC2174
  [[ -d "${d}" ]] || mkdir -p -m "${mode}" "${d}"
  chmod "${mode}" "${d}" 2>/dev/null || true
  chown "${owner}:${group}" "${d}" 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# download: 下载文件，支持本地镜像优先
#
# 用法:
#   download <url> <dst>           # 单一下载源
#   download <url> <dst> [mirror]  # 镜像优先 + url 兜底
#
# 镜像约定:
#   - INTERNAL_MIRROR 默认留空，由部署环境显式提供内网镜像根 URL。
#   - 内网镜像失败时禁止自动回退公网，必须由用户重新选择下载源。
#   - 镜像 URL 只取上游 URL 的 basename 部分拼接到镜像根。
# ------------------------------------------------------------------------------
download_raw() {
  local url="$1" dst="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 2 --connect-timeout 8 -o "${dst}" "${url}"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 10 -O "${dst}" "${url}"
  else
    echo "download: 需要 curl 或 wget" >&2
    return 1
  fi
}

# 交互向导会设置 DOWNLOAD_SOURCE_MODE / DOWNLOAD_SOURCE_VALUE。
# CLI 未设置时：已有缓存直接用；否则只尝试 INTERNAL_MIRROR，不自动回退公网。
download() {
  local upstream="$1" dst="$2" mirror_root="${3:-${INTERNAL_MIRROR:-}}"
  local mode="${DOWNLOAD_SOURCE_MODE:-auto}" src="${DOWNLOAD_SOURCE_VALUE:-}"
  local fname; fname="$(basename "${upstream}")"

  case "${mode}" in
    cache|file)
      [[ -r "${src}" ]] || { echo "[download] 本地文件不可读: ${src}" >&2; return 1; }
      if [[ "${src}" != "${dst}" ]]; then cp -f "${src}" "${dst}"; fi
      echo "[download] 使用本地文件: ${src}" >&2
      ;;
    internal|internet|url)
      [[ -n "${src}" ]] || { echo "[download] 下载地址为空" >&2; return 1; }
      echo "[download] ${mode}: ${src}" >&2
      download_raw "${src}" "${dst}" || return 1
      ;;
    auto)
      [[ -s "${dst}" ]] && { echo "[download] 使用已有缓存: ${dst}" >&2; return 0; }
      if [[ -n "${mirror_root}" ]]; then
        src="${mirror_root%/}/${fname}"
        echo "[download] CLI 默认仅尝试内网镜像: ${src}" >&2
        download_raw "${src}" "${dst}" || {
          rm -f "${dst}" 2>/dev/null || true
          echo "[download] 内网镜像失败；为避免意外访问公网，不自动回退 Internet。" >&2
          echo "           可使用交互向导选择 Internet/自定义 URL，或设置 DOWNLOAD_SOURCE_MODE=internet DOWNLOAD_SOURCE_VALUE=<url>。" >&2
          return 1
        }
      else
        echo "[download] 未配置内网镜像，且未显式授权 Internet 下载。" >&2
        return 1
      fi
      ;;
    *) echo "[download] 未知来源模式: ${mode}" >&2; return 64 ;;
  esac
  [[ -s "${dst}" ]] || { echo "[download] 文件为空: ${dst}" >&2; return 1; }
}

sha256_check() {
  local file="$1" expect="$2"
  if command -v sha256sum >/dev/null 2>&1; then
    local actual
    actual="$(sha256sum "${file}" | awk '{print $1}')"
    [[ "${actual}" == "${expect}" ]] || return 1
  fi
}

# ------------------------------------------------------------------------------
# 平台信息打印
# ------------------------------------------------------------------------------
platform_summary() {
  cat <<EOF
[platform]
  id=${PLATFORM_ID}
  systemd_min=${PLATFORM_SYSTEMD_VERSION_MIN}
  pkg_install='${PLATFORM_PKG_INSTALL}'
  fw_open='${PLATFORM_FW_OPEN}'
  archive=${PLATFORM_ARCHIVE_TOOL} ${PLATFORM_ARCHIVE_FLAG}
  lib_version=${PLATFORM_LIB_VERSION}
EOF
}

# ------------------------------------------------------------------------------
# 访问申请清单（审核 P0-02 / 补充 §6.4）
#
# 设计：
#   - 安装器在 install 前注册所有"安装后需要放行"的访问项
#   - 默认不修改防火墙（MANAGE_FIREWALL=0）；输出申请清单到 ${INST_ROOT}/state/access-request.md
#   - 显式开启防火墙管理（MANAGE_FIREWALL=1）时，按注册项实际生效
#   - 每条记录包含：来源、目的、协议、端口、方向、用途、跨机房、责任人
#
# 用法（由各 installer 在 cmd_install 中调用）：
#   acl_request "<component>-<port>" "src=<src>" "dst=<dst>" "proto=tcp" \
#               "port=<port>" "direction=in" "purpose=<purpose>" \
#               "cross_room=<yes|no>" "owner=<owner>"
#   acl_emit "${INST_ROOT}/state/access-request.md"
# ------------------------------------------------------------------------------
_ACL_REQUESTS=()

acl_request() {
  local id="${1:?acl_request: 需要规则 ID}"
  shift
  local entry="id=${id}"
  for kv in "$@"; do
    entry="${entry};${kv}"
  done
  _ACL_REQUESTS+=("${entry}")
}

acl_emit() {
  local out="${1:-${INST_ROOT:-/tmp}/state/access-request.md}"
  ensure_dir "$(dirname "${out}")" 0755 root root
  {
    echo "# 访问申请清单（自动生成）"
    echo
    echo "> 生成时间: $(date -Iseconds 2>/dev/null || date)"
    echo "> 主机: $(hostname 2>/dev/null || echo unknown)"
    echo "> 平台: ${PLATFORM_ID:-unknown}"
    echo "> 防火墙管理: MANAGE_FIREWALL=${MANAGE_FIREWALL:-0}（0=仅输出申请，不改防火墙；1=按申请实际生效）"
    echo
    echo "## 申请项"
    echo
    echo "| ID | 来源 | 目的 | 协议 | 端口 | 方向 | 用途 | 跨机房 | 责任人 |"
    echo "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"
    for entry in "${_ACL_REQUESTS[@]}"; do
      # 解析 key=value 对
      local id="" src="" dst="" proto="" port="" direction="" purpose="" cross="" owner=""
      IFS=';' read -ra parts <<< "${entry}"
      for kv in "${parts[@]}"; do
        local k="${kv%%=*}" v="${kv#*=}"
        case "${k}" in
          id) id="${v}" ;;
          src|source) src="${v}" ;;
          dst|dest) dst="${v}" ;;
          proto) proto="${v}" ;;
          port) port="${v}" ;;
          direction) direction="${v}" ;;
          purpose) purpose="${v}" ;;
          cross_room) cross="${v}" ;;
          owner) owner="${v}" ;;
        esac
      done
      printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n" \
        "${id}" "${src}" "${dst}" "${proto}" "${port}" "${direction}" \
        "${purpose}" "${cross}" "${owner}"
    done
    echo
    echo "## 备注"
    echo
    echo "- 本清单由 installer 在每次 install 时自动生成。"
    echo "- 默认状态（MANAGE_FIREWALL=0）：本脚本**不修改任何防火墙规则**，需由网络/安全流程按本清单实施。"
    echo "- 显式开启（MANAGE_FIREWALL=1）：本脚本按 ID 实际调用 fw_open_port；卸载时按 ID 调用 fw_close_port。"
    echo "- **不得**通过修改端口号反向推断开放规则；实例以 ID（含组件名+端口）为唯一标识。"
  } > "${out}"
  echo "[acl] 访问申请清单已写入 ${out}"
}

# ------------------------------------------------------------------------------
# 实例归属记录（卸载时按归属识别，避免误删其他系统的规则）
#
# 设计：
#   - 安装器在 install 时将自身 ID 与端口、用户、unit、配置文件路径记录到
#     ${INST_ROOT}/state/ownership.tsv
#   - 卸载时按 instance_id 查询 ownership，仅删除仍属于该 instance 的资源
#   - 重复 install 时追加，不覆盖
#
# 用法：
#   ownership_register "${INSTANCE_ID}" "${PORT}" "${USER}" "${UNIT}" \
#                      "${CONF_FILE}" "${DATA_DIR}" "${LOG_DIR}"
#   ownership_forget "${INSTANCE_ID}"
#   ownership_list "${OUT_FILE}"
# ------------------------------------------------------------------------------
ownership_register() {
  local instance_id="$1" port="$2" svc_user="$3" unit="$4" \
        conf_file="$5" data_dir="$6" log_dir="$7"
  local state_dir="${INST_ROOT:-/tmp}/state"
  ensure_dir "${state_dir}" 0755 root root
  local out="${state_dir}/ownership.tsv"
  # 去重：同 instance_id 行替换
  if [[ -f "${out}" ]]; then
    local tmp
    tmp="$(mktemp)"
    awk -F'\t' -v id="${instance_id}" '$1 != id' "${out}" > "${tmp}" || true
    mv "${tmp}" "${out}"
  fi
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "${instance_id}" "${port}" "${svc_user}" "${unit}" \
    "${conf_file}" "${data_dir}" "${log_dir}" >> "${out}"
  chmod 0644 "${out}"
  echo "[ownership] 注册 ${instance_id} (port=${port} unit=${unit})"
}

ownership_forget() {
  local instance_id="$1"
  local state_dir="${INST_ROOT:-/tmp}/state"
  local out="${state_dir}/ownership.tsv"
  [[ -f "${out}" ]] || return 0
  local tmp
  tmp="$(mktemp)"
  awk -F'\t' -v id="${instance_id}" '$1 != id' "${out}" > "${tmp}" || true
  mv "${tmp}" "${out}"
  echo "[ownership] 注销 ${instance_id}"
}

ownership_list() {
  local out="${1:-${INST_ROOT:-/tmp}/state/ownership.tsv}"
  if [[ -f "${out}" ]]; then
    awk -F'\t' 'BEGIN {print "instance_id\tport\tuser\tunit\tconf\tdata\tlog"} {print}' "${out}"
  else
    echo "(empty)"
  fi
}

ownership_belongs_to() {
  # 用法: ownership_belongs_to <resource_path> <expected_instance_id>
  # 返回 0（归属）/ 1（不归属或未登记）
  #
  # v3.0.0-rc4 audit-blocking 修复（B08）：
  #   - 显式 END 块返回 1，避免 awk 默认退出码 0 把未登记/无 id 命中判为归属
  #   - 路径匹配强制目录边界：res == path 或 res 以 "<path>/" 开头
  #     杜绝 `/data/abc` 误匹配 `/data/a`
  #   - unit 字段做精确匹配或 suffix 匹配（res 以 "/<unit>" 结尾）
  local resource="$1" expected_id="$2"
  local state_dir="${INST_ROOT:-/tmp}/state"
  local out="${state_dir}/ownership.tsv"
  [[ -f "${out}" ]] || return 1
  awk -F'\t' -v id="${expected_id}" -v res="${resource}" '
    BEGIN { found = 0; matched_id = 0 }
    $1 == id {
      matched_id = 1
      # 字段 4（unit 名）：精确匹配 或 res 以 "/<unit>" 结尾
      unit_suffix = "/" $4
      unit_suffix_len = length(unit_suffix)
      if (length($4) > 0) {
        if (res == $4) found = 1
        if (!found && length(res) > unit_suffix_len && substr(res, length(res) - unit_suffix_len + 1) == unit_suffix) found = 1
      }
      # 字段 5..NF（路径）：精确匹配 或 res 以 "<path>/" 开头（目录边界）
      for (i = 5; i <= NF && !found; i++) {
        if (length($i) > 0) {
          if (res == $i) { found = 1; break }
          path_len = length($i)
          if (length(res) > path_len && substr(res, path_len + 1, 1) == "/" && substr(res, 1, path_len) == $i) { found = 1; break }
        }
      }
    }
    # awk 中 exit 会先跑 END 再退出；统一用 found flag 在 END 决定最终退出码
    END { exit (found ? 0 : 1) }
  ' "${out}"
}

# 安全删除实例根目录：只允许删除组件 INSTALL_ROOT 的直接/下级实例目录，绝不删除 INSTALL_ROOT 本身。
safe_remove_instance_root() {
  local target="$1" base="$2" rt rb
  [[ -n "${target}" && -n "${base}" ]] || { echo "[uninstall] 拒绝删除空路径" >&2; return 1; }
  rt="$(readlink -m -- "${target}")"
  rb="$(readlink -m -- "${base}")"
  [[ "${rt}" != "/" && "${rt}" != "${rb}" && "${rt}" == "${rb}/"* ]] || {
    echo "[uninstall] 安全保护：拒绝删除超出组件目录的路径: ${rt}" >&2
    return 1
  }
  [[ -e "${rt}" ]] || { echo "[uninstall] 实例目录不存在，无需删除: ${rt}"; return 0; }
  rm -rf --one-file-system -- "${rt}"
  echo "[uninstall] 已删除实例目录: ${rt}"
}

# ==============================================================================
# 交互式向导与实例管理框架
# ==============================================================================

UI_EXIT_REQUESTED=0
DOWNLOAD_SOURCE_MODE="${DOWNLOAD_SOURCE_MODE:-auto}"
DOWNLOAD_SOURCE_VALUE="${DOWNLOAD_SOURCE_VALUE:-}"
DOWNLOAD_SOURCE_LABEL="${DOWNLOAD_SOURCE_LABEL:-自动}"
SELECTED_INSTANCE_UNIT=""
SELECTED_INSTANCE_PORT=""
SELECTED_INSTANCE_TYPE=""
SELECTED_INSTANCE_FRAGMENT=""
SELECTED_INSTANCE_EXEC=""
SELECTED_INSTANCE_PACKAGE=""

ui_ask() {
  local __var="$1" __prompt="$2" __default="${3:-}" __desc="${4:-}"
  local input
  [[ -n "${__desc}" ]] && echo "    说明: ${__desc}"
  if [[ -n "${__default}" ]]; then
    read -r -p "  ${__prompt} [${__default}] (q=退出): " input || return 1
  else
    read -r -p "  ${__prompt} (q=退出): " input || return 1
  fi
  case "${input}" in q|Q) UI_EXIT_REQUESTED=1; return 1 ;; "") input="${__default}" ;; esac
  printf -v "${__var}" '%s' "${input}"
  return 0
}

ui_confirm() {
  local answer
  echo "$1"
  echo "    1) 确认 [默认]"
  echo "    2) 取消"
  echo "    3) 返回"
  echo "    q) 退出"
  read -r -p "  请选择 [1]: " answer || return 1
  [[ -z "${answer}" ]] && answer=1
  case "${answer}" in
    1) return 0 ;;
    2|3) return 1 ;;
    q|Q) UI_EXIT_REQUESTED=1; return 1 ;;
    *) echo "  无效选择"; return 2 ;;
  esac
}

# 安装最终确认：不用 Y/n/q，明确使用序号。
# 返回时不依赖特殊退出码，而通过 UI_INSTALL_ACTION 告知调用方。
UI_INSTALL_ACTION=""
ui_install_confirm() {
  local input
  UI_INSTALL_ACTION=""
  echo
  echo "请选择下一步："
  echo "    1) 确认以上信息，立即开始安装 [默认]"
  echo "    2) 返回重新修改安装参数"
  echo "    3) 取消本次安装，返回主菜单"
  echo "    q) 退出安装器"
  while true; do
    read -r -p "  请选择 [1]: " input || { UI_INSTALL_ACTION=quit; UI_EXIT_REQUESTED=1; return 0; }
    [[ -z "${input}" ]] && input=1
    case "${input}" in
      1) UI_INSTALL_ACTION=install; return 0 ;;
      2) UI_INSTALL_ACTION=back; return 0 ;;
      3) UI_INSTALL_ACTION=cancel; return 0 ;;
      q|Q) UI_INSTALL_ACTION=quit; UI_EXIT_REQUESTED=1; return 0 ;;
      *) echo "  无效选择，请输入 1/2/3/q" ;;
    esac
  done
}

# 端口检测/选择：安装阶段严禁复用已监听端口。
port_in_use() {
  local port="$1"
  [[ "${port}" =~ ^[0-9]+$ ]] || return 1
  if command -v ss >/dev/null 2>&1; then
    ss -H -lnt 2>/dev/null | awk -v p="${port}" '{a=$4; sub(/^.*:/,"",a); if (a==p) {found=1; exit}} END{exit(found?0:1)}'
    return $?
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -lnt 2>/dev/null | awk -v p="${port}" 'NR>2 {a=$4; sub(/^.*:/,"",a); if (a==p) {found=1; exit}} END{exit(found?0:1)}'
    return $?
  fi
  return 1
}

port_is_reserved() {
  local port="$1" reserved_csv="${2:-}" item
  [[ -n "${reserved_csv}" ]] || return 1
  IFS=',' read -ra _rsv <<< "${reserved_csv}"
  for item in "${_rsv[@]}"; do [[ "${item}" == "${port}" ]] && return 0; done
  return 1
}

next_free_port() {
  local start="$1" reserved_csv="${2:-}" p i
  [[ "${start}" =~ ^[0-9]+$ ]] || start=1024
  (( start < 1024 )) && start=1024
  for ((i=0; i<200; i++)); do
    p=$((start+i))
    (( p <= 65535 )) || break
    port_is_reserved "${p}" "${reserved_csv}" && continue
    port_in_use "${p}" || { echo "${p}"; return 0; }
  done
  return 1
}

ui_ask_port() {
  local __var="$1" __prompt="$2" __default="$3" __desc="${4:-}" __reserved="${5:-}"
  local input candidate recommended
  [[ -n "${__desc}" ]] && echo "    说明: ${__desc}"
  while true; do
    read -r -p "  ${__prompt} [${__default}] (q=退出): " input || return 1
    case "${input}" in q|Q) UI_EXIT_REQUESTED=1; return 1 ;; "") candidate="${__default}" ;; *) candidate="${input}" ;; esac
    if ! [[ "${candidate}" =~ ^[0-9]+$ ]] || (( candidate < 1 || candidate > 65535 )); then
      echo "  无效端口：${candidate}；请输入 1-65535。"
      continue
    fi
    if port_is_reserved "${candidate}" "${__reserved}"; then
      echo "  端口 ${candidate} 为本组件其他用途预留，不能复用。"
    elif ! port_in_use "${candidate}"; then
      printf -v "${__var}" '%s' "${candidate}"
      return 0
    else
      echo "  [端口冲突] ${candidate} 已被其他进程监听，安装器禁止复用。"
    fi

    recommended="$(next_free_port "$((candidate+1))" "${__reserved}" || true)"
    echo "  请选择处理方式："
    if [[ -n "${recommended}" ]]; then echo "    1) 使用推荐空闲端口 ${recommended} [默认]"; else echo "    1) 自动查找空闲端口（当前未找到）"; fi
    echo "    2) 手动输入其他端口"
    echo "    3) 取消本次安装，返回主菜单"
    echo "    q) 退出安装器"
    read -r -p "  请选择 [1]: " input || return 1
    [[ -z "${input}" ]] && input=1
    case "${input}" in
      1) [[ -n "${recommended}" ]] || { echo "  未找到可用推荐端口，请手动输入。"; continue; }; printf -v "${__var}" '%s' "${recommended}"; return 0 ;;
      2) __default="${recommended:-$((candidate+1))}"; continue ;;
      3) return 1 ;;
      q|Q) UI_EXIT_REQUESTED=1; return 1 ;;
      *) echo "  无效选择，请输入 1/2/3/q" ;;
    esac
  done
}

ui_ask_secret() {
  local __var="$1" __prompt="$2" __desc="${3:-}"
  local input
  [[ -n "${__desc}" ]] && echo "    说明: ${__desc}"
  read -r -s -p "  ${__prompt} (留空=自动生成, q=退出): " input || return 1
  echo
  case "${input}" in q|Q) UI_EXIT_REQUESTED=1; return 1 ;; esac
  printf -v "${__var}" '%s' "${input}"
  return 0
}

ui_select_yes_no() {
  local __var="$1" __title="$2" __default="${3:-1}" __yes="${4:-是}" __no="${5:-否}"
  local input
  echo "  ${__title}"
  echo "    1) ${__yes}$([[ "${__default}" == 1 ]] && echo ' [默认]')"
  echo "    2) ${__no}$([[ "${__default}" == 2 ]] && echo ' [默认]')"
  echo "    q) 退出"
  read -r -p "  请选择 [${__default}]: " input || return 1
  [[ -z "${input}" ]] && input="${__default}"
  case "${input}" in 1) printf -v "${__var}" 1 ;; 2) printf -v "${__var}" 0 ;; q|Q) UI_EXIT_REQUESTED=1; return 1 ;; *) echo "  无效选择"; return 2 ;; esac
}

ui_choose_download_source() {
  local archive="$1" cache_dir="$2" upstream="$3" mirror_root="${4:-${INTERNAL_MIRROR:-}}"
  local cache_file="${cache_dir%/}/${archive}" mirror_url="" input custom
  [[ -n "${mirror_root}" ]] && mirror_url="${mirror_root%/}/${archive}"
  echo
  echo "[软件来源] 目标文件: ${archive}"
  if [[ -s "${cache_file}" ]]; then
    echo "  已发现本地缓存: ${cache_file}"
    echo "    1) 使用本地缓存 [默认]"
    echo "    2) 内网镜像${mirror_url:+ (${mirror_url})}"
    echo "    3) Internet 官方源"
    echo "    4) 指定本地文件"
    echo "    5) 指定 URL"
    echo "    q) 退出"
    read -r -p "  请选择 [1]: " input || return 1
    [[ -z "${input}" ]] && input=1
    case "${input}" in
      1) DOWNLOAD_SOURCE_MODE=cache; DOWNLOAD_SOURCE_VALUE="${cache_file}"; DOWNLOAD_SOURCE_LABEL="本地缓存" ;;
      2) [[ -n "${mirror_url}" ]] || { echo "  未配置内网镜像"; return 2; }; DOWNLOAD_SOURCE_MODE=internal; DOWNLOAD_SOURCE_VALUE="${mirror_url}"; DOWNLOAD_SOURCE_LABEL="内网镜像" ;;
      3) DOWNLOAD_SOURCE_MODE=internet; DOWNLOAD_SOURCE_VALUE="${upstream}"; DOWNLOAD_SOURCE_LABEL="Internet 官方源" ;;
      4) read -r -p "  本地文件绝对路径: " custom || return 1; [[ -r "${custom}" ]] || { echo "  文件不可读: ${custom}"; return 2; }; DOWNLOAD_SOURCE_MODE=file; DOWNLOAD_SOURCE_VALUE="${custom}"; DOWNLOAD_SOURCE_LABEL="指定本地文件" ;;
      5) read -r -p "  自定义 URL: " custom || return 1; [[ "${custom}" =~ ^https?:// ]] || { echo "  仅支持 http/https URL"; return 2; }; DOWNLOAD_SOURCE_MODE=url; DOWNLOAD_SOURCE_VALUE="${custom}"; DOWNLOAD_SOURCE_LABEL="自定义 URL" ;;
      q|Q) UI_EXIT_REQUESTED=1; return 1 ;; *) echo "  无效选择"; return 2 ;;
    esac
  else
    echo "  未发现本地缓存: ${cache_file}"
    if [[ -n "${mirror_url}" ]]; then
      echo "    1) 内网镜像 [默认] (${mirror_url})"
    else
      echo "    1) 指定内网镜像根 URL [默认]"
    fi
    echo "    2) Internet 官方源"
    echo "    3) 指定本地文件"
    echo "    4) 指定 URL"
    echo "    q) 退出"
    read -r -p "  请选择 [1]: " input || return 1
    [[ -z "${input}" ]] && input=1
    case "${input}" in
      1)
        if [[ -z "${mirror_url}" ]]; then
          read -r -p "  内网镜像根 URL（例如 http://mirror.example/monitor）: " custom || return 1
          [[ "${custom}" =~ ^https?:// ]] || { echo "  仅支持 http/https URL"; return 2; }
          mirror_url="${custom%/}/${archive}"
        fi
        DOWNLOAD_SOURCE_MODE=internal; DOWNLOAD_SOURCE_VALUE="${mirror_url}"; DOWNLOAD_SOURCE_LABEL="内网镜像"
        ;;
      2) DOWNLOAD_SOURCE_MODE=internet; DOWNLOAD_SOURCE_VALUE="${upstream}"; DOWNLOAD_SOURCE_LABEL="Internet 官方源" ;;
      3) read -r -p "  本地文件绝对路径: " custom || return 1; [[ -r "${custom}" ]] || { echo "  文件不可读: ${custom}"; return 2; }; DOWNLOAD_SOURCE_MODE=file; DOWNLOAD_SOURCE_VALUE="${custom}"; DOWNLOAD_SOURCE_LABEL="指定本地文件" ;;
      4) read -r -p "  自定义 URL: " custom || return 1; [[ "${custom}" =~ ^https?:// ]] || { echo "  仅支持 http/https URL"; return 2; }; DOWNLOAD_SOURCE_MODE=url; DOWNLOAD_SOURCE_VALUE="${custom}"; DOWNLOAD_SOURCE_LABEL="自定义 URL" ;;
      q|Q) UI_EXIT_REQUESTED=1; return 1 ;; *) echo "  无效选择"; return 2 ;;
    esac
  fi
  export DOWNLOAD_SOURCE_MODE DOWNLOAD_SOURCE_VALUE DOWNLOAD_SOURCE_LABEL
  return 0
}

download_source_summary() {
  printf '%s: %s' "${DOWNLOAD_SOURCE_LABEL:-自动}" "${DOWNLOAD_SOURCE_VALUE:-未选择}"
}

ui_print_plan() {
  local title="$1"; shift
  echo
  echo "========== ${title} =========="
  while [[ $# -ge 2 ]]; do printf "  %-20s %s\n" "$1" "$2"; shift 2; done
  echo "================================"
}

_package_for_fragment() {
  local f="$1" pkg=""
  [[ -n "${f}" && -e "${f}" ]] || return 1
  if command -v dpkg-query >/dev/null 2>&1; then pkg="$(dpkg-query -S "${f}" 2>/dev/null | head -1 | cut -d: -f1 || true)"; fi
  if [[ -z "${pkg}" ]] && command -v rpm >/dev/null 2>&1; then pkg="$(rpm -qf "${f}" 2>/dev/null || true)"; fi
  [[ -n "${pkg}" ]] && { echo "${pkg}"; return 0; }
  return 1
}

_unit_matches_component() {
  local prefix="$1" unit="$2"
  case "${prefix}" in
    node_exporter) [[ "${unit}" == node_exporter*.service || "${unit}" == node-exporter*.service ]] ;;
    blackbox_exporter) [[ "${unit}" == blackbox_exporter*.service || "${unit}" == blackbox-exporter*.service ]] ;;
    snmp_exporter) [[ "${unit}" == snmp_exporter*.service || "${unit}" == snmp-exporter*.service ]] ;;
    victoriametrics) [[ "${unit,,}" == victoriametrics*.service || "${unit}" == vmstorage*.service ]] ;;
    grafana) [[ "${unit}" == grafana*.service || "${unit}" == grafana-server.service ]] ;;
    *) [[ "${unit}" == "${prefix}"*.service ]] ;;
  esac
}

_detect_unit_port() {
  local unit="$1" prefix="$2" port="" pid="" exec=""
  if [[ "${unit}" =~ ^${prefix//_/-}-?([0-9]{2,5})\.service$ || "${unit}" =~ ^${prefix}-?([0-9]{2,5})\.service$ ]]; then port="${BASH_REMATCH[1]}"; fi
  pid="$(systemctl show -p MainPID --value "${unit}" 2>/dev/null || true)"
  if [[ -z "${port}" && "${pid}" =~ ^[1-9][0-9]*$ ]] && command -v ss >/dev/null 2>&1; then
    port="$(ss -lntpH 2>/dev/null | awk -v p="pid=${pid}," '$0~p {n=$4; sub(/^.*:/,"",n); if(n~/^[0-9]+$/){print n; exit}}')"
  fi
  if [[ -z "${port}" ]]; then
    exec="$(systemctl show -p ExecStart --value "${unit}" 2>/dev/null || true)"
    port="$(printf '%s\n' "${exec}" | grep -oE ':[0-9]{2,5}' | head -1 | tr -d ':' || true)"
  fi
  echo "${port}"
}

discover_instances() {
  local prefix="$1" unit fragment exec type port pkg ownership_file="${INST_ROOT:-/tmp}/state/ownership.tsv"
  local -A seen=()
  while read -r unit _; do
    [[ -n "${unit}" ]] || continue
    _unit_matches_component "${prefix}" "${unit}" || continue
    [[ -z "${seen[${unit}]:-}" ]] || continue; seen[${unit}]=1
    fragment="$(systemctl show -p FragmentPath --value "${unit}" 2>/dev/null || true)"
    exec="$(systemctl show -p ExecStart --value "${unit}" 2>/dev/null || true)"
    port="$(_detect_unit_port "${unit}" "${prefix}")"
    type=external; pkg=""
    if [[ -f "${ownership_file}" ]] && awk -F'\t' -v u="${unit}" '$4==u{found=1} END{exit !found}' "${ownership_file}"; then
      type=managed
    elif [[ "${fragment}" == /usr/lib/systemd/system/* || "${fragment}" == /lib/systemd/system/* ]]; then
      pkg="$(_package_for_fragment "${fragment}" || true)"; type=package
    fi
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "${unit}" "${port}" "${type}" "${fragment}" "${pkg}" "${exec}"
  done < <(systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null || true)
}

ui_pick_instance() {
  local prefix="$1" input i
  local -a rows=()
  mapfile -t rows < <(discover_instances "${prefix}")
  if [[ ${#rows[@]} -eq 0 ]]; then
    echo "  未发现 ${prefix} 相关 systemd 实例。" >&2; return 2
  fi
  echo "  已发现实例:" >&2
  for i in "${!rows[@]}"; do
    IFS=$'\x1f' read -r u p t f pkg ex <<< "${rows[$i]}"
    printf '    %d) %-34s port=%-6s type=%-8s %s\n' "$((i+1))" "${u}" "${p:--}" "${t}" "${pkg:+package=${pkg}}" >&2
  done
  read -r -p "  选择序号 (回车=第 1 个, q=退出): " input || return 1
  case "${input}" in q|Q) UI_EXIT_REQUESTED=1; return 1 ;; "") input=1 ;; esac
  [[ "${input}" =~ ^[0-9]+$ ]] && (( input>=1 && input<=${#rows[@]} )) || { echo "  无效选择" >&2; return 1; }
  IFS=$'\x1f' read -r SELECTED_INSTANCE_UNIT SELECTED_INSTANCE_PORT SELECTED_INSTANCE_TYPE SELECTED_INSTANCE_FRAGMENT SELECTED_INSTANCE_PACKAGE SELECTED_INSTANCE_EXEC <<< "${rows[$((input-1))]}"
  export SELECTED_INSTANCE_UNIT SELECTED_INSTANCE_PORT SELECTED_INSTANCE_TYPE SELECTED_INSTANCE_FRAGMENT SELECTED_INSTANCE_PACKAGE SELECTED_INSTANCE_EXEC
  return 0
}

external_instance_status() {
  systemctl --no-pager --full status "${SELECTED_INSTANCE_UNIT}" 2>&1 || true
  if [[ -n "${SELECTED_INSTANCE_PORT}" ]]; then
    ss -lnt 2>/dev/null | grep -qE ":${SELECTED_INSTANCE_PORT}([[:space:]]|$)" && echo "  端口 ${SELECTED_INSTANCE_PORT}: 监听中" || echo "  端口 ${SELECTED_INSTANCE_PORT}: 未监听"
  fi
}

external_instance_reload() {
  if systemctl reload "${SELECTED_INSTANCE_UNIT}" 2>/dev/null; then echo "[reload] ${SELECTED_INSTANCE_UNIT}"; return 0; fi
  systemctl kill -s HUP "${SELECTED_INSTANCE_UNIT}" && echo "[reload] sent HUP to ${SELECTED_INSTANCE_UNIT}"
}

external_instance_uninstall() {
  local choice inferred_root="" exec_path=""
  echo
  echo "[外部实例] 该服务不是本安装器托管实例："
  echo "  unit      : ${SELECTED_INSTANCE_UNIT}"
  echo "  type      : ${SELECTED_INSTANCE_TYPE}"
  echo "  fragment  : ${SELECTED_INSTANCE_FRAGMENT:--}"
  echo "  port      : ${SELECTED_INSTANCE_PORT:--}"
  echo "  package   : ${SELECTED_INSTANCE_PACKAGE:--}"
  echo "  ExecStart : ${SELECTED_INSTANCE_EXEC:--}"

  if [[ "${SELECTED_INSTANCE_TYPE}" == package ]]; then
    echo
    echo "请选择卸载方式："
    echo "    1) 仅停止并禁用服务 [默认]"
    echo "    2) 使用系统包管理器卸载 ${SELECTED_INSTANCE_PACKAGE:-<unknown>}"
    echo "    3) 取消并返回主菜单"
    echo "    q) 退出安装器"
    read -r -p "  请选择 [1]: " choice || return 1
    [[ -z "${choice}" ]] && choice=1
    case "${choice}" in
      1) systemctl disable --now "${SELECTED_INSTANCE_UNIT}" || true; return 0 ;;
      2)
        [[ -n "${SELECTED_INSTANCE_PACKAGE}" ]] || { echo "  无法识别所属软件包，拒绝删除"; return 1; }
        if command -v apt-get >/dev/null 2>&1; then apt-get remove -y "${SELECTED_INSTANCE_PACKAGE}"; elif command -v dnf >/dev/null 2>&1; then dnf remove -y "${SELECTED_INSTANCE_PACKAGE}"; else yum remove -y "${SELECTED_INSTANCE_PACKAGE}"; fi
        return $? ;;
      3) echo "已取消"; return 0 ;;
      q|Q) UI_EXIT_REQUESTED=1; return 1 ;;
      *) echo "  无效选择"; return 1 ;;
    esac
  fi

  [[ "${SELECTED_INSTANCE_FRAGMENT}" == /etc/systemd/system/* ]] || {
    echo "  外部 unit 不位于 /etc/systemd/system，禁止直接删除；仅允许 stop+disable。"
    systemctl disable --now "${SELECTED_INSTANCE_UNIT}" || true
    return 0
  }

  # 只有二进制明确位于当前组件 INSTALL_ROOT 下时，才允许提供“连安装目录一起删除”。
  exec_path="$(printf '%s\n' "${SELECTED_INSTANCE_EXEC}" | sed -n 's/.*path=\([^ ;}]*\).*/\1/p' | head -1)"
  if [[ -n "${exec_path}" && -n "${INSTALL_ROOT:-}" ]]; then
    case "${exec_path}" in
      "${INSTALL_ROOT}"/*/bin/*) inferred_root="${exec_path%/bin/*}" ;;
    esac
  fi

  echo
  echo "请选择卸载方式："
  echo "    1) 标准卸载 [默认] — stop+disable 并删除该 /etc/systemd/system unit；保留程序/配置/数据"
  if [[ -n "${inferred_root}" ]]; then
    echo "    2) 完整卸载 — 在标准卸载基础上删除检测到的安装目录 ${inferred_root}"
  else
    echo "    2) 完整卸载 — 不可用（未能安全识别位于 ${INSTALL_ROOT:-/usr/local} 下的实例目录）"
  fi
  echo "    3) 取消并返回主菜单"
  echo "    q) 退出安装器"
  read -r -p "  请选择 [1]: " choice || return 1
  [[ -z "${choice}" ]] && choice=1
  case "${choice}" in
    1)
      systemctl disable --now "${SELECTED_INSTANCE_UNIT}" || true
      rm -f -- "${SELECTED_INSTANCE_FRAGMENT}"
      systemctl daemon-reload
      echo "[uninstall] 已移除外部 unit；程序/配置/数据保留"
      ;;
    2)
      [[ -n "${inferred_root}" ]] || { echo "  无法安全识别实例目录，拒绝删除。"; return 1; }
      systemctl disable --now "${SELECTED_INSTANCE_UNIT}" || true
      rm -f -- "${SELECTED_INSTANCE_FRAGMENT}"
      systemctl daemon-reload
      safe_remove_instance_root "${inferred_root}" "${INSTALL_ROOT}"
      ;;
    3) echo "已取消"; return 0 ;;
    q|Q) UI_EXIT_REQUESTED=1; return 1 ;;
    *) echo "  无效选择"; return 1 ;;
  esac
}

interactive_loop() {
  local title="$1" prefix="$2" port_var="$3" install_wizard="$4"
  local choice uninstall_choice
  while true; do
    cat <<EOF

========================================
 ${title}
========================================
  1) 安装   install   新建/重装一个实例
  2) 状态   status    systemd unit 运行状态
  3) 监测   probe     端口/metrics/进程 存活检查
  4) 重载   reload    应用配置变更
  5) 卸载   uninstall 卸载实例（默认删除该实例安装目录）
  q) 退出
EOF
    read -r -p "请选择 (回车=退出, q=退出): " choice || return 0
    case "${choice}" in
      ""|q|Q) echo "退出"; return 0 ;;
      1)
        echo; echo "[安装向导] 主菜单回车=退出；向导内回车=默认值，q=退出安装器"
        UI_EXIT_REQUESTED=0
        if ! "${install_wizard}"; then
          if [[ "${UI_EXIT_REQUESTED}" == 1 ]]; then echo "退出"; return 0; fi
          echo "[安装向导] 已取消或失败"
        fi
        [[ "${UI_EXIT_REQUESTED}" == 1 ]] && { echo "退出"; return 0; }
        ;;
      2|3|4|5)
        UI_EXIT_REQUESTED=0
        if ! ui_pick_instance "${prefix}"; then
          [[ "${UI_EXIT_REQUESTED}" == 1 ]] && { echo "退出"; return 0; }
          continue
        fi
        if [[ -n "${SELECTED_INSTANCE_PORT}" ]]; then printf -v "${port_var}" '%s' "${SELECTED_INSTANCE_PORT}"; fi
        if [[ "${SELECTED_INSTANCE_TYPE}" == managed ]]; then
          case "${choice}" in
            2|3) cmd_status ;;
            4) cmd_reload ;;
            5)
              echo; echo "[卸载前检查] ${SELECTED_INSTANCE_UNIT}:"
              systemctl is-active --quiet "${SELECTED_INSTANCE_UNIT}" && echo "  服务状态 : active" || echo "  服务状态 : 非 active"
              echo "  实例目录 : $(instance_root)"
              echo
              echo "请选择卸载方式："
              echo "    1) 完整卸载 [默认] — 删除 unit，并删除该实例安装目录（含配置/数据）"
              echo "    2) 保留实例目录卸载 — 删除 unit，但保留配置/数据"
              echo "    3) 取消并返回主菜单"
              echo "    q) 退出安装器"
              read -r -p "  请选择 [1]: " uninstall_choice || continue
              [[ -z "${uninstall_choice}" ]] && uninstall_choice=1
              case "${uninstall_choice}" in
                1) UNINSTALL_MODE=remove; export UNINSTALL_MODE; cmd_uninstall ;;
                2) UNINSTALL_MODE=keep; export UNINSTALL_MODE; cmd_uninstall ;;
                3) echo "已取消" ;;
                q|Q) echo "退出"; return 0 ;;
                *) echo "无效选择: ${uninstall_choice}" ;;
              esac
              ;;
          esac
        else
          case "${choice}" in 2|3) external_instance_status ;; 4) external_instance_reload ;; 5) external_instance_uninstall ;; esac
          [[ "${UI_EXIT_REQUESTED}" == 1 ]] && { echo "退出"; return 0; }
        fi
        ;;
      *) echo "无效选择: ${choice}" ;;
    esac
  done
}

# __PLATFORM_EMBED_END__
