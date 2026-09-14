#!/usr/bin/env bash
# ==============================================================================
# prometheus_installer_v6.0.0.sh
#
# Prometheus 3.13.2 LTS 跨平台一键安装器 (v3 系列)
#
# ------------------------------------------------------------------------------
# 模块概述
# ------------------------------------------------------------------------------
# 职责：
#   - 下载 release tarball（prometheus + promtool + consoles + console_libraries）
#   - 落地到 ${INSTALL_ROOT}/prometheus-${PORT}/
#   - 生成 prometheus.yml + 渲染 scrape_configs 模板（替换 __PROM_FILE_SD_BASE__）
#   - 可选 basic auth（02 §3.2.1：basic auth first，NO nginx 代理）
#   - 支持 --role edge|center 切换 retention / remote_write 默认值
#
# 关键设计：
#   - 配置目录：${inst}/etc/（ADR-10）
#   - 规则目录：${inst}/etc/rules/
#   - 抓取片段：${inst}/etc/scrape_configs/（PLACEHOLDER 约定）
#   - file_sd：${inst}/etc/targets/（node/snmp/blackbox-*/docker/kubernetes）
#   - 凭据：${inst}/etc/secrets/ + ${inst}/etc/.remote_write_pass（0600）
#
# 关联 ADR / 审核:
#   - ADR-02 site / origin_prometheus / asset_type 标签契约
#   - ADR-08 多实例与旧系统迁移
#   - ADR-10 路径命名规范
#   - 审核 §3.2.1 basic auth first；P0-03 remote_write 凭据建模
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# 常量
# ------------------------------------------------------------------------------
SCRIPT_VERSION="6.0.0"
DEFAULT_PROMETHEUS_VERSION="3.13.2"
INSTALL_ROOT="/usr/local/prometheus"
DEFAULT_PORT=9090
SERVICE_NAME_PREFIX="prometheus"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common/platform.sh"
export INST_ROOT="${INST_ROOT:-${INSTALL_ROOT}}"

# ------------------------------------------------------------------------------
# 环境变量兼容垫片（旧 PROM_* → 新 PROMETHEUS_*）
# ------------------------------------------------------------------------------
PROM_USER="${PROM_USER:-prometheus}"
PROM_GROUP="${PROM_GROUP:-prometheus}"
[[ -n "${PROM_USER:-}"  && -z "${PROMETHEUS_USER:-}"  ]] && PROMETHEUS_USER="${PROM_USER}"
[[ -n "${PROM_GROUP:-}" && -z "${PROMETHEUS_GROUP:-}" ]] && PROMETHEUS_GROUP="${PROM_GROUP}"
PROMETHEUS_USER="${PROMETHEUS_USER:-prometheus}"
PROMETHEUS_GROUP="${PROMETHEUS_GROUP:-prometheus}"
PROMETHEUS_VERSION="${PROMETHEUS_VERSION:-${DEFAULT_PROMETHEUS_VERSION}}"

# ------------------------------------------------------------------------------
# 实例目录与 unit 派生
# ------------------------------------------------------------------------------
instance_root()      { echo "${INSTALL_ROOT}/${SERVICE_NAME_PREFIX}-${PORT}"; }
instance_bin()       { echo "$(instance_root)/bin/prometheus"; }
instance_etc()       { echo "$(instance_root)/etc"; }
instance_data()      { echo "$(instance_root)/data"; }
instance_log()       { echo "$(instance_root)/log"; }   # 注意：日志实目录是 logs/，此函数仅用于 ownership 兼容登记
service_unit()       { echo "${SERVICE_NAME_PREFIX}-${PORT}.service"; }
INSTANCE_STATE_DIR() { echo "${INSTALL_ROOT}/state/${SERVICE_NAME_PREFIX}-${PORT}"; }


# ------------------------------------------------------------------------------
# 帮助
# ------------------------------------------------------------------------------
# usage() 已在前部前向声明
usage() { cat <<EOF
prometheus_installer v${SCRIPT_VERSION}

用法:
  $0 install                          安装并启动 Prometheus
  $0 install --port 9091 --site sk-94 --version 3.13.2
  $0 install --role center            中心端默认 retention 180d/200GB
  $0 install --role edge              边缘端默认 retention 7d/10GB
  $0 install --auth-user admin --auth-pass-file /usr/local/prometheus/secrets/auth.pass   推荐（避免 CLI 明文）
  $0 install --auth-user admin --auth-pass 'P@ssw0rd!'   兼容（旧用法，仍可用）
  $0 install --auth-user admin                     只给用户，密码走 read -s 交互
  $0 status                           查看服务状态
  $0 reload                           发送 SIGHUP 热加载 (不依赖 --web.enable-lifecycle)
  $0 check                            执行 promtool 校验
  $0 uninstall                        停服并卸载

环境变量 (覆盖默认值):
  PROMETHEUS_VERSION  PORT  SITE_NAME  EXTRA_LABELS_ORIGIN
  RETENTION_TIME  RETENTION_SIZE  DOWNLOAD_CACHE  INTERNAL_MIRROR
  ROLE=edge|center
  REMOTE_WRITE_URL / REMOTE_WRITE_BASIC_AUTH_FILE
  WEB_CONFIG_FILE_PATH (默认 \${INSTALL_ROOT}/web_config.yml)
  SCRAPE_CONFIGS_SRC (v3.0.0-rc4: scrape_configs 源目录含 __PROM_FILE_SD_BASE__
                       占位符；默认 ../config/prometheus/scrape_configs)
  ENABLE_BLACKBOX=1 / ENABLE_DOCKER_CADVISOR=1 / ENABLE_KUBERNETES=1 / ENABLE_SNMP=1
                       可选抓取模块（默认不渲染；K8s 模块在非 K8s 主机会报错，切勿默认开）
EOF

}
# CLI 解析（必须在 role/default 之前；CLI > 环境变量 > 默认值）
# ------------------------------------------------------------------------------
# 记录原始参数个数：用于区分"裸跑（进交互向导）"与"只带 flag 无动作（打 usage）"
ORIG_ARGC=$#
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)      PORT="$2"; shift 2 ;;
    --site)      SITE_NAME="$2"; shift 2 ;;
    --origin)    EXTRA_LABELS_ORIGIN="$2"; shift 2 ;;
    --version)   PROMETHEUS_VERSION="$2"; shift 2 ;;
    --mirror)    INTERNAL_MIRROR="$2"; shift 2 ;;
    --role)      ROLE="$2"; shift 2 ;;
    --retention-time) RETENTION_TIME="$2"; shift 2 ;;
    --retention-size) RETENTION_SIZE="$2"; shift 2 ;;
    --remote-write-url) REMOTE_WRITE_URL="$2"; shift 2 ;;
    --remote-write-auth-file) REMOTE_WRITE_BASIC_AUTH_FILE="$2"; shift 2 ;;
    --auth-user) AUTH_USER_OPT="$2"; shift 2 ;;
    --auth-pass) AUTH_PASS_OPT="$2"; shift 2 ;;
    --auth-pass-file) AUTH_PASS_FILE_OPT="$2"; shift 2 ;;
    --web-config-file) WEB_CONFIG_FILE_PATH="$2"; shift 2 ;;
    # v3.0.0-rc4 audit-blocking 修复（B09）：重装语义显式化
    --upgrade-binary)   REINSTALL_MODE="upgrade-binary"; shift ;;
    --reinstall-keep)   REINSTALL_MODE="keep"; shift ;;
    --reinstall-migrate) REINSTALL_MODE="migrate"; shift ;;
    --force)            FORCE_REINSTALL=1; shift ;;
    -h|--help)   (usage) || true; exit 0 ;;
    *)           ARGS+=("$1"); shift ;;
  esac
done
# bash 4.2 (centos7) 在 set -u 下展开空数组 "${ARGS[@]}" 会报 unbound；
# ${ARGS[@]+...} 写法对空数组安全（裸跑进向导正是 ARGS 为空的场景）
set -- ${ARGS[@]+"${ARGS[@]}"}

PORT="${PORT:-${DEFAULT_PORT}}"
SITE_NAME="${SITE_NAME:-primary}"
EXTRA_LABELS_ORIGIN="${EXTRA_LABELS_ORIGIN:-${SERVICE_NAME_PREFIX}-${PORT}}"
# 02 §3.2.1: 边缘/中心 retention 分层 (按 --role 区分)
# CLI 显式值已在上方解析，此处 ${VAR:-default} 不会覆盖 CLI 值
ROLE="${ROLE:-center}"
case "${ROLE}" in center|edge) ;; *) ROLE="center" ;; esac
# center/edge 仅表达拓扑角色；长期数据统一由 VictoriaMetrics 承担，二者均默认短期本地留存。
RETENTION_TIME="${RETENTION_TIME:-7d}"
RETENTION_SIZE="${RETENTION_SIZE:-10GB}"
REMOTE_WRITE_URL="${REMOTE_WRITE_URL:-}"
REMOTE_WRITE_BASIC_AUTH_FILE="${REMOTE_WRITE_BASIC_AUTH_FILE:-}"
DOWNLOAD_CACHE="${DOWNLOAD_CACHE:-${INSTALL_ROOT}/cache}"
INTERNAL_MIRROR="${INTERNAL_MIRROR:-}"   # 形如 https://mirror.example.com/prometheus
GITHUB_BASE="https://github.com/prometheus/prometheus/releases/download"

# v3.0.0-rc4: scrape_configs 源目录 (含 __PROM_FILE_SD_BASE__ 占位符)；
# 默认相对本安装器同仓库 layout。部署到非默认路径时通过此变量覆盖。
SCRAPE_CONFIGS_SRC="${SCRAPE_CONFIGS_SRC:-$(cd "${SCRIPT_DIR}/.." 2>/dev/null && pwd)/config/prometheus/scrape_configs}"

# 02 §3.2.1: --web.config.file basic auth
WEB_CONFIG_FILE_PATH="${WEB_CONFIG_FILE_PATH:-$(instance_root)/etc/web_config.yml}"

# 命令行参数（已在上方解析）
AUTH_USER_OPT="${AUTH_USER_OPT:-}"
AUTH_PASS_OPT="${AUTH_PASS_OPT:-}"
AUTH_PASS_FILE_OPT="${AUTH_PASS_FILE_OPT:-}"
# v3.0.0-rc4 audit-blocking 修复（B09）：重装模式（空 = 默认拒绝覆盖已有实例）
REINSTALL_MODE="${REINSTALL_MODE:-}"
FORCE_REINSTALL="${FORCE_REINSTALL:-0}"

# ------------------------------------------------------------------------------
# wizard_install: 交互式安装向导（裸跑时由 interactive_loop 调用）
# 注意：
#   - WEB_CONFIG_FILE_PATH 顶层默认值按 DEFAULT_PORT 展开；PORT 在向导里变更后
#     必须重新推导，否则 web_config.yml 会落到旧端口实例目录
#   - 密码不在向导里收集：留 AUTH_USER_OPT 后由 cmd_install 的 read -s 兜底提示，
#     避免密码停留在 shell 变量里（02 §17.3）
# ------------------------------------------------------------------------------
wizard_install() {
  local role_choice enable_auth archive upstream platform_preview
  while true; do
    while true; do
      ui_ask_port PORT "监听端口" "${PORT}" "Prometheus HTTP/UI 端口；端口已占用时必须换用空闲端口" || return 1
      ui_ask SITE_NAME "站点名 site" "${SITE_NAME}" "external_labels.site，如 sk-94" || return 1
      echo "  请选择 Prometheus 部署角色："
      echo "    1) 中心节点 center [默认] — 中心监控区主实例，承担主要采集、规则计算和 Grafana 查询"
      echo "    2) 边缘节点 edge — 远端机房/独立网络区域就近采集，通常 remote_write 到中心长期存储"
      echo "    3) 返回上一步"
      echo "    q) 退出"
      read -r -p "  请选择 [1]: " role_choice || return 1
      [[ -z "${role_choice}" ]] && role_choice=1
      case "${role_choice}" in 1) ROLE=center; break ;; 2) ROLE=edge; break ;; 3) continue ;; q|Q) return 1 ;; *) echo "  无效选择" ;; esac
    done
    RETENTION_TIME="${RETENTION_TIME:-7d}"; RETENTION_SIZE="${RETENTION_SIZE:-10GB}"
    ui_ask RETENTION_TIME "本地数据保留时长" "${RETENTION_TIME}" "Prometheus 作为短期实时层，默认 7d；长期数据由 VictoriaMetrics 保存" || return 1
    ui_ask RETENTION_SIZE "本地数据保留容量" "${RETENTION_SIZE}" "默认 10GB；与时长条件先到先删" || return 1
    ui_ask PROMETHEUS_VERSION "Prometheus 版本" "${PROMETHEUS_VERSION}" "改版本需对应镜像/官方包存在" || return 1
    ui_ask REMOTE_WRITE_URL "remote_write 目标地址" "${REMOTE_WRITE_URL}" "留空=不配置；需要长期存储时填写 VictoriaMetrics/vmauth 写入地址" || return 1
    ui_ask enable_auth "启用 Web UI basic auth? (y/n)" "n" "启用后安装流程会单独 read -s 获取密码" || return 1
    if [[ "${enable_auth}" =~ ^[Yy]$ ]]; then ui_ask AUTH_USER_OPT "basic auth 用户名" "admin" "密码稍后不回显输入" || return 1; else AUTH_USER_OPT=""; fi
    WEB_CONFIG_FILE_PATH="$(instance_root)/etc/web_config.yml"
    archive="prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz"
    upstream="${GITHUB_BASE}/v${PROMETHEUS_VERSION}/${archive}"
    ui_choose_download_source "${archive}" "${DOWNLOAD_CACHE}" "${upstream}" "${INTERNAL_MIRROR:-}" || return 1
    platform_preview="$(detect_platform)"
    ui_print_plan "安装确认" \
      "组件" "Prometheus ${PROMETHEUS_VERSION}" "平台" "${platform_preview}" \
      "实例" "${SERVICE_NAME_PREFIX}-${PORT}" "站点 site" "${SITE_NAME}" \
      "部署角色" "${ROLE}" "本地 retention" "${RETENTION_TIME} / ${RETENTION_SIZE}" \
      "remote_write" "${REMOTE_WRITE_URL:-不配置}" "Web basic auth" "$([[ -n "${AUTH_USER_OPT}" ]] && echo "启用(${AUTH_USER_OPT})" || echo "关闭")" \
      "安装根目录" "$(instance_root)" "软件来源" "$(download_source_summary)" \
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

# ------------------------------------------------------------------------------
# 检查 root
# ------------------------------------------------------------------------------
require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "必须以 root 运行" >&2
    exit 1
  fi
}

# ------------------------------------------------------------------------------
# write_web_config: 生成 ${WEB_CONFIG_FILE_PATH}（--web.config.file 引用）
#
# bcrypt cost=10（Apache htpasswd -B 行为）；兜底用 python3 bcrypt。
# 文件权限 0640，属主 ${PROMETHEUS_USER}:${PROMETHEUS_GROUP}。
# 出口：在 ${WEB_CONFIG_FILE_PATH} 写入 basic_auth_users 配置。
#
# v3.0.0-rc4 上线门禁 P0-2（2026-09-10）：
#   按 exporter-toolkit 官方规范，basic_auth_users 顶层值为用户名 → bcrypt 哈希字符串，
#   不支持 password_file 子键。改为哈希直接写入 web_config.yml（受控权限 0640）。
# ------------------------------------------------------------------------------
write_web_config() {
  local user="$1"
  local pass="$2"
  local f="${WEB_CONFIG_FILE_PATH}"
  local inst; inst="$(instance_root)"
  if [[ -z "${f}" ]]; then
    f="${inst}/etc/web_config.yml"
    WEB_CONFIG_FILE_PATH="${f}"
  fi

  # htpasswd -iBC 10 user（-i 从 stdin 读密码，不经 argv）；python3 兜底走 stdin
  local hash_line
  if command -v htpasswd >/dev/null 2>&1; then
    hash_line="$(printf '%s' "${pass}" | htpasswd -niBC 10 "${user}" 2>/dev/null)" || {
      echo "[auth] htpasswd 生成失败" >&2
      return 1
    }
  elif python3 -c "import bcrypt" >/dev/null 2>&1; then
    hash_line="$(printf '%s' "${pass}" | python3 -c '
import sys, bcrypt
user = sys.argv[1]
pw = sys.stdin.read().rstrip("\n")
print(user + ":" + bcrypt.hashpw(pw.encode(), bcrypt.gensalt(rounds=10)).decode())
' "${user}" 2>/dev/null)" || {
      echo "[auth] python3 bcrypt 生成失败" >&2
      return 1
    }
  else
    echo "[auth] 缺少 htpasswd 或 python3 bcrypt，请安装 apache2-utils 或 python3-bcrypt" >&2
    return 1
  fi

  # hash_line 形如 "user:$2y$10$..."；提取 : 后面的 bcrypt 哈希
  local bcrypt_hash="${hash_line#*:}"

  cat > "${f}" <<EOF
# Prometheus web.config.yml - 由 prometheus_installer v${SCRIPT_VERSION} 生成
# 用于 --web.config.file 实现 UI basic auth
# basic_auth_users 按 exporter-toolkit 官方结构：用户名 -> bcrypt 哈希
basic_auth_users:
  '${user}': '${bcrypt_hash}'
EOF
  chmod 0640 "${f}"
  chown "${PROMETHEUS_USER}:${PROMETHEUS_GROUP}" "${f}"
  echo "[auth]  web.config.file=${f} user=${user} bcrypt_hash=${bcrypt_hash:0:7}..."
}

# ------------------------------------------------------------------------------
# download_prometheus: 下载 tarball + 落地 prometheus/promtool + consoles
#
# DOWNLOAD_CACHE 是共享缓存；多实例装同版本时第二次 install 不会重复下载。
# 失败语义：网络错误 exit 2；解压结构异常 exit 3。
# ------------------------------------------------------------------------------
download_prometheus() {
  mkdir -p "${DOWNLOAD_CACHE}"
  local ver="${PROMETHEUS_VERSION}"
  local archive="prometheus-${ver}.linux-amd64.tar.gz"
  local url
  if [[ -n "${INTERNAL_MIRROR}" ]]; then
    url="${INTERNAL_MIRROR}/${archive}"
  else
    url="${GITHUB_BASE}/v${ver}/${archive}"
  fi
  local dst="${DOWNLOAD_CACHE}/${archive}"

  if [[ ! -s "${dst}" || "${DOWNLOAD_SOURCE_MODE:-auto}" =~ ^(internal|internet|url|file)$ ]]; then
    echo "[download] 准备获取: ${archive}"
    download "${url}" "${dst}" || { echo "下载失败: ${archive}" >&2; exit 2; }
  fi
  echo "[verify]   ${dst}"
  sha256_check "${dst}" "${PROMETHEUS_SHA256:-}" || true

  local tmp
  tmp="$(mktemp -d)"
  archive_extract "${dst}" "${tmp}"

  local src_dir="${tmp}/prometheus-${ver}.linux-amd64"
  [[ -d "${src_dir}" ]] || { echo "解压结构异常: ${src_dir}" >&2; exit 3; }

  local inst; inst="$(instance_root)"
  mkdir -p "${inst}/bin" "${inst}/etc/rules" "${inst}/etc/scrape_configs" \
           "${inst}/etc/targets/node" "${inst}/etc/targets/snmp" \
           "${inst}/etc/targets/blackbox-http" "${inst}/etc/targets/blackbox-tcp" \
           "${inst}/etc/targets/blackbox-icmp" "${inst}/etc/targets/docker" \
           "${inst}/etc/targets/kubernetes" \
           "${inst}/etc/secrets" "${inst}/data" "${inst}/logs"

  install -m 0755 "${src_dir}/prometheus"      "${inst}/bin/prometheus"
  install -m 0755 "${src_dir}/promtool"        "${inst}/bin/promtool"
  # Prometheus 3.0 起官方包不再提供 consoles/console_libraries；不再复制，避免 set -e 下 install 失败。
  rm -rf "${tmp}"
}

# ------------------------------------------------------------------------------
# prepare_user_dirs: 建系统用户 + 8 类子目录
# ------------------------------------------------------------------------------
prepare_user_dirs() {
  sys_user_add "${PROMETHEUS_USER}" "${PROMETHEUS_GROUP}"
  local inst; inst="$(instance_root)"
  ensure_dir "${inst}/etc" 0755 "${PROMETHEUS_USER}" "${PROMETHEUS_GROUP}"
  ensure_dir "${inst}/data" 0755 "${PROMETHEUS_USER}" "${PROMETHEUS_GROUP}"
  ensure_dir "${inst}/logs" 0755 "${PROMETHEUS_USER}" "${PROMETHEUS_GROUP}"
  ensure_dir "${inst}/etc/rules" 0750 "${PROMETHEUS_USER}" "${PROMETHEUS_GROUP}"
  ensure_dir "${inst}/etc/scrape_configs" 0750 "${PROMETHEUS_USER}" "${PROMETHEUS_GROUP}"
  ensure_dir "${inst}/etc/targets" 0750 "${PROMETHEUS_USER}" "${PROMETHEUS_GROUP}"
  ensure_dir "${inst}/etc/secrets" 0750 "${PROMETHEUS_USER}" "${PROMETHEUS_GROUP}"
}

# ------------------------------------------------------------------------------
# render_scrape_configs: 把 ${SCRAPE_CONFIGS_SRC}/*.yml 拷到 ${inst}/etc/scrape_configs/
# 同时 sed 替换 __PROM_FILE_SD_BASE__ 为 ${inst}/etc/targets（v3.0.0-rc4 占位符约定）。
#
# 源目录缺失时 WARN 跳过（用户可手动拷贝并自行替换占位符）。
# ------------------------------------------------------------------------------
render_scrape_configs() {
  # v3.0.0-rc4 audit-blocking 修复（B03）：
  #   - 替换变量走白名单（__PROM_FILE_SD_BASE__ + ORIGIN_PROMETHEUS + 监听端口）
  #   - 不用 envsubst 整文件替换，避免 file_sd 标签里的 ${...} 被意外替换或注入
  #   - Prometheus 捕获组语法 ${1} / ${2} 是纯数字，本 sed 不匹配，保持原样
  local inst; inst="$(instance_root)"
  local sd_base="${inst}/etc/targets"
  # 安装期替换用的变量（白名单外的 ${VAR} 一律不替换）
  local origin="${EXTRA_LABELS_ORIGIN:-${SERVICE_NAME_PREFIX}-${PORT}}"
  local ne_port="${NODE_EXPORTER_PORT:-9100}"
  local bb_port="${BLACKBOX_PORT:-9115}"
  if [[ ! -d "${SCRAPE_CONFIGS_SRC}" ]]; then
    # 修复 (A 包 v2026-09-10): 外部 SCRAPE_CONFIGS_SRC 不可用时，回落到本安装器末尾
    # 嵌入的 scrape_configs 模板（__SCRAPE_NODE_EMBED_BEGIN__/END__）。这样单文件
    # 部署（拷贝一个 .sh 就能 install）也能产出 ${inst}/etc/scrape_configs/node.yml，
    # 不再因源码仓库不在邻接目录而留下 0 个 scrape target。
    # 注意：成功后会在函数末尾清理 _prom_embed_tmpdir，避免 /tmp 残留。
    local _prom_embed_tmpdir
    _prom_embed_tmpdir="$(mktemp -d -t scrapes_embed.XXXXXX)"
    if sed -n '/^# __SCRAPE_NODE_EMBED_BEGIN__$/,/^# __SCRAPE_NODE_EMBED_END__$/p' "${BASH_SOURCE[0]}" \
         | sed '1d;$d' > "${_prom_embed_tmpdir}/node.yml" 2>/dev/null \
       && [[ -s "${_prom_embed_tmpdir}/node.yml" ]]; then
      echo "[render_scrape_configs] SCRAPE_CONFIGS_SRC=${SCRAPE_CONFIGS_SRC} 不可用；使用本安装器末尾嵌入块" >&2
      SCRAPE_CONFIGS_SRC="${_prom_embed_tmpdir}"
    else
      rm -rf "${_prom_embed_tmpdir}"
      echo "[render_scrape_configs] WARN: SCRAPE_CONFIGS_SRC=${SCRAPE_CONFIGS_SRC} 不存在，跳过自动渲染" >&2
      echo "[render_scrape_configs] 用户需手动从 src/v6r4-RC6/config/prometheus/scrape_configs/*.yml 拷贝到 ${inst}/etc/scrape_configs/ 并替换占位符" >&2
      return 0
    fi
  fi
  local shopt_globnull_was_set=0
  case "$-" in *f*) shopt_globnull_was_set=1 ;; esac
  shopt -s nullglob
  local f out base gate
  for f in "${SCRAPE_CONFIGS_SRC}"/*.yml; do
    base="$(basename "${f}")"
    # B02 默认禁用模块（对应 ENABLE_*=1 才渲染）：
    # OSS Prometheus 没有 job 级 enabled 字段，"默认禁用"只能在渲染层实现；
    # kubernetes_sd 在非 K8s 主机会持续报错，尤其不能默认加载
    gate=""
    case "${base}" in
      blackbox.yml)        gate="${ENABLE_BLACKBOX:-0}" ;;
      docker_cadvisor.yml) gate="${ENABLE_DOCKER_CADVISOR:-0}" ;;
      kubernetes.yml)      gate="${ENABLE_KUBERNETES:-0}" ;;
      snmp.yml)            gate="${ENABLE_SNMP:-0}" ;;
    esac
    if [[ -n "${gate}" && "${gate}" != "1" ]]; then
      # 清掉历史渲染产物，避免旧文件继续被 scrape_config_files 通配加载
      rm -f "${inst}/etc/scrape_configs/${base}"
      echo "[render_scrape_configs] 跳过 ${base}（可选模块默认禁用；启用：安装前设 ENABLE 环境变量=1）"
      continue
    fi
    out="${inst}/etc/scrape_configs/${base}"
    sed \
      -e "s|__PROM_FILE_SD_BASE__|${sd_base}|g" \
      -e "s|\${ORIGIN_PROMETHEUS}|${origin}|g" \
      -e "s|\${NODE_EXPORTER_PORT}|${ne_port}|g" \
      -e "s|\${BLACKBOX_PORT}|${bb_port}|g" \
      "${f}" > "${out}"
    chown "${PROMETHEUS_USER}:${PROMETHEUS_GROUP}" "${out}"
    chmod 0640 "${out}"
    echo "[render_scrape_configs] ${out}"
  done
  [[ "${shopt_globnull_was_set}" -eq 1 ]] || shopt -u nullglob
  # 成功路径清理：仅当本函数创建了嵌入临时目录时删除（外层传入的 SCRAPE_CONFIGS_SRC 不动）
  if [[ -n "${_prom_embed_tmpdir:-}" && -d "${_prom_embed_tmpdir}" ]]; then
    rm -rf "${_prom_embed_tmpdir}"
  fi
}

# ------------------------------------------------------------------------------
# write_prometheus_yml: 生成主配置 ${inst}/etc/prometheus.yml
#
# 内容块：
#   - global: scrape_interval 30s + external_labels（site / origin_prometheus / role）
#   - storage.tsdb.retention: time + size（按 --role 决定）
#   - remote_write: 可选；basic_auth 走 username + password_file（审核 §12.3 P0-03）
#   - alerting: 可选 ALERTMANAGER_TARGETS
#   - rule_files + scrape_config_files: 通配 *.yml
#   - scrape_configs: 自身 scrape（labels 含 asset_type/component/role）
# ------------------------------------------------------------------------------
write_prometheus_yml() {
  local inst; inst="$(instance_root)"
  local origin="${EXTRA_LABELS_ORIGIN}"
  local cfg="${inst}/etc/prometheus.yml"
  local remote_write_block=""
  if [[ -n "${REMOTE_WRITE_URL}" ]]; then
    if [[ -n "${REMOTE_WRITE_BASIC_AUTH_FILE}" ]]; then
      # 审核 §12.3 P0-03: 删除非法 protocol 字段；username 实配（不用 username_file: /dev/null）
      # REMOTE_WRITE_BASIC_AUTH_FILE 格式: username:password（两行或单行）
      local rw_username rw_password
      rw_username=$(head -1 "${REMOTE_WRITE_BASIC_AUTH_FILE}" 2>/dev/null | cut -d: -f1)
      rw_password=$(head -1 "${REMOTE_WRITE_BASIC_AUTH_FILE}" 2>/dev/null | cut -d: -f2-)
      if [[ -z "${rw_username}" || -z "${rw_password}" ]]; then
        echo "[write_prometheus_yml] REMOTE_WRITE_BASIC_AUTH_FILE 格式错误（应为 username:password）" >&2
        exit 1
      fi
      # 写临时密码文件（仅含密码，0600）
      local rw_pass_file="${inst}/etc/.remote_write_pass"
      echo "${rw_password}" > "${rw_pass_file}"
      chmod 0600 "${rw_pass_file}"
      chown "${PROMETHEUS_USER}:${PROMETHEUS_GROUP}" "${rw_pass_file}"
      remote_write_block="remote_write:
  - url: '${REMOTE_WRITE_URL}'
    basic_auth:
      username: '${rw_username}'
      password_file: '${rw_pass_file}'
    write_relabel_configs: []
    queue_config:
      capacity: 10000
      max_samples_per_send: 2000
      batch_send_deadline: 10s
      min_shards: 4
      max_shards: 200
"
    else
      remote_write_block="remote_write:
  - url: '${REMOTE_WRITE_URL}'
    queue_config:
      capacity: 10000
      max_samples_per_send: 2000
      batch_send_deadline: 10s
      min_shards: 4
      max_shards: 200
"
    fi
  fi
  local alerting_block=""
  if [[ -n "${ALERTMANAGER_TARGETS:-}" ]]; then
    alerting_block="alerting:
  alertmanagers:
    - static_configs:
        - targets: [${ALERTMANAGER_TARGETS}]
"
  fi
  local promtool="${inst}/bin/promtool"
  # v3.0.0-rc4 audit-blocking 修复（B09）：用 atomic_write_file + promtool check 校验
  # 失败时旧 prometheus.yml 原封不动保留；通过时旧文件备份为 .bak.YYYYMMDDhhmmss
  atomic_write_file "${cfg}" 0640 \
    "${PROMETHEUS_USER}" "${PROMETHEUS_GROUP}" \
    --validate "${promtool} check config" \
    --keep 5 <<EOF
# Prometheus v${PROMETHEUS_VERSION} (role=${ROLE}) - 由 prometheus_installer v${SCRIPT_VERSION} 生成
# 主配置 : ${cfg}
# 规则   : ${inst}/etc/rules/*.yml
# 抓取  : ${inst}/etc/scrape_configs/*.yml
# file_sd: ${inst}/etc/targets/

global:
  scrape_interval: 30s
  evaluation_interval: 30s
  external_labels:
    site: '${SITE_NAME}'
    origin_prometheus: '${origin}'
    role: '${ROLE}'

storage:
  tsdb:
    retention:
      time: ${RETENTION_TIME}
      size: ${RETENTION_SIZE}

${remote_write_block}${alerting_block}# 规则与抓取
rule_files:
  - '${inst}/etc/rules/*.yml'

scrape_config_files:
  - '${inst}/etc/scrape_configs/*.yml'

# 自身抓取
scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['127.0.0.1:${PORT}']
        labels:
          role: monitoring
          asset_type: monitoring
          component: prometheus
EOF
}

write_self_alerts_placeholder() {
  local f; f="$(instance_root)/etc/rules/basic.yml"
  cat > "${f}" <<'EOF'
# 由 prometheus_installer v6.0.0 生成的占位规则
# 实际告警规则请从 src/v6r4-RC6/config/prometheus/rules/*.yml 拷贝并按需启用。
groups:
  - name: platform-availability-alerts
    interval: 30s
    rules: []
EOF
  chmod 0640 "${f}"
  chown "${PROMETHEUS_USER}:${PROMETHEUS_GROUP}" "${f}"
}

# ------------------------------------------------------------------------------
# write_systemd_unit: 生成 /etc/systemd/system/<unit>.service
#
# hardening（centos7 平台仅保留 ProtectSystem=full + NoNewPrivileges）：
#   ProtectSystem=full / ProtectHome / PrivateTmp / ProtectKernelTunables ...
#   ReadOnlyPaths=/ + ReadWritePaths=${TEXTFILE_DIR} ...
#   CapabilityBoundingSet= / MemoryDenyWriteExecute
# 注意：textfile collector 写入必须放 ReadWritePaths。
# ------------------------------------------------------------------------------
write_systemd_unit() {
  local sv; sv="$(systemd_version)"
  local user_directive=""
  # 兼容 systemd 219 (centos7): 使用 User= / Group= 而非 -User/-Group flag
  if [[ -n "${sv}" ]] && (( sv >= 232 )); then
    user_directive="User=${PROMETHEUS_USER}
Group=${PROMETHEUS_GROUP}"
  else
    user_directive="User=${PROMETHEUS_USER}
Group=${PROMETHEUS_GROUP}"
  fi

  local inst; inst="$(instance_root)"
  local sandbox=""
  if [[ "${PLATFORM_ID}" == "rhel" ]]; then
    # RC7: rhel-family（含通过 dnf/yum 识别的 Kylin）在 ProtectSystem=full 下
    # /usr 会被只读挂载；实例位于 /usr/local，因此只精确放行运行期必须写入的
    # TSDB 与日志目录，保留其余 /usr/local/<component> 内容只读。
    sandbox="ProtectSystem=full
ReadWritePaths=${inst}/data ${inst}/logs
NoNewPrivileges=true"
  fi

  local unit_file="/etc/systemd/system/${SERVICE_NAME_PREFIX}-${PORT}.service"
  # v3.0.0-rc4 audit-blocking 修复（B09）：atomic_write_file 包装 unit 文件写入
  # 失败时保留旧 unit；通过时旧 unit 备份为 .bak.YYYYMMDDhhmmss
  if atomic_write_file "${unit_file}" 0644 "" "" --keep 5 <<EOF
[Unit]
Description=Prometheus ${PROMETHEUS_VERSION} (port ${PORT}, role=${ROLE})
Documentation=https://prometheus.io/docs/
After=network-online.target
Wants=network-online.target

[Service]
${user_directive}
${sandbox}
# v3.0.0-rc4 上线门禁 BLOCKER-2（2026-09-10）：
#   显式声明 ExecReload，使 scanner / cmd_reload 调用 systemctl reload 时
#   由 systemd 转 SIGHUP 给 MainPID，无需人工绕过。Type 未显式设 simple，
#   reload 路径仍走 ExecReload 命令。
ExecReload=/bin/kill -HUP \$MAINPID
ExecStart=${inst}/bin/prometheus \\
  --config.file=${inst}/etc/prometheus.yml \\
  --storage.tsdb.path=${inst}/data \\
  --storage.tsdb.retention.time=${RETENTION_TIME} \\
  --storage.tsdb.retention.size=${RETENTION_SIZE} \\
  --web.listen-address=0.0.0.0:${PORT} \\
  --web.config.file=${WEB_CONFIG_FILE_PATH} \\
  --storage.tsdb.wal-compression \\
  --storage.tsdb.min-block-duration=2h \\
  --storage.tsdb.max-block-duration=6h
Restart=always
RestartSec=5
LimitNOFILE=65536
StandardOutput=append:${inst}/logs/prometheus.out.log
StandardError=append:${inst}/logs/prometheus.err.log

[Install]
WantedBy=multi-user.target
EOF
  then
    systemctl daemon-reload
  else
    echo "[write_systemd_unit] unit 写入失败；旧 unit 未变更，daemon-reload 跳过" >&2
    return 1
  fi
}

# ------------------------------------------------------------------------------
# install
# ------------------------------------------------------------------------------
# ------------------------------------------------------------------------------
# v3.0.0-rc4 audit-blocking 修复（B09）：原子化配置写入
#
# atomic_write_file <target_path> <mode> <user> <group> <validate_cmd> <backup_keep>
#   - stdin: 文件内容
#   - 流程：先写到 ${target}.tmp.XXXXXX；按需执行 validate_cmd 校验（失败则保留旧文件）
#   - 校验通过后备份现有 target 为 ${target}.bak.YYYYMMDDhhmmss
#   - 校验通过后 mv tmp -> target（同 fs mv 是原子的）
#   - 备份按 backup_keep 数量上限轮转
#   - mv 失败时尝试从最新备份恢复，保证旧的可用配置不被破坏
#
# validate_cmd 字符串中 "${tmp}" 会被替换为实际临时文件路径。建议格式：
#   '"${inst}/bin/promtool" check config'
# 注意：validate_cmd 中不要带具体文件名；本函数会自动追加 "${tmp}"
# ------------------------------------------------------------------------------
atomic_write_file() {
  local target="$1" mode="$2" user="$3" group="$4"
  local validate_cmd="" backup_keep="5"
  shift 4
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --validate) validate_cmd="$2"; shift 2 ;;
      --keep)     backup_keep="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local tmp; tmp="$(mktemp "${target}.tmp.XXXXXX")"
  local ts;   ts="$(date +%Y%m%d%H%M%S)"
  local rc=1

  cat > "${tmp}"
  chmod "${mode}" "${tmp}" 2>/dev/null || true
  if [[ -n "${user}" && -n "${group}" ]]; then
    chown "${user}:${group}" "${tmp}" 2>/dev/null || true
  fi

  if [[ -n "${validate_cmd}" ]]; then
    # 注意：validate_cmd 由脚本作者硬编码（非用户输入），用 eval 安全；
    # 模板字符串 "${tmp}" 占位符替换为实际临时文件路径。
    # eval 会把多个参数拼接成一条命令——严禁在末尾追加 "_ ${tmp}" 之类的
    # bash -c 风格位置参数（会拼进命令行，promtool 会把 _ 当成文件路径报错）。
    local vout
    if ! vout="$(eval "${validate_cmd} \"\${tmp}\"" 2>&1)"; then
      echo "[atomic_write_file] 校验失败，保留旧文件: ${target}" >&2
      echo "${vout}" | head -n 5 | sed 's/^/[validate] /' >&2
      rm -f "${tmp}"
      return 1
    fi
  fi

  local bak=""
  if [[ -f "${target}" ]]; then
    bak="${target}.bak.${ts}"
    cp -p "${target}" "${bak}" 2>/dev/null || true
  fi

  if mv -f "${tmp}" "${target}"; then
    rc=0
  else
    echo "[atomic_write_file] mv 失败，尝试从备份恢复: ${target}" >&2
    if [[ -n "${bak}" && -f "${bak}" ]]; then
      cp -p "${bak}" "${target}" 2>/dev/null || true
    fi
    rm -f "${tmp}"
    return 1
  fi

  if [[ "${backup_keep}" =~ ^[0-9]+$ ]] && (( backup_keep > 0 )); then
    local b_old
    while IFS= read -r b_old; do
      [[ -n "${b_old}" ]] && rm -f "${b_old}"
    done < <(ls -1t "${target}".bak.* 2>/dev/null | tail -n +$((backup_keep + 1)))
  fi

  return "${rc}"
}

# v3.0.0-rc4 audit-blocking 修复（B09）：探测是否已有 Prometheus 实例存在
existing_instance_p() {
  local inst; inst="$(instance_root)"
  local unit="${SERVICE_NAME_PREFIX}-${PORT}.service"
  [[ -f "${inst}/etc/prometheus.yml" ]] || \
  [[ -f "/etc/systemd/system/${unit}" ]] || \
  [[ -f "/lib/systemd/system/${unit}" ]]
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
  require_install_port_free "${PORT}" "Prometheus Web 端口" || return 1
  echo "[init] $(platform_summary)"

  # v3.0.0-rc4 audit-blocking 修复（B09）：
  #   默认拒绝覆盖已有实例；保留现有配置与凭据不被无意破坏。
  #   用户必须显式选择重装模式（--reinstall-keep / --reinstall-migrate /
  #   --upgrade-binary）或用 --force 跳过本检查。
  local inst; inst="$(instance_root)"
  local unit="${SERVICE_NAME_PREFIX}-${PORT}.service"
  if [[ "${FORCE_REINSTALL}" -ne 1 ]] && existing_instance_p; then
    echo "[B09] 检测到已存在实例 ${SERVICE_NAME_PREFIX}-${PORT}：" >&2
    echo "      - ${inst}/etc/prometheus.yml 或 /etc/systemd/system/${unit}" >&2
    case "${REINSTALL_MODE}" in
      upgrade-binary)
        echo "[B09] REINSTALL_MODE=upgrade-binary：仅刷新二进制并重启 unit，不触碰任何配置" >&2
        download_prometheus
        if systemctl --no-pager is-active "${unit}" >/dev/null 2>&1; then
          systemctl restart "${unit}"
        else
          svc_enable "${unit}"
        fi
        sleep 1
        cmd_status
        echo "[B09] 二进制升级完成；现有 prometheus.yml / web_config / scrape_configs / unit 文件均未变更"
        return 0
        ;;
      keep)
        echo "[B09] REINSTALL_MODE=keep：保留现有所有文件，仅确保服务已启用且处于运行状态" >&2
        if ! systemctl --no-pager is-active "${unit}" >/dev/null 2>&1; then
          svc_enable "${unit}"
        fi
        sleep 1
        cmd_status
        echo "[B09] 保留模式结束；未写入任何新配置"
        return 0
        ;;
      migrate)
        echo "[B09] REINSTALL_MODE=migrate：进入迁移流程；现有 prometheus.yml 等会做带时间戳备份再覆盖" >&2
        ;;
      "")
        echo "[B09] ERROR: 未显式指定重装模式；拒绝覆盖。" >&2
        echo "[B09]   可选模式：" >&2
        echo "[B09]     --reinstall-keep         保留现有所有文件，仅保证服务运行" >&2
        echo "[B09]     --reinstall-migrate      备份现有文件后按新模板覆盖（默认会生成 .bak.YYYYMMDDhhmmss）" >&2
        echo "[B09]     --upgrade-binary         只升级二进制" >&2
        echo "[B09]     --force                  跳过本检查（不推荐；保留旧行为）" >&2
        return 1
        ;;
    esac
  fi

  # 审核 P0-02：注册访问申请清单（默认不改防火墙；MANAGE_FIREWALL=1 才生效）
  local instance_id="${SERVICE_NAME_PREFIX}-${PORT}"
  # 主动抓取：区域 Prometheus 抓取 Node Exporter（9100）、Blackbox（9115）等
  acl_request "${instance_id}-scrape-node" \
    "src=${instance_id}" "dst=node_exporter" "proto=tcp" "port=9100" \
    "direction=out" "purpose=scrape_node_metrics" "cross_room=no" \
    "owner=monitoring-team"
  acl_request "${instance_id}-scrape-blackbox" \
    "src=${instance_id}" "dst=blackbox_exporter" "proto=tcp" "port=9115" \
    "direction=out" "purpose=scrape_blackbox_probes" "cross_room=no" \
    "owner=monitoring-team"
  # 入站：区域 Prometheus 自身被采集与被 Grafana 查询
  acl_request "${instance_id}-web" \
    "src=grafana_vmauth" "dst=${instance_id}" "proto=tcp" "port=${PORT}" \
    "direction=in" "purpose=local_dashboard_query" "cross_room=no" \
    "owner=monitoring-team"
  # 出站：remote_write 写入 VM/vmauth
  if [[ -n "${REMOTE_WRITE_URL}" ]]; then
    acl_request "${instance_id}-remote-write" \
      "src=${instance_id}" "dst=vm_or_vmauth_writer" "proto=tcp" "port=8428" \
      "direction=out" "purpose=remote_write_metrics" "cross_room=no" \
      "owner=monitoring-team"
  fi
  # 出站：告警发送至 AM
  acl_request "${instance_id}-alerting" \
    "src=${instance_id}" "dst=alertmanager" "proto=tcp" "port=9093" \
    "direction=out" "purpose=send_alerts" "cross_room=no" \
    "owner=monitoring-team"
  acl_emit "$(INSTANCE_STATE_DIR)/access-request.md"

  # 兼容 MANAGE_FIREWALL=1 的显式开启：按 ID 调用
  fw_open_port "${PORT}" tcp

  download_prometheus
  prepare_user_dirs
  # 02 §3.2.1: basic auth 凭据
  # 优先级：--auth-pass-file > --auth-pass > read -s 交互
  local auth_pass_actual=""
  if [[ -n "${AUTH_USER_OPT}" ]]; then
    if [[ -n "${AUTH_PASS_FILE_OPT}" ]]; then
      if [[ ! -r "${AUTH_PASS_FILE_OPT}" ]]; then
        echo "[auth] ERROR: --auth-pass-file 不可读: ${AUTH_PASS_FILE_OPT}" >&2
        exit 1
      fi
      # 读取并 strip 尾随 \r\n（容忍 Windows 编辑的凭据文件）
      auth_pass_actual="$(<"${AUTH_PASS_FILE_OPT}")"
      auth_pass_actual="${auth_pass_actual%$'\r'}"
      auth_pass_actual="${auth_pass_actual%$'\n'}"
    elif [[ -n "${AUTH_PASS_OPT}" ]]; then
      auth_pass_actual="${AUTH_PASS_OPT}"
      echo "[auth] WARN: --auth-pass 走 CLI 参数，ps 可读；建议改用 --auth-pass-file" >&2
    else
      # 交互式 read -s 兜底
      echo -n "[auth] 请输入 ${AUTH_USER_OPT} 的密码（不回显）: " >&2
      read -rs auth_pass_actual
      echo >&2
      if [[ -z "${auth_pass_actual}" ]]; then
        echo "[auth] ERROR: 密码不能为空" >&2
        exit 1
      fi
    fi
    write_web_config "${AUTH_USER_OPT}" "${auth_pass_actual}"
  else
    # 未启用 UI auth：直接写空 basic_auth_users（占位文件供 --web.config.file 引用）
    cat > "${WEB_CONFIG_FILE_PATH}" <<EOF
# basic auth 未启用；保留占位文件供 --web.config.file 引用
basic_auth_users: {}
EOF
    chmod 0640 "${WEB_CONFIG_FILE_PATH}"
    chown "${PROMETHEUS_USER}:${PROMETHEUS_GROUP}" "${WEB_CONFIG_FILE_PATH}"
  fi
  # 顺序约束：scrape_configs 必须先渲染，write_prometheus_yml 的
  # promtool check config 会加载 scrape_config_files 通配到的全部子文件；
  # migrate 重装时子文件可能是旧格式，后渲染会让校验读到过期内容
  render_scrape_configs
  write_self_alerts_placeholder
  write_prometheus_yml
  write_systemd_unit

  # 审核 P0-02：注册实例归属，便于卸载识别
  ownership_register "${instance_id}" "${PORT}" "${PROMETHEUS_USER}" \
    "$(service_unit)" "$(instance_etc)/prometheus.yml" \
    "$(instance_data)" "$(instance_log)"

  svc_enable "${SERVICE_NAME_PREFIX}-${PORT}.service"
  sleep 1

  # v3.0.0-rc4 上线门禁 BLOCKER-3（2026-09-10）：
  #   readiness 必须等待认证后 /-/ready=200；超时非零退出。
  #   避免 "systemd 已启动" 被当作 "服务可用"。
  wait_for_prometheus_ready || return 1
  cmd_status

  echo "[done] Prometheus ${PROMETHEUS_VERSION} @ ${PORT} role=${ROLE} retention=${RETENTION_TIME}/${RETENTION_SIZE}"
  if [[ -n "${REMOTE_WRITE_URL}" ]]; then
    echo "[rw]    ${REMOTE_WRITE_URL}"
  fi
  if [[ -n "${AUTH_USER_OPT}" ]]; then
    echo "[auth]  basic auth enabled, user=${AUTH_USER_OPT}"
  fi
}

cmd_status() {
  local unit="${SERVICE_NAME_PREFIX}-${PORT}.service"
  systemctl --no-pager --full status "${unit}" 2>&1 || true
  echo "----- /-/ready -----"
  # v3.0.0-rc4 上线门禁 BLOCKER-3（2026-09-10）：
  #   status 不传密码；启用认证时 /-/ready 返回 401 是预期（不是健康）。
  #   明确区分"服务运行中"与"认证未验证"，避免误导运维。
  # 上线门禁 BLOCKER-3（2026-09-10）status 修复：
  #   探测 web_config.yml 是否启用 basic_auth_users；启用时 401 表示"认证未验证"
  #   而非"未就绪"。同时支持运行期显式传入 AUTH_USER_OPT/AUTH_PASS_OPT 走 netrc 自证。
  local code authed web_cfg netrc
  authed=0
  web_cfg="$(instance_root)/etc/web_config.yml"
  if [[ -s "${web_cfg}" ]] && grep -q '^[[:space:]]*basic_auth_users:' "${web_cfg}"; then
    authed=1
  fi
  if [[ -n "${AUTH_USER_OPT:-}" ]]; then authed=1; fi
  netrc=""
  if [[ "${authed}" -eq 1 && -n "${AUTH_USER_OPT:-}" && -n "${AUTH_PASS_OPT:-}" ]]; then
    netrc="$(mktemp -t promstatus.XXXXXX)"
    chmod 0600 "${netrc}"
    printf 'machine 127.0.0.1 login %s password %s\n' \
      "${AUTH_USER_OPT}" "${AUTH_PASS_OPT}" > "${netrc}"
  fi
  if [[ -n "${netrc}" ]]; then
    code="$(curl --noproxy '*' --netrc-file "${netrc}" \
      --connect-timeout "${STATUS_CURL_CONNECT_TIMEOUT:-2}" \
      --max-time "${STATUS_CURL_MAX_TIMEOUT:-5}" \
      -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/-/ready" 2>/dev/null)"
    rm -f "${netrc}"
  else
    code="$(curl --noproxy '*' \
      --connect-timeout "${STATUS_CURL_CONNECT_TIMEOUT:-2}" \
      --max-time "${STATUS_CURL_MAX_TIMEOUT:-5}" \
      -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/-/ready" 2>/dev/null)"
  fi
  [[ -z "${code}" ]] && code=000
  if [[ "${code}" == "200" ]]; then
    echo "ready (200)"
  elif [[ "${code}" == "401" && "${authed}" -eq 1 ]]; then
    echo "服务运行中，但 readiness 因认证未验证（HTTP 401）；带凭据验证请用 --auth-user/--auth-pass 调用 status"
  else
    echo "(未就绪 HTTP=${code})"
  fi
  echo "----- targets -----"
  curl --noproxy '*' \
    --connect-timeout "${STATUS_CURL_CONNECT_TIMEOUT:-2}" \
    --max-time "${STATUS_CURL_MAX_TIMEOUT:-5}" \
    -fsS "http://127.0.0.1:${PORT}/api/v1/targets" 2>&1 | head -c 400 || true
  echo
}

# wait_for_prometheus_ready: 等待 /-/ready 返回 200，超时返回非零
#   启用 Basic Auth 时用内存里的 AUTH_USER_OPT + auth_pass_actual 走 --netrc-file
#   临时文件 0600，避免密码进 ps 输出；trap 兜底清理（含中断路径）。
# v3.0.0-rc4 上线门禁 TASK-2（2026-09-10 + 2026-09-11 二次加固）：
#   1. curl 必须带 --connect-timeout 与 --max-time，避免单次请求永久阻塞。
#   2. 总截止按"实际经过时间"判定，而非迭代次数。
#      即"循环 N 次 = N 秒上限"是错的：N 次 sleep 1 加 N 次 curl 开销，
#      实际可能 30s + N*max_time；现改 while-elapsed < DEADLINE，真实反映总耗时。
#   3. 失败时仅打印到 stderr，函数返回 1；由调用方（cmd_install）阻断 [done] 输出。
#   4. 不得依赖外部 timeout 124 作为"已超时"证据——失败是 installer 自身的非零退出。
#   5. 所有退出路径（含 ctrl-c / error）都先清理 0600 netrc，避免密码残留 /tmp。
# 2026-09-11 复核发现的 stale-elapsed bug（v6r 包）：
#   旧实现里 `elapsed` 在循环开头算一次就被复用。死循环场景：
#     - deadline=1s，server 在 1.5s 才返回 200；curl --max-time=3 能等到；
#     - iter 1 开头 elapsed=0；curl 返回 200；
#     - 函数打印 `after 0s` 并 return 0 —— 实际已超 deadline。
#   修复（v6r2）：
#   A. curl 前用剩余时间（deadline - elapsed）限制 --max-time；
#   B. curl 完成后必须重算 elapsed，再判定"截止内拿到 200"；
#   C. 仅当 code=200 且 elapsed_after < deadline 时 return 0；其他全部 FAIL。
# 2026-09-11 v6r3 第三次复核：
#   v6r2 仍用 `date +%s` 整数秒计时，有两个时间分辨问题：
#     - start 落在秒边界 700ms 处，下一轮 elapsed=0，下下次 elapsed=1；判断"剩余 1s"
#       与 server 实际用掉的 1.4s 不一致。
#     - "剩余时间"在临界场景下会被四舍五入到整秒，单次 --max-time 跨过 deadline。
#   修复（v6r3）：
#   1. 计时改 `date +%s%N`（纳秒），统一为 ms；判断全部走 ms 精度；
#      stdout "after Xs" 允许小数（awk 截断为 0.1s 精度）。
#   2. 优先使用 monotonic clock（/proc/uptime）避免 wall clock 校准回退；
#      /proc/uptime 不可读时降级到 `date +%s%N`。
#   3. 单次 curl --max-time = min(remaining_ms/1000, max_to)，允许小数；
#      不强制最小 1s、不因剩余 < 500ms 提前失败；剩余为 0 时直接判 FAIL。
#   4. 第一轮立即发起请求，无前置 sleep；
#      失败后重试间隔 = min(200ms, 剩余 ms)，不引入可配置项。
#   5. 每次请求返回后重算 elapsed；只有 elapsed_ms < deadline_ms 且 code=200 才成功。
wait_for_prometheus_ready() {
  local code url netrc deadline deadline_ms start_ms elapsed_ms remaining_ms conn_to max_to max_to_ms curl_max_now curl_max_now_ms sleep_ms
  url="http://127.0.0.1:${PORT}/-/ready"
  deadline="${WAIT_PROM_READY_TIMEOUT:-30}"
  deadline_ms=$(( deadline * 1000 ))
  conn_to="${WAIT_CURL_CONNECT_TIMEOUT:-2}"
  max_to="${WAIT_CURL_MAX_TIMEOUT:-5}"
  max_to_ms=$(( max_to * 1000 ))
  netrc=""
  if [[ -n "${AUTH_USER_OPT:-}" && -n "${auth_pass_actual:-}" ]]; then
    netrc="$(mktemp -t promready.XXXXXX)"
    chmod 0600 "${netrc}"
    printf 'machine 127.0.0.1 login %s password %s\n' \
      "${AUTH_USER_OPT}" "${auth_pass_actual}" > "${netrc}"
  fi
  # trap 兜底：函数返回 / 中断 / 错误都先清理 netrc，再退出
  trap '[[ -n "${netrc}" ]] && rm -f "${netrc}"; trap - RETURN INT TERM ERR' RETURN INT TERM ERR

  # monotonic 计时：/proc/uptime 提供自启动以来的秒.小数字符串，避免 wall clock 跳变；
  # 不可读时降级到 `date +%s%N`。awk 只在每次调用时起一个子进程，零状态。
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
      echo "[ready] FAIL: /-/ready 未在 ${deadline}s 内返回 200（last_code=${code:-000}，实际耗时 $(awk -v ms="${elapsed_ms}" 'BEGIN{printf "%.1f", ms/1000}')s）" >&2
      return 1
    fi
    remaining_ms=$(( deadline_ms - elapsed_ms ))
    curl_max_now_ms="${remaining_ms}"
    [[ "${curl_max_now_ms}" -gt "${max_to_ms}" ]] && curl_max_now_ms="${max_to_ms}"
    curl_max_now="$(awk -v ms="${curl_max_now_ms}" 'BEGIN{printf "%.3f", ms/1000}')"
    if [[ -n "${netrc}" ]]; then
      code="$(curl --noproxy '*' --netrc-file "${netrc}" \
        --connect-timeout "${conn_to}" --max-time "${curl_max_now}" \
        -s -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null)"
    else
      code="$(curl --noproxy '*' \
        --connect-timeout "${conn_to}" --max-time "${curl_max_now}" \
        -s -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null)"
    fi
    [[ -z "${code}" ]] && code=000
    # 每次请求后必须重算 elapsed，再判定"截止前拿到 200"
    elapsed_ms=$(( $(_now_ms) - start_ms ))
    if [[ "${code}" == "200" && "${elapsed_ms}" -lt "${deadline_ms}" ]]; then
      echo "[ready] /-/ready=200 after $(awk -v ms="${elapsed_ms}" 'BEGIN{printf "%.1f", ms/1000}')s"
      return 0
    fi
    # 截止后才拿到 200（或 503/000）—— 判定为失败
    if [[ "${elapsed_ms}" -ge "${deadline_ms}" ]]; then
      echo "[ready] FAIL: /-/ready 未在 ${deadline}s 内返回 200（last_code=${code:-000}，实际耗时 $(awk -v ms="${elapsed_ms}" 'BEGIN{printf "%.1f", ms/1000}')s）" >&2
      return 1
    fi
    # 重新计算 remaining_ms，sleep = min(200ms, remaining_ms)
    remaining_ms=$(( deadline_ms - elapsed_ms ))
    sleep_ms="${remaining_ms}"
    [[ "${sleep_ms}" -gt 200 ]] && sleep_ms=200
    # 用秒.小数 sleep 兼容 busybox / dash
    awk -v ms="${sleep_ms}" 'BEGIN{printf "%.3f", ms/1000}' | xargs sleep
  done
}

cmd_reload() {
  local unit="${SERVICE_NAME_PREFIX}-${PORT}.service"
  svc_reload "${unit}" || systemctl kill -s HUP "${unit}"
  echo "[reload] sent SIGHUP to ${unit}"
}

cmd_check() {
  local inst; inst="$(instance_root)"
  "${inst}/bin/promtool" check config "${inst}/etc/prometheus.yml"
}

cmd_uninstall() {
  require_root
  local unit="${SERVICE_NAME_PREFIX}-${PORT}.service"
  local instance_id="${SERVICE_NAME_PREFIX}-${PORT}"
  # 审核 P0-02：仅在 ownership 记录包含此 instance 时删除 unit
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
  # 卸载按 ID 调用（不按端口号反推）
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

# 裸跑（无任何参数）→ 交互式向导；带参数 → 原 CLI 行为（脚本化/dry-run 路径不变）
# v3.0.0-rc4 audit-blocking 修复（B05）：dispatch 块必须位于所有 cmd_* 函数
# 定义之后，避免交互路径下 exit 0 之后 parser 不再解析后续函数。
if [[ "${ORIG_ARGC}" -eq 0 ]]; then
  interactive_loop "prometheus 安装器 v${SCRIPT_VERSION}" \
    "${SERVICE_NAME_PREFIX}" "PORT" wizard_install
  exit 0
fi

# ------------------------------------------------------------------------------
# main
# ------------------------------------------------------------------------------
ACTION="${1:-help}"
shift || true

case "${ACTION}" in
  install)   cmd_install ;;
  status)    cmd_status ;;
  reload)    cmd_reload ;;
  check)     cmd_check ;;
  uninstall) cmd_uninstall ;;
  help|-h|--help) usage ;;
  *) echo "未知动作: ${ACTION}" >&2; usage; exit 64 ;;
esac

# 兜底：以下 scrape_configs 嵌入块用 `if false; then ... fi` 包裹，
# 防止 bash 跑到 main 末尾后把块内 YAML（`scrape_configs:` 等）当命令执行；
# 同时 sed 仍按 __SCRAPE_NODE_EMBED_BEGIN__/END__ 标记解出原始 YAML。
if false; then
# __SCRAPE_NODE_EMBED_BEGIN__
# ==============================================================================
# scrape_configs/node.yml (A 包嵌入)
#
# Node Exporter 抓取配置（主机/虚拟机视角）
# 适用：node_exporter 1.12.1+（由 node_exporter_installer_v4.0.0.sh 部署）
#
# v3.0.0-rc4 P0-04：
#   - 文件 SD 路径用 `__PROM_FILE_SD_BASE__` 占位符（prometheus_installer 安装时替换）
#   - 默认监听端口 ${NODE_EXPORTER_PORT} (9100)
#   - 与 edge VM K8s 集成互不干扰
#   - metric_relabel 白名单严格收敛 cardinality（PSI/percpu 子项已禁）
#   - enabled_modules（NE_* 启用的 collector 列表）通过 instance 文件 SD 注入
# ==============================================================================

scrape_configs:
  - job_name: node_exporter
    metrics_path: /metrics
    scrape_interval: 30s
    scrape_timeout: 20s
    file_sd_configs:
      - files:
          - '__PROM_FILE_SD_BASE__/node/*.json'
        refresh_interval: 60s

    relabel_configs:
      # v3.0.0-rc4 上线门禁 P0-1（2026-09-10）：
      #   标签契约：job/instance 由 Prometheus 内部生成；site/origin_prometheus 由
      #   Prometheus external_labels 注入；file_sd 只承载业务标签，不写入
      #   job/instance/site/origin_prometheus。origin_prometheus 也不再额外拼接
      #   "prom-edge-" 前缀，以与 Prometheus 自身 external_labels 完全一致。
      #   job 在 scrape job_name=node_exporter 自动生成，无需 relabel 注入。
      - source_labels: [host]
        target_label: host
      - source_labels: [env]
        target_label: env
      - source_labels: [alert_policy]
        target_label: alert_policy
      - target_label: asset_type
        replacement: host
      - target_label: role
        replacement: infrastructure

    metric_relabel_configs:
      - source_labels: [__name__]
        regex: '(node_cpu_(guest_seconds_total|seconds_total|iowait_seconds_total|usage_total)|node_memory_(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree|Active|Inactive|Dirty|Writeback|AnonPages|Mapped|Shmem|KernelStack|PageTables|NFS_Unstable|Bounce|CommitLimit|Committed_AS|VmallocUsed|VmallocChunk|HardwareCorrupted|AnonHugePages|CmaFree|CmaTotal|HugePages_Total|HugePages_Free|HugePages_Rsvd|HugePages_Surplus|Hugepagesize|DirectMap4k|DirectMap2M|DirectMap1G)|node_(load[0-9]+|uptime|entropy_available)|node_filesystem_(avail|files|files_free|free|inodes|inodes_free|readonly|size|device_error)|node_disk_(reads|reads_merged|read_bytes|writes|writes_merged|written_bytes|io_now|io_time_seconds_weighted|read_time_seconds|write_time_seconds|io_time_seconds|discards_completed|discarded_sectors)|node_network_(receive|transmit)_(bytes|packets|errors|drop|compressed|multicast)|node_systemd_(unit_state|units_total|unit_start_time_seconds)|node_pressure_(cpu_waiting_seconds_total|memory_stalled_seconds_total|io_stalled_seconds_total|full_stalled_seconds_total|some_stalled_seconds_total)|node_textfile_mtime_seconds|node_(sockstat|sockets|conntrack_(entries|entries_limit|inserted|insert_failed)|timex|uname)|node_hwmon_temp_celsius)[a-zA-Z0-9_]*'
        action: keep
      - source_labels: [__name__]
        regex: 'node_cpu_per_cpu.*'
        action: drop
      - source_labels: [__name__]
        regex: 'node_exporter_(build_info|memstats_).*'
        action: drop
      - source_labels: [__name__]
        regex: 'node_network_mtu_bytes.*'
        action: drop
      - source_labels: [__name__]
        regex: 'process_(cpu_seconds_total|max_fds|open_fds|resident_memory_bytes|virtual_memory_bytes|start_time_seconds|num_procs|threads).*'
        action: drop
      - source_labels: [__name__]
        regex: 'go_(gc_duration_seconds|goroutines|info|memstats_).*'
        action: drop
      - source_labels: [__name__]
        regex: 'promhttp_(metric_handler_requests_in_flight|metric_handler_requests_total|response_size_bytes_bucket).*'
        action: drop
# __SCRAPE_NODE_EMBED_END__
fi
