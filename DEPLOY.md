# 告警规则部署说明

适用于已有Prometheus实例更新规则。规则版本读取[VERSION](VERSION)，本页示例为v4.0.0。此次文档补充不改变规则行为，不代表已部署到现场。

## 1. 选一套，明确要复制哪些文件

| 场景 | 取文件的目录 | 必须配套部署的三个文件 |
|---|---|---|
| 生产 | [prod](scenarios/sk-91/prod/) | recording_prod_v4.0.0.yml、node_prod_v4.0.0.yml、prometheus_prod_v4.0.0.yml |
| 建议非生产 | [nonprod](scenarios/sk-91/nonprod/) | recording_nonprod_v4.0.0.yml、node_nonprod_v4.0.0.yml、prometheus_nonprod_v4.0.0.yml |
| 非生产内存降噪 | [nonprod-memory](scenarios/sk-91/nonprod-memory/) | recording_nonprod_v4.0.0.yml、node_nonprod_v4.0.0.yml、prometheus_nonprod_v4.0.0.yml |

每个实例只选一套。recording计算记录指标，node定义主机告警，prometheus监控Prometheus自身；三份必须配套。两个非生产目录的文件名相同，策略靠目录区分。

所有版本均保留OOM及真实100%内存严重告警。非生产内存降噪版停用其他内存阈值，非内存规则与建议非生产版相同。规则按job=node_exporter及job=prometheus编写；启用前确认现场任务名一致。

生产目录中的正常目标采用生产策略；显式alert_policy=nonprod/stress的目标采用非生产内存降噪策略。若同一生产实例希望某些非生产目标采用“建议非生产”策略，需要单独定制目标选择器，不能直接再叠加整套nonprod目录。

### 证书监控另外选择

| 文件 | 何时使用 |
|---|---|
| [tls_common_v4.0.0.yml](catalog/probes/tls_common_v4.0.0.yml) | 已有Blackbox TLS探测，需监控证书到期、过期及TLS观测异常时加这一份 |
| [certificate_policy_common_v4.0.0.yml](catalog/probes/certificate_policy_common_v4.0.0.yml) | 独立可选的证书有效期观察，不是普通到期监控必需项，也不能据此判定违规 |

已有证书规则时，替换同职责旧文件；不要保留旧证书规则再叠加新TLS规则。原来启用的certificate_validity_policy.yml不会因为这次更新自动停用，需明确记录继续、替换还是移出；不要误删其他职责的规则。

### 其他文件放哪里

| 内容 | 用途及部署位置 |
|---|---|
| 三套目录中的三个YAML | 放入对应Prometheus实际加载的规则目录 |
| TLS/可选证书YAML | 按需放入同一Prometheus规则目录 |
| [alertmanager_common_v4.0.0.yml](scenarios/sk-91/alertmanager_common_v4.0.0.yml) | Alertmanager路由/抑制示例，合并到现有Alertmanager配置，不能放入Prometheus规则目录 |
| policies/、tools/、tests/ | 生成源、维护工具和测试，不部署进规则目录 |
| catalog/其他模块 | 后续按实际Exporter和软件版本选用，不把整个catalog复制到当前实例 |
| BASELINE.md、BASELINE.json、VERSION、README等 | 版本、校验及操作文档，不由Prometheus加载 |
| installers/ | 新装监控组件时使用；本次已有实例更新规则无需重新运行安装器 |

## 2. 找准实际主配置与规则目录

在实际运行Prometheus的主机或容器内检查进程启动参数：

```bash
pgrep -a -x prometheus
```

从对应实例的`--config.file`确定主配置，核对其中`rule_files`。相对路径按该主配置的位置核对；不要只凭当前shell目录判断。现场若有多个实例，逐实例确认端口、配置和PID。

你此前展示过`/etc/rules`，也提供过安装目录下的`etc/rules`配置，两者可能是容器映射或不同位置。**复制目的地必须与实际加载路径一致。**

例如，主配置若确实是下面这样，才复制到`/etc/rules`：

```yaml
rule_files:
  - /etc/rules/*.yml
```

这个模式不递归：子目录、ZIP不会被加载；当前目录中所有匹配的旧YAML仍会加载。若主配置明确列出旧文件名，新名称不会自动加载，必须同步修改rule_files；修改前备份主配置，并把配置恢复纳入回退。下文命令按**已经核实的非递归通配目录**演示，不自动改主配置。

## 3. 准备文件并固定来源

可在管理机下载同一提交的文件后传到服务器，或者获取整个仓库。使用Git时，先审核本次要部署的提交，再固定到该提交；不要把`git pull`当成自动发布。

```bash
git clone https://github.com/yjj1030/prometheus-install.git
cd prometheus-install
git log -5 --oneline
# 确认当前提交为本次要部署的版本后，固定当前快照。
git checkout --detach "$(git rev-parse HEAD)"
git rev-parse HEAD
cat VERSION
python3 tools/check_alert_baseline.py
```

最后一项是管理机的仓库基线检查，依赖Python3及PyYAML；没有这些工具时，可在管理机完成，不要求在生产服务器安装整套开发工具。下载单独文件时，从同一个已核对的提交获取，并按BASELINE.json中对应路径的SHA256核对。

仓库VERSION是规则版本，安装器RC版本是另一条基线。仓库未承诺存在与VERSION同名的Git标签，不能假定`git checkout v4.0.0`可用。

## 4. 选择参数，先在加载目录外校验

下面Bash代码按顺序在同一终端执行。先填入现场真实路径，任何一步失败都停止处理。`REPO_DIR`指服务器上已核对的仓库副本；若文件由管理机传输，可传输所选目录及按需证书文件，并相应调整来源路径。

```bash
set -euo pipefail

REPO_DIR='/填写仓库绝对路径'
PROM_CONFIG='/填写Prometheus实际主配置绝对路径'
RULE_DIR='/填写主配置实际加载的规则目录'
PROMTOOL='/填写现场配套promtool绝对路径'
PROM_URL='http://127.0.0.1:9091'  # 按实际端口、协议、路径前缀调整

PROFILE='prod'       # 只选：prod、nonprod、nonprod-memory
WITH_TLS=1           # 已有TLS探测且本次替换TLS规则填1，否则填0

test -d "$REPO_DIR"
test -f "$PROM_CONFIG"
test -d "$RULE_DIR"
test -x "$PROMTOOL"
case "$PROFILE" in
  prod) RULE_ENV='prod' ;;
  nonprod|nonprod-memory) RULE_ENV='nonprod' ;;
  *) printf 'PROFILE错误\n' >&2; exit 1 ;;
esac
case "$WITH_TLS" in 0|1) ;; *) exit 1 ;; esac
RULE_VERSION=$(tr -d '\r\n' < "$REPO_DIR/VERSION")
STAGE_DIR=$(mktemp -d /var/tmp/prometheus-rules-stage.XXXXXX)

for kind in recording node prometheus; do
  file="${kind}_${RULE_ENV}_v${RULE_VERSION}.yml"
  install -m 0644 "$REPO_DIR/scenarios/sk-91/$PROFILE/$file" "$STAGE_DIR/$file"
done
if [ "$WITH_TLS" = 1 ]; then
  file="tls_common_v${RULE_VERSION}.yml"
  install -m 0644 "$REPO_DIR/catalog/probes/$file" "$STAGE_DIR/$file"
fi
"$PROMTOOL" check rules "$STAGE_DIR"/*.yml
printf '暂存目录：%s\n' "$STAGE_DIR"
```

至此只创建暂存目录，运行中的规则尚未改变。检查输出必须成功；模板有keep_firing_for等字段，现场版本不支持时应先处理兼容性，不能直接删字段后继续部署。

## 5. 备份并替换同职责旧规则

先查看当前目录，与下表核对：

```bash
find "$RULE_DIR" -maxdepth 1 -type f -name '*.yml' -print
```

| 原文件示例 | 生产版替换为 |
|---|---|
| node_recording.yml | recording_prod_v4.0.0.yml |
| node_alerts.yml | node_prod_v4.0.0.yml |
| prometheus_self.yml | prometheus_prod_v4.0.0.yml |
| certificate_alerts.yml | tls_common_v4.0.0.yml，仅本次选择TLS时替换 |
| 其他旧版本的同职责文件 | 所选场景的对应新文件；旧名称必须加入下面的明确清单 |

下面OLD_RULES以此前旧文件名为例；**先按刚才的目录清单补齐实际旧版本名称**。保留其他业务规则，不按`*.yml`整目录删除。备份、暂存必须在所有生效rule_files模式之外。

```bash
OLD_RULES=(node_recording.yml node_alerts.yml prometheus_self.yml)
# 若当前已部署带版本号的同职责规则，在数组中加入这些实际旧文件名。
if [ "$WITH_TLS" = 1 ]; then
  OLD_RULES+=(certificate_alerts.yml)
fi
for file in "${OLD_RULES[@]}"; do
  case "$file" in ''|*/*|..|*.yaml) exit 1 ;; *.yml) ;; *) exit 1 ;; esac
done

BACKUP_DIR=$(mktemp -d /var/tmp/prometheus-rules-backup.XXXXXX)
chmod 700 "$BACKUP_DIR"
mkdir "$BACKUP_DIR/rules-before" "$BACKUP_DIR/retired"
cp -a "$RULE_DIR/." "$BACKUP_DIR/rules-before/"
cp -a "$PROM_CONFIG" "$BACKUP_DIR/prometheus-config.before"
printf '%s\n' "${OLD_RULES[@]}" > "$BACKUP_DIR/old-rules.list"
for source in "$STAGE_DIR"/*.yml; do
  basename "$source"
done > "$BACKUP_DIR/new-rules.list"
printf '回退备份：%s\n' "$BACKUP_DIR"

for file in "${OLD_RULES[@]}"; do
  if [ -f "$RULE_DIR/$file" ]; then
    mv -- "$RULE_DIR/$file" "$BACKUP_DIR/retired/$file"
  fi
done
for source in "$STAGE_DIR"/*.yml; do
  file=$(basename "$source")
  if [ -f "$RULE_DIR/$file" ]; then
    mv -- "$RULE_DIR/$file" "$BACKUP_DIR/retired/$file"
  fi
  install -m 0644 "$source" "$RULE_DIR/$file"
done
```

这是人工替换流程，不是原子发布；应在既定变更窗口执行，期间不要让另一个自动化任务同时写规则或触发reload。若复制途中失败，执行第9节回退后重新检查。记录BACKUP_DIR、STAGE_DIR、提交SHA和所选PROFILE，保留至验收完成。

## 6. 检查实际主配置，再重载

```bash
"$PROMTOOL" check rules "$RULE_DIR"/*.yml
"$PROMTOOL" check config "$PROM_CONFIG"
```

两项都成功后才重载；任一失败先回退，不继续reload。主配置若还引用旧名称，要在已备份前提下修正为本次实际文件，再重跑检查。

已启用`--web.enable-lifecycle`的实例可执行：

```bash
curl --fail --silent --show-error --max-time 30 \
  -X POST "$PROM_URL/-/reload"
```

未启用HTTP重载时，按既有运维方式对**已确认的该实例PID**发送SIGHUP。不要用向所有Prometheus进程广播信号的命令；systemd、容器部署应按对应实例管理方式处理。启用TLS/认证/反向代理时按现场访问方式调用，不修改服务安全配置来迁就示例。

若使用进程信号方式，在第2节已核对PID和主配置对应关系后执行下列代码。它与HTTP重载二选一：

```bash
PROM_PID='填写已核对的Prometheus进程PID'
case "$PROM_PID" in ''|*[!0-9]*) exit 1 ;; esac
test "$PROM_PID" -gt 1
kill -HUP "$PROM_PID"
```

## 7. 验证确实加载了新规则

```bash
curl --fail --silent --show-error --max-time 15 "$PROM_URL/-/ready"
curl --fail --silent --show-error --max-time 15 \
  "$PROM_URL/api/v1/rules" -o "$STAGE_DIR/loaded-rules.json"
```

然后在Prometheus的`/rules`页面或API响应中核对：

- file字段指向本次新文件，旧的同职责规则已不再加载；HTTP请求成功本身不证明更新成功。
- 等待至少两个评价/记录周期，确认规则完成评价、health正常、lastError为空。
- 本次三个文件应有：生产45条记录＋67条告警；建议非生产45＋31；内存降噪45＋28。TLS另外加7条。其他原有业务规则和可选项单独计数。
- 查询`node:memory_usage:percent`等记录指标确有值，目标覆盖符合清单；新装不能立即得到24小时hostname历史。
- 检查`prometheus_config_last_reload_successful`及规则评价失败指标、日志；没有告警不等于没有错误。

使用受控测试目标验证告警、恢复、路由、抑制和消息字段；不要在生产主机耗尽内存来触发测试。**100%规则无额外for等待，但记录指标每分钟计算，通知还受Alertmanager分组时序影响。**

## 8. Alertmanager单独处理

`alertmanager_common_v4.0.0.yml`是共用示例，接收地址为无效示例地址。不要整份覆盖现有配置，也不要复制进Prometheus规则目录。

需要结合现场配置核对并合并：

1. severity路由及实际接收器，保留现场地址、认证和模板。
2. 同对象同condition的分级抑制、NodeDown派生阈值抑制，以及100%内存抑制较低内存阈值的规则。OOM事件保留。
3. equal中的site、origin_prometheus、environment_class、job、instance及资源子维度；必要标签缺失时示例抑制可能不生效。
4. info默认记录、Watchdog独立deadman接收器与普通消息渠道的职责。

改动前单独备份Alertmanager配置，用现场配套的`amtool check-config`检查实际配置，再按该实例方式重载并验收。Prometheus规则已加载不等于Alertmanager配置已更新；仓库CI通过也不证明真实接收人收到消息。

hostname在Prometheus每条告警annotations里已有值、最终消息仍不显示时，应继续检查Alertmanager/webhook/网关逐条渲染，修改阈值不会修复这一层。

## 9. 回退

保留同一终端的变量；若会话已断开，先从变更记录恢复准确的RULE_DIR、STAGE_DIR、BACKUP_DIR、PROM_CONFIG、PROMTOOL和PROM_URL。不要猜备份目录。

以下按备份中的明确清单恢复，兼顾复制中途失败的情况。新文件同名路径原来存在时，从rules-before恢复；原来不存在时移出新文件。其他业务规则不动：

```bash
mkdir -p "$BACKUP_DIR/failed-new"
while IFS= read -r file; do
  if [ -f "$RULE_DIR/$file" ]; then
    mv -- "$RULE_DIR/$file" "$BACKUP_DIR/failed-new/$file"
  fi
  if [ -f "$BACKUP_DIR/rules-before/$file" ]; then
    cp -a "$BACKUP_DIR/rules-before/$file" "$RULE_DIR/$file"
  fi
done < "$BACKUP_DIR/new-rules.list"
while IFS= read -r file; do
  if [ -f "$BACKUP_DIR/rules-before/$file" ]; then
    cp -a "$BACKUP_DIR/rules-before/$file" "$RULE_DIR/$file"
  fi
done < "$BACKUP_DIR/old-rules.list"
# 若本次另行修改过主配置，先恢复对应备份，核对无后续变更后再使用。
"$PROMTOOL" check rules "$RULE_DIR"/*.yml
"$PROMTOOL" check config "$PROM_CONFIG"
```

检查成功后，按第6节同一方式reload，再核对旧规则文件已加载、health和lastError正常。若Alertmanager也改过，使用它自己的备份单独回退。rules-before是完整目录副本，仅用于进一步比对/恢复；不要把它整套叠加进当前目录造成重复规则。

## 10. 后续维护入口

- 管理要求：[BASELINE.md](BASELINE.md)；策略及现场确认：[CONTEXT.md](scenarios/sk-91/CONTEXT.md)。
- 规则源和生成方法：[场景说明](scenarios/sk-91/README.md)；验证边界：[VALIDATION.md](scenarios/sk-91/VALIDATION.md)。
- 以后升级仍按“固定提交→选一套→校验暂存→备份替换→主配置检查→reload→验收”的顺序，不能让多个版本同时留在通配加载目录。
- 单纯部署文档澄清用Git提交追踪，不触发整套规则改名；运行时规则/参数/标签/annotation变更仍按版本规则升级。

重载和API行为依据：[Prometheus管理API](https://prometheus.io/docs/prometheus/latest/management_api/)、[HTTP API](https://prometheus.io/docs/prometheus/latest/querying/api/)。
