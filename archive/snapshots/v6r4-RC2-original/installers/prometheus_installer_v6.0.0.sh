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
    echo "[download] ${url}"
    download "${url}" "${dst}" || { echo "下载失败: ${url}" >&2; exit 2; }
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
      echo "[render_scrape_configs] 用户需手动从 v3.0.0-rc4/config/prometheus/scrape_configs/*.yml 拷贝到 ${inst}/etc/scrape_configs/ 并替换占位符" >&2
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
# 实际告警规则请从 v3.0.0-rc4/config/prometheus/rules/*.yml 拷贝并按需启用。
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

  local sandbox=""
  if [[ "${PLATFORM_ID}" == "rhel" ]]; then
    sandbox="ProtectSystem=full
NoNewPrivileges=true"
  fi

  local inst; inst="$(instance_root)"
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
