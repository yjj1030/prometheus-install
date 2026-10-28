# 场景约定与未核实项

最后确认：2026-10-28。后续本机构规则、策略决定、现场验证结果统一更新本目录。通用内容维护在 `catalog/`。本仓库是规则的后续维护入口，不再用聊天附件作为最新版本依据。

## 已确认

- Prometheus负责规则评价，VictoriaMetrics用作远程存储；未确认部署vmalert。
- node_exporter任务名为 `node_exporter`，Prometheus自身任务名为 `prometheus`，抓取/评价基线30秒；记录规则沿用1分钟。
- 主机标签使用 `asset_ip`、`alert_policy`；`stress`并入非生产，作为兼容标签保留。
- 三种部署选择：production、test-recommended、test-memory-oom-only。每个Prometheus只选一套完整的三个YAML文件，不能叠加三套。
- 用户已澄清：测试内存降噪策略是**仅OOM告警**，内存100%也不告警；这不关闭CPU、磁盘、可用性或Prometheus自监控告警。
- 两套测试版的非内存规则必须完全一致；测试建议版允许内存早期预警。
- production保留显式nonprod/stress目标的兼容策略，这部分使用OOM-only；默认/缺失/其他alert_policy使用生产策略。
- hostname显示契约：每个alert分别读取labels.hostname、labels.nodename、annotations.hostname；不依赖CommonAnnotations中一定有hostname。
- 实际rule_files使用非递归 `rules/*.yml`；子目录和ZIP不被该模式加载。

## 本次继承和修订

- 规则来源为上一版v2.3.8简版；新规则库版本v3.0.0。
- 生产正常目标各阈值保持原值；TCP为5分钟重传段/发送段：2%且>100段/秒持续15分钟warning，5%且>100段/秒持续10分钟critical，延迟解除2分钟。是当前治理参数，不是通用网络质量标准；低流量故障需业务探测补充。
- 测试建议版内存：97%/30分钟warning、99%/15分钟critical、Swap≥60%且换入换出>1页/秒30分钟warning、OOM critical。
- 测试OOM-only版仅移除以上三项阈值内存告警，其余与建议版一致。
- NodeDown表达式改为直接使用up，不再把历史uname的动态nodename连接成告警label。hostname历史仅用于annotation；避免主机名变化造成NodeDown身份变化。首次升级可能使已有NodeDown实例更换一次身份。
- OOM的解除文字改为“事件已移出检测窗口”，不声明业务已经恢复。

## 待核实，不能标为已修复

- 生产Prometheus/Alertmanager/Exporter的实际版本和指标完整性。
- 当前Alertmanager生效配置、路由、抑制及通知网关部署版本。
- hostname仍未显示的现场根因；需要核对Prometheus `/api/v1/alerts`中每条annotation与网关实际收到的同一payload。本次只验证规则侧回退，未验证线上模板/网关改动。
- TCP门槛、CPU/磁盘阈值与业务影响的历史相关性；尚无同时间窗口生产指标证据。
- Linux主机vmstat OOM计数能否覆盖所有容器/cgroup事件；未采集的容器OOM不能靠本规则承诺捕获。
- 所有新规则均未在生产reload，未做真实通知端到端验收。

公共仓库只存规则、脱敏结构和决策。不得写入真实内网地址清单、账号密码、认证文件、私钥或完整现场配置。
