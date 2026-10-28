# Prometheus Monitoring Installers

## 已有Prometheus：先看部署说明

**更新告警规则直接按[DEPLOY.md](DEPLOY.md)操作。** 文档包含选版本、复制文件、替换旧规则、校验、重载、验收和回退。已有实例更新规则无需重跑安装器。

| 你要做什么 | 入口 |
|---|---|
| 生产规则 | [prod](scenarios/sk-91/prod/) |
| 建议非生产规则 | [nonprod](scenarios/sk-91/nonprod/) |
| 非生产内存降噪，保留OOM和100% | [nonprod-memory](scenarios/sk-91/nonprod-memory/) |
| 文件用途与完整操作 | [部署说明](DEPLOY.md) |
| 命名、分类分级和版本维护 | [维护基线](BASELINE.md) |

每个实例只选一套三个文件；TLS按需另加。Alertmanager示例不是Prometheus规则文件。安装器版本与规则VERSION分别管理。

Current installer baseline: **v6r4-RC7** — cross-distro first-install regression release candidate.

This repository contains prod-oriented Linux installers for seven monitoring components, active source/tests, and archived historical delivery material.

## Production installers

Use only the files under [`installers/`](installers/) on target servers:

- Alertmanager
- Blackbox Exporter
- Grafana
- Node Exporter
- Prometheus
- SNMP Exporter
- VictoriaMetrics single-node

Each prod installer is a **single self-contained shell script**. No sibling `common/platform.sh` is required or loaded at runtime.

## Repository layout

- `installers/` — seven self-contained prod/UAT installer scripts only.
- `src/v6r4-RC7/` — active source, shared build-time `common/platform.sh`, configs and tests.
- `tools/` — supporting tools such as node discovery.
- `docs/` — current RC7 baseline, validation and targeted UAT instructions.
- `releases/v6r4-RC7/` — RC7 ZIP and SHA256.
- `archive/` — historical snapshots; never treat archived files as the current baseline.

## RC7 scope

RC5 closed install-side symlink/path-escape writes, but cross-platform Linux UAT found a P0 clean-first-install regression when `/usr/local/<component>` did not yet exist.

RC7 is deliberately minimal: safely create a missing component root while preserving RC5 fail-closed symlink/path defenses and RC4 uninstall state cleanup.

RC7 is **not GA**. Freeze Candidate requires targeted UAT on Debian 12, openSUSE 15 and Kylin V10 SP3. See [`docs/RC7_BASELINE.md`](docs/RC7_BASELINE.md) and [`docs/RC7_SERVER_UAT.md`](docs/RC7_SERVER_UAT.md).

## 告警规则 · v4.0.0

告警规则从2026-10-28起单独在本仓库维护，与安装器RC版本分开管理：

- [通用场景库](catalog/README.md)：按依赖选用的24个模块、147条告警、45条Linux记录规则；含来源、指标契约和运行手册。
- [本机构场景](scenarios/sk-91/README.md)：生产版、建议测试版、非生产内存降噪版（OOM＋100%）三套互斥部署选择。
- [场景约定](scenarios/sk-91/CONTEXT.md)：后续确认的策略和现场证据统一记录于此。
- [验证范围](scenarios/sk-91/VALIDATION.md)：规则测试、路由与抑制测试，以及尚未完成的现场验收。

现有RC7安装器仍携带自己的配置基线，本次未把新规则自动写入安装器；安装后选择新场景版时应按场景说明显式替换规则。不要混载历史规则、新catalog和场景成套规则。

本地验证需Python 3、PyYAML、promtool、amtool和alertmanager；本次固定验证工具为Prometheus 3.5.0、Alertmanager 0.28.1，现场版本仍需核对。运行 `bash tools/validate_alert_rules.sh`；工具路径可用PROMTOOL/AMTOOL/ALERTMANAGER覆盖。CI执行同一流程。

命名、统一版本、告警分类分级和后续维护要求以[BASELINE.md](BASELINE.md)为准；[BASELINE.json](BASELINE.json)固化本次文件清单及SHA256，CI阻止版本和模板漂移。
