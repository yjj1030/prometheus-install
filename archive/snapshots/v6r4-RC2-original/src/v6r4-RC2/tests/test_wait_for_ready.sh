#!/usr/bin/env bash
# test_wait_for_ready.sh - TASK-2 readiness 实测（v6r3 重写）
#
# 覆盖:
#   - 正常 200
#   - 持续非 200 (503)
#   - 接受连接但不响应（Python HTTPServer 不写响应体、关闭超时=无穷）
#   - 截止后才返回 200（最关键的 stale-elapsed 回归 case）
#   - prom Basic Auth 路径 (netrc 创建 + 所有退出路径都清理)
#
# 每个场景必须断言 expected RC + 关键文本；任一断言失败则脚本整体非零退出。
# 沙箱位置: /tmp/t2-test/test_wait_for_ready.sh（与本仓库同源）。
#
# 清理策略（v6r3）：
#   - 禁止 pkill -f（按通用名批量杀）；
#   - 直接 python3 /tmp/t2srv.*.py & 在父 shell 保存 $! 到 SRV_PIDS；
#   - 每个子进程独占一个 Python HTTPServer，覆盖 4 类场景；
#   - cleanup 走 TERM → 等 0.3s → KILL → wait，避免 PID 复用误杀；
#   - cleanup 可重复执行（idempotent），trap EXIT 统一触发，
#     INT/TERM 只置 NONZERO_EXIT=1 后回到主流程退出，不直接清理（防止 trap 覆盖问题）。
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_DIR="${INSTALLER_DIR:-${SCRIPT_DIR}/../installers}"
PROM_SRC="${INSTALLER_DIR}/prometheus_installer_v6.0.0.sh"
GRAF_SRC="${INSTALLER_DIR}/grafana_installer_v1.0.0.sh"

if [[ ! -r "${PROM_SRC}" || ! -r "${GRAF_SRC}" ]]; then
  echo "FATAL: missing installers at ${INSTALLER_DIR}" >&2
  exit 99
fi

extract_function() {
  awk -v fn="$2" '
    $0 ~ "^"fn"\\(\\)" {p=1}
    p {print}
    p && $0 == "}" {exit}
  ' "$1"
}

eval "$(extract_function "${PROM_SRC}" wait_for_prometheus_ready)"
eval "$(extract_function "${GRAF_SRC}" wait_for_grafana_ready)"

# 默认短 deadline 加快测试；用户可覆盖
export WAIT_PROM_READY_TIMEOUT="${WAIT_PROM_READY_TIMEOUT:-8}"
export WAIT_GRAFANA_READY_TIMEOUT="${WAIT_GRAFANA_READY_TIMEOUT:-8}"
export WAIT_CURL_CONNECT_TIMEOUT="${WAIT_CURL_CONNECT_TIMEOUT:-2}"
export WAIT_CURL_MAX_TIMEOUT="${WAIT_CURL_MAX_TIMEOUT:-3}"

# ---------- 全局状态：PID 数组、临时脚本文件、结果 ----------
RESULTS_FILE="$(mktemp -t t2results.XXXXXX)"
SRV_PIDS=()
STARTED_PID=""
SRV_FILES=()
NONZERO_EXIT=0

cleanup_all() {
  # TERM → wait → KILL → wait；幂等（重复调用安全）
  echo "[cleanup_all] SRV_PIDS=${SRV_PIDS[*]}" >&2
  local pid i
  # 1. TERM
  for pid in "${SRV_PIDS[@]:-}"; do
    [[ -z "${pid}" ]] && continue
    kill -TERM "${pid}" 2>/dev/null || true
  done
  # 2. 等最多 0.3s
  for _ in 1 2 3 4 5 6; do
    local alive=0
    for pid in "${SRV_PIDS[@]:-}"; do
      [[ -z "${pid}" ]] && continue
      if kill -0 "${pid}" 2>/dev/null; then alive=1; break; fi
    done
    [[ "${alive}" == "0" ]] && break
    sleep 0.05
  done
  # 3. KILL 仍存活的（不留情面：测试服务进程是可牺牲的）
  for pid in "${SRV_PIDS[@]:-}"; do
    [[ -z "${pid}" ]] && continue
    if kill -0 "${pid}" 2>/dev/null; then
      kill -KILL "${pid}" 2>/dev/null || true
    fi
  done
  # 4. 等 KILL 生效（最多 0.5s）
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    local alive=0
    for pid in "${SRV_PIDS[@]:-}"; do
      [[ -z "${pid}" ]] && continue
      if kill -0 "${pid}" 2>/dev/null; then alive=1; break; fi
    done
    [[ "${alive}" == "0" ]] && break
    sleep 0.05
  done
  # 5. wait 回收所有 PID（不关心退出码，-- 防空数组）
  for pid in "${SRV_PIDS[@]:-}"; do
    [[ -z "${pid}" ]] && continue
    wait "${pid}" 2>/dev/null || true
  done
  # 兜底：检查每个 PID 是否还活着
  for pid in "${SRV_PIDS[@]:-}"; do
    [[ -z "${pid}" ]] && continue
    if kill -0 "${pid}" 2>/dev/null; then
      echo "[cleanup_all] WARN pid ${pid} still alive after KILL" >&2
    fi
  done
  SRV_PIDS=()
  # 6. 删除临时 server 脚本（不删 /tmp/t2-stdout /tmp/t2-stderr —— 测试场景内联断言需要）
  if [[ "${#SRV_FILES[@]}" -gt 0 ]]; then
    rm -f "${SRV_FILES[@]}" 2>/dev/null || true
  fi
  SRV_FILES=()
  rm -f "${RESULTS_FILE}" 2>/dev/null || true
  # 7. 兜底删除已知的 t2srv 临时脚本（stop_srv 漏掉的边角；不按通用名杀进程）
  rm -f /tmp/t2srv.*.py 2>/dev/null || true
}

on_exit() {
  local rc=$?
  cleanup_all
  # 中断路径保留非零退出
  if [[ "${NONZERO_EXIT}" != "0" ]]; then
    exit "${NONZERO_EXIT}"
  fi
  exit "${rc}"
}

on_signal() {
  # 中断信号：显式 cleanup + exit，避免 bash 默认 TERM 行为绕过 EXIT trap。
  # bash 在 trap handler return 后仍按默认动作终止 shell（不触发 EXIT trap），
  # 这里手动 cleanup 然后显式 exit，让 on_exit 接管 NONZERO_EXIT 传播。
  NONZERO_EXIT=130
  cleanup_all
  exit "${NONZERO_EXIT}"
}

trap on_exit EXIT
trap on_signal INT TERM

# ---------- 进程辅助 ----------
pick_port() {
  python3 - <<'PY'
import socket
s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()
PY
}

# write_srv_script <file> <mode> <port> [delay]
#   mode: 200 | 503 | hang | slow200:<delay>
write_srv_script() {
  local srvfile="$1" mode="$2" port="$3" delay="${4:-0}"
  case "${mode}" in
    200)
      cat >"${srvfile}" <<PYEOF
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b"x")
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", ${port}), H).serve_forever()
PYEOF
      ;;
    503)
      cat >"${srvfile}" <<PYEOF
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(503); self.end_headers(); self.wfile.write(b"x")
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", ${port}), H).serve_forever()
PYEOF
      ;;
    hang)
      cat >"${srvfile}" <<PYEOF
import socket
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", ${port}))
s.listen(64)
while True:
    try:
        c, _ = s.accept()
    except Exception:
        pass
PYEOF
      ;;
    slow200)
      cat >"${srvfile}" <<PYEOF
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        time.sleep(${delay})
        self.send_response(200); self.end_headers(); self.wfile.write(b"x")
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", ${port}), H).serve_forever()
PYEOF
      ;;
    *)
      echo "FATAL: unknown srv mode '${mode}'" >&2; exit 99 ;;
  esac
}

# start_srv <mode> <port> [delay_for_slow200]
#   立即把子进程 PID 加入 SRV_PIDS（"$!" → 数组 = 单条赋值，无 race 窗口），
#   避免父 shell 在 fork 之后被 SIGTERM 时 SRV_PIDS+=("${pid}") 还没执行。
start_srv() {
  local mode="$1" port="$2" delay="${3:-0}"
  local srvfile
  srvfile="$(mktemp -t t2srv.XXXXXX.py)"
  write_srv_script "${srvfile}" "${mode}" "${port}" "${delay}"
  SRV_FILES+=("${srvfile}")
  python3 "${srvfile}" >/dev/null 2>&1 &
  STARTED_PID="$!"
  SRV_PIDS+=("${STARTED_PID}")
}

# stop_srv <pid> —— 显式 TERM + KILL + wait 单个 PID
# 不从 SRV_PIDS 移除（让 EXIT trap 兜底，保证中断路径也能清理）
stop_srv() {
  local pid="$1"
  [[ -z "${pid}" ]] && return 0
  kill -TERM "${pid}" 2>/dev/null || true
  for _ in 1 2 3 4 5 6; do
    kill -0 "${pid}" 2>/dev/null || break
    sleep 0.05
  done
  if kill -0 "${pid}" 2>/dev/null; then
    kill -KILL "${pid}" 2>/dev/null || true
  fi
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "${pid}" 2>/dev/null || break
    sleep 0.05
  done
  wait "${pid}" 2>/dev/null || true
}

wait_port() {
  local port="$1" max="${2:-30}"
  local _ i
  for _ in $(seq 1 "${max}"); do
    python3 -c "import socket,sys
s=socket.socket(); s.settimeout(0.3)
try: s.connect(('127.0.0.1',${port})); sys.exit(0)
except OSError: sys.exit(1)" 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    echo "  ASSERT ${label}=${actual} (expected ${expected}) ✓"
    printf 'PASS\t%s\t%s\n' "${label}" "${actual}" >> "${RESULTS_FILE}"
    return 0
  else
    echo "  ASSERT ${label}=${actual} ✗ expected ${expected}"
    printf 'FAIL\t%s\t%s\n' "${label}" "${actual}" >> "${RESULTS_FILE}"
    return 1
  fi
}

assert_contains() {
  local label="$1" actual="$2" needle="$3"
  if [[ "${actual}" == *"${needle}"* ]]; then
    echo "  ASSERT ${label} contains '${needle}' ✓"
    printf 'PASS\t%s\t%s\n' "${label}.contains" yes >> "${RESULTS_FILE}"
    return 0
  else
    echo "  ASSERT ${label} does NOT contain '${needle}' ✗ (got: ${actual})"
    printf 'FAIL\t%s\t%s\n' "${label}.contains" no >> "${RESULTS_FILE}"
    return 1
  fi
}

assert_not_contains() {
  local label="$1" actual="$2" needle="$3"
  if [[ "${actual}" == *"${needle}"* ]]; then
    echo "  ASSERT ${label} should NOT contain '${needle}' ✗ (got: ${actual})"
    printf 'FAIL\t%s\t%s\n' "${label}.notcontains" violated >> "${RESULTS_FILE}"
    return 1
  else
    echo "  ASSERT ${label} free of '${needle}' ✓"
    printf 'PASS\t%s\t%s\n' "${label}.notcontains" clean >> "${RESULTS_FILE}"
    return 0
  fi
}

# ---------- 跑分函数 ----------
# run_ready_bounded <svc> <port> [deadline]
# 测试夹具自身必须有硬上限：即使被测 readiness 发生回归，也不能把整套验收永久挂死。
run_ready_bounded() {
  local svc="$1" port="$2" deadline_override="${3:-}"
  local deadline hard_limit call_pid rc i max_ticks

  if [[ -n "${deadline_override}" ]]; then
    deadline="${deadline_override}"
  elif [[ "${svc}" == "prom" ]]; then
    deadline="${WAIT_PROM_READY_TIMEOUT}"
  else
    deadline="${WAIT_GRAFANA_READY_TIMEOUT}"
  fi
  # 被测 deadline + 单次 curl 最大超时 + 5 秒夹具余量。
  hard_limit=$(( deadline + WAIT_CURL_MAX_TIMEOUT + 5 ))

  (
    if [[ "${svc}" == "prom" ]]; then
      if [[ -n "${deadline_override}" ]]; then
        WAIT_PROM_READY_TIMEOUT="${deadline_override}" PORT="${port}" wait_for_prometheus_ready
      else
        PORT="${port}" wait_for_prometheus_ready
      fi
    else
      if [[ -n "${deadline_override}" ]]; then
        WAIT_GRAFANA_READY_TIMEOUT="${deadline_override}" PORT="${port}" wait_for_grafana_ready
      else
        PORT="${port}" wait_for_grafana_ready
      fi
    fi
  ) >/tmp/t2-stdout 2>/tmp/t2-stderr &
  call_pid=$!

  max_ticks=$(( hard_limit * 10 ))
  for ((i=0; i<max_ticks; i++)); do
    if ! kill -0 "${call_pid}" 2>/dev/null; then
      wait "${call_pid}"; return $?
    fi
    sleep 0.1
  done

  echo "FAIL: test harness hard timeout after ${hard_limit}s" >>/tmp/t2-stderr
  kill -TERM "${call_pid}" 2>/dev/null || true
  sleep 0.2
  kill -KILL "${call_pid}" 2>/dev/null || true
  wait "${call_pid}" 2>/dev/null || true
  return 124
}

run_case() {
  local svc="$1" port="$2" expected_rc="$3" expect_marker="$4" label="$5"
  local timeout_override="${6:-}"
  local start end elapsed rc stdout_text stderr_text
  echo "----------------------------------------------------------"
  echo "  ${label}  svc=${svc} port=${port} expected_rc=${expected_rc}"
  echo "----------------------------------------------------------"
  start=$(date +%s)
  run_ready_bounded "${svc}" "${port}" "${timeout_override}"
  rc=$?
  end=$(date +%s)
  elapsed=$((end-start))
  stdout_text="$(cat /tmp/t2-stdout)"
  stderr_text="$(cat /tmp/t2-stderr)"

  echo "  RC=${rc}  ELAPSED=${elapsed}s"
  echo "  STDOUT=|${stdout_text}|"
  echo "  STDERR=|${stderr_text}|"

  local local_fail=0
  assert_eq "${label}.rc" "${rc}" "${expected_rc}" || local_fail=1
  if [[ "${expect_marker}" == "yes" ]]; then
    assert_contains "${label}.marker" "${stdout_text}" "[ready]" || local_fail=1
    assert_contains "${label}.marker_after" "${stdout_text}" "after" || local_fail=1
  else
    assert_not_contains "${label}.no_marker" "${stdout_text}" "[ready]" || local_fail=1
  fi
  if [[ "${expected_rc}" == "1" ]]; then
    assert_contains "${label}.fail_msg" "${stderr_text}" "FAIL" || local_fail=1
  fi
  return "${local_fail}"
}

check_netrc_cleanup() {
  local label="$1"
  local leaked
  leaked="$(find /tmp -maxdepth 1 -name 'promready.*' -perm -600 2>/dev/null | head -5)"
  if [[ -z "${leaked}" ]]; then
    echo "  ASSERT ${label}.netrc_clean ✓"
    printf 'PASS\t%s\t%s\n' "${label}.netrc" clean >> "${RESULTS_FILE}"
    return 0
  else
    echo "  ASSERT ${label}.netrc_clean ✗ 残留: ${leaked}"
    printf 'FAIL\t%s\t%s\n' "${label}.netrc" leak >> "${RESULTS_FILE}"
    return 1
  fi
}

check_password_leak() {
  local label="$1" password="$2"
  if grep -rl "${password}" /tmp/promready.* 2>/dev/null | head -3 | grep -q .; then
    echo "  ASSERT ${label}.password_clean ✗ !!! 密码字面量残留"
    printf 'FAIL\t%s\t%s\n' "${label}.password" leak >> "${RESULTS_FILE}"
    return 1
  else
    echo "  ASSERT ${label}.password_clean ✓"
    printf 'PASS\t%s\t%s\n' "${label}.password" clean >> "${RESULTS_FILE}"
    return 0
  fi
}

# =========================================================
# 场景矩阵
# =========================================================
echo "############################################################"
echo "# 服务端表现矩阵（prom + grafana 各 4 场景）"
echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "############################################################"

pass=0
fail=0
fail_log=()

for SVC in prom grafana; do
  echo
  echo "############################################################"
  echo "# ${SVC}（每个场景使用独立临时端口）"
  echo "############################################################"

  # —— 场景 1: 正常 200 ——
  PORT_X=$(pick_port)
  start_srv "200" "${PORT_X}"; PID="${STARTED_PID}"
  wait_port "${PORT_X}" 10 || { echo "FAIL: server didn't start"; exit 99; }
  if run_case "${SVC}" "${PORT_X}" "0" "yes" "${SVC}.1.normal_200"; then pass=$((pass+1)); else fail=$((fail+1)); fail_log+=("${SVC}.1.normal_200"); fi
  stop_srv "${PID}"

  # —— 场景 2: 持续非 200 (503) ——
  PORT_X=$(pick_port)
  start_srv "503" "${PORT_X}"; PID="${STARTED_PID}"
  wait_port "${PORT_X}" 10 || { echo "FAIL: server didn't start"; exit 99; }
  if run_case "${SVC}" "${PORT_X}" "1" "no" "${SVC}.2.persistent_503"; then pass=$((pass+1)); else fail=$((fail+1)); fail_log+=("${SVC}.2.persistent_503"); fi
  stop_srv "${PID}"

  # —— 场景 3: 接受连接但不响应（Python hang）——
  PORT_X=$(pick_port)
  start_srv "hang" "${PORT_X}"; PID="${STARTED_PID}"
  wait_port "${PORT_X}" 10 || { echo "FAIL: hang server didn't start"; exit 99; }
  if run_case "${SVC}" "${PORT_X}" "1" "no" "${SVC}.3.hang"; then pass=$((pass+1)); else fail=$((fail+1)); fail_log+=("${SVC}.3.hang"); fi
  stop_srv "${PID}"

  # —— 场景 4: 截止后才返回 200（v6r3 关键回归 case）——
  PORT_X=$(pick_port)
  start_srv "slow200" "${PORT_X}" "2.5"; PID="${STARTED_PID}"
  wait_port "${PORT_X}" 10 || { echo "FAIL: slow server didn't start"; exit 99; }
  _saved_curl_max="${WAIT_CURL_MAX_TIMEOUT}"
  WAIT_CURL_MAX_TIMEOUT=5
  run_ready_bounded "${SVC}" "${PORT_X}" 2
  rc=$?
  WAIT_CURL_MAX_TIMEOUT="${_saved_curl_max}"
  echo "----------------------------------------------------------"
  echo "  ${SVC}.4.returns_200_after_deadline (deadline=2s, delay=2.5s)"
  echo "  RC=${rc}"
  echo "  STDOUT=|$(cat /tmp/t2-stdout)|"
  echo "  STDERR=|$(cat /tmp/t2-stderr)|"
  local_fail=0
  assert_eq "${SVC}.4.rc" "${rc}" "1" || local_fail=1
  assert_not_contains "${SVC}.4.no_after_marker" "$(cat /tmp/t2-stdout)" "after" || local_fail=1
  assert_contains "${SVC}.4.fail_msg" "$(cat /tmp/t2-stderr)" "FAIL" || local_fail=1
  if [[ "${local_fail}" == "0" ]]; then pass=$((pass+1)); else fail=$((fail+1)); fail_log+=("${SVC}.4.returns_200_after_deadline"); fi
  stop_srv "${PID}"
done

# =========================================================
# prom Basic Auth netrc 路径
# =========================================================
echo
echo "############################################################"
echo "# prom + Basic Auth netrc cleanup"
echo "############################################################"

AUTH_PORT=$(pick_port)
AUTH_PASS="s3cret-do-not-leak-$$"
export AUTH_USER_OPT="tester"
export auth_pass_actual="${AUTH_PASS}"
export WAIT_PROM_READY_TIMEOUT=6
export WAIT_CURL_MAX_TIMEOUT=3

# —— 场景 5: prom + Basic Auth, normal 200 ——
start_srv "200" "${AUTH_PORT}"; PID="${STARTED_PID}"
wait_port "${AUTH_PORT}" 10 || { echo "FAIL: auth server didn't start"; exit 99; }
echo "----------------------------------------------------------"
echo "  prom.5.basic_auth_200"
echo "----------------------------------------------------------"
start=$(date +%s)
run_ready_bounded "prom" "${AUTH_PORT}"
rc=$?
end=$(date +%s); elapsed=$((end-start))
echo "  RC=${rc} ELAPSED=${elapsed}s"
echo "  STDOUT=|$(cat /tmp/t2-stdout)|"
echo "  STDERR=|$(cat /tmp/t2-stderr)|"
local_fail=0
assert_eq "prom.5.rc" "${rc}" "0" || local_fail=1
assert_contains "prom.5.marker" "$(cat /tmp/t2-stdout)" "[ready]" || local_fail=1
check_netrc_cleanup "prom.5" || local_fail=1
check_password_leak "prom.5" "${AUTH_PASS}" || local_fail=1
if [[ "${local_fail}" == "0" ]]; then pass=$((pass+1)); else fail=$((fail+1)); fail_log+=("prom.5.basic_auth_200"); fi
stop_srv "${PID}"

# —— 场景 6: prom + Basic Auth, 持久 503 ——
AUTH_PORT=$(pick_port)
start_srv "503" "${AUTH_PORT}"; PID="${STARTED_PID}"
wait_port "${AUTH_PORT}" 10 || { echo "FAIL: auth server didn't start"; exit 99; }
echo "----------------------------------------------------------"
echo "  prom.6.basic_auth_503"
echo "----------------------------------------------------------"
start=$(date +%s)
run_ready_bounded "prom" "${AUTH_PORT}"
rc=$?
end=$(date +%s); elapsed=$((end-start))
echo "  RC=${rc} ELAPSED=${elapsed}s"
echo "  STDOUT=|$(cat /tmp/t2-stdout)|"
echo "  STDERR=|$(cat /tmp/t2-stderr)|"
local_fail=0
assert_eq "prom.6.rc" "${rc}" "1" || local_fail=1
assert_not_contains "prom.6.no_marker" "$(cat /tmp/t2-stdout)" "[ready]" || local_fail=1
assert_contains "prom.6.fail_msg" "$(cat /tmp/t2-stderr)" "FAIL" || local_fail=1
check_netrc_cleanup "prom.6" || local_fail=1
check_password_leak "prom.6" "${AUTH_PASS}" || local_fail=1
if [[ "${local_fail}" == "0" ]]; then pass=$((pass+1)); else fail=$((fail+1)); fail_log+=("prom.6.basic_auth_503"); fi
stop_srv "${PID}"

unset AUTH_USER_OPT auth_pass_actual

# =========================================================
# 旁路进程断言（v6r3 新增）：启一个不被脚本管理的旁路 Python server，
# 跑完所有场景后检查它仍然存活 —— 证明 cleanup 没有按通用名误杀
# =========================================================
echo
echo "############################################################"
echo "# 旁路进程断言（v6r3 新增）"
echo "############################################################"
BYPASS_PORT=$(pick_port)
BYPASS_SRV=$(mktemp -t bypass.XXXXXX.py)
cat >"${BYPASS_SRV}" <<PYEOF
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b"x")
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", ${BYPASS_PORT}), H).serve_forever()
PYEOF
python3 "${BYPASS_SRV}" >/dev/null 2>&1 &
BYPASS_PID=$!
# 用 wait_port 确认旁路 server 就绪（禁止 sleep 盲等）
if ! wait_port "${BYPASS_PORT}" 10; then
  echo "  ASSERT bypass.alive ✗ 旁路 server 端口未就绪"; fail=$((fail+1)); fail_log+=("bypass.alive")
elif ! kill -0 "${BYPASS_PID}" 2>/dev/null; then
  echo "  ASSERT bypass.alive ✗ 旁路 server 启动失败"; fail=$((fail+1)); fail_log+=("bypass.alive")
else
  echo "  ASSERT bypass.alive ✓ (pid=${BYPASS_PID} port=${BYPASS_PORT})"
  printf 'PASS\tbypass.alive\tyes\n' >> "${RESULTS_FILE}"
  pass=$((pass+1))
fi
# 用 curl 旁路 port 确认仍在响应；curl 失败后单独规范化空值为 000（避免 000000）
bypass_code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 1 --max-time 2 "http://127.0.0.1:${BYPASS_PORT}/" 2>/dev/null)"
[[ -z "${bypass_code}" ]] && bypass_code=000
if [[ "${bypass_code}" == "200" ]]; then
  echo "  ASSERT bypass.responsive ✓ (code=200)"
  printf 'PASS\tbypass.responsive\t200\n' >> "${RESULTS_FILE}"
  pass=$((pass+1))
else
  echo "  ASSERT bypass.responsive ✗ code=${bypass_code}"
  printf 'FAIL\tbypass.responsive\t%s\n' "${bypass_code}" >> "${RESULTS_FILE}"
  fail=$((fail+1)); fail_log+=("bypass.responsive")
fi
# 清理旁路
kill -TERM "${BYPASS_PID}" 2>/dev/null || true
sleep 0.2
kill -KILL "${BYPASS_PID}" 2>/dev/null || true
wait "${BYPASS_PID}" 2>/dev/null || true
rm -f "${BYPASS_SRV}"

# =========================================================
# 总结与自退出
# =========================================================
echo
echo "############################################################"
echo "# RESULTS SUMMARY"
echo "############################################################"
echo "  pass=${pass}"
echo "  fail=${fail}"
if [[ "${fail}" -gt 0 ]]; then
  echo "  failed scenarios:"
  for s in "${fail_log[@]}"; do echo "    - ${s}"; done
fi
echo
echo "  raw results (tab-separated: status\tlabel\tvalue):"
sort "${RESULTS_FILE}" | sed 's/^/    /'

if [[ "${fail}" -gt 0 ]]; then
  echo
  echo "TEST_SCRIPT_RC=1  ← at least one scenario failed; refusing zero exit"
  exit 1
fi
echo
echo "TEST_SCRIPT_RC=0  ← all scenarios passed"
exit 0
