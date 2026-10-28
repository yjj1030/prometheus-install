# 自定义指标契约

`application/contracts.yml` 和 `slo/http.yml` 是需先实现适配的模板。`ops_*` 是本仓库定义的接口，不是任何数据库、备份软件或通知网关已经提供的指标。

| 指标 | 类型与单位 | 必需标签/含义 |
|---|---|---|
| `ops_backup_last_success_timestamp_seconds` | gauge，Unix秒 | service,backup_job；成功备份完成时间，失败不得覆盖；从未成功置0 |
| `ops_backup_rpo_seconds` | gauge，秒，>0 | 与上一项一对一；经确认的RPO |
| `ops_restore_test_last_success_timestamp_seconds` | gauge，Unix秒 | service,backup_job；完成实际恢复校验的时间，不能用备份成功代替 |
| `ops_restore_test_max_age_seconds` | gauge，秒，>0 | 同上；演练最大间隔 |
| `ops_batch_last_success_timestamp_seconds` | gauge，Unix秒 | service,batch_job；持久保存，成功才更新 |
| `ops_batch_max_delay_seconds` | gauge，秒，>0 | 同上；调用方须处理工作日、节假日、停跑窗口 |
| `ops_business_queue_oldest_age_seconds` | gauge，秒 | service,queue；无待办时输出0，采集失败时不能输出0 |
| `ops_business_queue_max_age_seconds` | gauge，秒，>0 | 同上；业务可接受时限 |
| `ops_consumer_lag_seconds` | gauge，秒 | service,consumer_group,topic；转换自消息时间或积压年龄，不直接把offset数量当秒 |
| `ops_consumer_lag_budget_seconds` | gauge，秒，>0 | 同上；预算 |
| `ops_process_running` | gauge，0或1 | service,process,managed=true；显式期望清单中的进程，即使进程不存在也输出0 |
| `ops_certificate_not_after_seconds` | gauge，Unix秒 | service,certificate；证书到期时间，不含私钥、路径秘密或证书正文 |
| `ops_gateway_delivery_failures_total` | counter，次数 | service,channel；最终下游投递失败；网关HTTP接收成功不能计作最终成功 |
| `ops_expected_metric_info` | gauge，恒为1 | service,metric_id；来自独立受管清单 |
| `ops_observed_metric_info` | gauge，恒为1 | 与上一项同维度；只有真实输入存在且新鲜时输出，过期停止输出 |
| `ops_http_requests_total` | counter，请求数 | site,environment_class,service,result=good或bad；互斥且完备的SLI事件 |

所有适配指标还应携带稳定的 site/environment_class；多采集副本须在进入本契约之前去重。二元运算两侧标签集合须一致，阈值指标每个对象仅一条。示例中的 `on(...)` 包括site/environment_class；阈值与观测指标必须保留相同作用域。独立评价域内两侧同时没有这些标签时可以匹配，集中评价前必须补齐。

`ops_http_requests_total` 的good/bad时序都应在服务启动时初始化为0。bad必须由业务SLI定义，不能简单把所有4xx或所有TCP重传当成用户失败。禁止URL全文、用户ID、订单号等高基数标签。

SLO示例是30天99.9%：快速消耗14.4倍（1h/5m）、慢速6倍（6h/30m）、工单1倍（3d/6h）。短窗口至少100次请求仅是演示门槛，可能漏掉低流量的重要失败；低流量服务应结合合成探测、事件严重性或更适合的SLI，不照搬门槛。变更SLO或统计周期必须重算预算系数。

缺失数据、采集错误和真实零值必须区别处理。不能用 `or vector(0)` 把未知当成健康。全量目标从未入库、全部采集器都停止、期望清单本身缺失，需要独立库存/外部心跳覆盖。
