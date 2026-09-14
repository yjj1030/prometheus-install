# v6r4-RC6 change log

## Fixed

RC5 Linux UAT found that a clean first install could fail when `/usr/local/<component>` did not yet exist. RC6 restores the intended tri-state security contract:

- existing and safe path: success;
- missing but safely creatable path: create path;
- symlink, non-directory or escaping path: fail closed.

The secure creation path creates only the final component root when its parent already exists. It does not use unrestricted recursive `mkdir -p` to bypass validation.

## Preserved

RC5 symlink/path-escape defenses and RC4 uninstall state cleanup remain enforced.
