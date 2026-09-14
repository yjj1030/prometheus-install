# v6r4-RC7 Validation

## Local gates

- `bash -n`: PASS for active source installers/common platform layer.
- RC7 Kylin/ProtectSystem regression: 14/14 PASS.
- RC6 first-install + symlink security regression: 22/22 PASS.
- RC6 uninstall state cleanup regression: 16/16 PASS.
- Installer logic regression: 17/17 PASS.
- Installer UX contract: 7/7 PASS.
- Self-contained/sibling-common poisoning: 7/7 PASS.
- Sub-second readiness regression: PASS.
- Stale elapsed regression: PASS.
- Interrupt cleanup: 4/4 PASS.
- ShellCheck: SKIP in the build environment because ShellCheck is not installed.

The aggregated long readiness matrix was not re-run to completion in this execution environment because of runner execution-time limits. RC7 does not modify readiness code; the previous passing baseline remains applicable and Linux targeted UAT remains the release gate.
