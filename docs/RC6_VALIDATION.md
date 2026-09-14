# v6r4-RC6 validation record

Validation date: 2026-09-13

## First-install/security gates

- Missing component root classified as creatable: PASS.
- First install safely creates missing component root: PASS.
- Created component root is a real directory: PASS.
- Nested instance state is created under the component root: PASS.
- Component-root symlink is rejected: PASS.
- External symlink target remains unchanged: PASS.
- Missing parent hierarchy is not implicitly recursively created: PASS.
- RC5 state-root / instance-state / ownership / Grafana symlink defenses remain PASS.
- RC6 state/path security test: **22/22 PASS**.

## Regression gates

- Active shell syntax: PASS.
- RC6 install logic: **17/17 PASS**.
- Uninstall state cleanup: **16/16 PASS**.
- Installer UX contract: **7/7 PASS**.
- Self-contained/sibling-common poisoning: **7/7 PASS**.
- Sub-second readiness regression: PASS.
- Stale deadline regression: PASS.
- Interrupt cleanup: PASS.
- Production installer count: exactly seven.
- ShellCheck: SKIP in current build environment because ShellCheck is not installed.

## Linux acceptance required

RC6 must be tested on all three project validation platforms: Debian 12, openSUSE 15 and Kylin V10 SP3. Clean first install and symlink fail-closed behavior are mandatory on each platform before Freeze Candidate.
