# Prometheus v3 平台适配层 common/platform.sh

所有 v3 安装器统一 source 该库。它屏蔽包管理、init、用户/组、防火墙、归档、二进制能力等差异。
本文件不直接执行任何动作；被 source 后输出 `PLATFORM_*` 变量与若干函数。

## 用法

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common/platform.sh"

platform_init    # 必须先调用
pkg_install jq
fw_open_port 9115 tcp
cap_net_raw_for_binary /usr/local/blackbox_exporter/blackbox_exporter
```

## 设计约束

- 仅使用 POSIX sh + bash 4.0+ 公共子集；不依赖任何第三方二进制。
- 检测失败时输出明确 `unknown` 并提示用户手动设置 `PLATFORM_ID`。
- 所有动作幂等；重复执行不会报错。
- 不静默 `setcap` / `firewall-cmd`：失败必须返回非零。

## 安装器命名约定（v3.0.0-rc3 起强制）

### systemd unit 命名

**统一为** `<component>-<port>.service`，无例外。

| 组件 | unit 名 |
|---|---|
| prometheus | `prometheus-<port>.service` |
| node_exporter | `node_exporter-<port>.service` |
| alertmanager | `alertmanager-<web_port>.service` |
| blackbox_exporter | `blackbox_exporter-<port>.service` |
| snmp_exporter | `snmp_exporter-<port>.service` |
| victoriametrics | `victoriametrics-<http_port>.service` |
| cadvisor | `cadvisor-<port>.service` |
| grafana | `grafana-<port>.service`（覆盖官方 `grafana-server.service`） |
| vmauth | `vmauth-<port>.service` |
| vmalert | `vmalert-<port>.service` |

### 实例根目录布局

**统一为** `${INSTALL_ROOT}/<component>-<port>/`，与 unit 名一一对应。

| 组件 | INSTALL_ROOT | 实例根 |
|---|---|---|
| prometheus | `/usr/local/prometheus` | `/usr/local/prometheus/prometheus-<port>/` |
| node_exporter | `/usr/local/node_exporter` | `/usr/local/node_exporter/node_exporter-<port>/` |
| alertmanager | `/usr/local/alertmanager` | `/usr/local/alertmanager/alertmanager-<web_port>/` |
| blackbox_exporter | `/usr/local/blackbox_exporter` | `/usr/local/blackbox_exporter/blackbox_exporter-<port>/` |
| snmp_exporter | `/usr/local/snmp_exporter` | `/usr/local/snmp_exporter/snmp_exporter-<port>/` |
| victoriametrics | `/usr/local/victoriametrics` | `/usr/local/victoriametrics/victoriametrics-<http_port>/` |
| vmauth | `/usr/local/vmauth` | `/usr/local/vmauth/vmauth-<port>/` |
| vmalert | `/usr/local/vmalert` | `/usr/local/vmalert/vmalert-<port>/` |

数据目录（VM）保留独立挂载点：`/var/lib/victoriametrics`（不受实例根迁移影响）。

### 安装器内 helper

```bash
# 间接常量：改一处即可批量替换所有引用（包括 instance_root/service_unit/
# unit 文件路径、cmd_status/reload/uninstall 目标）
SERVICE_NAME_PREFIX="<component>"

instance_root() { echo "${INSTALL_ROOT}/${SERVICE_NAME_PREFIX}-${PORT}"; }
service_unit()  { echo "${SERVICE_NAME_PREFIX}-${PORT}.service"; }
```

> **注意**：cadvisor 因容器化部署无 `instance_root()`，仅有 `service_unit()`；
> cadvisor 容器名 `cadvisor-${PORT}` 与 `SERVICE_NAME_PREFIX` 解耦（容器名不属于
> unit 命名概念）。grafana 中上游 `grafana-server.service` 字面量保留（属上游
> 包默认 unit，非本安装器派生）。

### 端口变量

统一使用 `PORT` 作为变量名；HTTP_PORT / WEB_PORT 作为组件特定别名，但 unit 名与目录
构造必须走 `PORT` 变量或显式别名声明。

### Grafana 特殊

`grafana-server.service` 是上游包默认 unit。安装器在 install/uninstall 时显式 disable
它，并写入自有的 `grafana-<port>.service`。`cmd_reload` 走 `systemctl restart`
（Grafana 不支持 reload）。

### cadvisor 特殊

容器内 `--user=0:0` 与 host uid=0 映射，host unit 不强制 `User=` 指令；如需降权部署，
需自行调整 ExecStart 的 `--user=` 与 User= 的语义一致。