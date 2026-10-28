# 规则变更

## v3.0.0 · 2026-10-28

- 首次将后续规则维护迁入本Git仓库，区分通用catalog和本场景。
- 提供production、test-recommended、test-memory-oom-only三套；测试非内存部分一致。
- 澄清并落实OOM-only：取消测试版100%内存告警；保留其他类别。
- 保留生产原阈值及nonprod/stress混合目标兼容。
- NodeDown移除历史nodename label连接，主机名保留annotation回退。
- 增加指标/规则/路由测试与抑制集成验证；验证范围见VALIDATION.md。
- 未修改安装器，未部署至现场，hostname线上问题仍待实际payload核实。
