# v6r4-RC7 Baseline

RC7 is the candidate after RC6 cross-distribution UAT.

Release gate requires targeted Linux UAT on all three supported validation families:

- Debian 12
- openSUSE 15
- Kylin V10 SP3

The candidate must preserve RC6 first-install and fail-closed symlink protections, while proving the rhel-family systemd sandbox can start and persist runtime data under the project `/usr/local/<component>` layout.
