# zabbix-template

用于统一存放本项目后续所有 Zabbix 相关资产。

## 当前基线

- Target: Zabbix 7.0 LTS
- Scope: Templates / SNMP / Import-export artifacts / Validation notes / Migration notes
- Repository role: Zabbix 专用仓库
- Legacy content: retired

## 当前最新模板

### H3C Comware

- V5: `templates/network/h3c/H3C_Comware_V5_Production_by_SNMP_Zabbix_7.0_rc3.2.json`
  - visible name: `H3C Comware V5 Production by SNMP`
  - vendor version: `2.0.0-rc3.2-v5`
- V7: `templates/network/h3c/H3C_Comware_V7_Production_by_SNMP_Zabbix_7.0_rc3.2.json`
  - visible name: `H3C Comware V7 Production by SNMP`
  - vendor version: `2.0.0-rc3.2-v7`
- Validation: `docs/validation/H3C_Comware_V5_V7_Zabbix_7.0_rc3.2_AUDIT.md`

当前 H3C 模板目标版本为 Zabbix 7.0 LTS。V5/V7 分开维护，避免跨 Comware 大版本混用。

## 目录约定

- `templates/` — Zabbix templates
- `docs/` — 设计、迁移、兼容性与验收文档
- `tools/` — 模板校验、转换、辅助脚本

后续所有 Zabbix 模板与配套文档统一在本仓库维护。
