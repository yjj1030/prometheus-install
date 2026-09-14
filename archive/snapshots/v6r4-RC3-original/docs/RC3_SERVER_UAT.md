# v6r4-RC3 server UAT

Run first on a non-production or rebuildable Linux host. Do not overwrite a production monitoring instance before the same component has passed UAT.

## Per-component acceptance

For each of the seven installers verify:

1. Main-menu Enter exits; `q` exits.
2. Enter inside the install wizard accepts the displayed default.
3. Cancel before final install confirmation creates no component root/state/cache/unit.
4. Download source and destination are displayed before installation.
5. Occupied default port is rejected and a free replacement is proposed.
6. Installation succeeds and systemd service becomes active.
7. `status` works.
8. `probe` confirms process/listener/metrics or health endpoint as applicable.
9. `reload` behaves safely for the component.
10. After uninstall stops/releases the listener, reinstalling the desired port succeeds; an actively occupied port is never reused.
11. Managed uninstall option 1 removes the selected instance directory.
12. Managed uninstall option 2 retains the selected instance directory.
13. An external/manual systemd unit is discovered without corrupt package/ExecStart display fields.
14. Package-managed units are never blindly deleted from `/usr/lib/systemd/system` or `/lib/systemd/system`.

## Alertmanager

Default is single-node mode. Port 9094 (or another cluster port) must not listen unless HA is explicitly enabled.

## Prometheus

`center` and `edge` are project deployment roles, not upstream Prometheus concepts. Role selection does not silently force a long retention period or localhost vmauth endpoint.

## Evidence to retain

For every tested instance retain:

- OS release and architecture
- installer filename/SHA256
- chosen parameters
- `systemctl status`
- `ss -lntup` relevant lines
- probe output
- uninstall result
- resulting filesystem check

Do not include passwords, tokens or Basic Auth credentials in UAT evidence.
