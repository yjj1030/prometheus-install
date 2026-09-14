# v6r4-RC3 baseline

Date: 2026-09-13
Status: **Release Candidate / server UAT**

## Scope

The supported production installer set is exactly seven components:

1. Prometheus
2. VictoriaMetrics single-node
3. Alertmanager
4. Grafana
5. Node Exporter
6. Blackbox Exporter
7. SNMP Exporter

cAdvisor, vmalert and vmauth are not part of the current installer baseline. Their historical material is retained only under `archive/`.

## Directory policy

For each component, persistent installer-managed files must stay under `/usr/local/<component>/...`, except operating-system integration files such as systemd units and normal system logs/journal facilities.

Examples:

- Grafana cache: `/usr/local/grafana/cache/`
- Prometheus instances: `/usr/local/prometheus/prometheus-<port>/`
- Alertmanager instances: `/usr/local/alertmanager/alertmanager-<port>/`
- VictoriaMetrics data: inside the selected instance root

The installer must not create component cache/data/config under `/var/cache`, `/var/lib`, `/etc/<component>` or `/opt/<component>` by default.

## Runtime self-containment

`src/v6r4-RC3/installers/common/platform.sh` is a source/build-time library. `tests/build_self_contained.sh` embeds it into the production scripts.

The seven scripts in repository-root `installers/`:

- do not require `common/platform.sh` beside them;
- do not prefer or override themselves from a sibling `common/platform.sh`;
- are the only files intended to be copied to ordinary target servers.

## Download policy

- Cache is kept under the component `/usr/local/<component>/cache/` hierarchy.
- `INTERNAL_MIRROR` has no hard-coded default IP or network.
- If no cache and no mirror are configured, the interactive installer asks for the internal mirror URL or another explicit source.
- Internal-mirror failure never silently falls back to the public Internet.
- Internet access must be explicitly selected by the operator.

## Port policy

A new installation may not reuse an already-listening TCP port.

When the proposed/default port is occupied, the installer:

1. reports the conflict;
2. computes a nearby free recommended port;
3. offers the recommendation as the next default;
4. still permits a valid user-specified free port.

Alertmanager additionally prevents Web and HA cluster ports from colliding with each other.

## Installation transaction boundary

Before the final explicit install choice, the wizard is read-only. It must not create the component root, cache, state, users, units or downloaded files.

The final action is a numbered menu rather than an ambiguous `[Y/n/q]` prompt:

1. start installation (default)
2. return and edit parameters
3. cancel and return to main menu
q. exit installer

## Uninstall policy

For installer-managed instances, uninstall uses a numbered menu:

1. full uninstall (default): remove the service/unit and the selected instance installation directory
2. remove service/unit but retain the selected instance directory
3. cancel and return to main menu
q. exit installer

Safety rules prevent deleting the component root itself or paths outside the component root.

For external/package-managed units, the installer uses a separate conservative flow and does not blindly remove package-owned units or arbitrary paths.

## Version baseline

RC3 pins versions deliberately rather than blindly following newest releases. Prometheus 3.13.2, Node Exporter 1.12.1, Blackbox Exporter 0.28.0, Alertmanager 0.34.0 and Grafana OSS 13.2.1 are validated baseline versions. VictoriaMetrics is raised to 1.151.0 because that release contains a relevant HTTP Basic Auth security fix. SNMP Exporter remains intentionally pinned at 0.28.0 pending template/generator compatibility validation against newer 0.30.x releases.

Grafana 13.2.1 default standalone download is pinned to build `33191028959` and its official SHA256. Custom Grafana versions require the operator to verify the matching upstream build id and checksum.
