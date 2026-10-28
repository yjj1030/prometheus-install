# v3.0.0验证记录

验证日期：2026-10-28。验证对象是本次规则提交，不代表生产已部署。

## 已执行

| 检查 | 结果与范围 |
|---|---|
| 工具 | 官方Prometheus/promtool 3.5.0；Alertmanager/amtool 0.28.1；Python 3.12、PyYAML 6.0.3 |
| 工具来源 | 发布包SHA256与官方sha256sums.txt一致；CI固定相同版本与SHA256 |
| 通用规则语法 | 24个告警模块共146条告警，另45条记录规则，全部通过promtool check rules |
| 三套部署版 | production：45记录+65告警；test-recommended：45记录+30告警；test-memory-oom-only：45记录+27告警；全部通过语法检查 |
| 组装一致性 | 从catalog及场景policy重新生成结果一致；两个测试版非内存规则逐项相同；OOM-only内存类仅NodeOOMKillDetected |
| 原生规则测试 | 34个测试文件、78个场景用例，包含101项PromQL断言、7项完整alert标签/annotation断言；全部通过 |
| 重点行为 | TCP低流量门槛、阈值边界、for和延迟解除；OOM增量/重置/事件窗口；100%内存降噪；CPU/文件系统不受内存策略影响；缺失/stale；记录公式；各扩展模块代表性输入 |
| hostname | 静态hostname、nodename、实时uname、历史记录、冲突、跨job隔离、缺失共7种规则侧渲染通过；NodeDown不再连接历史nodename label |
| 主配置组装 | 三套规则分别加入脱敏的最小Prometheus主配置，promtool check config通过；不是未修改现场主配置的在线检查 |
| Alertmanager配置 | 示例配置语法通过；warning、critical、emergency、info、Watchdog及未知severity共6项接收器路由测试通过 |
| 抑制集成 | 启动隔离真实Alertmanager，本地注入告警，14项断言通过；验证同condition跨级抑制、跨主机/站点/独立评价器隔离、磁盘子对象隔离、缺失身份保护、NodeDown派生阈值抑制及OOM证据保留 |
| 公共仓库检查 | 新增/修改内容通过仓库现有脱敏检查规则；没有导入现场地址清单、认证文件或原始配置ZIP |

## 验证边界

- 不是146条规则逐条穷举了所有异常输入；扩展模块做了语法与代表性场景测试，实际软件版本/标签/collector仍需验收。
- 单元测试使用模拟输入，不证明真实Exporter正在输出对应指标，也不证明每个应监控对象已入库。
- 本地抑制测试没有任何外部接收器；路由测试只验证接收器选择，不证明最终用户收到消息。
- 未访问或reload现场Prometheus/Alertmanager，未修改通知网关，未把hostname线上问题标记解决。
- 未确认现场软件版本与本次工具版本一致；升级/部署前应使用现场配套工具重跑。
- 还需现场确认有效rule_files、目标覆盖、核心输入存在与新鲜度、评价错误/性能、真实告警和恢复投递、mixed firing/resolved显示及外部心跳失联演练。

## 重跑

在仓库根目录安装PyYAML并将工具放入PATH，执行 `bash tools/validate_alert_rules.sh`。也可设置PROMTOOL、AMTOOL、ALERTMANAGER为各二进制的绝对路径。CI使用相同入口。

任何后续规则或policy修改都应重跑。现场证据更新到CONTEXT.md，不能只保留聊天中的结论。
