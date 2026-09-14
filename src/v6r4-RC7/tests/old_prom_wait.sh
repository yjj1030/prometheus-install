wait_for_prometheus_ready() {
  local code url netrc deadline start elapsed conn_to max_to
  url="http://127.0.0.1:${PORT}/-/ready"
  deadline="${WAIT_PROM_READY_TIMEOUT:-30}"
  conn_to="${WAIT_CURL_CONNECT_TIMEOUT:-2}"
  max_to="${WAIT_CURL_MAX_TIMEOUT:-5}"
  netrc=""
  if [[ -n "${AUTH_USER_OPT:-}" && -n "${auth_pass_actual:-}" ]]; then
    netrc="$(mktemp -t promready.XXXXXX)"
    chmod 0600 "${netrc}"
    printf 'machine 127.0.0.1 login %s password %s\n' \
      "${AUTH_USER_OPT}" "${auth_pass_actual}" > "${netrc}"
  fi
  # trap 兜底：函数返回 / 中断 / 错误都先清理 netrc，再退出
  trap '[[ -n "${netrc}" ]] && rm -f "${netrc}"; trap - RETURN INT TERM ERR' RETURN INT TERM ERR
  start="$(date +%s)"
  while true; do
    elapsed=$(( $(date +%s) - start ))
    if [[ "${elapsed}" -ge "${deadline}" ]]; then
      echo "[ready] FAIL: /-/ready 未在 ${deadline}s 内返回 200（last_code=${code:-000}）" >&2
      return 1
    fi
    if [[ -n "${netrc}" ]]; then
      code="$(curl --noproxy '*' --netrc-file "${netrc}" \
        --connect-timeout "${conn_to}" --max-time "${max_to}" \
        -s -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null)"
    else
      code="$(curl --noproxy '*' \
        --connect-timeout "${conn_to}" --max-time "${max_to}" \
        -s -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null)"
    fi
    # curl 超时/连接失败时 -w '%{http_code}' 输出 000 或空；统一规整为 000
    [[ -z "${code}" ]] && code=000
    if [[ "${code}" == "200" ]]; then
      echo "[ready] /-/ready=200 after ${elapsed}s"
      return 0
    fi
    # sleep 1 但避免跨过 deadline；剩余 <1s 时直接退出失败
    remaining=$(( deadline - elapsed - 1 ))
    if [[ "${remaining}" -lt 1 ]]; then
      echo "[ready] FAIL: /-/ready 未在 ${deadline}s 内返回 200（last_code=${code:-000}）" >&2
      return 1
    fi
    sleep 1
  done
}
