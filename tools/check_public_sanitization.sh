#!/usr/bin/env bash
set -euo pipefail

# Fail when tracked text or release ZIP content contains values that should not
# be published. RFC 5737 documentation ranges, loopback, wildcard listeners,
# protocol OIDs, integrity checksums, and application-defined Grafana UIDs are
# intentionally allowed.

repo_root="$(git rev-parse --show-toplevel)"
cd "${repo_root}"

private_ipv4='(^|[^0-9])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}|169\.254\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3})([^0-9]|$)'
local_path='/(mnt/data|home/[^/[:space:]]+|Users/[^/[:space:]]+|workspace/[^/[:space:]]+)/'
unsafe_snmp='community:[[:space:]]*(public|private|prom_snmp_v2c)([[:space:]]|$)'

scan_tree() {
  local target="$1"
  local failed=0

  if LC_ALL=C grep -IRnE --exclude-dir=.git --exclude='check_public_sanitization.sh' \
      "${private_ipv4}" "${target}"; then
    echo "ERROR: found private, carrier-grade NAT, or link-local IPv4 data" >&2
    failed=1
  fi
  if LC_ALL=C grep -IRnE --exclude-dir=.git --exclude='check_public_sanitization.sh' \
      "${local_path}" "${target}"; then
    echo "ERROR: found workstation or build-environment absolute path" >&2
    failed=1
  fi
  if LC_ALL=C grep -IRnE --exclude-dir=.git --exclude='check_public_sanitization.sh' \
      "${unsafe_snmp}" "${target}"; then
    echo "ERROR: found a fixed or well-known SNMP community" >&2
    failed=1
  fi

  return "${failed}"
}

scan_tree .

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "${tmp_dir}"' EXIT

while IFS= read -r -d '' archive; do
  extract_dir="${tmp_dir}/$(basename "${archive}" .zip)"
  mkdir -p "${extract_dir}"
  unzip -qq "${archive}" -d "${extract_dir}"
  scan_tree "${extract_dir}"
done < <(find releases -type f -name '*.zip' -print0 2>/dev/null)

echo "Public-repository sanitization check passed."
