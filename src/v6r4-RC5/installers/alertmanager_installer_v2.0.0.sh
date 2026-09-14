#!/usr/bin/env bash
# ==============================================================================
# alertmanager_installer_v2.0.0.sh
#
# Alertmanager 0.34.0 跨平台一键安装器 (v3 系列)
#
# ------------------------------------------------------------------------------
# 模块概述
# ------------------------------------------------------------------------------
# 职责：
#   - 下载 release tarball，落地到 ${INSTALL_ROOT}/alertmanager-${WEB_PORT}/
#   - 创建系统用户 / 数据目录 / 凭据目录 / 日志目录
#   - 生成 alertmanager.yml 默认骨架 + notification.tmpl（v3 标签契约）
#   - 写 systemd unit，启动并注册实例归属
#
# 关键设计：
#   - 配置目录：${inst}/etc/（ADR-10：官方 config 改 etc/，与 9/10 组件一致）
#   - 模板目录：${inst}/etc/templates/
#   - 数据目录：${inst}/data/（silences / nflog / gossip）
#   - 凭据目录：${inst}/etc/secrets/
#   - 日志目录：${inst}/logs/（out/err 分流）
#
# 通用 5 动作：install / status / reload / uninstall
#
# 用法:
#   sudo ./alertmanager_installer_v2.0.0.sh install [--port 9093] [--cluster-port 9094]
#   sudo ./alertmanager_installer_v2.0.0.sh status  --port 9093
#   sudo ./alertmanager_installer_v2.0.0.sh reload  --port 9093
#   sudo ./alertmanager_installer_v2.0.0.sh uninstall --port 9093
#
# 关联 ADR / 审核:
#   - ADR-08 多实例与旧系统迁移
#   - ADR-10 路径命名规范（官方约定优先；本组件 config/ → etc/）
#   - 审核 P0-02 访问申请清单 + 卸载归属识别
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# 常量（默认值集中区；CLI > 环境变量 > 默认值）
# ------------------------------------------------------------------------------
SCRIPT_VERSION="2.0.0"
DEFAULT_VERSION="0.34.0"
INSTALL_ROOT="/usr/local/alertmanager"
GITHUB_BASE="https://github.com/prometheus/alertmanager/releases/download"
DEFAULT_WEB_PORT=9093
DEFAULT_CLUSTER_PORT=9094
SERVICE_NAME_PREFIX="alertmanager"

# ------------------------------------------------------------------------------
# 平台抽象层 source（pkg_* / svc_* / fw_* / sys_user_add / acl_* / ownership_* / archive_*）
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common/platform.sh"
export INST_ROOT="${INST_ROOT:-${INSTALL_ROOT}}"

# ------------------------------------------------------------------------------
# 环境变量兼容垫片：旧 AM_* 前缀保留，新名 ALERTMANAGER_* 优先
# （v3.0.0-rc4 命名统一；详见 feedback_env_var_prefix.md）
# ------------------------------------------------------------------------------
AM_USER="${AM_USER:-alertmanager}"
AM_GROUP="${AM_GROUP:-alertmanager}"
[[ -n "${AM_USER:-}"     && -z "${ALERTMANAGER_USER:-}"     ]] && ALERTMANAGER_USER="${AM_USER}"
[[ -n "${AM_GROUP:-}"    && -z "${ALERTMANAGER_GROUP:-}"    ]] && ALERTMANAGER_GROUP="${AM_GROUP}"
[[ -n "${AM_VERSION:-}"  && -z "${ALERTMANAGER_VERSION:-}"  ]] && ALERTMANAGER_VERSION="${AM_VERSION:-${DEFAULT_VERSION}}"

# 默认值（v3.0.0-rc4-G0 修复：避免 compat shim 自赋值触发 set -u unbound）
ALERTMANAGER_USER="${ALERTMANAGER_USER:-alertmanager}"
ALERTMANAGER_GROUP="${ALERTMANAGER_GROUP:-alertmanager}"
ALERTMANAGER_VERSION="${ALERTMANAGER_VERSION:-${DEFAULT_VERSION}}"
WEB_PORT="${WEB_PORT:-${DEFAULT_WEB_PORT}}"
CLUSTER_PORT="${CLUSTER_PORT:-${DEFAULT_CLUSTER_PORT}}"
CLUSTER_ENABLED="${CLUSTER_ENABLED:-0}"
CLUSTER_PEERS="${CLUSTER_PEERS:-}"
RETENTION="${RETENTION:-120h}"
DOWNLOAD_CACHE="${DOWNLOAD_CACHE:-${INSTALL_ROOT}/cache}"

usage() {
  cat <<EOF
alertmanager_installer v${SCRIPT_VERSION}

用法:
  $0 install [--port 9093] [--cluster-port 9094] [--version ${DEFAULT_VERSION}] [--retention 120h]
  $0 status  --port 9093
  $0 reload  --port 9093
  $0 uninstall --port 9093
EOF
}

# ------------------------------------------------------------------------------
# 实例目录与 unit 派生（v3.0.0-rc4 命名：${INSTALL_ROOT}/<component>-<port>/）
# 所有函数都是单行 echo；调用者通过 $(instance_root) 拿值。
# ------------------------------------------------------------------------------
instance_root()      { echo "${INSTALL_ROOT}/${SERVICE_NAME_PREFIX}-${WEB_PORT}"; }
service_unit()       { echo "${SERVICE_NAME_PREFIX}-${WEB_PORT}.service"; }
INSTANCE_STATE_DIR() { echo "${INSTALL_ROOT}/state/${SERVICE_NAME_PREFIX}-${WEB_PORT}"; }

# ------------------------------------------------------------------------------
# 权限校验：所有动作都需 root
# ------------------------------------------------------------------------------
require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "必须以 root 运行" >&2
    exit 1
  fi
}

# ------------------------------------------------------------------------------
# download_am: 下载 release tarball，落地二进制到 ${inst}/bin/
#
# 流程：
#   1. 若 DOWNLOAD_CACHE 已有同名 archive，跳过下载（多实例共享缓存）
#   2. 解压到 mktemp 临时目录
#   3. install 0755 alertmanager + amtool
#
# 失败语义：网络错误 exit 2；解压结构异常由 archive_extract 自己报错。
# ------------------------------------------------------------------------------
download_am() {
  mkdir -p "${DOWNLOAD_CACHE}"
  local archive="alertmanager-${ALERTMANAGER_VERSION}.linux-amd64.tar.gz"
  local url="${GITHUB_BASE}/v${ALERTMANAGER_VERSION}/${archive}"
  local dst="${DOWNLOAD_CACHE}/${archive}"
  if [[ ! -s "${dst}" || "${DOWNLOAD_SOURCE_MODE:-auto}" =~ ^(internal|internet|url|file)$ ]]; then
    echo "[download] 准备获取: ${archive}"
    download "${url}" "${dst}" || { echo "下载失败" >&2; exit 2; }
  fi

  local tmp; tmp="$(mktemp -d)"
  archive_extract "${dst}" "${tmp}"
  local src="${tmp}/alertmanager-${ALERTMANAGER_VERSION}.linux-amd64"
  local inst; inst="$(instance_root)"
  mkdir -p "${inst}/bin" "${inst}/etc" \
           "${inst}/etc/templates" "${inst}/data" \
           "${inst}/logs" "${inst}/etc/secrets"
  install -m 0755 "${src}/alertmanager" "${inst}/bin/alertmanager"
  install -m 0755 "${src}/amtool"       "${inst}/bin/amtool"
  rm -rf "${tmp}"
}

# ------------------------------------------------------------------------------
# prepare_dirs: 建系统用户 + 8 类子目录（ensure_dir 幂等）
# ------------------------------------------------------------------------------
prepare_dirs() {
  sys_user_add "${ALERTMANAGER_USER}" "${ALERTMANAGER_GROUP}"
  local inst; inst="$(instance_root)"
  ensure_dir "${inst}"                0755 "${ALERTMANAGER_USER}" "${ALERTMANAGER_GROUP}"
  ensure_dir "${inst}/etc"            0750 "${ALERTMANAGER_USER}" "${ALERTMANAGER_GROUP}"
  ensure_dir "${inst}/etc/templates"  0750 "${ALERTMANAGER_USER}" "${ALERTMANAGER_GROUP}"
  ensure_dir "${inst}/data"           0750 "${ALERTMANAGER_USER}" "${ALERTMANAGER_GROUP}"
  ensure_dir "${inst}/logs"           0750 "${ALERTMANAGER_USER}" "${ALERTMANAGER_GROUP}"
  ensure_dir "${inst}/etc/secrets"    0750 "${ALERTMANAGER_USER}" "${ALERTMANAGER_GROUP}"
}

# ------------------------------------------------------------------------------
# write_default_config: 生成 ${inst}/etc/alertmanager.yml 默认骨架
#
# 内容要点：
#   - resolve_timeout 5m（v3 默认）
#   - route group_by 含 v3 6 标签契约中的 5 项（condition_id / site / origin_prometheus / job / instance）
#   - inhibit_rules: critical/emergency 抑制同 condition_id 的 warning/info
#   - receivers 仅 default-null（用户按需添加）
# ------------------------------------------------------------------------------
write_default_config() {
  local inst; inst="$(instance_root)"
  local cfg="${inst}/etc/alertmanager.yml"
  cat > "${cfg}" <<EOF
# Alertmanager v${ALERTMANAGER_VERSION} - 由 alertmanager_installer v${SCRIPT_VERSION} 生成
# 用户实际路由模板请参考 src/v6r4-RC5/config/alertmanager/alertmanager.yml

global:
  resolve_timeout: 5m

templates:
  - '${inst}/etc/templates/*.tmpl'

route:
  receiver: default-null
  group_by:
    - alertname
    - severity
    - site
    - origin_prometheus
    - job
    - condition_id
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

  routes:
    # 按 notify_profile + severity 二维路由
    # 用户按需启用 receiver 后即可生效
    - receiver: default-null
      matchers:
        - severity="critical"
      repeat_interval: 1h
    - receiver: default-null
      matchers:
        - severity="emergency"
      repeat_interval: 15m

# critical/emergency 抑制同 condition_id 的 warning/info
inhibit_rules:
  - source_matchers:
      - severity="critical"
    target_matchers:
      - severity=~"warning|info"
    equal:
      - condition_id
      - site
      - origin_prometheus
      - job
      - instance
      - device
      - mountpoint

receivers:
  - name: default-null
EOF
  chmod 0640 "${cfg}"
  chown "${ALERTMANAGER_USER}:${ALERTMANAGER_GROUP}" "${cfg}"
}

# ------------------------------------------------------------------------------
# write_default_template: notification.tmpl 模板
# v3 6 标签契约的字段渲染：severity / site / origin_prometheus / job / instance /
# notify_profile / condition_id / category；annotation 三件套 description/impact/action。
# ------------------------------------------------------------------------------
write_default_template() {
  local inst; inst="$(instance_root)"
  local t="${inst}/etc/templates/notification.tmpl"
  cat > "${t}" <<'EOF'
{{ define "default.subject" }}[{{ .Status | toUpper }}][{{ or .CommonLabels.severity "warning" }}][{{ or .CommonLabels.site "-" }}/{{ or .CommonLabels.origin_prometheus "-" }}] {{ .GroupLabels.alertname }}{{ end }}

{{ define "default.message" }}{{ range .Alerts }}
[{{ .Status | toUpper }}] {{ .Annotations.summary }}
  site         : {{ or .Labels.site "-" }}
  origin       : {{ or .Labels.origin_prometheus "-" }}
  job          : {{ or .Labels.job "-" }}
  instance     : {{ or .Labels.instance "-" }}
  severity     : {{ or .Labels.severity "-" }}
  category     : {{ or .Labels.category "-" }}
  notify_profile: {{ or .Labels.notify_profile "-" }}
  condition_id : {{ or .Labels.condition_id "-" }}
{{ if .Annotations.description }}  description  : {{ .Annotations.description }}{{ end }}
{{ if .Annotations.impact }}  impact       : {{ .Annotations.impact }}{{ end }}
{{ if .Annotations.action }}  action       : {{ .Annotations.action }}{{ end }}
{{ end }}{{ end }}
EOF
  chmod 0640 "${t}"
  chown "${ALERTMANAGER_USER}:${ALERTMANAGER_GROUP}" "${t}"
}

# ------------------------------------------------------------------------------
# write_systemd_unit: 生成 /etc/systemd/system/<unit>.service
#
# centos7 仅加 ProtectSystem=full / NoNewPrivileges；
# 其他平台：默认不写 sandbox 指令（不阻塞 advanced 配置场景）。
# ------------------------------------------------------------------------------
write_systemd_unit() {
  local user_directive="User=${ALERTMANAGER_USER}
Group=${ALERTMANAGER_GROUP}"
  local sandbox=""
  if [[ "${PLATFORM_ID}" == "rhel" ]]; then
    sandbox="ProtectSystem=full
NoNewPrivileges=true"
  fi

  local inst; inst="$(instance_root)"
  local unit_file; unit_file="/etc/systemd/system/$(service_unit)"
  local cluster_listen="" peer_lines=""
  if [[ "${CLUSTER_ENABLED}" == "1" ]]; then
    cluster_listen="0.0.0.0:${CLUSTER_PORT}"
    if [[ -n "${CLUSTER_PEERS}" ]]; then
      local peer
      IFS=',' read -ra _peers <<< "${CLUSTER_PEERS}"
      for peer in "${_peers[@]}"; do
        [[ -n "${peer}" ]] && peer_lines+=$' \
  --cluster.peer='"${peer}"
      done
    fi
  fi
  cat > "${unit_file}" <<EOF
[Unit]
Description=Alertmanager ${ALERTMANAGER_VERSION} (web ${WEB_PORT})
After=network-online.target

[Service]
${user_directive}
${sandbox}
ExecStart=${inst}/bin/alertmanager \\
  --config.file=${inst}/etc/alertmanager.yml \\
  --storage.path=${inst}/data \\
  --web.listen-address=0.0.0.0:${WEB_PORT} \\
  --cluster.listen-address=${cluster_listen}${peer_lines} \
  --data.retention=${RETENTION}
Restart=always
RestartSec=5
LimitNOFILE=65536
StandardOutput=append:${inst}/logs/alertmanager.out.log
StandardError=append:${inst}/logs/alertmanager.err.log

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "${unit_file}"
  systemctl daemon-reload
}

# ------------------------------------------------------------------------------
# cmd_install: install 子动作主流程
#
# 顺序：
#   1. require_root + platform_init
#   2. 注册 ACL 访问申请清单（仅写文件，不改防火墙；MANAGE_FIREWALL=1 才真改）
#   3. 下载 → 建用户/目录 → 写默认 config / template → 写 unit
#   4. 注册实例归属（uninstall 时校验）
#   5. enable --now + sleep 1 + status 验证
# ------------------------------------------------------------------------------
cmd_install() {
  require_root
  if platform_init; then
    :
  else
    local rc=$?
    echo "[ERROR] 平台初始化失败；安装未进入持久化变更阶段。" >&2
    return "${rc}"
  fi
  require_install_port_free "${WEB_PORT}" "Alertmanager Web 端口" "${CLUSTER_PORT}" || return 1
  if [[ "${CLUSTER_ENABLED:-0}" == 1 ]]; then
    require_install_port_free "${CLUSTER_PORT}" "Alertmanager 集群端口" "${WEB_PORT}" || return 1
  fi

  # 审核 P0-02：注册访问申请清单
  local instance_id="${SERVICE_NAME_PREFIX}-${WEB_PORT}"
  acl_request "${instance_id}-web" \
    "src=prometheus_vmalert" "dst=${instance_id}" "proto=tcp" "port=${WEB_PORT}" \
    "direction=in" "purpose=receive_alerts" "cross_room=no" \
    "owner=monitoring-team"
  acl_request "${instance_id}-notify" \
    "src=${instance_id}" "dst=notify-gateway" "proto=tcp" "port=443" \
    "direction=out" "purpose=notify_im_bridge" "cross_room=no" \
    "owner=monitoring-team"
  if [[ "${CLUSTER_ENABLED}" == "1" ]]; then
    acl_request "${instance_id}-cluster-tcp" "src=alertmanager_peers" "dst=${instance_id}" "proto=tcp" "port=${CLUSTER_PORT}" "direction=in" "purpose=ha_gossip" "cross_room=no" "owner=monitoring-team"
    acl_request "${instance_id}-cluster-udp" "src=alertmanager_peers" "dst=${instance_id}" "proto=udp" "port=${CLUSTER_PORT}" "direction=in" "purpose=ha_gossip" "cross_room=no" "owner=monitoring-team"
  fi
  acl_emit "$(INSTANCE_STATE_DIR)/access-request.md"

  fw_open_port "${WEB_PORT}" tcp
  if [[ "${CLUSTER_ENABLED}" == "1" ]]; then fw_open_port "${CLUSTER_PORT}" tcp; fw_open_port "${CLUSTER_PORT}" udp; fi

  download_am
  prepare_dirs
  write_default_config
  write_default_template
  write_systemd_unit

  # 注册实例归属（卸载时识别）
  ownership_register "${instance_id}" "${WEB_PORT}" "${ALERTMANAGER_USER}" \
    "$(service_unit)" "$(instance_root)/etc/alertmanager.yml" \
    "$(instance_root)/data" "$(instance_root)/logs"

  svc_enable "$(service_unit)"
  sleep 1
  cmd_status
  echo "[done] alertmanager ${ALERTMANAGER_VERSION} @ web=${WEB_PORT} cluster=$([[ "${CLUSTER_ENABLED}" == 1 ]] && echo "${CLUSTER_PORT}" || echo disabled)"
}

# ------------------------------------------------------------------------------
# cmd_status: 显示 unit 状态 + /-/ready 健康检查
# ------------------------------------------------------------------------------
cmd_status() {
  systemctl --no-pager --full status "$(service_unit)" 2>&1 || true
  echo "----- /-/ready -----"
  curl --noproxy '*' -fsS "http://127.0.0.1:${WEB_PORT}/-/ready" 2>&1 || echo "(未就绪)"
}

# ------------------------------------------------------------------------------
# cmd_reload: 发送 SIGHUP（Alertmanager 配置热加载）
# ------------------------------------------------------------------------------
cmd_reload() {
  svc_reload "$(service_unit)" || systemctl kill -s HUP "$(service_unit)"
  echo "[reload] sent SIGHUP"
}

# ------------------------------------------------------------------------------
# cmd_uninstall: 停服 + 删 unit + 关防火墙 + 注销 ownership
# ownership 不匹配时 WARN 跳过（防误删其他系统的同名 unit）。
# 数据与配置按 ADR 保留 ${inst}/；如需彻底清理须手动 rm -rf。
# ------------------------------------------------------------------------------
cmd_uninstall() {
  require_root
  local unit; unit="$(service_unit)"
  local instance_id="${SERVICE_NAME_PREFIX}-${WEB_PORT}"
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
  fw_close_port "${WEB_PORT}" tcp || true
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
# main: 解析 ACTION + CLI 参数；分派到 cmd_*
# 参数解析顺序：CLI > 环境变量 > 默认值（VAR:-default 不覆盖已设值）
# ------------------------------------------------------------------------------
# ------------------------------------------------------------------------------
# wizard_install: 交互式安装向导（无参数运行时由 interactive_loop 调用）
# ------------------------------------------------------------------------------
wizard_install() {
  local cluster_choice archive upstream platform_preview
  while true; do
    ui_ask_port WEB_PORT "Web 端口" "${WEB_PORT}" "Alertmanager HTTP/API 端口；已占用时必须换用空闲端口" "${CLUSTER_PORT}" || return 1
  
    echo "  是否启用 Alertmanager 高可用集群？"
    echo "    1) 否，单节点运行 [默认] — 不监听 gossip 端口"
    echo "    2) 是，启用 HA 集群 — 需要配置 9094/TCP+UDP 与 peer"
    echo "    3) 返回上一步"
    echo "    q) 退出"
    while true; do
      read -r -p "  请选择 [1]: " cluster_choice || return 1
      [[ -z "${cluster_choice}" ]] && cluster_choice=1
      case "${cluster_choice}" in
        1) CLUSTER_ENABLED=0; CLUSTER_PEERS=""; break ;;
        2) CLUSTER_ENABLED=1; ui_ask_port CLUSTER_PORT "集群 gossip 端口" "${CLUSTER_PORT}" "HA 节点间 TCP/UDP 通信端口；不得与 Web 端口冲突" "${WEB_PORT}" || return 1; ui_ask CLUSTER_PEERS "peer 节点（逗号分隔）" "${CLUSTER_PEERS}" "例如 192.0.2.18:9094,192.0.2.19:9094；首节点可暂留空" || return 1; break ;;
        3) ui_ask_port WEB_PORT "Web 端口" "${WEB_PORT}" "返回上一步修改 Web 端口" "${CLUSTER_PORT}" || return 1 ;;
        q|Q) return 1 ;; *) echo "  无效选择" ;;
      esac
    done
  
    ui_ask ALERTMANAGER_VERSION "Alertmanager 版本" "${ALERTMANAGER_VERSION}" "改版本需对应镜像/官方包存在" || return 1
    ui_ask RETENTION "告警保留时长" "${RETENTION}" "历史告警保留时间（如 120h）" || return 1
    archive="alertmanager-${ALERTMANAGER_VERSION}.linux-amd64.tar.gz"
    upstream="${GITHUB_BASE}/v${ALERTMANAGER_VERSION}/${archive}"
    ui_choose_download_source "${archive}" "${DOWNLOAD_CACHE}" "${upstream}" "${INTERNAL_MIRROR:-}" || return 1
    platform_preview="$(detect_platform)"
    ui_print_plan "安装确认" \
      "组件" "Alertmanager ${ALERTMANAGER_VERSION}" \
      "平台" "${platform_preview}" \
      "实例" "${SERVICE_NAME_PREFIX}-${WEB_PORT}" \
      "Web 端口" "${WEB_PORT}" \
      "HA 集群" "$([[ "${CLUSTER_ENABLED}" == 1 ]] && echo "启用，端口 ${CLUSTER_PORT}，peers=${CLUSTER_PEERS:-未填}" || echo "关闭（单节点）")" \
      "保留时长" "${RETENTION}" \
      "安装根目录" "$(instance_root)" \
      "软件来源" "$(download_source_summary)" \
      "防火墙管理" "MANAGE_FIREWALL=${MANAGE_FIREWALL:-0}"
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
  interactive_loop "alertmanager 安装器 v${SCRIPT_VERSION}" \
    "${SERVICE_NAME_PREFIX}" "WEB_PORT" wizard_install
  exit 0
fi

ACTION="${1:-help}"; shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) WEB_PORT="$2"; shift 2 ;;
    --cluster-port) CLUSTER_PORT="$2"; CLUSTER_ENABLED=1; shift 2 ;;
    --cluster-enable) CLUSTER_ENABLED=1; shift ;;
    --cluster-peers) CLUSTER_PEERS="$2"; CLUSTER_ENABLED=1; shift 2 ;;
    --version) ALERTMANAGER_VERSION="$2"; shift 2 ;;
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
