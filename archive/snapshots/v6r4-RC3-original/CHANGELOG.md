# Changelog

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
