#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
promtool_bin="${PROMTOOL:-promtool}"
amtool_bin="${AMTOOL:-amtool}"
alertmanager_bin="${ALERTMANAGER:-alertmanager}"
python3 tools/build_alert_rules.py --check
python3 tools/check_alert_contracts.py
mapfile -t catalog_files < <(find catalog -name '*.yml' -type f | sort)
"${promtool_bin}" check rules "${catalog_files[@]}"
for profile in production test-recommended test-memory-oom-only; do
  "${promtool_bin}" check rules scenarios/sk-91/"${profile}"/*.yml
done
"${promtool_bin}" test rules tests/alert-rules/*.test.yml
"${amtool_bin}" check-config scenarios/sk-91/alertmanager.example.yml
for mapping in 'warning planned' 'critical oncall' 'emergency urgent' 'info record-only'; do
  read -r severity receiver <<< "${mapping}"
  "${amtool_bin}" config routes test --config.file=scenarios/sk-91/alertmanager.example.yml \
    --verify.receivers="${receiver}" severity="${severity}" alertname=Example
done
"${amtool_bin}" config routes test --config.file=scenarios/sk-91/alertmanager.example.yml \
  --verify.receivers=deadman alertname=Watchdog severity=none
"${amtool_bin}" config routes test --config.file=scenarios/sk-91/alertmanager.example.yml \
  --verify.receivers=review alertname=Unknown severity=unknown
python3 tests/alertmanager_integration.py --alertmanager="${alertmanager_bin}"
