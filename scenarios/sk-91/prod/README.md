# prod · v4.0.0

**如何部署：[统一部署说明](../../../DEPLOY.md)**。本目录只部署三个YAML；先备份替换旧规则，检查通过后reload和验收。

部署本目录 `node_prod_v4.0.0.yml`、`recording_prod_v4.0.0.yml`、`prometheus_prod_v4.0.0.yml` 三个文件；使用方法及限制见[上级说明](../README.md)。100%内存耗尽为独立严重告警，无额外for等待。

| 告警 | 等级 | 持续时间 | 判定条件 |
|---|---|---|---|
| NodeDownWarning（nonprod/stress） | warning | 15m | Prometheus抓取up=0，连续 ≥15分钟 |
| NodeDownCritical（nonprod/stress） | critical | 60m | Prometheus抓取up=0，连续 ≥60分钟 |
| NodeExporterCoreCollectorFailed（nonprod/stress） | warning | 30m | 关键 Collector 失败持续 ≥30分钟 |
| NodeExporterCoreCollectorMissing（nonprod/stress） | warning | 30m | up=1但必需采集器指标缺失，连续 ≥30分钟 |
| NodeTargetDisappeared（nonprod/stress） | warning | 30m | 过去24小时出现过的目标当前无up时序，连续 ≥30分钟 |
| NodeCPUUsageHighWarning（nonprod/stress） | warning | 60m | 最近5分钟CPU非空闲占比 ≥95%，连续 ≥60分钟 |
| NodeCPUUsageHighCritical（nonprod/stress） | critical | 30m | 最近5分钟CPU非空闲占比 ≥99%，连续 ≥30分钟 |
| NodeOOMKillDetected（nonprod/stress） | critical | 无额外等待 | 最近10分钟OOM Kill计数器增量 >0；无额外for等待 |
| NodeMemoryExhaustedCritical（nonprod/stress） | critical | 无额外等待 | MemAvailable口径内存使用率真实计算值 ≥100%；无额外for等待，不按显示四舍五入判断 |
| NodeFilesystemUsageWarning（nonprod/stress） | warning | 2h | 文件系统使用率（df近似口径） ≥90%，连续 ≥2小时 |
| NodeFilesystemUsageCritical（nonprod/stress） | critical | 30m | 文件系统使用率（df近似口径） ≥97%，连续 ≥30分钟 |
| NodeFilesystemFreeSpaceCritical（nonprod/stress） | critical | 15m | 可用空间 <2GiB 且使用率 >90%，持续 ≥15分钟 |
| NodeFilesystemInodeCritical（nonprod/stress） | critical | 30m | inode使用率 ≥98%，连续 ≥30分钟 |
| NodeFilesystemReadOnly（nonprod/stress） | critical | 5m | 只读状态持续 ≥5分钟 |
| NodeDown | critical | 2m | Prometheus抓取up=0，连续 ≥2分钟 |
| NodeExporterFlapping | warning | 5m | 15分钟内状态变化 ≥4次，并持续5分钟 |
| NodeExporterCoreCollectorFailed | warning | 15m | 关键 Collector 失败持续 ≥15分钟 |
| NodeExporterCoreCollectorMissing | warning | 15m | up=1但必需采集器指标缺失，连续 ≥15分钟 |
| NodeTargetDisappeared | warning | 10m | 过去24小时出现过的目标当前无up时序，连续 ≥10分钟 |
| NodeCPUUsageHighWarning | warning | 20m | 最近5分钟CPU非空闲占比 ≥85%，连续 ≥20分钟 |
| NodeCPUUsageHighCritical | critical | 10m | 最近5分钟CPU非空闲占比 ≥95%，连续 ≥10分钟 |
| NodeCPUIOWaitHighWarning | warning | 15m | 最近5分钟CPU iowait占比 ≥25%，连续 ≥15分钟 |
| NodeCPUIOWaitHighCritical | critical | 10m | 最近5分钟CPU iowait占比 ≥40%，连续 ≥10分钟 |
| NodeCPUStealHighWarning | warning | 15m | 最近5分钟CPU steal占比 ≥10%，连续 ≥15分钟 |
| NodeCPUStealHighCritical | critical | 10m | 最近5分钟CPU steal占比 ≥20%，连续 ≥10分钟 |
| NodeMemoryUsageHighWarning | warning | 20m | MemAvailable口径内存使用率 ≥96%，连续 ≥20分钟 |
| NodeMemoryUsageHighCritical | critical | 10m | MemAvailable口径内存使用率 ≥98%，连续 ≥10分钟 |
| NodeSwapPressureWarning | warning | 15m | Swap使用率 ≥60%，且最近5分钟换入换出合计 >1页/秒，连续 ≥15分钟 |
| NodeOOMKillDetected | critical | 无额外等待 | 最近10分钟OOM Kill计数器增量 >0；无额外for等待 |
| NodeMemoryExhaustedCritical | critical | 无额外等待 | MemAvailable口径内存使用率真实计算值 ≥100%；无额外for等待，不按显示四舍五入判断 |
| NodeFilesystemUsageWarning | warning | 30m | 文件系统使用率（df近似口径） ≥85%，连续 ≥30分钟 |
| NodeFilesystemUsageCritical | critical | 10m | 文件系统使用率（df近似口径） ≥95%，连续 ≥10分钟 |
| NodeFilesystemFreeSpaceCritical | critical | 10m | 可用空间 <2GiB 且使用率 >90%，持续 ≥10分钟 |
| NodeFilesystemFreeSpaceEmergency | emergency | 5m | 可用空间 <1GiB 且使用率 >98%，持续 ≥5分钟 |
| NodeFilesystemWillFillIn24Hours | warning | 30m | 以过去6小时可用空间线性拟合24小时后 <0，且当前使用率 >75%，连续 ≥30分钟 |
| NodeFilesystemInodeWarning | warning | 30m | inode使用率 ≥85%，连续 ≥30分钟 |
| NodeFilesystemInodeCritical | critical | 10m | inode使用率 ≥95%，连续 ≥10分钟 |
| NodeFilesystemInodeEmergency | emergency | 5m | inode使用率 ≥99%，连续 ≥5分钟 |
| NodeFilesystemReadOnly | critical | 2m | 只读状态持续 ≥2分钟 |
| NodeDiskIOUtilizationWarning | warning | 15m | 最近5分钟块设备I/O忙碌时间占比 ≥90%，连续 ≥15分钟 |
| NodeDiskIOUtilizationCritical | critical | 10m | 最近5分钟块设备I/O忙碌时间占比 ≥98%，连续 ≥10分钟 |
| NodeDiskLatencyWarning | warning | 15m | 最近5分钟同方向平均延迟 ≥50 ms，且同方向IOPS ≥5，连续 ≥15分钟 |
| NodeDiskLatencyCritical | critical | 10m | 最近5分钟同方向平均延迟 ≥200 ms，且同方向IOPS ≥5，连续 ≥10分钟 |
| NodeNetworkUtilizationWarning | warning | 15m | 最近5分钟单网卡单方向参考带宽利用率 ≥85%，连续 ≥15分钟 |
| NodeNetworkUtilizationCritical | critical | 10m | 最近5分钟单网卡单方向参考带宽利用率 ≥95%，连续 ≥10分钟 |
| NodeNetworkErrorDropRatioWarning | warning | 10m | 最近5分钟错误及丢弃计数/收发包计数的比例 ≥0.5%，且最近5分钟收发包速率 >10包/秒，连续 ≥10分钟 |
| NodeNetworkErrorDropRatioCritical | critical | 10m | 最近5分钟错误及丢弃计数/收发包计数的比例 ≥2%，且最近5分钟收发包速率 >10包/秒，连续 ≥10分钟 |
| NodeTCPRetransmissionWarning | warning | 15m | 最近5分钟主机 TCP 重传率 ≥2%，正常发送量 >100段/秒，连续 ≥15分钟 |
| NodeTCPRetransmissionCritical | critical | 10m | 最近5分钟主机 TCP 重传率 ≥5%，正常发送量 >100段/秒，连续 ≥10分钟 |
| NodeFileDescriptorUsageWarning | warning | 15m | 系统文件句柄已分配量/系统上限 ≥85%，连续 ≥15分钟 |
| NodeFileDescriptorUsageCritical | critical | 10m | 系统文件句柄已分配量/系统上限 ≥95%，连续 ≥10分钟 |
| NodeConntrackUsageWarning | warning | 15m | 连接跟踪表已用量/上限 ≥80%，连续 ≥15分钟 |
| NodeConntrackUsageCritical | critical | 10m | 连接跟踪表已用量/上限 ≥95%，连续 ≥10分钟 |
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
