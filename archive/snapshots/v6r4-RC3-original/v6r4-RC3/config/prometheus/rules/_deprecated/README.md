# ==============================================================================
# _deprecated/ 目录说明
#
# 审核 P1-01: 旧规则退出活动加载范围。
# 本目录下的 *.yml 文件**不会被 prometheus.yml / vmalert 加载**：
#   - 文件名前缀为 `_` 与目录模式 (`*-deprecated.yml`) 都不匹配 glob `*.yml`
#   - 即使被显式引用，规则自身标注 `paused: true` 阻断实际生效
#
# 保留原因：
#   1. v2.x → v3.0.0-rc4 演进期间，部分规则被拆分 / 重写 / 合并
#   2. 历史告警抑制链路引用旧 condition_id；彻底删除会破坏链追溯
#   3. 用户可能需要在 6 个月回退窗口内对比新旧告警
#
# 如何彻底删除：
#   - 等所有 site 升级到 v3.0.0-rc5+，并且无抑制链路引用旧 condition_id
#   - 走 PROJECT_AUDIT_RESPONSE 流程（P0/P1 闭环 §44）
#   - 删除时连同 suppression_eq 表中引用一并清理
# ==============================================================================

# 已下架但保留的 v2.x 规则（应在 v3.0.0-rc5 之后清理）：

# 1. node_alerts_v2.4.0.yml（原版节点告警，已被 node_alerts_v3.0.0_prod.yml 取代）
#    关键变化：
#    - condition_id 命名空间重构（NODE_CPU_HIGH → CPU_USAGE_HIGH 等）
#    - 增加 alert_policy 过滤
#    - 增加 asset_type / alert_type 标签
#    - severity 改用 info / warning / critical / emergency 四档
#
# 2. cpu_alerts_legacy.yml（v1 时代 CPU 规则，含 percpu 计算，已下架）
#    替换为 node_usage_record_rules_v3.0.0.yml 中的 9 合约指标
#
# 3. fs_alerts_legacy.yml（v1 时代 FS 规则，缺失 mountpoint label，已下架）
#    替换为 node_alerts_v3.0.0_prod.yml 中 FilesystemFillingUp* 系列
#
# 4. snmp_alerts_v2.x.yml（旧版 SNMP 规则，含 if_mib sysUpTime 错位）
#    替换为 snmp_alerts_v3.0.0.yml（含 if_mib_system 组合模块）
#
# 5. memory_alerts_legacy.yml（v1 时代 Memory 规则，Swap 语义错误）
#    替换为 node_alerts_v3.0.0_prod.yml 中的 MemoryPressure 系列

# 占位文件（确保目录被版本控制追踪；可删除此文件而不影响 _deprecated/ 语义）
groups: []
