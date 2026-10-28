# 通用告警场景库 · v4.0.0

共24个告警模块、147条告警，另有45条Linux记录规则。按场景选取模块，每个模块独立说明指标依赖；不提供默认加载全部模块的通配配置。此处为可调整的通用起点，不能把“promtool语法通过”解释成目标软件已经暴露这些指标或已在生产验收。

## 启用顺序

1. 确认监控对象和故障影响，确定由谁处理、何时必须处理；无处理动作的指标优先看板或记录。
2. 在实际`/metrics`与Prometheus中核对指标名称、类型、单位、标签、collector、软件版本和数据新鲜度。先确认期望输入存在，再测试异常表达式。
3. 只部署需要的模块；Linux核心必须同时加载`linux/recording_common_v4.0.0.yml`。不同模块存在职责重叠，见下方组合约束。
4. 按业务角色、容量、变化率、维护窗口调整阈值及持续时间。所有固定阈值均不是普适的故障分界。
5. 先测规则，再测路由/抑制、通知字段、真实接收及恢复；启用后用真实事件复盘误报和漏报。

## 模块清单

| 模块 | 告警数 | 依赖与启用条件 | 指标/实现参考 |
|---|---:|---|---|
| [业务、任务、备份、证书与网关契约](application/contracts_common_v4.0.0.yml) | 9 | 自定义ops_*指标，必须先实现catalog/CONTRACTS.md的采集适配；不自动适用于任何成品软件 | [上游](https://prometheus.io/docs/practices/instrumentation/) |
| [JVM应用](application/jvm_common_v4.0.0.yml) | 3 | Micrometer Prometheus命名；JMX需适配，不能混用 | [上游](https://docs.micrometer.io/micrometer/reference/jvm.html) |
| [采集与指标覆盖](common/targets_common_v4.0.0.yml) | 5 | 所有抓取任务；需用独立清单检测从未注册的目标 | [上游](https://prometheus.io/docs/practices/alerting/) |
| [Docker与容器资源](containers/cadvisor_common_v4.0.0.yml) | 3 | cAdvisor；容器需name非空，内存限制有效且小于1EiB；容器身份变动不能推断任意容器消失 | [上游](https://github.com/google/cadvisor/blob/master/docs/storage/prometheus.md) |
| [Elasticsearch](database/elasticsearch_common_v4.0.0.yml) | 3 | elasticsearch_exporter，cluster_health启用；多Exporter采同集群需去重 | [上游](https://github.com/prometheus-community/elasticsearch_exporter) |
| [MySQL](database/mysql_common_v4.0.0.yml) | 4 | mysqld_exporter标准global_status/global_variables；需replica_role=replica标签启用复制检查 | [上游](https://github.com/prometheus/mysqld_exporter) |
| [PostgreSQL](database/postgresql_common_v4.0.0.yml) | 4 | postgres_exporter；启用stat_database、replication；复制空闲时lag语义需核实 | [上游](https://github.com/prometheus-community/postgres_exporter) |
| [Redis](database/redis_common_v4.0.0.yml) | 5 | redis_exporter；maxmemory=0不按容量耗尽告警，Cluster指标仅Cluster有 | [上游](https://github.com/oliver006/redis_exporter/tree/master/contrib/redis-mixin) |
| [Kubernetes工作负载与存储](kubernetes/workloads_common_v4.0.0.yml) | 7 | kube-state-metrics + kubelet/cAdvisor；多副本KSM先去重，cluster身份由采集标签保留 | [上游](https://github.com/kubernetes/kube-state-metrics/tree/main/docs/metrics) |
| [Linux主机核心](linux/node_common_v4.0.0.yml) | 39 | node_exporter；配套node_recording.yml；CPU/内存/容量/存储/网络/系统限额 | [上游](https://github.com/prometheus/node_exporter/tree/master/docs/node-mixin) |
| [Linux扩展：时间、RAID、系统服务、PSI](linux/optional_common_v4.0.0.yml) | 6 | node_exporter timex/mdadm/systemd/pressure/textfile；systemd仅标记critical_service=true的抓取目标 | [上游](https://github.com/prometheus/node_exporter/tree/master/docs/node-mixin) |
| [Kafka Broker](messaging/kafka_common_v4.0.0.yml) | 3 | 使用prometheus/jmx_exporter Kafka示例配置；Consumer lag另接契约adapter，不捏造JMX指标 | [上游](https://github.com/prometheus/jmx_exporter/blob/main/examples/kafka-2_0_0.yml) |
| [RabbitMQ](messaging/rabbitmq_common_v4.0.0.yml) | 4 | 内置Prometheus插件；队列规则要求/per-object或对应详细端点，按vhost/queue保留维度 | [上游](https://www.rabbitmq.com/docs/prometheus) |
| [交换机、防火墙、网络设备接口](network/snmp_common_v4.0.0.yml) | 4 | snmp_exporter IF-MIB；需generator保留接口ifIndex，ifHighSpeed单位Mbit/s，ifAdminStatus枚举数值 | [上游](https://github.com/prometheus/snmp_exporter) |
| [Alertmanager自身与通知失败](platform/alertmanager_common_v4.0.0.yml) | 4 | 单独抓取job=alertmanager；通知计数是发送尝试，不代表最终用户收到 | [上游](https://github.com/prometheus/alertmanager/tree/main/doc/alertmanager-mixin) |
| [Prometheus自身](platform/prometheus_common_v4.0.0.yml) | 14 | job=prometheus；remote_write指标兼容两套命名，按实际版本确认 | [上游](https://prometheus.io/docs/practices/alerting/) |
| [VictoriaMetrics单机存储](platform/victoriametrics_common_v4.0.0.yml) | 5 | job=victoriametrics；依当前版本/flags核对指标，不使用vmalert扩展YAML | [上游](https://github.com/VictoriaMetrics/VictoriaMetrics/tree/master/deployment/docker/rules) |
| [vmalert独立规则引擎](platform/vmalert_common_v4.0.0.yml) | 3 | 仅部署vmalert时启用；贵方当前Prometheus规则不加载本模块 | [上游](https://docs.victoriametrics.com/victoriametrics/vmalert/) |
| [HTTP、TCP、DNS、ICMP探测](probes/availability_common_v4.0.0.yml) | 4 | blackbox_exporter；目标添加probe_kind=http|tcp|dns|icmp，重标签保留instance=被探测目标 | [上游](https://github.com/prometheus/blackbox_exporter) |
| [可选证书有效期观察](probes/certificate_policy_common_v4.0.0.yml) | 1 | 仅target_scope=internet；不是合规判定 | [上游](https://github.com/prometheus/blackbox_exporter) |
| [线上TLS证书](probes/tls_common_v4.0.0.yml) | 7 | Blackbox的TLS相关目标，支持tls_expected=true | [上游](https://github.com/prometheus/blackbox_exporter) |
| [请求型服务SLO多窗口](slo/http_common_v4.0.0.yml) | 3 | 自定义ops_http_requests_total{service,result=good|bad}；99.9%、30天仅示例，必须经业务确认 | [上游](https://sre.google/workbook/alerting-on-slos/) |
| [全链路心跳](watchdog/heartbeat_common_v4.0.0.yml) | 1 | 外部独立deadman接收器；普通告警群不能作为心跳监测器 | [上游](https://runbooks.prometheus-operator.dev/runbooks/general/watchdog/) |
| [Windows主机](windows/host_common_v4.0.0.yml) | 6 | windows_exporter当前指标命名；服务需critical_service=true，collector已启用 | [上游](https://github.com/prometheus-community/windows_exporter/tree/master/docs) |

## 组合约束

- 本目录和`scenarios/sk-91/`中的成套规则二选一；不得一起加载，否则重复评价、重复告警或记录规则冲突。
- `common/targets_common_v4.0.0.yml`不覆盖node_exporter及blackbox系列任务，这两类由专用模块检查；数据库`*_up`检查连接，普通`up`检查Exporter抓取，二者意义不同。
- TLS模块已含TLS探测失败；与`probes/availability_common_v4.0.0.yml`并用时，同一HTTPS目标可能收到两条不同condition告警。应选定一个探测失败职责，或在场景中删除重复规则；不能靠不同alertname假装已去重。
- Kubernetes容器OOM与cAdvisor容器OOM是两种观察来源。同一容器不要无选择地重复通知；优先使用工作负载身份，保留原始证据用于排查。
- `linux/optional_common_v4.0.0.yml`不在本机构三套基础版中；尤其测试内存降噪环境不得另行启用PSI内存告警；该模式仅保留OOM和真实100%内存告警。
- CPU非空闲、iowait、steal、磁盘busy、网卡利用率、重传比例是诊断/资源风险信号，不能单独证明业务不可用。磁盘busy不等于所有并行设备的饱和程度，虚拟网卡标称速率不等于云带宽配额。
- Linux文件系统默认只监控常用本地文件系统及EFI分区，排除容器挂载；NFS/CIFS/网络存储需要按职责补充选择器和独立探测。dm设备默认排除可能不符合某些存储拓扑，启用前核对物理/逻辑层覆盖。
- SNMP空口、备用接口、关闭的服务、延迟队列、无副本测试ES、计划停跑任务均需资产职责清单限定，不把发现的全部对象一律叫醒值班。
- 通用模块没有自动补齐各对象的缺失告警：无数据通常不产生阈值告警。各组件是否启用应有独立期望清单，再据此检查`up`、核心指标缺失和输入新鲜度。全部源同时停止须外部Watchdog覆盖。

## 告警治理约定

- `critical`表示需立即响应，`warning`表示可计划处理，`info`默认仅记录；本机构历史策略额外保留`emergency`用于升级。这不是Prometheus内建强制等级。
- 对象身份与数值分离：动态当前值和hostname回退放annotation，不放查询生成的identity label。静态目标标签变动仍可能改变告警身份。
- 分级抑制按同一作用域、同一对象、同一condition，资源子维度如device/mountpoint/direction也必须相同；不得跨主机、跨站或跨独立Prometheus抑制。不同等级的severity不能放入equal。
- `for`过滤短暂波动；`keep_firing_for`推迟解除；M-of-N容忍非连续异常；恢复阈值实现滞回。四者不同，原生Prometheus没有可直接写入的`recovery_threshold`字段。
- 连续阈值条件退出、事件滑动窗口结束、数据缺失、规则移除是不同“告警结束”原因；恢复通知不能统一声称业务恢复。
- 比例需要分母与足够样本。TCP/错误率的最低流量门槛会形成低流量盲区，需业务探测补充；不能把SLO预算系数用于TCP重传分级。
- Alertmanager按至少一次设计处理分区下的可用性，不能承诺任何情况下绝无重复。只有确为同一逻辑评价器的HA副本才考虑规范化副本标签，不删除独立站点/评价器身份。
- 主机异常父告警只抑制已确认同对象的派生阈值，保留OOM等事件证据；不可宽泛抑制整个环境。

## 更多软件与场景

Oracle/SQL Server、国产数据库、MongoDB、Ceph/MinIO、硬件RAID/SMART、UPS、云厂商配额、业务日终、专线与灾备切换也在治理范围。其指标和角色高度依赖产品/版本，本版未声称提供这些产品的原生完整规则。可先用端点探测、SNMP和[业务指标契约](CONTRACTS.md)建立最低覆盖，再读取相应官方Exporter指标及产品故障语义后新增独立模块；不得随意猜metric名称。Kafka KRaft需改用对应JMX配置并实测，不把旧Controller规则视为全版本通用。

完整阈值、持续时间和表达式见各YAML；处理手册见[RUNBOOKS.md](RUNBOOKS.md)，来源和取舍见[SOURCES.md](SOURCES.md)。`slo/http_common_v4.0.0.yml`和`application/contracts_common_v4.0.0.yml`必须先实现[CONTRACTS.md](CONTRACTS.md)。
