# v6r4-RC5 baseline

Date: 2026-09-13
Status: **Release Candidate / security targeted Linux UAT**

## Decision basis

RC4 targeted Linux UAT passed its stated functional scope: six shared-state components correctly preserved instance state in preserve mode and removed only the selected instance state in full-uninstall mode; Grafana completed its full lifecycle; Prometheus retention, Alertmanager single-node behavior, VictoriaMetrics port model, self-containment and firewall behavior also passed.

During RC4 UAT, a new P0 security finding was discovered: if `${INSTALL_ROOT}/state` is pre-created as a symbolic link, install-side state generation could follow that link and write installer-owned files outside the component root. A release candidate cannot be frozen with a known path-escape write primitive, even when the finding was outside RC4's original stated scope.

RC5 exists solely to close that finding.

## RC5 change scope

RC5 adds fail-closed validation for installer-owned state paths before create/read/update operations:

- reject symbolic links in the state path chain below the component root;
- reject real paths that escape the component root;
- reject non-directory path components;
- protect `acl_emit` / `access-request.md` writes;
- protect `ownership.tsv` registration, lookup and removal;
- retain RC4 full-uninstall state cleanup safeguards.

The same generic state-path guard also protects Grafana's instance-local `state/` path without changing Grafana lifecycle semantics.

## Explicit non-goals

RC5 does not change component versions, ports, retention, download policy, menu semantics, firewall defaults, Status/Probe behavior, VictoriaMetrics topology, Alertmanager HA defaults or production self-containment.
