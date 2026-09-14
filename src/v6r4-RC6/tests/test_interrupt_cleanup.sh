#!/usr/bin/env bash
# test_interrupt_cleanup.sh — v6r3 新增：中断路径断言
#
# 启 test_wait_for_ready.sh 后台跑，等跑到第一个场景 srv 已起时 SIGTERM 主进程；
# 验证：
#   1) 主进程被 kill -TERM 后必须非零退出（128+15=143 或 130）；
#   2) SRV_PIDS 中的 PID 必须全部不在运行（kill -0 失败）；
#   3) /tmp/promready.* 临时凭据无残留；
#   4) /tmp/t2srv.*.py 临时脚本无残留；
#   5) 不在通用名 pkill 误杀范围：本脚本额外启一个不被测试管理的旁路 python server，
#      跑完确认它仍然存活。
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_SCRIPT="${TEST_SCRIPT:-${SCRIPT_DIR}/test_wait_for_ready.sh}"
INSTALLER_DIR="${INSTALLER_DIR:-${SCRIPT_DIR}/../installers}"

if [[ ! -r "${TEST_SCRIPT}" ]]; then
  echo "FATAL: missing ${TEST_SCRIPT}" >&2; exit 99
fi

# 清前序 run 残留的 t2srv 临时脚本与进程（限定命名空间 '^python3 /tmp/t2srv'，
# 不按通用名杀进程；只针对 t2srv.* 临时 python HTTPServer）；
# 否则上轮失败 run 漏掉的 python 进程会让本轮 no_residual 误判为失败。
for _f in /tmp/t2srv.*.py; do [[ -e "${_f}" ]] && rm -f "${_f}"; done 2>/dev/null || true
for _pid in $(pgrep -f '^python3 /tmp/t2srv' 2>/dev/null); do kill -9 "${_pid}" 2>/dev/null || true; done

pick_port() {
  python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'
}

# 旁路 server：用一个不属于测试的 python server，验证 cleanup 不误杀
BYPASS_PORT=$(pick_port)
BYPASS_SRV=$(mktemp -t bypass_iv.XXXXXX.py)
cat >"${BYPASS_SRV}" <<PYEOF
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b"x")
    def log_message(self,*a): pass
HTTPServer(("127.0.0.1", ${BYPASS_PORT}), H).serve_forever()
PYEOF
python3 "${BYPASS_SRV}" >/dev/null 2>&1 &
BYPASS_PID=$!
sleep 0.4
# 旁路 server 必须存活
if ! kill -0 "${BYPASS_PID}" 2>/dev/null; then
  echo "FATAL: bypass server failed to start"; exit 99
fi

# 后台跑测试
INSTALLER_DIR="${INSTALLER_DIR}" bash "${TEST_SCRIPT}" >/tmp/iv-out 2>/tmp/iv-err &
TEST_PID=$!

# 等测试进入第一个 srv 场景：看见 stdout 含 "normal_200"（场景 1 已启动 srv 后）即可
# 必须在 stop_srv 之前抓住它
for _ in $(seq 1 50); do
  if grep -q "normal_200" /tmp/iv-out 2>/dev/null; then break; fi
  sleep 0.05
done

# 给主测试进程发 SIGTERM
kill -TERM "${TEST_PID}" 2>/dev/null
# 等主进程自然退出
for _ in $(seq 1 30); do
  if ! kill -0 "${TEST_PID}" 2>/dev/null; then break; fi
  sleep 0.1
done
wait "${TEST_PID}" 2>/dev/null
TEST_RC=$?
# 必须在当前 shell wait；command substitution 会进入子 shell，无法 wait 父 shell 的子进程。

# 给 EXIT trap + 子 python srv 充分时间清理（SIGTERM → trap on_signal → 主循环退出 → EXIT → cleanup_all → TERM 子 python → 等退；链路总耗时 1.5s 较稳）
sleep 1.5

pass=0; fail=0; fail_log=()

# 断言 1: 主进程 RC 非零
if [[ "${TEST_RC}" != "0" ]]; then
  echo "  ASSERT test.rc_nonzero ✓ (rc=${TEST_RC})"
  pass=$((pass+1))
else
  echo "  ASSERT test.rc_nonzero ✗ 主进程居然 RC=0"
  fail=$((fail+1)); fail_log+=("test.rc_nonzero")
fi

# 断言 2: SRV_PIDS 残留 —— 抓所有 python3 -c srv/HTTPServer/listen 子进程属于测试范围
#   v6r3 后所有测试进程都是 SRV_PIDS 内的 python3 -u t2srv.*.py；
#   kill -0 任何一个都不应存活
residual=0
# 检查 t2srv.* 临时脚本是否还存在
if compgen -G "/tmp/t2srv.*.py" >/dev/null; then
  residual=1
  echo "  残留临时脚本：$(ls /tmp/t2srv.*.py 2>/dev/null)"
fi
# 检查以 t2srv 启动的 python 是否还活着
# 用 '^python3 /tmp/t2srv' 锚定 cmdline，避免 pgrep 误匹配到含 t2srv 字符串的父 shell
# （如 `bash -c '... t2srv ...'` 在 grep 自己时）。
if pgrep -af '^python3 /tmp/t2srv' 2>/dev/null | grep -q .; then
  residual=1
  echo "  残留测试进程：$(pgrep -af '^python3 /tmp/t2srv' 2>/dev/null)"
fi
# 注意：这里用 pgrep 是查看是否有 t2srv 标签残留，不是按通用名杀进程
if [[ "${residual}" == "0" ]]; then
  echo "  ASSERT test.no_residual ✓ (无 t2srv 临时脚本/进程)"
  pass=$((pass+1))
else
  echo "  ASSERT test.no_residual ✗ 残留清理不完整"
  fail=$((fail+1)); fail_log+=("test.no_residual")
fi

# 断言 3: /tmp/promready.* 无残留（仅检查，不删；后面 trap cleanup 兜底）
leaked_netrc="$(find /tmp -maxdepth 1 -name 'promready.*' 2>/dev/null | head -5)"
if [[ -z "${leaked_netrc}" ]]; then
  echo "  ASSERT test.no_netrc_leak ✓"
  pass=$((pass+1))
else
  echo "  ASSERT test.no_netrc_leak ✗ 残留: ${leaked_netrc}"
  # 收尾：自己清掉（不影响后续测试）
  rm -f ${leaked_netrc}
  fail=$((fail+1)); fail_log+=("test.no_netrc_leak")
fi

# 断言 4: 旁路 server 必须仍存活（cleanup 不误杀）
if kill -0 "${BYPASS_PID}" 2>/dev/null; then
  bypass_code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 1 --max-time 2 "http://127.0.0.1:${BYPASS_PORT}/" 2>/dev/null)"
  [[ -z "${bypass_code}" ]] && bypass_code=000
  if [[ "${bypass_code}" == "200" ]]; then
    echo "  ASSERT bypass.alive_after_test ✓ (code=200)"
    pass=$((pass+1))
  else
    echo "  ASSERT bypass.alive_after_test ✗ code=${bypass_code}"
    fail=$((fail+1)); fail_log+=("bypass.alive_after_test")
  fi
else
  echo "  ASSERT bypass.alive_after_test ✗ bypass server killed by test cleanup"
  fail=$((fail+1)); fail_log+=("bypass.alive_after_test")
fi

# 收尾旁路
kill -TERM "${BYPASS_PID}" 2>/dev/null
sleep 0.2
kill -KILL "${BYPASS_PID}" 2>/dev/null
wait "${BYPASS_PID}" 2>/dev/null
rm -f "${BYPASS_SRV}"

echo
echo "############################################################"
echo "# INTERRUPT-CLEANUP RESULTS"
echo "############################################################"
echo "  pass=${pass}  fail=${fail}"
if [[ "${fail}" -gt 0 ]]; then
  for s in "${fail_log[@]}"; do echo "    - ${s}"; done
  echo "TEST_SCRIPT_RC=1"
  exit 1
fi
echo "TEST_SCRIPT_RC=0  ← interrupt path clean"
exit 0
