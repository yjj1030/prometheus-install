#!/usr/bin/env bash
# test_stale_elapsed_regression.sh — TASK-2 关键回归测试（v6r3 重写）
#
# 同一场景 (deadline=2s, server_delay=2.5s) 下:
#   - 旧实现（v6r2, git HEAD~1）→ 期望 RC=0 且打印 "after 0s"（复现 BUG）
#   - 新实现（v6r3, git HEAD）→ 期望 RC=1 且 stderr 含 "FAIL"
#
# 该脚本自身必须非零退出当两路验证任一不符预期。
# 清理策略（v6r3）：禁止 pkill -f；只杀 SRV_PIDS 中本脚本启动的 PID。
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_DIR="${INSTALLER_DIR:-${SCRIPT_DIR}/../installers}"
PROM_SRC="${INSTALLER_DIR}/prometheus_installer_v6.0.0.sh"
# 旧（buggy）函数存档默认在同目录 old_prom_wait.sh（不再依赖 /tmp 预置）
OLD_FUNC_FILE="${OLD_FUNC_FILE:-${SCRIPT_DIR}/old_prom_wait.sh}"

if [[ ! -r "${PROM_SRC}" ]]; then
  echo "FATAL: missing ${PROM_SRC}" >&2; exit 99
fi
if [[ ! -r "${OLD_FUNC_FILE}" ]]; then
  echo "FATAL: missing ${OLD_FUNC_FILE}" >&2; exit 99
fi

SRV_PIDS=()
SRV_FILES=()
NONZERO_EXIT=0

cleanup_all() {
  local pid
  for pid in "${SRV_PIDS[@]:-}"; do
    [[ -z "${pid}" ]] && continue
    kill -TERM "${pid}" 2>/dev/null || true
  done
  for _ in 1 2 3 4 5 6; do
    local alive=0
    for pid in "${SRV_PIDS[@]:-}"; do
      [[ -z "${pid}" ]] && continue
      if kill -0 "${pid}" 2>/dev/null; then alive=1; break; fi
    done
    [[ "${alive}" == "0" ]] && break
    sleep 0.05
  done
  for pid in "${SRV_PIDS[@]:-}"; do
    [[ -z "${pid}" ]] && continue
    if kill -0 "${pid}" 2>/dev/null; then
      kill -KILL "${pid}" 2>/dev/null || true
    fi
  done
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    local alive=0
    for pid in "${SRV_PIDS[@]:-}"; do
      [[ -z "${pid}" ]] && continue
      if kill -0 "${pid}" 2>/dev/null; then alive=1; break; fi
    done
    [[ "${alive}" == "0" ]] && break
    sleep 0.05
  done
  for pid in "${SRV_PIDS[@]:-}"; do
    [[ -z "${pid}" ]] && continue
    wait "${pid}" 2>/dev/null || true
  done
  SRV_PIDS=()
  if [[ "${#SRV_FILES[@]}" -gt 0 ]]; then
    rm -f "${SRV_FILES[@]}" 2>/dev/null || true
  fi
  SRV_FILES=()
  rm -f /tmp/t2-stdout /tmp/t2-stderr /tmp/old-stdout /tmp/old-stderr 2>/dev/null || true
  rm -f /tmp/t2srv.*.py 2>/dev/null || true
}

on_exit() {
  local rc=$?
  cleanup_all
  if [[ "${NONZERO_EXIT}" != "0" ]]; then exit "${NONZERO_EXIT}"; fi
  exit "${rc}"
}
on_signal() { NONZERO_EXIT=130; }

trap on_exit EXIT
trap on_signal INT TERM

pick_port() {
  python3 - <<'PY'
import socket
s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()
PY
}

# start_slow_server <port> <delay> → 写脚本、启动、返回 PID
start_slow_server() {
  local port="$1" delay="$2"
  local srvfile
  srvfile="$(mktemp -t t2srv.XXXXXX.py)"
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
  SRV_FILES+=("${srvfile}")
  python3 "${srvfile}" >/dev/null 2>&1 &
  local pid=$!
  SRV_PIDS+=("${pid}")
  echo "${pid}"
}

wait_port() {
  local port="$1" max="${2:-30}"
  local _
  for _ in $(seq 1 "${max}"); do
    python3 -c "import socket,sys
s=socket.socket(); s.settimeout(0.3)
try: s.connect(('127.0.0.1',${port})); sys.exit(0)
except OSError: sys.exit(1)" 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}

# 提取新函数
NEW_FUNC="$(awk '/^wait_for_prometheus_ready\(\)/,/^}/' "${PROM_SRC}")"

run_scenario() {
  local label="$1" func_src="$2" expected_rc="$3"
  echo "=========================================================="
  echo "  ${label}  (expected_rc=${expected_rc})"
  echo "=========================================================="
  PORT="${PORT}" eval "${func_src}"
  export PORT WAIT_PROM_READY_TIMEOUT=2 WAIT_CURL_MAX_TIMEOUT=5
  PORT="${PORT}" \
    wait_for_prometheus_ready >/tmp/t2-stdout 2>/tmp/t2-stderr
  local rc=$?
  echo "  RC=${rc}"
  echo "  STDOUT=|$(cat /tmp/t2-stdout 2>/dev/null || echo '<missing>')|"
  echo "  STDERR=|$(cat /tmp/t2-stderr 2>/dev/null || echo '<missing>')|"

  local fail=0
  if [[ "${rc}" != "${expected_rc}" ]]; then
    echo "  ASSERT ${label}.rc=${rc} ✗ expected ${expected_rc}"
    fail=1
  else
    echo "  ASSERT ${label}.rc=${rc} ✓"
  fi
  return "${fail}"
}

PORT=$(pick_port)
SRV=$(start_slow_server "${PORT}" 2.5)
wait_port "${PORT}" 15 || { echo "FATAL: server didn't start"; exit 99; }

results_total=0

# OLD function
run_scenario "OLD (v6r2, buggy)" "$(cat "${OLD_FUNC_FILE}")" "0" || results_total=$((results_total+1))

# NEW function
run_scenario "NEW (v6r3, fixed)" "${NEW_FUNC}" "1" || results_total=$((results_total+1))

# 同时检查 NEW 必须 stderr 含 FAIL
NEW_STDERR="$(cat /tmp/t2-stderr 2>/dev/null || true)"
if [[ "${NEW_STDERR}" != *"FAIL"* ]]; then
  echo "ASSERT NEW.stderr_contains_FAIL ✗ (got: ${NEW_STDERR})"
  results_total=$((results_total+1))
else
  echo "ASSERT NEW.stderr_contains_FAIL ✓"
fi

# 重新跑 OLD 一次保存 stdout 用于 "after" 检测
PORT="${PORT}" eval "$(cat "${OLD_FUNC_FILE}")"
export PORT WAIT_PROM_READY_TIMEOUT=2 WAIT_CURL_MAX_TIMEOUT=5
PORT="${PORT}" wait_for_prometheus_ready >/tmp/old-stdout 2>/tmp/old-stderr
OLD_STDOUT="$(cat /tmp/old-stdout 2>/dev/null || true)"
if [[ "${OLD_STDOUT}" == *"after"* ]]; then
  echo "ASSERT OLD.stdout_contains_after ✓ (proves BUG: elapsed stale)"
else
  echo "ASSERT OLD.stdout_contains_after ✗ (got: ${OLD_STDOUT})"
  results_total=$((results_total+1))
fi

# 总结
echo
echo "=========================================================="
echo "REGRESSION RESULTS"
echo "=========================================================="
echo "  results_total=${results_total}  (must be 0 for regression closed)"

if [[ "${results_total}" -gt 0 ]]; then
  echo "TEST_SCRIPT_RC=1  ← regression NOT closed"
  exit 1
fi
echo "TEST_SCRIPT_RC=0  ← regression closed"
exit 0
