# v6r4-RC4 targeted change log

RC4 is intentionally small.

## Fixed

RC3 Linux UAT found that full uninstall removed the unit and instance directory but left installer-generated instance state such as:

`/usr/local/<component>/state/<component>-<port>/access-request.md`

RC4 adds a guarded `safe_remove_instance_state_dir()` helper and calls it from the full-uninstall branch of the six shared-state components.

## Not changed

- ports and port-conflict policy;
- component versions;
- download-source policy;
- Prometheus 7d/10GB default retention;
- Alertmanager default single-node behavior;
- VictoriaMetrics single-node port model;
- Grafana lifecycle logic;
- status/probe semantics;
- firewall default behavior;
- runtime self-containment model.
