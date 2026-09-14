# rules/ 目录说明

本目录采用“顶层即 edge 正式加载集”原则：Prometheus 的 `rule_files: - '<inst>/etc/rules/*.yml'` 只应加载本目录顶层的 8 个正式规则文件。

- `_center/`：仅中心评估器使用，**不得**复制到 edge 的 `etc/rules/` 顶层。
- `_reference/`：设计/审核参考，**不得加载**。
- `_deprecated/`：历史废弃规则，**不得加载**。

顶层正式 edge 文件：

- `node_usage_record_rules_v3.0.0.yml`
- `node_alerts_v3.0.0_prod.yml`
- `node_alerts_v1.0.0_stress.yml`
- `blackbox_alerts_v3.0.0.yml`
- `snmp_alerts_v3.0.0.yml`
- `docker_k8s_alerts_v3.0.0.yml`
- `basic_alerts_v3.0.0.yml`
- `watchdog_alerts_v1.0.0.yml`

中心规则位于 `_center/global_alerts_v1.0.0.yml`。

## 文件清单

| 文件 | 用途 | 加载端 | 规则归属（W1 §11.3） |
|---|---|---|---|
| `node_usage_record_rules_v3.0.0.yml` | 主机 9 合约指标 + 衍生记录规则 | edge | 区域评估（本地告警用） |
| `node_alerts_v3.0.0_prod.yml` | 主机告警 prod / nonprod (alert_policy!="stress") | edge | 区域评估 |
| `node_alerts_v1.0.0_stress.yml` | 主机告警 压测 (alert_policy="stress") | edge 或独立部署 | 区域评估 |
| `blackbox_alerts_v3.0.0.yml` | Web/HTTP/TCP/ICMP/DNS + SSL/TLS | edge | 区域评估 |
| `snmp_alerts_v3.0.0.yml` | 网络设备接口/重启/健康 | edge | 区域评估 |
| `docker_k8s_alerts_v3.0.0.yml` | Docker 容器 + Kubernetes | edge | 区域评估 |
| `basic_alerts_v3.0.0.yml` | Prometheus / Alertmanager 自监控 | edge | 区域评估 |
| `watchdog_alerts_v1.0.0.yml` | 链路自证心跳 | edge | 区域评估 |
| `_center/global_alerts_v1.0.0.yml` | 跨站点 / SLO burn-rate / 数据平面 | center (vmalert) | 中心评估 |

## 部署矩阵

```
edge Prometheus
  └─ rule_files: - rules/*.yml     # 排除 global_alerts_*.yml
center vmalert
  └─ -rule: rules/global_alerts_*.yml
```

排除方法示例（prometheus.yml 的 rule_files）：

```yaml
rule_files:
  - /usr/local/.../etc/rules/node_usage_record_rules_v3.0.0.yml
  - /usr/local/.../etc/rules/node_alerts_v3.0.0_prod.yml
  - /usr/local/.../etc/rules/node_alerts_v1.0.0_stress.yml
  - /usr/local/.../etc/rules/blackbox_alerts_v3.0.0.yml
  - /usr/local/.../etc/rules/snmp_alerts_v3.0.0.yml
  - /usr/local/.../etc/rules/docker_k8s_alerts_v3.0.0.yml
  - /usr/local/.../etc/rules/basic_alerts_v3.0.0.yml
  - /usr/local/.../etc/rules/watchdog_alerts_v1.0.0.yml
```

## 标签契约（强约束）

每条 alert 必须具备以下 6 个 label（01 §2.4）：

| label | 取值范围 |
|---|---|
| `severity` | `info` / `warning` / `critical` / `emergency` |
| `asset_type` | `server` / `web` / `network_device` / `monitoring` / `container_host` / `kubernetes` |
| `category` | `availability` / `config` / `rules` / `alerting` / `remote_write` / `tsdb` / `query` / `resource` / `capacity` / `performance` / `security` / `hardware` / `os` / `network` / `application` |
| `alert_type` | `threshold` / `state` / `capacity` / `forecast` / `event` |
| `condition_id` | snake_case；与同 condition_id 多 severity 配合 03 §抑制 |
| `notify_profile` | 15 个故障域之一（见下表） |

### notify_profile 故障域（15）

```
availability / monitoring_agent / resource_cpu / resource_memory
capacity_filesystem / capacity_forecast / performance_storage
network_bandwidth / network_quality / system_limit / event
web_availability / security_cert / network_device / container / kubernetes
```

### annotations 六元组

```
summary / current_value / threshold / impact / action / description
```

## 抑制规则 equal 键（02 §6.2 CAUTION）

```
condition_id + site + origin_prometheus + job + instance
        + device + mountpoint + namespace + pod + container
```

这些 label 不存在的 series 不参与抑制；新增/新增继承 device 等子维度的告警时，
必须在 relabel / label_replace 阶段补齐空 label，避免抑制链断。

## 多严重度不重叠约定（v2 §5）

同 `condition_id` 的多级告警阈值不重叠：

```
warning < critical < emergency
```

禁止 critical 阈值低于 warning；禁止同一 condition_id 的多条 alert 同时 firing。

## alert_policy 联动

| alert_policy | 加载的告警文件 |
|---|---|
| `prod` / `uat` / `dev` / `nonprod` | `node_alerts_v3.0.0_prod.yml` |
| `stress` | `node_alerts_v1.0.0_stress.yml`（独立阈值） |

`alert_policy` 是 file_sd 注入的外部标签；prod 文件中的告警 `expr`
统一带 `{alert_policy!="stress"}` 过滤；stress 文件中的告警
`expr` 统一带 `{alert_policy="stress"}` 过滤。

## 加载校验

```bash
promtool check rules /path/to/<rule>.yml
```

任何加载失败必须在 `PrometheusConfigReloadFailed` 触发 5 分钟内被修复。

## 修改流程

1. 改之前：`promtool check rules <file>` 本地校验
2. 灰度：在 1 个 edge / 1 个 site 先加载
3. 全量：prometheus_installer reload（svc_reload / SIGHUP）
4. 验证：`/api/v1/rules?status=any` 与 `/api/v1/alerts`
