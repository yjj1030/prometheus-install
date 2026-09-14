# v6r4-RC2 validation record

Validation date: 2026-09-13

## Passed gates

- Current shell syntax: PASS.
- Production installer count: exactly 7; no root `installers/common/` directory.
- Rebuild from `src/v6r4-RC2`: 7/7 generated installers byte-match repository-root production installers.
- Installer UX contract: 7/7 PASS.
- Self-contained/sibling-common poisoning test: 7/7 PASS; production installers ignore sibling `common/platform.sh`.
- Sub-second readiness regression: PASS (approximately 0.35 s server delay reported as 0.4 s).
- Stale elapsed/deadline regression: PASS.
- Interrupt cleanup: PASS; no residual test server/netrc leak.
- Prometheus/Grafana readiness matrix: 12 scenarios, 12 PASS, 0 FAIL, test RC=0.
- Current installer path/network scan: PASS; no default `/var/cache` component cache and no hard-coded project-forbidden network ranges in current installer shell code.
- Deterministic current release ZIP integrity: PASS.

## Readiness matrix coverage

Prometheus and Grafana each cover:

- immediate HTTP 200;
- persistent HTTP 503;
- accepted TCP connection with no HTTP response;
- HTTP 200 arriving after the configured deadline (must fail).

Prometheus additionally covers Basic Auth temporary netrc creation/cleanup and password-leak checks.

The test harness assigns a separate ephemeral port to each scenario and enforces a harness-level hard timeout, preventing a readiness regression from hanging the acceptance job indefinitely.

## Status

These gates qualify v6r4-RC2 for real Linux server UAT. They do not constitute GA approval.
