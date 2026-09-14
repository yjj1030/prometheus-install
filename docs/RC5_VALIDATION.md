# v6r4-RC5 validation record

Validation date: 2026-09-13

## Security-specific gates

- Normal installer-owned state directory creation: PASS.
- `state` root symlink is rejected before ACL state write: PASS.
- External symlink target remains unchanged: PASS.
- `ownership_register` rejects symlinked state root: PASS.
- Instance-state symlink is rejected: PASS.
- Grafana instance-local state works on a normal directory: PASS.
- Symlinked Grafana instance root is rejected for state creation: PASS.
- `ownership_belongs_to` fails closed on symlinked state root: PASS.
- `ownership_forget` rejects symlinked state root and leaves external ownership file unchanged: PASS.
- RC5 state symlink security test: **14/14 PASS**.

## Regression gates

- Active shell syntax: PASS.
- RC5 install logic contract: **17/17 PASS**.
- RC5 uninstall state cleanup: **16/16 PASS**.
- Installer UX contract: **7/7 PASS**.
- Self-contained/sibling-common poisoning test: **7/7 PASS**.
- Sub-second readiness regression: PASS.
- Stale elapsed/deadline regression: PASS.
- Interrupt cleanup: PASS.
- Production installer count: exactly seven.
- `shellcheck`: SKIP because it is not installed in the current build environment.

## Linux acceptance still required

RC5 requires a focused Linux UAT that reproduces the RC4 symlink attack precondition and confirms fail-closed behavior with no external write, followed by a normal-path installation check.
