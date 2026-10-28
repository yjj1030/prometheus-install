# 维护约定

必须先读根目录BASELINE.md。遵守VERSION统一版本、prod/nonprod/common短文件名、分类分级和BASELINE.json校验。路径/契约不兼容升MAJOR，兼容新增升MINOR，规则修正升PATCH；同一基线不得混用版本。

对监控告警规则的后续工作，以本仓库为维护入口。

- 每次交付同步DEPLOY.md、仓库首页、场景及三套目录入口；明确选哪些文件、放哪里、如何替换/校验/reload/验收/回退。
- 仅文档澄清沿用规则版本，记录Git提交和CHANGELOG并刷新基线清单；运行时规则及annotation变更按版本规范升级。

- 通用场景维护在 `catalog/`；机构定制统一在 `scenarios/sk-91/`。
- 开始修改定制规则前先读 `scenarios/sk-91/CONTEXT.md`，把新确认的决策和现场证据更新进去。
- 三个部署版本由 `tools/build_alert_rules.py` 生成，编辑源再生成；不得单独修改生成副本。
- 测试内存降噪版必须保留OOM和真实100%内存严重告警，其余内存阈值停用；CPU、磁盘、可用性等与nonprod相同。生产及非生产均须有100%独立告警，不得再次关闭。当前三套目录固定为prod、nonprod、nonprod-memory。
- 新规则须说明指标来源、启用条件、单位、处理动作和缺失语义。公共阈值只是起点，不能称为已通过现场验证。
- 提交前执行 `tools/validate_alert_rules.sh`；工具缺失或现场验证未完成时如实记录，不声称全部通过。
- 规则校验不代表真实接收人已收到。hostname现场问题必须按实际payload逐段核实。
- 保护现有安装器及历史文件；不得把生产账号、密钥或真实网络清单写进公共仓库。
