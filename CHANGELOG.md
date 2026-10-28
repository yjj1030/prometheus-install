# Changelog

## v6r4-RC7 - 2026-09-13

- Cross-distro compatibility fix after RC6 UAT on Kylin V10 SP3.
- Keep `ProtectSystem=full` for rhel-family service hardening while adding precise `ReadWritePaths=` only for runtime-writable data/storage and log directories.
- Prometheus: allow `${inst}/data` and `${inst}/logs`.
- Alertmanager: allow `${inst}/data` and `${inst}/logs`.
- VictoriaMetrics: allow `${STORAGE_PATH}` and `${inst}/logs`.
- Do not make `/usr/local` or the full component root writable.
- RC6 first-install and symlink fail-closed protections remain unchanged.

## v6r4-RC6

- Minimal follow-up to RC5 after Linux UAT found a P0 clean-first-install regression when `${INSTALL_ROOT}` was absent.
- Missing component roots are now safely creatable by the guarded state layer.
- Existing component-root symlinks/non-directories and escaping state paths remain fail-closed.
- No unrelated installer behavior changed.

## v6r4-RC5

- Security-only release candidate after RC4 targeted Linux UAT discovered a P0 install-side state-path symlink escape.
- Installer-owned state creation now rejects symlinked or escaping paths below the configured component root.
- ACL state writes and ownership registry create/read/update paths fail closed on invalid state paths.
- RC4 full-uninstall instance-state cleanup semantics remain unchanged.
- No component versions, ports, retention, firewall defaults, Status/Probe semantics or download policies changed.

## v6r4-RC4

- Targeted release candidate after RC3 Linux UAT returned `PASS WITH FIXES`.
- Full uninstall now removes only the selected instance state directory under `state/<component>-<port>/` for Prometheus, VictoriaMetrics, Alertmanager, Node Exporter, Blackbox Exporter and SNMP Exporter.
- Added deletion guards that reject the component root, shared `state/` root and paths outside the component root.
- Preserve uninstall semantics remain unchanged: instance directory and instance state are retained.
- Grafana uninstall logic is unchanged because its access-request state is already instance-local and removed with the instance directory.
- Added focused RC4 regression coverage for state cleanup and sibling-state preservation.

## v6r4-RC3

- Release-candidate hardening after RC2 self-audit.
- Removed residual Grafana provisioning path outside the instance root.
- Hardened readiness test harness with per-scenario retry and runner-file timeout execution.
- Preserved prod installer runtime as seven standalone self-contained scripts.

## v6r4-RC2

- Fixed server-UAT installer lifecycle issues found after RC1.
- Moved component cache paths under `/usr/local/<component>/cache`.
- Replaced ambiguous install/uninstall confirmations with numbered choices.
- Enforced occupied-port rejection and next-free-port recommendation.

## Alert rules v3.0.0 · 2026-10-28

- Add an optional general catalog (24 alert modules, 146 alerts and 45 Linux recording rules), source references, metric contracts and runbooks.
- Add the maintained institution scenario under `scenarios/sk-91/`, with prod, recommended test and test OOM-only profiles.
- OOM-only suppresses memory utilization/swap thresholds including 100%, while retaining all other test policy categories.
- Preserve mixed nonprod/stress target support in prod; keep prod thresholds in the scenario policy.
- Keep hostname fallback in annotations and remove dynamic historical nodename enrichment from NodeDown identity.
- Add deterministic profile generation, rule tests, routing tests, isolated Alertmanager inhibition tests and CI. Installation scripts and existing snapshots are unchanged.
- Live deployment, notification gateway rendering and actual delivery remain unverified; see scenario VALIDATION.md.

## Alert rules v3.0.1 · 2026-10-28

- Supersede the earlier OOM-only decision: all prod/nonprod profiles now retain a dedicated actual-100% critical memory alert, without an additional for delay.
- Reduced-noise test memory policy retains OOM and 100% only; other categories are unchanged.
- Add boundary tests and scoped memory notification inhibition; update maintained context and policy documentation.

## v4.0.0 · 2026-10-28

- 按用户要求统一模板环境与版本标识；部署入口简化为prod、nonprod、nonprod-memory；旧路径由Git历史保留。
- 固化VERSION、BASELINE.md、SHA256清单及CI检查，规范后续主/次/修订版本升级。
- category按信号分类，不按操作系统或Exporter目录分类；severity按响应紧迫性管理，保留现有机构分级阈值。
- 三套版本均保留OOM及真实100%内存严重告警。

## 部署文档补充 · 2026-10-28（规则仍为v4.0.0）

- 新增统一DEPLOY.md，补齐场景选择、文件用途、来源固定、实际目录确认、暂存校验、备份替换、重载验收及按清单回退。
- 仓库首页、场景和各版本目录增加直达入口，区分Prometheus规则、Alertmanager配置、安装器及维护文件。
- 部署文档纳入BASELINE.json；明确纯文档澄清由Git追踪，运行时规则版本不变。
- 告警表达式、阈值、分级、持续时间及部署模板内容均未改动；未执行现场部署。
