# Source and release layout

- `src/v6r4-RC5/installers/` — editable installer sources.
- `src/v6r4-RC5/installers/common/platform.sh` — build-time shared platform library.
- `src/v6r4-RC5/tests/build_self_contained.sh` — embeds the shared library into production scripts.
- `installers/` — seven built self-contained production/UAT scripts. No runtime `common/` dependency is allowed.
- `archive/snapshots/v6r4-RC3-original/` — frozen RC3 repository snapshot used as RC4 provenance.
