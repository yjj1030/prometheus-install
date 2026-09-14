# v6r4-RC6 cross-distro targeted Linux UAT

RC6 is a minimal follow-up to RC5. Do not introduce unrelated code changes during UAT.

## Required platforms

- Debian 12
- openSUSE 15
- Kylin V10 SP3

Use the same RC6 ZIP and verify SHA256 independently on every server.

## Mandatory tests on every platform

1. remove only the selected test component root so that `/usr/local/<component>` genuinely does not exist;
2. perform a clean first install using a test port and local/internal package source where appropriate;
3. first install must succeed and create a real component root;
4. full uninstall must remove only the selected instance state and instance directory;
5. pre-create the component root or state root as a test-owned symlink to `/tmp/...` and repeat install;
6. installer must fail closed and the external target must remain unchanged;
7. restore a real directory and confirm normal install succeeds again.

At minimum run the above on Prometheus and one second shared-state component per OS. Also run 7/7 `bash -n`, `--help`, self-contained checks and quick invariants (Prometheus 7d/10GB, Alertmanager no default 9094 listener, VictoriaMetrics no 8480/8481, firewall not auto-modified).

## Verdict

Freeze Candidate requires all three operating systems to PASS with no new P0/P1 finding.
