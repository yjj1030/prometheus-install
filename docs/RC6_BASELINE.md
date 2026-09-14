# v6r4-RC6 baseline

Date: 2026-09-13
Status: **Release Candidate / cross-distro first-install regression UAT**

## Decision basis

RC5 closed the install-side symlink/path-escape write primitive, but Linux UAT discovered a P0 regression on clean hosts: when `${INSTALL_ROOT}` did not yet exist, `secure_validate_dir_under_root` returned a hard failure and first install could exit without completing.

RC6 exists solely to restore safe first-install behavior without weakening RC5 fail-closed path protections.

## RC6 change scope

- a missing component root is classified as safely creatable rather than invalid;
- the secure state layer creates only the final component root, never an arbitrary missing parent hierarchy;
- a component root that already exists as a symlink or non-directory is still rejected;
- RC5 state-root, instance-state, ownership and Grafana symlink protections remain unchanged;
- RC4 full-uninstall state cleanup semantics remain unchanged.

## Explicit non-goals

No component version, default port, retention, download policy, firewall behavior, menu contract, Status/Probe behavior, VictoriaMetrics topology or Alertmanager HA default is changed.
