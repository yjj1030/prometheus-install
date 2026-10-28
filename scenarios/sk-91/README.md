# 本机构三套规则 · v4.0.0

| 版本 | 目录 | 内存策略 | 适用范围 |
|---|---|---|---|
| 生产版 | [prod](prod/) | 正常生产目标96%/20m warning、98%/10m critical；Swap压力、OOM及独立100%告警保留 | 正常生产目标；显式nonprod/stress目标兼容OOM+100%策略 |
| 建议测试版 | [nonprod](nonprod/) | 97%/30m warning、99%/15m critical；Swap压力30m；OOM及独立100%告警保留 | 独立测试/压测Prometheus，覆盖所有node_exporter目标 |
| 测试内存降噪版 | [nonprod-memory](nonprod-memory/) | **OOM + 真实100%严重告警**；停用其他使用率、Swap和PSI阈值告警 | 同上，其他规则与建议测试版完全一致 |

生产、非生产均新增独立 `NodeMemoryExhaustedCritical`：真实计算值≥100%，无额外for等待，延迟解除2分钟。记录指标每分钟计算；最终通知遵循Alertmanager分组等待。显示四舍五入为100.00%但真实值小于100%时不触发此告警。当前三个入口为prod、nonprod、nonprod-memory；旧v3目录仅在Git历史保留。

两个测试版均保留：抓取失败15m warning/60m critical、核心collector失败/缺失30m、目标消失30m、CPU≥95%/60m warning和≥99%/30m critical、文件系统90%/2h warning和97%/30m critical、小空间、inode、只读告警，以及14项Prometheus自身检查。测试版没有TCP、磁盘IO和网卡阈值告警；这是继承已有测试职责，没有因内存降噪额外关闭其他规则。

OOM表达式为 `increase(node_vmstat_oom_kill[10m]) > 0`，critical，无额外for等待。其含义是最近10分钟观察到内核OOM Kill计数增长。未发生kill的内存分配错误、未暴露的cgroup OOM、进程自身报内存不足，不保证被该计数捕获。计数器重置按Prometheus rate/increase语义处理；短于抓取间隔的事件及未采到的重启存在观测限制。

## 使用

每个版本只部署该目录内 带环境和版本号的 `recording_*`、`node_*`、`prometheus_*` 三个文件。先在规则目录外备份旧文件，移走旧的同职责YAML，再复制选中版本。不要把三套版本、catalog或历史文件一起复制进 `rules/*.yml`，也不要把备份命名为同目录下的 `.yml`。

证书监控按需额外部署 [TLS规则](../../catalog/probes/tls_common_v4.0.0.yml)。[证书有效期策略](../../catalog/probes/certificate_policy_common_v4.0.0.yml) 是独立可选检查，默认不加载，不表示超过某天数即违规。证书info默认仅记录，不建议在群里反复通知。已启用该可选项的现场应在清点后决定是否继续。

部署前运行与现场版本配套的 `promtool check rules <规则文件>` 和 `promtool check config <实际主配置>`，再走既有受控reload流程。reload后查看 `/rules` 的lastError/health，核对 `/api/v1/alerts`，并实测通知和恢复。复制文件不会自动使规则生效。

Alertmanager示例见 [alertmanager_common_v4.0.0.yml](alertmanager_common_v4.0.0.yml)；只提供路由/抑制起点，接收地址是无效示例地址，不直接替换现场配置。

## 修改入口

- 生产规则的通用计算与字段：`catalog/linux/node_common_v4.0.0.yml`；本机构阈值/持续时间覆盖：`policies/policy_common_v4.0.0.yml`；记录规则：`catalog/linux/recording_common_v4.0.0.yml`。
- 测试非内存公共策略及OOM：`policies/base_nonprod_v4.0.0.yml`。
- 测试建议版内存差异：`policies/policy_common_v4.0.0.yml`；三个版本的组装逻辑：`tools/build_alert_rules.py`。
- 修改源后在仓库根目录运行 `python3 tools/build_alert_rules.py`，再执行 `tools/validate_alert_rules.sh`。
- 三个部署目录是生成结果，CI检查它们与源文件一致；不要只改某一份副本。
- 策略与现场结论记入 [CONTEXT.md](CONTEXT.md) 和 [CHANGELOG.md](CHANGELOG.md)。

## hostname排查

规则支持静态hostname、nodename、新鲜uname和24小时历史annotation回退；新装后没有历史、同一目标存在冲突主机名或长期断采会显示“未提供”。建议在file_sd中维护真实hostname，而不是从IP反向猜测。脱敏格式见[目标标签示例](examples/node-targets.example.json)，示例地址不可当作真实资产。

逐层比对同一条alert的labels与annotations：Prometheus告警API → Alertmanager API → webhook请求体 → 通知网关内部对象 → 最终消息。若Prometheus的annotations.hostname有值而群内没有，修改规则阈值不会修好显示。通知模板必须逐条渲染，混合firing/resolved成员应分别遍历，不把CommonAnnotations作为所有成员的字段来源。
