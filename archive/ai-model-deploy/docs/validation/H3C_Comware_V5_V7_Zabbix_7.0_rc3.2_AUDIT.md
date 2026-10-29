# H3C Comware V5/V7 Production by SNMP — Zabbix 7.0 LTS rc3.2

## 根因

Zabbix 7.0 LLD 会从 Graph Prototype 创建实际 Host Graph。

如果 Host 上已经存在同名 Graph，而 Graph Items 集合不一致，LLD/模板同步不会把它视为同一 Graph，会产生：

```text
图形 "...: Network traffic" 已存在于 "<host>" 中 (监控项不一致)
```

普通 Unlink 会保留 Items、Triggers、Graphs、LLD 等实体，因此历史上做过模板 unlink/replace 后，Host 上可能残留同名 Graph，继续与新模板发生冲突。

## rc3.2 处理

不删除历史 Items，不使用 Unlink and clear。

对 V5/V7 三个 Graph Prototype 进行 Comware 主版本命名隔离：

### V5

- `H3C V5 - {#MODULE_NAME}: CPU utilization`
- `H3C V5 - {#MODULE_NAME}: Memory utilization`
- `H3C V5 - Interface {#IFNAME}({#IFALIAS}): Network traffic`

### V7

- `H3C V7 - {#MODULE_NAME}: CPU utilization`
- `H3C V7 - {#MODULE_NAME}: Memory utilization`
- `H3C V7 - Interface {#IFNAME}({#IFALIAS}): Network traffic`

Graph Prototype UUID、Item Prototype UUID、Item Key、OID、监控数据和历史数据均未因本修正而改变。

Dashboard 中对 Graph Prototype 的引用同步更新。

## 三轮最终校验

### Validation 1 — Zabbix 7.0 结构与引用闭包

PASS

- export version 7.0
- UUIDv4 / unique
- value-map closure
- dependency/recovery closure
- graph -> item prototype
- dashboard -> graph prototype

### Validation 2 — rc3.1 -> rc3.2 身份连续性

PASS

- Template UUID unchanged
- 全部模板内部对象 UUID 集合 unchanged
- 3 个 Graph Prototype UUID unchanged
- Graph Item 集合 unchanged
- 仅 Graph Prototype 名称增加 V5/V7 namespace

### Validation 3 — Host Graph 名称冲突模拟

PASS

- legacy graph names ∩ V5 graph names = 0
- legacy graph names ∩ V7 graph names = 0
- V5 graph names ∩ V7 graph names = 0
- 旧冲突名 `Interface {#IFNAME}({#IFALIAS}): Network traffic` 在 rc3.2 V5/V7 中均不存在
- Dashboard 仅引用新的 namespaced Graph Prototype

## 导入方式

### V5

V5 仍是旧生产模板 `H3C Comware Production by SNMP` 的原位升级。

在：

`Data collection -> Templates -> Import`

使用：

- Update existing: ON
- Create new: ON
- Delete missing: OFF

不要在 Host 页面执行 Replace。
不要 Unlink and clear。

### V7

V7 是独立新模板，直接导入并用于新的 Comware V7 Host。

## 旧 Host Graph

rc3.2 通过新名称避免与旧 Graph 冲突。

旧 Graph 本身不保存时序历史；历史数据属于 Items。旧 Graph 可以在完成模板稳定性验证后，再按 Host 实际状态逐步清理，不应为了清 Graph 删除历史 Items。