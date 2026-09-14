#!/usr/bin/env bash
# ==============================================================================
# grafana_installer_v1.0.0.sh
#
# Grafana v3 系列二进制安装器（Standalone Linux Binaries）
#
# ------------------------------------------------------------------------------
# 模块概述
# ------------------------------------------------------------------------------
# 职责：
#   - 下载 Grafana standalone Linux binaries tar.gz
#   - 解压到 /usr/local/grafana/grafana-${PORT}/
#   - 生成 grafana.ini + provisioning + admin secret
#   - 写 systemd unit grafana-${PORT}.service
#   - 支持内网镜像（INTERNAL_MIRROR）fallback 上游 dl.grafana.com
#
# 关键设计：
#   - 二进制：/usr/local/grafana/grafana-${PORT}/bin/grafana
#   - 配置：  /usr/local/grafana/grafana-${PORT}/etc/grafana.ini
#   - 密码：  /usr/local/grafana/grafana-${PORT}/etc/secret_admin_password
#   - 数据：  /usr/local/grafana/grafana-${PORT}/data
#   - 日志：  /usr/local/grafana/grafana-${PORT}/logs
#   - 前端：  /usr/local/grafana/grafana-${PORT}/public
#   - 供应：  /usr/local/grafana/grafana-${PORT}/provisioning
#
# 关联 ADR / 审核:
#   - ADR-10 路径命名规范
#   - 03 §3.6.2 reload 实际为 restart（Grafana 不支持 reload）
# ==============================================================================

set -euo pipefail

SCRIPT_VERSION="1.0.0"
DEFAULT_VERSION="13.2.1"
DEFAULT_BUILD_ID="33191028959"
GF_USER="${GF_USER:-grafana}"
GF_GROUP="${GF_GROUP:-grafana}"
DEFAULT_PORT=3000
SERVICE_NAME_PREFIX="grafana"
INSTALL_ROOT="${INSTALL_ROOT:-/usr/local/grafana}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common/platform.sh"
export INST_ROOT="${INST_ROOT:-${INSTALL_ROOT}}"

GRAFANA_VERSION="${GRAFANA_VERSION:-${DEFAULT_VERSION}}"
GRAFANA_BUILD_ID="${GRAFANA_BUILD_ID:-${DEFAULT_BUILD_ID}}"
# v3.0.0-rc4: 旧 GF_* 前缀保留为兼容垫片；新名 GRAFANA_* 优先
[[ -n "${GF_USER:-}"    && -z "${GRAFANA_USER:-}"    ]] && GRAFANA_USER="${GF_USER}"
[[ -n "${GF_GROUP:-}"   && -z "${GRAFANA_GROUP:-}"   ]] && GRAFANA_GROUP="${GF_GROUP}"
[[ -n "${GF_VERSION:-}" && -z "${GRAFANA_VERSION:-}" ]] && GRAFANA_VERSION="${GF_VERSION}"
# 默认值
GRAFANA_USER="${GRAFANA_USER:-grafana}"
GRAFANA_GROUP="${GRAFANA_GROUP:-grafana}"
PORT="${PORT:-${DEFAULT_PORT}}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
PROM_URL="${PROM_URL:-http://127.0.0.1:9090}"

usage() {
  cat <<EOF
grafana_installer v${SCRIPT_VERSION}

用法:
  $0 install [--version ${DEFAULT_VERSION}] [--build-id ${DEFAULT_BUILD_ID}] [--port 3000] \
             [--admin-password <pwd>] [--prom-url http://127.0.0.1:9090]
  $0 status
  $0 reload           # Grafana 不支持 reload，触发 restart
  $0 uninstall
EOF
}

instance_root() { echo "${INSTALL_ROOT}/${SERVICE_NAME_PREFIX}-${PORT}"; }
service_unit() { echo "${SERVICE_NAME_PREFIX}-${PORT}.service"; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then echo "必须以 root 运行" >&2; exit 1; fi
}

# ------------------------------------------------------------------------------
# ensure_password: 确保 ADMIN_PASSWORD 长度 ≥ 12；缺省自动生成 16 位 base64 串
# 输出：admin 密码写入 ${inst}/etc/secret_admin_password（0640）
# ------------------------------------------------------------------------------
ensure_password() {
  local inst; inst="$(instance_root)"
  if [[ -z "${ADMIN_PASSWORD}" ]]; then
    ADMIN_PASSWORD="$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)"
    echo "[init] admin 密码已自动生成（见 ${inst}/etc/secret_admin_password）"
  fi
  if (( ${#ADMIN_PASSWORD} < 12 )); then
    echo "admin 密码至少 12 字符" >&2; exit 1
  fi
}

# ------------------------------------------------------------------------------
# download_grafana: 下载 standalone binaries tar.gz
# 内网镜像优先：${INTERNAL_MIRROR}/grafana_${VERSION}_${BUILD}_linux_amd64.tar.gz
# 上游官方源：dl.grafana.com/grafana/release/${VERSION}/grafana_${VERSION}_${BUILD}_linux_amd64.tar.gz
# ------------------------------------------------------------------------------
download_grafana() {
  local archive="grafana_${GRAFANA_VERSION}_${GRAFANA_BUILD_ID}_linux_amd64.tar.gz"
  local cache="${DOWNLOAD_CACHE:-${INSTALL_ROOT}/cache}"
  mkdir -p "${cache}"
  local dst="${cache}/${archive}"
  local url
  if [[ -n "${INTERNAL_MIRROR:-}" ]]; then
    url="${INTERNAL_MIRROR}/${archive}"
  else
    url="https://dl.grafana.com/grafana/release/${GRAFANA_VERSION}/grafana_${GRAFANA_VERSION}_${GRAFANA_BUILD_ID}_linux_amd64.tar.gz"
  fi
  if [[ ! -s "${dst}" || "${DOWNLOAD_SOURCE_MODE:-auto}" =~ ^(internal|internet|url|file)$ ]]; then
    echo "[download] 准备获取: ${archive}" >&2
    download "${url}" "${dst}" || { echo "下载失败" >&2; exit 2; }
  fi
  # Grafana 官方对默认固定版本提供 SHA256；对该版本无论缓存/镜像/公网均做完整性校验。
  # 其他自定义版本必须由部署方自行核对官方 SHA256，不在脚本内臆测。
  if [[ "${GRAFANA_VERSION}" == "13.2.1" && "${GRAFANA_BUILD_ID}" == "33191028959" ]]; then
    local expected_sha256="849b3f17a0a318a2f1a681b663e9feb4e4fc7f70d43bb0b4ea07cd34b1987462"
    sha256_check "${dst}" "${expected_sha256}" || {
      echo "[download] SHA256 校验失败，拒绝使用: ${dst}" >&2
      rm -f "${dst}" 2>/dev/null || true
      exit 2
    }
    echo "[download] SHA256 校验通过" >&2
  fi
  echo "[download] 归档位于 ${dst}" >&2
  echo "${dst}"
}

# ------------------------------------------------------------------------------
# install_grafana_binary: 二进制部署主流程
# ------------------------------------------------------------------------------
install_grafana_binary() {
  local inst; inst="$(instance_root)"
  local tar_path; tar_path="$(download_grafana)"
  local tmp; tmp="$(mktemp -d)"
  archive_extract "${tar_path}" "${tmp}"

  # tar 顶层目录名：grafana-${VERSION}/
  local src_dir; src_dir="${tmp}/grafana-${GRAFANA_VERSION}"
  if [[ ! -d "${src_dir}" ]]; then
    echo "[FAIL] 解压后顶层目录不是 grafana-${GRAFANA_VERSION}: ${src_dir}" >&2
    exit 2
  fi

  # 创建实例目录
  ensure_dir "${inst}/bin" 0755 "${GRAFANA_USER}" "${GRAFANA_GROUP}"
  ensure_dir "${inst}/conf" 0755 "${GRAFANA_USER}" "${GRAFANA_GROUP}"
  ensure_dir "${inst}/etc" 0750 "${GRAFANA_USER}" "${GRAFANA_GROUP}"
  ensure_dir "${inst}/data" 0750 "${GRAFANA_USER}" "${GRAFANA_GROUP}"
  ensure_dir "${inst}/data/dashboards" 0750 "${GRAFANA_USER}" "${GRAFANA_GROUP}"
  ensure_dir "${inst}/logs" 0750 "${GRAFANA_USER}" "${GRAFANA_GROUP}"
  ensure_dir "${inst}/public" 0755 "${GRAFANA_USER}" "${GRAFANA_GROUP}"
  ensure_dir "${inst}/provisioning/datasources" 0755 "${GRAFANA_USER}" "${GRAFANA_GROUP}"
  ensure_dir "${inst}/provisioning/dashboards" 0755 "${GRAFANA_USER}" "${GRAFANA_GROUP}"
  ensure_dir "${inst}/provisioning/alerting" 0755 "${GRAFANA_USER}" "${GRAFANA_GROUP}"

  # 复制二进制、前端、默认配置（conf/ 必须位于 homepath 下供 grafana 加载 defaults.ini）
  cp -r "${src_dir}/bin/grafana" "${inst}/bin/"
  cp -r "${src_dir}/public/"* "${inst}/public/"
  cp -r "${src_dir}/conf/"* "${inst}/conf/"
  chmod -R 0755 "${inst}/bin" "${inst}/public" "${inst}/conf"
  chown -R "${GRAFANA_USER}:${GRAFANA_GROUP}" "${inst}"
  rm -rf "${tmp}"
}

# ------------------------------------------------------------------------------
# write_systemd_unit: 写 grafana-${PORT}.service
# ------------------------------------------------------------------------------
write_systemd_unit() {
  local inst; inst="$(instance_root)"
  local unit_file; unit_file="/etc/systemd/system/$(service_unit)"
  cat > "${unit_file}" <<EOF
[Unit]
Description=Grafana ${GRAFANA_VERSION} (port ${PORT})
Documentation=https://grafana.com/docs/grafana/latest/
After=network-online.target

[Service]
User=${GRAFANA_USER}
Group=${GRAFANA_GROUP}
Type=simple
Restart=always
RestartSec=5
WorkingDirectory=${inst}
ExecStart=${inst}/bin/grafana server \\
  --homepath=${inst} \\
  --config=${inst}/etc/grafana.ini
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "${unit_file}"
  systemctl daemon-reload
}

# ------------------------------------------------------------------------------
# write_provisioning: 写 datasources / dashboards provisioning 文件
# ------------------------------------------------------------------------------
write_provisioning() {
  local inst; inst="$(instance_root)"
  cat > "${inst}/provisioning/datasources/prometheus.yml" <<EOF
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: ${PROM_URL}
    isDefault: true
    editable: false
    jsonData:
      timeInterval: 30s
      httpMethod: POST
EOF

  cat > "${inst}/provisioning/dashboards/cluster.yml" <<EOF
apiVersion: 1
providers:
  - name: 'cluster-overview'
    orgId: 1
    folder: 'Prometheus'
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options:
      path: ${inst}/data/dashboards
EOF
}

# ------------------------------------------------------------------------------
# write_grafana_ini: 写主配置 + 落 admin 密码到独立 secret 文件
# ------------------------------------------------------------------------------
write_grafana_ini() {
  local inst; inst="$(instance_root)"
  local secret_file="${inst}/etc/secret_admin_password"
  echo -n "${ADMIN_PASSWORD}" > "${secret_file}"
  chmod 0640 "${secret_file}"
  chown "${GRAFANA_USER}:${GRAFANA_GROUP}" "${secret_file}"

  cat > "${inst}/etc/grafana.ini" <<EOF
[paths]
data = ${inst}/data
logs = ${inst}/logs
plugins = ${inst}/data/plugins
provisioning = ${inst}/provisioning

[server]
http_port = ${PORT}

[security]
admin_user = admin
admin_password = ${ADMIN_PASSWORD}

[users]
allow_sign_up = false

[analytics]
reporting_enabled = false

[log]
level = info
EOF
  chmod 0640 "${inst}/etc/grafana.ini"
  chown "${GRAFANA_USER}:${GRAFANA_GROUP}" "${inst}/etc/grafana.ini"
}

# ------------------------------------------------------------------------------
# cmd_install: 入口主流程
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
  require_install_port_free "${PORT}" "Grafana Web 端口" || return 1
  sys_user_add "${GRAFANA_USER}" "${GRAFANA_GROUP}"
  echo "[init] $(platform_summary)"

  local instance_id="${SERVICE_NAME_PREFIX}-${PORT}"
  acl_request "${instance_id}-web" \
    "src=users_browsers" "dst=${instance_id}" "proto=tcp" "port=${PORT}" \
    "direction=in" "purpose=dashboard_ui" "cross_room=yes" \
    "owner=monitoring-team"
  acl_request "${instance_id}-datasource" \
    "src=${instance_id}" "dst=vm_or_vmauth" "proto=tcp" "port=8428" \
    "direction=out" "purpose=datasource_query" "cross_room=no" \
    "owner=monitoring-team"
  acl_emit "$(instance_root)/state/access-request.md"

  ensure_password
  fw_open_port "${PORT}" tcp

  install_grafana_binary
  write_grafana_ini
  write_provisioning
  write_systemd_unit

  ownership_register "${instance_id}" "${PORT}" "grafana" \
    "$(service_unit)" "$(instance_root)/etc" \
    "$(instance_root)/data" "$(instance_root)/logs"

  svc_enable "$(service_unit)"
  systemctl restart "$(service_unit)"
  # v3.0.0-rc4 上线门禁 BLOCKER-3（2026-09-10）：
  #   install 路径必须等待 /api/health=200；超时非零退出。
  #   避免 migration 期间打印 [done] 又未真正可用。
  wait_for_grafana_ready || return 1
  echo "[done] grafana ${GRAFANA_VERSION} @ ${PORT}, admin password 位于 $(instance_root)/etc/secret_admin_password"
}

cmd_status() {
  systemctl --no-pager --full status "$(service_unit)" 2>&1 || true
  echo "----- /api/health -----"
  # v3.0.0-rc4 上线门禁 BLOCKER-3（2026-09-10）：
  #   明确区分"服务进程"与"健康接口"；HTTP 000/503 一律视作未就绪。
  # v3.0.0-rc4 上线门禁 TASK-2（2026-09-10）：
  #   status curl 必须带 --connect-timeout / --max-time，避免后续阻塞。
  local code
  code="$(curl --noproxy '*' \
    --connect-timeout "${STATUS_CURL_CONNECT_TIMEOUT:-2}" \
    --max-time "${STATUS_CURL_MAX_TIMEOUT:-5}" \
    -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/api/health" 2>/dev/null)"
  [[ -z "${code}" ]] && code=000
  if [[ "${code}" == "200" ]]; then
    echo "ready (200)"
  else
    echo "(未就绪 HTTP=${code})"
  fi
}

# wait_for_grafana_ready: 等待 /api/health 返回 200，超时返回非零
# v3.0.0-rc4 上线门禁 TASK-2（2026-09-10 + 2026-09-11 二次加固）：
#   1. curl 必须带 --connect-timeout 与 --max-time，避免单次请求永久阻塞。
#   2. 总截止按"实际经过时间"判定，而非迭代次数；
#      旧实现 30 次 sleep 1 + 30 次 curl，真实上限可能 30s + 30*max_time，
#      且 wait_for_grafana_ready 与 cmd_reload 共用，必须口径统一。
#   3. 失败时仅打印到 stderr，函数返回 1；阻断 [done] 与 [reload] 成功输出。
#   4. 不得依赖外部 timeout 124 作为"已超时"证据——失败是 installer 自身的非零退出。
# 2026-09-11 复核发现的 stale-elapsed bug（v6r 包）：同 prometheus 函数。
#   修复（v6r2）：curl 前用剩余时间限制 --max-time；curl 后重算 elapsed，
#   仅当 code=200 且 elapsed_after < deadline 时 return 0。
# 2026-09-11 v6r3 第三次复核（同 prometheus v6r3）：
#   1. 计时改 `date +%s%N` / monotonic clock（/proc/uptime），统一 ms 精度；
#      stdout "after Xs" 允许 0.1s 小数。
#   2. 单次 curl --max-time = min(remaining_ms/1000, max_to)，允许小数；
#      不强制最小 1s、不因剩余 < 500ms 提前失败；剩余 0 时直接判 FAIL。
#   3. 第一轮立即发起请求；失败后重试间隔 = min(200ms, 剩余 ms)，不引入可配置项。
#   4. 每次请求返回后重算 elapsed；只有 elapsed_ms < deadline_ms 且 code=200 才成功。
wait_for_grafana_ready() {
  local url code deadline deadline_ms start_ms elapsed_ms remaining_ms conn_to max_to max_to_ms curl_max_now curl_max_now_ms sleep_ms
  url="http://127.0.0.1:${PORT}/api/health"
  deadline="${WAIT_GRAFANA_READY_TIMEOUT:-30}"
  deadline_ms=$(( deadline * 1000 ))
  conn_to="${WAIT_CURL_CONNECT_TIMEOUT:-2}"
  max_to="${WAIT_CURL_MAX_TIMEOUT:-5}"
  max_to_ms=$(( max_to * 1000 ))
  # v6r3 复核修正：awk 直接读第一字段（秒.小数）乘 1000 转 ms，避免 split 换算误差。
  if [[ -r /proc/uptime ]]; then
    _now_ms() { LC_ALL=C awk '{printf "%.0f\n", $1 * 1000}' /proc/uptime; }
  else
    _now_ms() { echo $(( $(date +%s%N) / 1000000 )); }
  fi
  start_ms="$(_now_ms)"
  while true; do
    elapsed_ms=$(( $(_now_ms) - start_ms ))
    if [[ "${elapsed_ms}" -ge "${deadline_ms}" ]]; then
      echo "[ready] FAIL: /api/health 未在 ${deadline}s 内返回 200（last_code=${code:-000}，实际耗时 $(awk -v ms="${elapsed_ms}" 'BEGIN{printf "%.1f", ms/1000}')s）" >&2
      return 1
    fi
    remaining_ms=$(( deadline_ms - elapsed_ms ))
    curl_max_now_ms="${remaining_ms}"
    [[ "${curl_max_now_ms}" -gt "${max_to_ms}" ]] && curl_max_now_ms="${max_to_ms}"
    curl_max_now="$(awk -v ms="${curl_max_now_ms}" 'BEGIN{printf "%.3f", ms/1000}')"
    code="$(curl --noproxy '*' \
      --connect-timeout "${conn_to}" --max-time "${curl_max_now}" \
      -s -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null)"
    [[ -z "${code}" ]] && code=000
    elapsed_ms=$(( $(_now_ms) - start_ms ))
    if [[ "${code}" == "200" && "${elapsed_ms}" -lt "${deadline_ms}" ]]; then
      echo "[ready] /api/health=200 after $(awk -v ms="${elapsed_ms}" 'BEGIN{printf "%.1f", ms/1000}')s"
      return 0
    fi
    if [[ "${elapsed_ms}" -ge "${deadline_ms}" ]]; then
      echo "[ready] FAIL: /api/health 未在 ${deadline}s 内返回 200（last_code=${code:-000}，实际耗时 $(awk -v ms="${elapsed_ms}" 'BEGIN{printf "%.1f", ms/1000}')s）" >&2
      return 1
    fi
    # 重新计算 remaining_ms，sleep = min(200ms, remaining_ms)
    remaining_ms=$(( deadline_ms - elapsed_ms ))
    sleep_ms="${remaining_ms}"
    [[ "${sleep_ms}" -gt 200 ]] && sleep_ms=200
    awk -v ms="${sleep_ms}" 'BEGIN{printf "%.3f", ms/1000}' | xargs sleep
  done
}

# ------------------------------------------------------------------------------
# cmd_reload: Grafana 不支持 SIGHUP；走 restart
#
# v3.0.0-rc4 上线门禁 P1-1（2026-09-10）：
#   - 记录重启前 MainPID
#   - systemctl restart 后再次读取 MainPID 必须变更
#   - 循环等待 /api/health 直至 HTTP=200；超时返回非零
# ------------------------------------------------------------------------------
cmd_reload() {
  local unit; unit="$(service_unit)"
  local pid_before
  pid_before="$(systemctl --no-pager show -p MainPID --value "${unit}" 2>/dev/null || echo 0)"
  systemctl restart "${unit}"
  local pid_after
  pid_after="$(systemctl --no-pager show -p MainPID --value "${unit}" 2>/dev/null || echo 0)"
  echo "[reload] grafana-${PORT} restart (pid_before=${pid_before} pid_after=${pid_after})"
  if wait_for_grafana_ready; then
    echo "[reload] /api/health=200 (pid_before=${pid_before} pid_after=${pid_after})"
    return 0
  fi
  return 1
}

cmd_uninstall() {
  require_root
  local unit; unit="$(service_unit)"
  local instance_id="${SERVICE_NAME_PREFIX}-${PORT}"
  local inst; inst="$(instance_root)"
  if ownership_belongs_to "/etc/systemd/system/${unit}" "${instance_id}"; then
    if systemctl list-unit-files "${unit}" >/dev/null 2>&1; then
      svc_disable "${unit}" || true
      rm -f "/etc/systemd/system/${unit}"
    fi
    systemctl daemon-reload
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
# wizard_install: 交互式安装向导
# ------------------------------------------------------------------------------
wizard_install() {
  local archive upstream platform_preview
  while true; do
    ui_ask_port PORT "监听端口" "${PORT}" "Grafana Web UI 端口；端口已占用时必须换用空闲端口" || return 1
    ui_ask GRAFANA_VERSION "Grafana 版本" "${GRAFANA_VERSION}" "二进制 tar.gz 版本号" || return 1
    ui_ask GRAFANA_BUILD_ID "Grafana build id" "${GRAFANA_BUILD_ID}" "Grafana 官方 standalone 包文件名的一部分；版本变化时需同步核对官方 build id" || return 1
    ui_ask PROM_URL "Prometheus 数据源地址" "${PROM_URL}" "provisioning 默认数据源" || return 1
    ui_ask_secret ADMIN_PASSWORD "admin 初始密码" "至少 12 字符；只保存在内存，最终确认后才写文件" || return 1
    archive="grafana_${GRAFANA_VERSION}_${GRAFANA_BUILD_ID}_linux_amd64.tar.gz"
    upstream="https://dl.grafana.com/grafana/release/${GRAFANA_VERSION}/grafana_${GRAFANA_VERSION}_${GRAFANA_BUILD_ID}_linux_amd64.tar.gz"
    ui_choose_download_source "${archive}" "${DOWNLOAD_CACHE:-${INSTALL_ROOT}/cache}" "${upstream}" "${INTERNAL_MIRROR:-}" || return 1
    platform_preview="$(detect_platform)"
    ui_print_plan "安装确认" "组件" "Grafana ${GRAFANA_VERSION}" "平台" "${platform_preview}" "实例" "${SERVICE_NAME_PREFIX}-${PORT}" "Web 端口" "${PORT}" "Prometheus 数据源" "${PROM_URL}" "安装根目录" "$(instance_root)" "软件来源" "$(download_source_summary)" "admin 密码" "已设置（不显示）"
    ui_install_confirm
    case "${UI_INSTALL_ACTION}" in
      install) cmd_install; return $? ;;
      back) echo "[安装向导] 返回重新修改参数"; continue ;;
      cancel) echo "[安装向导] 已取消"; return 0 ;;
      quit) return 1 ;;
    esac
  done
}

# 无参数 → 交互式向导；带参数 → 原 CLI 行为
if [[ -z "${1:-}" ]]; then
  interactive_loop "grafana 安装器 v${SCRIPT_VERSION}" \
    "${SERVICE_NAME_PREFIX}" "PORT" wizard_install
  exit 0
fi

ACTION="${1:-help}"; shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) GRAFANA_VERSION="$2"; shift 2 ;;
    --build-id) GRAFANA_BUILD_ID="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
    --prom-url) PROM_URL="$2"; shift 2 ;;
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
