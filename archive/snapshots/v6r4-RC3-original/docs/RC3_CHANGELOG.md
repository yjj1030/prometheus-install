# v6r4-RC3 change log

RC3 is based on v6r4-RC2 plus independent release-candidate audit findings and real Linux server-UAT feedback.

## Installer lifecycle changes

- Moved installer download caches from `/var/cache/<component>_installer` to `/usr/local/<component>/cache`.
- Removed remaining current-baseline persistent-path defaults outside the component root, including Grafana dashboard provisioning and VictoriaMetrics data defaults.
- Replaced final `[Y/n/q]` install confirmation with a numbered action menu.
- Added occupied-port rejection and next-free-port recommendation across all seven installers.
- Changed managed uninstall default to remove the selected instance installation directory.
- Added explicit 1/2/3/q uninstall choices.
- Fixed systemd instance discovery field parsing so an empty package field cannot shift `ExecStart` data into the package column.
- Improved safe handling of non-installer and package-managed systemd services.
- Removed hard-coded internal mirror IPs; internal mirror URL is environment/operator supplied.
- Kept VictoriaMetrics single-node semantics on its real HTTP port rather than exposing unused cluster-style insert/select ports.

## Self-contained build changes

- Production installer scripts embed the platform library permanently.
- Production scripts never load a sibling `common/platform.sh`.
- Root `installers/` contains exactly seven scripts and no `common/` directory.

## Test-harness changes

- Readiness matrix now gives each scenario a separate ephemeral port.
- Readiness calls have a harness-level hard timeout so a regression cannot hang the whole acceptance run indefinitely.
- Prometheus/Grafana readiness matrix covers 200, persistent 503, accepted-but-no-response, response-after-deadline, and Prometheus Basic Auth/netrc cleanup.

## Independent RC3 audit fixes

- Split managed `status` and real `probe` behavior; menu item 3 now performs service/PID/port/HTTP health checks instead of aliasing `status`.
- Added non-interactive CLI occupied-port gates so `install --port` cannot bypass the wizard check.
- Corrected Grafana 13.2.1 official standalone URL to the current version/build-id path and pinned the official SHA256 for the default build.
- Fixed Grafana dashboard provisioning so the generated path expands to the actual instance root and the dashboard directory is created before start.
- Removed an invalid JSON header from the current Grafana dashboard definition.
- Separated edge-active Prometheus rules from center/reference/deprecated material to prevent wildcard duplicate evaluation.
- Aligned production memory alerts to non-overlapping 96% / 98% / 99% thresholds.
- Replaced sticky cumulative swap/TSDB failure alerts with time-window `increase()` expressions.
- Removed obsolete notification destination names and replaced network examples with documentation-only address ranges.
