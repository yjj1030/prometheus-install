# Changelog

## v6r4-RC7 - 2026-09-13

- Cross-distro compatibility fix after RC6 UAT on Kylin V10 SP3.
- Keep `ProtectSystem=full` for rhel-family service hardening while adding precise `ReadWritePaths=` only for runtime-writable data/storage and log directories.
- Prometheus: allow `${inst}/data` and `${inst}/logs`.
- Alertmanager: allow `${inst}/data` and `${inst}/logs`.
- VictoriaMetrics: allow `${STORAGE_PATH}` and `${inst}/logs`.
- Do not make `/usr/local` or the full component root writable.
- RC6 first-install and symlink fail-closed protections remain unchanged.

## v6r4-RC6

- Minimal follow-up to RC5 after Linux UAT found a P0 clean-first-install regression when `${INSTALL_ROOT}` was absent.
- Missing component roots are now safely creatable by the guarded state layer.
- Existing component-root symlinks/non-directories and escaping state paths remain fail-closed.
- No unrelated installer behavior changed.

## v6r4-RC5

- Security-only release candidate after RC4 targeted Linux UAT discovered a P0 install-side state-path symlink escape.
- Installer-owned state creation now rejects symlinked or escaping paths below the configured component root.
- ACL state writes and ownership registry create/read/update paths fail closed on invalid state paths.
- RC4 full-uninstall instance-state cleanup semantics remain unchanged.
- No component versions, ports, retention, firewall defaults, Status/Probe semantics or download policies changed.

## v6r4-RC4

- Targeted release candidate after RC3 Linux UAT returned `PASS WITH FIXES`.
- Full uninstall now removes only the selected instance state directory under `state/<component>-<port>/` for Prometheus, VictoriaMetrics, Alertmanager, Node Exporter, Blackbox Exporter and SNMP Exporter.
- Added deletion guards that reject the component root, shared `state/` root and paths outside the component root.
- Preserve uninstall semantics remain unchanged: instance directory and instance state are retained.
- Grafana uninstall logic is unchanged because its access-request state is already instance-local and removed with the instance directory.
- Added focused RC4 regression coverage for state cleanup and sibling-state preservation.

## v6r4-RC3

- Release-candidate hardening after RC2 self-audit.
- Removed residual Grafana provisioning path outside the instance root.
- Hardened readiness test harness with per-scenario retry and runner-file timeout execution.
- Preserved production installer runtime as seven standalone self-contained scripts.

## v6r4-RC2

- Fixed server-UAT installer lifecycle issues found after RC1.
- Moved component cache paths under `/usr/local/<component>/cache`.
- Replaced ambiguous install/uninstall confirmations with numbered choices.
- Enforced occupied-port rejection and next-free-port recommendation.
