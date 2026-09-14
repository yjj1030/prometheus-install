# v6r4-RC4 targeted Linux UAT

RC4 is a narrow follow-up to RC3. Do not repeat unrelated architecture changes while testing.

## A. Fast regression for all seven installers

For each production installer:

- `bash -n`;
- `--help`;
- main-menu Enter/q/invalid-input behavior;
- self-contained execution with no sibling `common/platform.sh`.

## B. State-cleanup acceptance

For Prometheus, VictoriaMetrics, Alertmanager, Node Exporter, Blackbox Exporter and SNMP Exporter:

1. install a dedicated test instance;
2. confirm its `state/<component>-<port>/access-request.md` exists when applicable;
3. create/retain at least one sibling instance-state directory or sentinel;
4. run preserve uninstall and verify the selected instance state remains;
5. reinstall as required;
6. run full uninstall;
7. verify the selected `state/<component>-<port>/` directory is gone;
8. verify sibling state and `state/ownership.tsv` remain;
9. verify no component root or unrelated path was deleted.

Any deletion outside the selected instance state is P0.

## C. Grafana completion

RC3 Grafana full lifecycle was blocked by external download throughput. RC4 must complete:

`install -> status -> probe -> preserve uninstall -> reinstall -> full uninstall`

Prefer a pre-staged, SHA256-verified official Grafana tarball and the installer's local-file mode. The purpose is to test installer lifecycle, not public Internet throughput.

Verify that Grafana does not create or depend on:

- `/var/cache/grafana_installer`;
- `/var/lib/grafana/dashboards`.

## D. Verdict

RC4 may become a freeze candidate only when targeted Linux UAT returns **PASS** with no P0/P1 product defect.
