# ==============================================================================
# alertmanager/suppression_notes.md
#
# 抑制链路 equal 键文档（02 §6.2 + 审核 P1-08）
# ==============================================================================
#
# 抑制等键（Alertmanager inhibit_rules.equal）：
#   condition_id + site + origin_prometheus + job + instance
#           + device + mountpoint + namespace + pod + container
#
# 含义：所有 label 一致的两条 alert，后者被前者抑制
#
# ==============================================================================
# 审核 P1-08: 同设备不同接口不互抑制（snmp_exporter）
#
# 场景：交换机 SW-CORE-01 上有 48 个端口
#   - ifName=Eth1/1 ifOperStatus=down
#   - ifName=Eth1/2 ifOperStatus=down
#
# 期望：两条 alert 应分别发送（运维要看到每个端口的状态）
# 不能：因 condition_id 都为 switch_iface_down 互抑制
#
# 解决：Alertmanager 中将 snmp_exporter 系列 alert 的抑制等键中加入 `ifName`
#   （针对 switch_iface_down / switch_iface_in_err / switch_iface_out_err /
#    switch_iface_in_util / switch_iface_out_util / switch_iface_util）
# 通过 alertmanager.yml 的 route.group_by 包含 ifName + ifIndex 实现
#
# 完整配置见：
#   config/alertmanager/alertmanager.yml
#   config/alertmanager/inhibit_rules.yml
# ==============================================================================

# 示例 inhibit_rules.yml 片段：
#
# inhibit_rules:
#   # 同一 instance 上同 condition_id 抑制（保留旧语义）
#   - source_matchers:
#       - alertname="SwitchInterfaceDown"
#     target_matchers:
#       - alertname="SwitchInterfaceUtilHigh"
#     equal: ['instance', 'device', 'ifName']
#
#   # 同 condition_id 但不同 ifName 不抑制
#   # （隐式：因为 equal 列表里有 ifName，不同 ifName 的 alert 不在抑制等键范围内）
#
#   # 接口错误多级抑制（warning → critical）
#   - source_matchers:
#       - alertname="SwitchInterfaceInErrHigh"
#       - severity="warning"
#     target_matchers:
#       - alertname="SwitchInterfaceInErrHigh"
#       - severity="critical"
#     equal: ['instance', 'device', 'ifName']

# ==============================================================================
# 验证方法
# ==============================================================================
#
# 1. 临时关闭 Eth1/1（sudo ifconfig Eth1/1 down）
# 2. 临时关闭 Eth1/2（sudo ifconfig Eth1/2 down）
# 3. 等待 3 分钟后检查 Alertmanager UI：
#    - 应看到 2 条独立的 SwitchInterfaceDown，labels.ifName 分别是 Eth1/1 / Eth1/2
#    - 不应只看到 1 条（被合并）
# 4. 检查 suppress_silenced 字段：无被抑制的 instance
