# 告警模板维护基线

当前版本以根目录 `VERSION` 为唯一版本入口；完整文件范围和SHA256见 `BASELINE.json`。本基线只管理catalog、机构场景及配套工具/测试，不改变既有安装器和历史归档的版本。

**现场操作先读[部署说明](DEPLOY.md)**：选择一套、确认实际加载目录、暂存校验、备份替换、重载验收和回退均以该文档为操作入口。已有Prometheus更新规则不需要重新运行安装器。

## 目录和文件名

| 范围 | 目录 | 文件名约定 |
|---|---|---|
| 通用模块 | catalog/按组件分类 | `<用途>_common_vx.y.z.yml` |
| 生产版 | scenarios/sk-91/prod | `node_prod_vx.y.z.yml`、`recording_prod_vx.y.z.yml`、`prometheus_prod_vx.y.z.yml` |
| 建议非生产版 | scenarios/sk-91/nonprod | `node_nonprod_vx.y.z.yml`、`recording_nonprod_vx.y.z.yml`、`prometheus_nonprod_vx.y.z.yml` |
| 非生产内存降噪版 | scenarios/sk-91/nonprod-memory | 与建议非生产版相同的三个短文件名；目录区分策略 |
| 共用路由示例 | scenarios/sk-91 | `alertmanager_common_vx.y.z.yml` |
| 机构源策略 | scenarios/sk-91/policies | 带common/nonprod及版本号；仅供生成，不部署 |

文件名只保留用途、环境、版本；不附日期、final、latest、simple、修订次数。目录区分组件和策略。测试文件和维护脚本保持稳定名称，不属于可部署模板。每个实例只选一套，不能叠加prod和nonprod，也不能在加载目录同时保留多版本YAML。历史版本由Git提交保存。

本轮改名和目录调整属于兼容性变更，因此建立 **v4.0.0** 基线。旧v3目录不再作为当前入口；不得把删除旧目录理解为已替现场升级。

## 版本控制

- MAJOR：文件路径、标签身份、指标契约或部署方式不兼容。
- MINOR：兼容地增加场景/规则/能力。
- PATCH：修正表达式、阈值、持续时间、运行时annotation说明或既有规则行为。阈值变化也必须记录影响。
- 仅补充README/部署文档、不改变运行时规则、部署接口或文件名时，保留规则版本，用Git提交和CHANGELOG追踪文档修订，并刷新BASELINE.json。不得为文档澄清让全部模板反复改名。
- 同一基线所有可部署模板共用一个版本，不逐文件独立滚动；文件名版本必须等于VERSION。
- 运行 `python3 tools/check_alert_baseline.py --bump x.y.z` 更新版本引用和文件名，再补充CHANGELOG、CONTEXT，重新生成、测试；最后 `--write` 刷新基线清单，执行完整验证。
- CI检查版本、文件名、分类分级、生成一致性、清单SHA256、规则、路由和抑制。不能只修改生成文件或只改文件名。

## 部署交付要求

每次发版同步维护[DEPLOY.md](DEPLOY.md)、仓库首页和场景入口，至少包含：

1. 三套场景选择、准确文件名和配套依赖；不能只给目录树。
2. TLS可选项、Alertmanager示例、源策略、测试和工具各自用途及部署位置。
3. 旧文件与新文件对应关系、精确替换清单、备份位置；避免通配加载多套或多版本。
4. 现场主配置、规则加载路径、进程/容器实例识别；以实际配置为准。
5. 暂存规则检查、实际主配置检查、重载方式和新规则加载验证。
6. 告警、恢复、抑制、hostname及最终通知验收；不能把语法通过写成现场验收完成。
7. 明确的回退清单和重载验证，覆盖复制中途失败；保留无关业务规则。

部署文档属于基线受管文件，CI校验SHA256。示例命令在隔离目录验证，涉及真实实例的路径、凭据和PID由现场填入，不从历史片段推断为当前事实。

## 分类

类别使用稳定的category，不把操作系统名或Exporter名称当作故障类别。组件通过目录、job、asset_type和对象标签识别。

| category | 含义 |
|---|---|
| availability | 采集/端点/服务可用性 |
| compute | CPU、iowait、steal |
| memory | MemAvailable、Swap、PSI、OOM |
| filesystem | 空间、inode、只读 |
| storage | IO、阵列及存储健康 |
| network | 带宽、错误、重传、接口 |
| system_limit | fd、conntrack等系统限额 |
| time | 时间同步与偏差 |
| certificate | TLS及证书生命周期 |
| monitoring | 监控配置、规则、采集覆盖、存储/投递链路及心跳 |
| database / messaging | 数据库 / 消息中间件 |
| container / kubernetes | 容器 / 编排工作负载 |
| application / backup / slo | 应用任务 / 备份恢复 / 业务错误预算 |

同一故障用condition_id关联，资源对象保留device/mountpoint/direction等维度。类别用于职责分派，不能仅凭同类别跨对象抑制。

## 分级

| severity | 响应意义 | 通知原则 |
|---|---|---|
| emergency | 需升级协调的紧急风险 | 本机构保留的扩展等级，需明确升级链路 |
| critical | 需立即响应的故障或重大风险 | 进入值班响应；恢复和业务验证分开 |
| warning | 需要计划处置的持续风险 | 聚合通知或工单，避免与严重级重复 |
| info | 观察或提示 | 默认仅记录，不反复推群 |
| none | 仅Watchdog持续心跳 | 发独立deadman接收器，不进入普通告警群 |

等级代表响应紧迫性，固定资源阈值是当前策略起点，不是所有业务的故障标准。改级须同时核对影响、处理动作、路由和抑制。高CPU、磁盘busy或重传比例本身不能证明业务已不可用。

## 本机构必须保留的策略

- **生产、非生产：真实内存使用率≥100%均有独立critical告警，无额外for等待，延迟解除2分钟。**记录指标每分钟计算，通知仍受Alertmanager分组时序影响。
- 非生产内存降噪版保留OOM和100%，停用其他内存阈值；非内存规则与建议非生产版一致。
- hostname按每条alert解析，查询回退放annotation；未取得现场通知证据不得声称线上显示已修复。
- 后续确认都写入scenarios/sk-91/CONTEXT.md；通用变更与机构参数分开维护。
