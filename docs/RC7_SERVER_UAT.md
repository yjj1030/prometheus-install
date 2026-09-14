# v6r4-RC7 Cross-Distro Targeted UAT

RC7 must be tested on Debian 12, openSUSE 15, and Kylin V10 SP3 before Freeze Candidate approval.

Primary checks:

1. SHA256 integrity of the identical RC7 ZIP on all hosts.
2. First-install behavior remains successful.
3. Component-root/state/instance-state symlink attacks remain fail-closed.
4. Prometheus starts on Kylin with `ProtectSystem=full` and can persist TSDB data.
5. Alertmanager and VictoriaMetrics rhel-family units receive equivalent writable-path protection.
6. No unit exposes all of `/usr/local` as writable.
7. RC6 uninstall state cleanup and platform invariants remain unchanged.
