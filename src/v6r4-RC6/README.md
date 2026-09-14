# v6r4-RC6 source

This is the active source for the seven supported monitoring installers.

- `installers/common/platform.sh` is a **build-time/source-time** common library only.
- Production files under repository-root `installers/` are self-contained and do not read a sibling `common/platform.sh`.
- `tests/build_self_contained.sh` rebuilds the seven production installers into a transient `installers_dist/` directory.
- Legacy cAdvisor/vmalert/vmauth installer sources are not part of RC5; historical delivery material is retained under repository `archive/` for traceability.
