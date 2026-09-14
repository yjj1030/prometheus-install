# v6r4-RC4 validation record

Validation date: 2026-09-13

## RC4-specific gates

- Instance-state cleanup unit/safety test: **16/16 PASS**.
- Selected state directory is removed in full-uninstall semantics: PASS.
- Sibling instance state is preserved: PASS.
- Shared `state/ownership.tsv` is preserved: PASS.
- Deletion of shared `state/` root is rejected: PASS.
- Deletion of component root is rejected: PASS.
- Deletion outside the component root is rejected: PASS.
- Six shared-state installers invoke instance-state cleanup only on the full-uninstall branch: PASS.
- Grafana remains instance-local and does not acquire unnecessary shared-state deletion logic: PASS.

## Regression gates

- Active installer shell syntax: PASS.
- RC4 install logic contract: **17/17 PASS**.
- Installer UX contract: **7/7 PASS**.
- Self-contained/sibling-common poisoning test: **7/7 PASS**.
- Sub-second readiness regression: PASS.
- Stale elapsed/deadline regression: PASS.
- Interrupt cleanup: PASS.
- No default `/var/cache` component cache in active installer shell: PASS.
- No hard-coded project-forbidden network ranges in active installer shell: PASS.
- VictoriaMetrics single-node has no 8480/8481 legacy port logic: PASS.

`shellcheck` is not installed in the current build environment, therefore the shellcheck gate is recorded as SKIP rather than falsely reported as PASS.

## Readiness scope

RC4 does not modify readiness logic. The RC3 Prometheus/Grafana readiness matrix already passed 12/12 before Linux UAT and is inherited without code changes in that path.

## Remaining Linux acceptance

RC4 still requires targeted Linux UAT for:

1. full uninstall state cleanup on representative shared-state components, preferably all six;
2. preserve-mode confirmation that instance state remains;
3. complete Grafana install/status/probe/preserve-uninstall/reinstall/full-uninstall cycle using a verified local official tarball if public download throughput is inadequate.
