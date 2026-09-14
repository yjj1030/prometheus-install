#!/usr/bin/env bash
# ==============================================================================
# test_subsecond_timing.sh — 亚秒计时回归测试（v6r3 复核修正）
#
# 目的：
#   验证 readiness 函数的 ms 计时正确性，特别是 /proc/uptime 换算。
#   必须能发现错误的换算（如 `(a[1]*1000)+(int(a[2])/10)` 导致 135.56 → 135005ms）。
#
# 设计：
#   - server 延迟约 0.35s 返回 200，deadline 放宽到 5s（不依赖窄窗口）
#   - reported "after X.Xs" 必须与实际 wall-clock 耗时接近（误差 < 250ms）
#   - 反向断言：实际几百 ms 时 reported 不得为 "0.0s"（错误换算特征）
#   - 动态空闲端口；启动 server 后 wait_port 确认就绪
#   - 临时文件与 server 统一一个 EXIT cleanup（trap 不互相覆盖）
#
# 用法：
#   bash test_subsecond_timing.sh
#
# 退出码：0=PASS；1=FAIL
# ==============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_DIR="${INSTALLER_DIR:-${SCRIPT_DIR}/../installers}"
INSTALLER="${INSTALLER_DIR}/prometheus_installer_v6.0.0.sh"

if [[ ! -f "${INSTALLER}" ]]; then
  echo "[FAIL] installer not found: ${INSTALLER}" >&2
  exit 1
fi

pick_port() {
  python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'
}

wait_port() {
  local port="$1" max="${2:-30}" _
  for _ in $(seq 1 "${max}"); do
    python3 -c "import socket,sys
s=socket.socket(); s.settimeout(0.3)
try: s.connect(('127.0.0.1',${port})); sys.exit(0)
except OSError: sys.exit(1)" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

# ---------- 统一清理（单一 EXIT trap，不互相覆盖） ----------
FUNC_FILE=""
SRV_FILE=""
SRV_PID=""
cleanup() {
  [[ -n "${SRV_PID}" ]] && kill -TERM "${SRV_PID}" 2>/dev/null || true
  [[ -n "${SRV_PID}" ]] && { sleep 0.2; kill -KILL "${SRV_PID}" 2>/dev/null || true; wait "${SRV_PID}" 2>/dev/null || true; }
  [[ -n "${SRV_FILE}" ]] && rm -f "${SRV_FILE}"
  [[ -n "${FUNC_FILE}" ]] && rm -f "${FUNC_FILE}"
}
trap cleanup EXIT

# 提取 wait_for_prometheus_ready 函数
FUNC_FILE="$(mktemp -t wait_func.XXXXXX)"
awk '/^wait_for_prometheus_ready\(\) \{/,/^\}/' "${INSTALLER}" > "${FUNC_FILE}"
if [[ ! -s "${FUNC_FILE}" ]]; then
  echo "[FAIL] could not extract wait_for_prometheus_ready from ${INSTALLER}" >&2
  exit 1
fi

# 动态端口 + 延迟 0.35s 的 200 server
PORT="$(pick_port)"
SRV_FILE="$(mktemp -t subsec_srv.XXXXXX.py)"
cat >"${SRV_FILE}" <<PYEOF
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        time.sleep(0.35)
        self.send_response(200); self.end_headers(); self.wfile.write(b"OK")
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", ${PORT}), H).serve_forever()
PYEOF
python3 "${SRV_FILE}" >/dev/null 2>&1 &
SRV_PID=$!

if ! wait_port "${PORT}" 20; then
  echo "[FAIL] test server did not become ready on port ${PORT}" >&2
  exit 1
fi

# deadline 放宽到 5s：测试重点是 reported 与实际一致，不是窄窗口
export PORT
export WAIT_PROM_READY_TIMEOUT=5
export WAIT_CURL_CONNECT_TIMEOUT=1
export WAIT_CURL_MAX_TIMEOUT=3

# shellcheck disable=SC1090
source "${FUNC_FILE}"

echo "[TEST] sub-second timing: server delays 0.35s, deadline=5s, port=${PORT}"
start_ns=$(date +%s%N)
OUTPUT=$(wait_for_prometheus_ready 2>&1)
RC=$?
end_ns=$(date +%s%N)
actual_ms=$(( (end_ns - start_ns) / 1000000 ))

echo "[TEST] RC=${RC}"
echo "[TEST] actual wall-clock elapsed: ${actual_ms}ms"
echo "[TEST] output: ${OUTPUT}"

if [[ ${RC} -ne 0 ]]; then
  echo "[FAIL] expected RC=0, got ${RC}"
  exit 1
fi

if [[ "${OUTPUT}" =~ after[[:space:]]+([0-9]+\.[0-9]+)s ]]; then
  reported_s="${BASH_REMATCH[1]}"
  reported_ms=$(awk -v s="${reported_s}" 'BEGIN{printf "%.0f", s * 1000}')
  echo "[TEST] reported elapsed: ${reported_s}s (${reported_ms}ms)"
else
  echo "[FAIL] output does not contain 'after X.Xs' pattern"
  exit 1
fi

# 反向断言：实际几百 ms 时 reported 不得为 0.0s（错误换算特征：135.56→135005ms 会让
# elapsed 看起来只有几 ms，输出 after 0.0s）
if [[ ${actual_ms} -ge 200 && "${reported_s}" == "0.0" ]]; then
  echo "[FAIL] actual=${actual_ms}ms but reported=0.0s —— /proc/uptime 换算错误特征"
  exit 1
fi

# 主断言：reported 与实际 wall-clock 误差 < 250ms
diff=$(( actual_ms > reported_ms ? actual_ms - reported_ms : reported_ms - actual_ms ))
if [[ ${diff} -ge 250 ]]; then
  echo "[FAIL] reported ${reported_ms}ms vs actual ${actual_ms}ms differ by ${diff}ms (>= 250ms)"
  exit 1
fi

echo "[PASS] sub-second timing correct (reported=${reported_s}s, actual=${actual_ms}ms, diff=${diff}ms)"
exit 0
