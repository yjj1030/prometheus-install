# nonprod-memory · v4.0.0

部署本目录 `node_nonprod_v4.0.0.yml`、`recording_nonprod_v4.0.0.yml`、`prometheus_nonprod_v4.0.0.yml` 三个文件；使用方法及限制见[上级说明](../README.md)。100%内存耗尽为独立严重告警，无额外for等待。

| 告警 | 等级 | 持续时间 | 判定条件 |
|---|---|---|---|
| NodeDownWarning | warning | 15m | Prometheus抓取up=0，连续 ≥15分钟 |
| NodeDownCritical | critical | 60m | Prometheus抓取up=0，连续 ≥60分钟 |
| NodeExporterCoreCollectorFailed | warning | 30m | 关键 Collector 失败持续 ≥30分钟 |
| NodeExporterCoreCollectorMissing | warning | 30m | up=1但必需采集器指标缺失，连续 ≥30分钟 |
| NodeTargetDisappeared | warning | 30m | 过去24小时出现过的目标当前无up时序，连续 ≥30分钟 |
| NodeCPUUsageHighWarning | warning | 60m | 最近5分钟CPU非空闲占比 ≥95%，连续 ≥60分钟 |
| NodeCPUUsageHighCritical | critical | 30m | 最近5分钟CPU非空闲占比 ≥99%，连续 ≥30分钟 |
| NodeOOMKillDetected | critical | 无额外等待 | 最近10分钟OOM Kill计数器增量 >0；无额外for等待 |
| NodeMemoryExhaustedCritical | critical | 无额外等待 | MemAvailable口径内存使用率真实计算值 ≥100%；无额外for等待，不按显示四舍五入判断 |
| NodeFilesystemUsageWarning | warning | 2h | 文件系统使用率（df近似口径） ≥90%，连续 ≥2小时 |
| NodeFilesystemUsageCritical | critical | 30m | 文件系统使用率（df近似口径） ≥97%，连续 ≥30分钟 |
| NodeFilesystemFreeSpaceCritical | critical | 15m | 可用空间 <2GiB 且使用率 >90%，持续 ≥15分钟 |
| NodeFilesystemInodeCritical | critical | 30m | inode使用率 ≥98%，连续 ≥30分钟 |
| NodeFilesystemReadOnly | critical | 5m | 只读状态持续 ≥5分钟 |
| PrometheusConfigReloadFailed | critical | 5m | 最近一次配置重载状态=失败，持续 ≥5分钟 |
| PrometheusRuleEvaluationFailures | critical | 5m | 最近15分钟规则评估失败增量 >0，并持续 ≥5分钟 |
| PrometheusRuleEvaluationsMissed | warning | 10m | 最近15分钟 missed iterations 增量 >0，并持续 ≥10分钟 |
| PrometheusTargetSyncFailure | critical | 5m | 最近30分钟 target sync failure 增量 >0，并持续 ≥5分钟 |
| PrometheusNotConnectedToAlertmanager | critical | 5m | 5分钟窗口内可发现 Alertmanager 数量始终 <1，并持续 ≥5分钟 |
| PrometheusAlertDeliveryErrors | critical | 10m | 最近5分钟发送错误量/发送尝试量 >3%，且有发送尝试，连续 ≥10分钟 |
| PrometheusAlertDeliveryStopped | critical | 5m | 错误增速>0且sent增速=0，连续 ≥5分钟 |
| PrometheusRemoteWriteFailures | critical | 10m | Remote Write 失败率 >1%，持续 ≥10分钟 |
| PrometheusRemoteWriteBehindWarning | warning | 10m | 发送时间戳落后 >120秒，持续 ≥10分钟 |
| PrometheusRemoteWriteBehindCritical | critical | 10m | 发送时间戳落后 >600秒，持续 ≥10分钟 |
| PrometheusRemoteWriteShardsAtLimit | warning | 15m | 最近5分钟所需分片最大值 >配置分片上限最大值，连续 ≥15分钟 |
| PrometheusTSDBCompactionsFailing | warning | 15m | 最近1小时 compaction failure 增量 >0，并持续 ≥15分钟 |
| PrometheusTSDBReloadsFailing | warning | 15m | 最近1小时 block reload failure 增量 >0，并持续 ≥15分钟 |
| PrometheusHighQueryLoad | warning | 15m | 最近5分钟平均并发/窗口内并发上限最大值 >80%，且上限 >0，连续 ≥15分钟 |
