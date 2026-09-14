# Prometheus Monitoring Installers

Current baseline: **v6r4-RC7** — cross-distro first-install regression release candidate.

This repository contains production-oriented Linux installers for seven monitoring components, active source/tests, and archived historical delivery material.

## Production installers

Use only the files under [`installers/`](installers/) on target servers:

- Alertmanager
- Blackbox Exporter
- Grafana
- Node Exporter
- Prometheus
- SNMP Exporter
- VictoriaMetrics single-node

Each production installer is a **single self-contained shell script**. No sibling `common/platform.sh` is required or loaded at runtime.

## Repository layout

- `installers/` — seven self-contained production/UAT installer scripts only.
- `src/v6r4-RC7/` — active source, shared build-time `common/platform.sh`, configs and tests.
- `tools/` — supporting tools such as node discovery.
- `docs/` — current RC7 baseline, validation and targeted UAT instructions.
- `releases/v6r4-RC7/` — RC7 ZIP and SHA256.
- `archive/` — historical snapshots; never treat archived files as the current baseline.

## RC7 scope

RC5 closed install-side symlink/path-escape writes, but cross-platform Linux UAT found a P0 clean-first-install regression when `/usr/local/<component>` did not yet exist.

RC7 is deliberately minimal: safely create a missing component root while preserving RC5 fail-closed symlink/path defenses and RC4 uninstall state cleanup.

RC7 is **not GA**. Freeze Candidate requires targeted UAT on Debian 12, openSUSE 15 and Kylin V10 SP3. See [`docs/RC7_BASELINE.md`](docs/RC7_BASELINE.md) and [`docs/RC7_SERVER_UAT.md`](docs/RC7_SERVER_UAT.md).
