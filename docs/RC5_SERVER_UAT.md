# v6r4-RC5 security targeted Linux UAT

RC5 is a security-only follow-up to RC4. Do not introduce unrelated code or architecture changes during this UAT.

## A. Input integrity

Verify Windows ZIP SHA256, supplied `.sha256`, and Linux `sha256sum` are identical before executing any installer.

## B. Fast regression

For all seven production installers:

- `bash -n`;
- `--help`;
- self-contained execution without sibling `common/platform.sh`;
- basic menu Enter/q/invalid-input contract.

## C. P0 symlink regression — mandatory

Use only a dedicated test instance and a test-owned external directory.

For at least Prometheus and one additional shared-state component, and preferably all six shared-state components:

1. ensure the test instance is absent;
2. create a test-owned external directory;
3. pre-create `${INSTALL_ROOT}/state` as a symlink to that external directory;
4. attempt installation;
5. installation must fail closed before creating installer-owned state outside the component root;
6. external directory must remain unchanged;
7. remove only the test-created symlink and test external directory;
8. restore a normal real `${INSTALL_ROOT}/state` directory and confirm normal installation still succeeds.

Also test an instance-state symlink where applicable. Uninstall must continue to reject symlinked state deletion.

**Never point the symlink at a real system directory or existing data.**

## D. RC4 functional inheritance spot-check

Confirm at minimum:

- preserve uninstall retains selected instance state;
- full uninstall removes selected instance state only;
- sibling state and `ownership.tsv` remain;
- Grafana normal local-file lifecycle still works or, if not repeated, at least its state path remains instance-local and no regression is observed;
- Prometheus 7d/10GB default unchanged;
- Alertmanager default does not listen on 9094;
- VictoriaMetrics has no 8480/8481 legacy listeners;
- firewall is not modified automatically.

## E. Verdict

RC5 may enter Freeze Candidate only if the P0 symlink path-escape test is closed and no new P0/P1 defect is found.
