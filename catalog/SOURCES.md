# 资料依据与取舍

核对日期：2026-10-28。没有把资料中的固定阈值视为本机构已验证基线。以下是实际阅读的官方说明、维护者实现及指标定义；GitHub文件记录内容blob SHA，便于从Git Data API复核原始内容。上游main/master链接随后可能变化，SHA不表示已在本地运行该软件。

## 方法依据

- [Prometheus告警最佳实践](https://prometheus.io/docs/practices/alerting/)：症状、可操作性和监控自身。
- [Prometheus规则语义](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/)：for、keep_firing_for、label与annotation。
- [规则单元测试](https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/)：模拟输入、缺失/stale和期望输出。
- [Alertmanager路由与抑制](https://prometheus.io/docs/alerting/latest/configuration/)及[HA语义](https://prometheus.io/docs/alerting/latest/high_availability/)：分组、通知重复、缺失equal标签及故障下的可用性。
- [Google SRE监控](https://sre.google/sre-book/monitoring-distributed-systems/)与[SLO告警](https://sre.google/workbook/alerting-on-slos/)：四个黄金信号、错误预算、多窗口与低流量盲区。
- [Monitoring Mixins约定](https://monitoring.mixins.dev/)：按职责组合、分级语义、摘要和逐条描述。
- [kube-prometheus实际抑制配置](https://github.com/prometheus-operator/kube-prometheus/blob/main/manifests/alertmanager-secret.yaml)：借鉴分级抑制，未照搬Kubernetes namespace作用域到主机。
- [Watchdog运行手册](https://runbooks.prometheus-operator.dev/runbooks/general/watchdog/)：外部系统检测心跳缺失。
- [Grafana缺失数据](https://grafana.com/docs/grafana/latest/alerting/guides/missing-data/)与[查询条件](https://grafana.com/docs/grafana/latest/alerting/fundamentals/alert-rules/queries-conditions/)：NoData/Error/MissingSeries以及恢复阈值；不混入原生Prometheus配置字段。
- [VictoriaMetrics vmalert](https://docs.victoriametrics.com/victoriametrics/vmalert/)：输入覆盖、数据延迟、动态label、规则状态；本机构未因此迁移引擎。
- [AWS CloudWatch缺失数据](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/alarms-and-missing-data.html)及[评价方式](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/alarm-evaluation.html)：依指标职责处理缺失，M-of-N与连续for不同；只借鉴设计，不混淆引擎。
- [GitLab告警手册管理](https://handbook.gitlab.com/handbook/engineering/infrastructure-platforms/alert-playbook-management/)：先有按告警可执行的手册，再启用通知。
- [RabbitMQ官方监控](https://www.rabbitmq.com/docs/prometheus)：聚合/逐对象端点不同，队列指标需核对端点和维度。

## 指标/实现核对快照

| 仓库与文件 | 内容blob SHA |
|---|---|
| [prometheus/alertmanager/doc/alertmanager-mixin/alerts.libsonnet](https://github.com/prometheus/alertmanager/blob/HEAD/doc/alertmanager-mixin/alerts.libsonnet) | [ad0c71f14e57e8bbb6ed62d3961f6d9d48bd181d](https://api.github.com/repos/prometheus/alertmanager/git/blobs/ad0c71f14e57e8bbb6ed62d3961f6d9d48bd181d) |
| [prometheus/mysqld_exporter/mysqld-mixin/alerts/general.yaml](https://github.com/prometheus/mysqld_exporter/blob/HEAD/mysqld-mixin/alerts/general.yaml) | [b4d8bf9e13d5384755ae1ddaabfa939a3631d11c](https://api.github.com/repos/prometheus/mysqld_exporter/git/blobs/b4d8bf9e13d5384755ae1ddaabfa939a3631d11c) |
| [oliver006/redis_exporter/contrib/redis-mixin/alerts/redis.libsonnet](https://github.com/oliver006/redis_exporter/blob/HEAD/contrib/redis-mixin/alerts/redis.libsonnet) | [8717c35bda520aa8bb427221d9ce477ce304272a](https://api.github.com/repos/oliver006/redis_exporter/git/blobs/8717c35bda520aa8bb427221d9ce477ce304272a) |
| [prometheus-community/postgres_exporter/collector/pg_replication.go](https://github.com/prometheus-community/postgres_exporter/blob/HEAD/collector/pg_replication.go) | [085b624156c9c772c34df682b07296ff3d59f800](https://api.github.com/repos/prometheus-community/postgres_exporter/git/blobs/085b624156c9c772c34df682b07296ff3d59f800) |
| [prometheus-community/postgres_exporter/collector/pg_stat_database.go](https://github.com/prometheus-community/postgres_exporter/blob/HEAD/collector/pg_stat_database.go) | [f67bc225649bf583fbbce82c1f4408f561684c4a](https://api.github.com/repos/prometheus-community/postgres_exporter/git/blobs/f67bc225649bf583fbbce82c1f4408f561684c4a) |
| [prometheus-community/windows_exporter/docs/collector.cpu.md](https://github.com/prometheus-community/windows_exporter/blob/HEAD/docs/collector.cpu.md) | [8dde57f0afc265239d72479aba6e0150b02367b4](https://api.github.com/repos/prometheus-community/windows_exporter/git/blobs/8dde57f0afc265239d72479aba6e0150b02367b4) |
| [prometheus-community/windows_exporter/docs/collector.memory.md](https://github.com/prometheus-community/windows_exporter/blob/HEAD/docs/collector.memory.md) | [4a6ce8a260dc02c6bbcefe5d2e8ffcdc7df9fbb4](https://api.github.com/repos/prometheus-community/windows_exporter/git/blobs/4a6ce8a260dc02c6bbcefe5d2e8ffcdc7df9fbb4) |
| [prometheus-community/windows_exporter/docs/collector.logical_disk.md](https://github.com/prometheus-community/windows_exporter/blob/HEAD/docs/collector.logical_disk.md) | [46e3d8555557574e035489277b291f6f82d1c18a](https://api.github.com/repos/prometheus-community/windows_exporter/git/blobs/46e3d8555557574e035489277b291f6f82d1c18a) |
| [prometheus-community/windows_exporter/docs/collector.service.md](https://github.com/prometheus-community/windows_exporter/blob/HEAD/docs/collector.service.md) | [6c394869585a016b49083161a29945c6e51068d2](https://api.github.com/repos/prometheus-community/windows_exporter/git/blobs/6c394869585a016b49083161a29945c6e51068d2) |
| [prometheus-community/elasticsearch_exporter/collector/cluster_health.go](https://github.com/prometheus-community/elasticsearch_exporter/blob/HEAD/collector/cluster_health.go) | [a6924df682ad835f472315a78fd6be9ab6989014](https://api.github.com/repos/prometheus-community/elasticsearch_exporter/git/blobs/a6924df682ad835f472315a78fd6be9ab6989014) |
| [rabbitmq/rabbitmq-server/deps/rabbitmq_prometheus/src/collectors/prometheus_rabbitmq_core_metrics_collector.erl](https://github.com/rabbitmq/rabbitmq-server/blob/HEAD/deps/rabbitmq_prometheus/src/collectors/prometheus_rabbitmq_core_metrics_collector.erl) | [fc4c8c0601b06361b44892aab26c8040f8278fb4](https://api.github.com/repos/rabbitmq/rabbitmq-server/git/blobs/fc4c8c0601b06361b44892aab26c8040f8278fb4) |
| [prometheus/jmx_exporter/examples/kafka-2_0_0.yml](https://github.com/prometheus/jmx_exporter/blob/HEAD/examples/kafka-2_0_0.yml) | [c7ae644fe7fa748013f0a88e6bce6aadb8807a33](https://api.github.com/repos/prometheus/jmx_exporter/git/blobs/c7ae644fe7fa748013f0a88e6bce6aadb8807a33) |
| [kubernetes/kube-state-metrics/docs/metrics/workload/pod-metrics.md](https://github.com/kubernetes/kube-state-metrics/blob/HEAD/docs/metrics/workload/pod-metrics.md) | [50d9ce15c1043051cc8f06b212011ee807aa6ef6](https://api.github.com/repos/kubernetes/kube-state-metrics/git/blobs/50d9ce15c1043051cc8f06b212011ee807aa6ef6) |
| [kubernetes/kube-state-metrics/docs/metrics/storage/persistentvolumeclaim-metrics.md](https://github.com/kubernetes/kube-state-metrics/blob/HEAD/docs/metrics/storage/persistentvolumeclaim-metrics.md) | [c2abd01c01717e3216e47c09fd259fdd3354167f](https://api.github.com/repos/kubernetes/kube-state-metrics/git/blobs/c2abd01c01717e3216e47c09fd259fdd3354167f) |
| [VictoriaMetrics/VictoriaMetrics/deployment/docker/rules/alerts-health.yml](https://github.com/VictoriaMetrics/VictoriaMetrics/blob/HEAD/deployment/docker/rules/alerts-health.yml) | [de5f6f70b5af1c3165af7822e04430c33ef4a706](https://api.github.com/repos/VictoriaMetrics/VictoriaMetrics/git/blobs/de5f6f70b5af1c3165af7822e04430c33ef4a706) |
| [VictoriaMetrics/VictoriaMetrics/deployment/docker/rules/alerts-single-node.yml](https://github.com/VictoriaMetrics/VictoriaMetrics/blob/HEAD/deployment/docker/rules/alerts-single-node.yml) | [2dda0f170c5d292bddfb2f05e9b89ed657cc98b3](https://api.github.com/repos/VictoriaMetrics/VictoriaMetrics/git/blobs/2dda0f170c5d292bddfb2f05e9b89ed657cc98b3) |
| [VictoriaMetrics/VictoriaMetrics/deployment/docker/rules/alerts-vmalert.yml](https://github.com/VictoriaMetrics/VictoriaMetrics/blob/HEAD/deployment/docker/rules/alerts-vmalert.yml) | [b08faa06ac243bcbe10d45f28a44090a14dfdcde](https://api.github.com/repos/VictoriaMetrics/VictoriaMetrics/git/blobs/b08faa06ac243bcbe10d45f28a44090a14dfdcde) |
| [prometheus/snmp_exporter/README.md](https://github.com/prometheus/snmp_exporter/blob/HEAD/README.md) | [0daabd959dfa54cd79725fb16e02550783a44bec](https://api.github.com/repos/prometheus/snmp_exporter/git/blobs/0daabd959dfa54cd79725fb16e02550783a44bec) |
| [google/cadvisor/docs/storage/prometheus.md](https://github.com/google/cadvisor/blob/HEAD/docs/storage/prometheus.md) | [f7a84ca91f509cdffe46b1bb92a00f9e1dd01705](https://api.github.com/repos/google/cadvisor/git/blobs/f7a84ca91f509cdffe46b1bb92a00f9e1dd01705) |
| [micrometer-metrics/micrometer/micrometer-core/src/main/java/io/micrometer/core/instrument/binder/jvm/JvmGcMetrics.java](https://github.com/micrometer-metrics/micrometer/blob/HEAD/micrometer-core/src/main/java/io/micrometer/core/instrument/binder/jvm/JvmGcMetrics.java) | [c57df3350eff7d77388b1d546ba531c3479c6ed8](https://api.github.com/repos/micrometer-metrics/micrometer/git/blobs/c57df3350eff7d77388b1d546ba531c3479c6ed8) |
| [prometheus/node_exporter/docs/node-mixin/alerts/alerts.libsonnet](https://github.com/prometheus/node_exporter/blob/HEAD/docs/node-mixin/alerts/alerts.libsonnet) | [29c934f57b49869b656dee3a459ea3d14a65424c](https://api.github.com/repos/prometheus/node_exporter/git/blobs/29c934f57b49869b656dee3a459ea3d14a65424c) |

## 社区与产品资料如何使用

用户提供的[社区文章](https://www.cnblogs.com/yangykaifa/p/19615990)、[sretalk规则库](https://github.com/sretalk/prometheus-rules)、[阿里云告警规则说明](https://help.aliyun.com/zh/prometheus/user-guide/create-an-alert-rule-for-a-prometheus-instance)作为补充比较。社区代码需逐条检查单位、标签和抑制关系；阿里云托管告警事件流程不能当成原生Prometheus恢复语义。未整库复制第三方规则。

本库固定阈值有两类：从本机构已交付策略继承的参数、为通用模块明确给出的示例起点。它们都需要真实数据校准，不宣称为所有软件和环境共同认可的标准。后续扩展产品模块先核对维护者指标定义，避免不存在的名称导致规则永不触发。
