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

**完整操作见[部署说明](../../DEPLOY.md)**，按顺序执行：

1. 在上表选择一套三个文件，TLS按需另加；不复制整个catalog或policies。
2. 核对实际Prometheus主配置的rule_files及运行实例；不是按当前shell所在目录决定目的地。
3. 加载目录外暂存校验，备份并移走同职责旧文件，再复制新文件。
4. 检查实际主配置，成功后reload；核对新文件、评价状态、目标覆盖和真实通知。
5. 失败按部署说明的精确清单回退；不要叠加旧、新版本。

Alertmanager的[共用示例](alertmanager_common_v4.0.0.yml)单独合并到现有Alertmanager配置，其示例地址不可使用，不放进Prometheus规则目录。部署说明同时列出证书规则可选项、旧文件对应关系和回退命令。

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
