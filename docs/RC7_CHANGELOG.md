# v6r4-RC7 Change Log

RC7 is a narrowly scoped compatibility release based on RC6 cross-distribution UAT.

## Trigger

On Kylin V10 SP3, Prometheus installed under `/usr/local/...` could not write its runtime data when the unit used `ProtectSystem=full`. The rhel-family platform path enables that hardening, and `/usr` (therefore `/usr/local`) becomes read-only inside the service namespace.

## Fix

RC7 preserves `ProtectSystem=full` and adds only the required writable paths:

- Prometheus: instance `data` and `logs`.
- Alertmanager: instance `data` and `logs`.
- VictoriaMetrics: configured storage path and instance `logs`.

RC7 does **not** make `/usr/local` or a whole component root writable.

## Non-goals

No changes to ports, retention defaults, installer menus, download logic, firewall behavior, state cleanup semantics, symlink/path-escape defenses, or Grafana/Exporter runtime design.
