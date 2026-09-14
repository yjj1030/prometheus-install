# Source and archive layout

## Current source

`src/v6r4-RC2/` is the only active installer source tree.

- `installers/` contains seven source installers.
- `installers/common/platform.sh` is build-time shared code.
- `config/` contains current monitoring configuration/rules carried forward from the project source.
- `tests/` contains active build and regression gates.

Generated `installers_dist/` is transient and intentionally ignored by Git.

## Production output

Repository-root `installers/` is generated from the active source and contains only seven self-contained executable scripts.

## Historical snapshot

`archive/snapshots/v6r4-RC1-original/` preserves the original RC1 delivery used for this revision. It may contain obsolete paths, legacy installers and old documentation. It is not a deployment source.
