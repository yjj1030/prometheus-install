# v6r4-RC2 source

This is the active source for the seven supported monitoring installers.

- `installers/common/platform.sh` is a **build-time/source-time** common library only.
- Production files under repository-root `installers/` are self-contained and do not read a sibling `common/platform.sh`.
- `tests/build_self_contained.sh` rebuilds the seven production installers into a transient `installers_dist/` directory.
- Legacy cAdvisor/vmalert/vmauth installer sources are not part of RC2; they remain in `archive/snapshots/v6r4-RC1-original/` for traceability.
