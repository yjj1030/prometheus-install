# v6r4-RC5 security change log

## Fixed

RC4 Linux UAT discovered that install-side state creation could follow a pre-existing symbolic link such as:

`/usr/local/<component>/state -> /outside/path`

and then create `access-request.md` or ownership state outside the component root.

RC5 adds guarded state directory validation/creation in the shared platform layer. Installer-owned state writes now fail closed if any state path component below the configured component root is a symbolic link, is not a directory, or resolves outside the component root.

The fix covers:

- `acl_emit`;
- `ownership_register`;
- `ownership_belongs_to`;
- `ownership_forget`;
- `ownership_list` state-path validation;
- existing RC4 full-uninstall state cleanup remains enforced.

## Not changed

All RC4 functional behavior outside this path-safety issue is intentionally unchanged.
