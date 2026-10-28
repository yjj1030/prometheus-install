# 场景约定与未核实项

最后确认：2026-10-28。后续本机构规则、策略决定、现场验证结果统一更新本目录。通用内容维护在 `catalog/`。本仓库是规则的后续维护入口，不再用聊天附件作为最新版本依据。

## 已确认

- Prometheus负责规则评价，VictoriaMetrics用作远程存储；未确认部署vmalert。
- node_exporter任务名为 `node_exporter`，Prometheus自身任务名为 `prometheus`，抓取/评价基线30秒；记录规则沿用1分钟。
- 主机标签使用 `asset_ip`、`alert_policy`；`stress`并入非生产，作为兼容标签保留。
- 三种部署选择：prod、nonprod、nonprod-memory。每个Prometheus只选一套完整的三个YAML文件，不能叠加三套。
- 用户最新确认：**生产、非生产内存真实计算值达到100%都必须告警**；测试内存降噪版保留OOM和100%，其他内存阈值停用。此次确认覆盖此前仅OOM的表述；CPU、磁盘、可用性和自监控不变。
- 两套测试版的非内存规则必须完全一致；测试建议版允许内存早期预警。
- prod保留显式nonprod/stress目标的兼容策略，这部分使用OOM+100%内存降噪策略；默认/缺失/其他alert_policy使用生产策略。
- hostname显示契约：每个alert分别读取labels.hostname、labels.nodename、annotations.hostname；不依赖CommonAnnotations中一定有hostname。
- 实际rule_files使用非递归 `rules/*.yml`；子目录和ZIP不被该模式加载。

## 本次继承和修订

- 规则来源为上一版v2.3.8简版；当前规则库版本v4.0.0。
- 生产正常目标各阈值保持原值；TCP为5分钟重传段/发送段：2%且>100段/秒持续15分钟warning，5%且>100段/秒持续10分钟critical，延迟解除2分钟。是当前治理参数，不是通用网络质量标准；低流量故障需业务探测补充。
- 测试建议版内存：97%/30分钟warning、99%/15分钟critical、Swap≥60%且换入换出>1页/秒30分钟warning、OOM critical。
- 测试内存降噪版移除97%/99%/Swap三项阈值告警，保留OOM和独立100%严重告警，其余与建议版一致。旧v3目录已迁移，现行入口为prod、nonprod、nonprod-memory；部署文件均带环境标识和v4.0.0。
- 三套版本均有NodeMemoryExhaustedCritical：MemAvailable口径真实计算值≥100%，无额外for等待，keep_firing_for=2m；记录规则每分钟计算，通知仍遵循Alertmanager分组时序。100%时由内存专用抑制规则抑制同对象较低阈值通知，OOM证据保留。
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

## 命名及版本基线补充

用户要求所有已整理模板固化基线，后续不得遗忘。当前基线v4.0.0统一环境/版本命名，根目录BASELINE.md规定分类分级和升级要求，BASELINE.json锁定全部受管文件；不通过CI不得宣称完成。

## 部署说明维护确认 · 2026-10-28

用户要求基线和部署说明必须能指导实际使用。统一入口为根目录DEPLOY.md，首页和各场景目录必须可直接进入。文档明确三文件配套、TLS可选、Alertmanager单独配置、实际加载路径、旧新文件对应、检查/reload/验收/回退。仅文档补充保留规则v4.0.0，由Git提交记录，不等同现场已执行。
