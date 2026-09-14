# v6r4-RC4 baseline

Date: 2026-09-13
Status: **Release Candidate / targeted Linux UAT**

## Decision basis

RC3 completed Linux UAT on a Debian 12 test host with the verdict **PASS WITH FIXES**. The core lifecycle passed for Prometheus, VictoriaMetrics, Alertmanager and the three exporters. Grafana full lifecycle was not completed because the external download path was too slow; its existing instance/path checks passed.

The only product defect promoted into RC4 is instance-state residue after full uninstall.

## RC4 change scope

RC4 intentionally changes only uninstall state cleanup plus release/test metadata.

For components using shared instance state:

- Prometheus
- VictoriaMetrics
- Alertmanager
- Node Exporter
- Blackbox Exporter
- SNMP Exporter

full uninstall removes:

1. the selected systemd unit;
2. the selected instance directory;
3. only `${INSTALL_ROOT}/state/<component>-<port>/` for the selected instance.

It must preserve:

- `${INSTALL_ROOT}/state/ownership.tsv`;
- sibling instance state directories;
- the component root;
- all paths outside the component root.

Grafana is unchanged because its access-request state is stored beneath the instance directory and is already removed by full instance deletion.

## Preserve uninstall

Preserve mode keeps the instance directory and instance state. RC4 must not turn preserve uninstall into a partial full uninstall.

## Production set

Exactly seven production installers are supported:

1. Prometheus
2. VictoriaMetrics single-node
3. Alertmanager
4. Grafana
5. Node Exporter
6. Blackbox Exporter
7. SNMP Exporter

The scripts in repository-root `installers/` are self-contained and must not read a sibling `common/platform.sh` at runtime.
