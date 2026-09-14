# Source and archive layout

## Current source

`src/v6r4-RC3/` is the only active installer source tree.

- `installers/` contains seven source installers.
- `installers/common/platform.sh` is build-time shared code.
- `config/` contains current monitoring configuration/rules carried forward from the project source.
- `tests/` contains active build and regression gates.

Generated `installers_dist/` is transient and intentionally ignored by Git.

## Production output

Repository-root `installers/` is generated from the active source and contains only seven self-contained executable scripts.

## Historical snapshot

Historical RC1/RC2/v6r3 delivery material is retained under `archive/` in the Git repository for traceability. Archived material may contain obsolete paths, legacy installers and old documentation and is never a deployment source.
