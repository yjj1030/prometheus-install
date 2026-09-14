#!/usr/bin/env python3
"""
Prometheus Node Exporter 生产发现工具

定位：
  - 适配 prometheus_installer v5.x 的标准目录结构；
  - 扫描指定 IPv4/CIDR，确认 Node Exporter；
  - 直接更新 Prometheus file_sd JSON；
  - 将“确认主机存活，但未确认 Node Exporter”的 IP 以带时间戳 TXT 写到本 .run 所在目录；
  - 首次运行时，如 node_exporter Job 不存在，则创建标准 scrape_config，并以 Prometheus 实际运行身份校验后 reload；
  - 支持公共自定义标签、排除网段以及显式 merge/replace 发布策略；
  - 所有目标显式维护 alert_policy 标签；新目标默认 prod，可选择 stress/test/uat/dev 或手工值；
  - 已有目标的合法 alert_policy 在后续扫描时保持不变，支持生成后逐项人工调整；
  - 发布后通过 Prometheus HTTP API 验证目标已进入运行时 target，杜绝“文件成功、运行时未生效”的假成功；
  - 保留 Node Exporter 原生指标标签，不把 nodename、版本等信息复制为全局目标标签；
  - 保留 Prometheus 标准实例标识 instance=IPv4:端口，增加 asset_ip 和 alert_policy；
  - 自动清理旧版扫描器注入的 name/hostname/os_nodename 等受管标签，避免覆盖原生标签。

设计原则：
  - 只保留生产发现真正需要的功能，不承担资产标签平台、DNS 管理或报表功能；
  - file_sd JSON 只承载目标地址、asset_ip、alert_policy 和经校验的低基数业务标签，并采用原子更新；
  - 受管目录和文件按 Prometheus systemd 实际 User/Group 设置最小读取权限；
  - 默认只新增/更新已确认的 Node Exporter，不自动删除历史目标，避免短时故障导致监控对象消失；
  - missing TXT 只记录“已确认存活”的主机，无法确认存活的地址不会误判为未安装；
  - Prometheus 生效 JSON 使用固定路径并原子更新；辅助 TXT 不依赖额外目录且不静默覆盖。

仅使用 Python 标准库。
"""

from __future__ import annotations

import argparse
import concurrent.futures
import errno
import fcntl
import ipaddress
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence

TOOL_NAME = "prometheus-node-discovery"
TOOL_VERSION = "2.4.1"

PROM_ROOT = Path("/usr/local/prometheus")
DEFAULT_NODE_PORT = 9102
DEFAULT_WORKERS = 64
DEFAULT_CONNECT_TIMEOUT = 0.8
DEFAULT_HTTP_TIMEOUT = 3.0
DEFAULT_MAX_HOSTS = 4096
DEFAULT_ALIVE_PORTS = (22, 80, 443)
DEFAULT_BACKUP_KEEP = 20
DEFAULT_ALERT_POLICY = "prod"
ALERT_POLICY_PRESETS = ("prod", "stress", "test", "uat", "dev")
ALERT_POLICY_LABEL = "alert_policy"
MAX_METRICS_READ = 8 * 1024 * 1024
RUNTIME_VERIFY_TIMEOUT = 45.0
RUNTIME_VERIFY_INTERVAL = 2.0

JOB_FILE_NAME = "node.yml"
TARGET_JSON_NAME = "node_exporter.json"
SCRIPT_DIR = Path(sys.argv[0]).resolve().parent
REQUIRED_RECORD_RULES = (
    "cpu:usage:rate1m",
    "mem:usage:rate1m",
    "node:cpu_usage:percent",
    "node:memory_usage:percent",
    "node:filesystem_usage:max",
    "node:disk_io_utilization:max:rate5m",
    "node:network_throughput:rate5m",
    "node:tcp_retransmission:percent",
    "node:resource_pressure:max",
)

NODE_MARKERS = (
    b"node_exporter_build_info",
    b"node_uname_info",
)
UNAME_LINE_RE = re.compile(r"^node_uname_info\{([^}]*)\}\s+[0-9.eE+-]+$", re.MULTILINE)
BUILD_LINE_RE = re.compile(r"^node_exporter_build_info\{([^}]*)\}\s+[0-9.eE+-]+$", re.MULTILINE)
LABEL_RE = re.compile(r'([a-zA-Z_][a-zA-Z0-9_]*)="((?:\\.|[^"\\])*)"')
PROM_LABEL_NAME_RE = re.compile(r"^[a-zA-Z_][a-zA-Z0-9_]*$")
ALERT_POLICY_VALUE_RE = re.compile(r"^[a-z][a-z0-9_.-]{0,63}$")
# 旧版扫描器曾把这些信息作为 file_sd 目标标签注入所有 Node Exporter 指标。
# 2.4.1 在重写目标时主动删除，防止 name 覆盖 systemd 等指标的原生 name 标签。
LEGACY_MANAGED_LABELS = {
    "instance", "name", "hostname", "os_nodename", "name_source",
    "discovered_ip", "node_exporter_port", "node_exporter_version",
    "discovery_source", "exporter", "monitor_type",
}

# 这些名称由 Node Exporter 各指标自行定义，不允许作为全局目标标签写入。
NODE_EXPORTER_NATIVE_LABELS = {
    "nodename", "domainname", "machine", "release", "sysname", "version",
    "cpu", "mode", "device", "fstype", "mountpoint", "state", "type",
}
PROMETHEUS_SOURCE_LABELS = {"job", "origin_prometheus", "site"}
TARGET_LABELS_TO_REMOVE = (
    LEGACY_MANAGED_LABELS | NODE_EXPORTER_NATIVE_LABELS | PROMETHEUS_SOURCE_LABELS
)

# 禁止自定义标签占用 Prometheus 身份标签、外部来源标签及 Node Exporter 常用原生标签。
RESERVED_LABELS = (
    LEGACY_MANAGED_LABELS
    | {"asset_ip", ALERT_POLICY_LABEL, "__name__"}
    | PROMETHEUS_SOURCE_LABELS
    | NODE_EXPORTER_NATIVE_LABELS
)

MANAGED_TARGET_LABELS = ("asset_ip", ALERT_POLICY_LABEL)
MAX_CUSTOM_LABELS = 16
MAX_LABEL_VALUE_LENGTH = 256


@dataclass(frozen=True)
class PrometheusInstance:
    name: str
    root: Path
    config: Path
    promtool: Path
    env_file: Path | None
    service: str
    listen: str


@dataclass(frozen=True)
class ScanResult:
    ip: str
    status: str  # node_exporter | alive_no_node | unknown
    hostname: str = ""
    os_nodename: str = ""
    name_source: str = ""
    node_exporter_version: str = ""
    detail: str = ""


def eprint(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def require_root() -> None:
    if os.geteuid() != 0:
        raise ValueError("请使用 root 权限运行，例如：sudo ./prometheus_node_discovery_v2.4.1.run")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog=Path(sys.argv[0]).name,
        description=(
            "扫描 IPv4/CIDR 中的 Node Exporter，并直接更新本机 Prometheus "
            "targets/node/node_exporter.json。"
        ),
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--networks",
        action="append",
        help="扫描 IPv4/CIDR，可重复或逗号分隔，例如 192.0.2.0/24,198.51.100.15",
    )
    parser.add_argument(
        "--input-file",
        type=Path,
        help="扫描范围文件，每行一个 IPv4/CIDR，支持空行和 # 注释",
    )
    parser.add_argument(
        "--exclude",
        action="append",
        help="排除 IPv4/CIDR，可重复或逗号分隔；在 --max-hosts 计数前应用",
    )
    parser.add_argument(
        "--instance",
        help="Prometheus 实例名或端口，例如 prometheus-9090 或 9090",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=None,
        help=f"Node Exporter 端口；交互默认 {DEFAULT_NODE_PORT}",
    )
    parser.add_argument(
        "--workers",
        type=int,
        default=DEFAULT_WORKERS,
        help="并发扫描线程数",
    )
    parser.add_argument(
        "--max-hosts",
        type=int,
        default=DEFAULT_MAX_HOSTS,
        help="单次最多扫描的 IPv4 地址数量",
    )
    parser.add_argument(
        "--allow-public",
        action="store_true",
        help="允许扫描公网可路由 IPv4；默认拒绝",
    )
    parser.add_argument(
        "--label",
        action="append",
        default=[],
        metavar="KEY=VALUE",
        help="给本次发现目标添加公共标签，可重复；保留标签不可设置",
    )
    parser.add_argument(
        "--alert-policy",
        default=None,
        metavar="VALUE",
        help=(
            "新发现目标或缺少该标签目标的告警策略；"
            f"内置 prod/stress/test/uat/dev，也可自定义；非交互默认 {DEFAULT_ALERT_POLICY}，"
            "已有合法值保持不变"
        ),
    )
    parser.add_argument(
        "--publish-mode",
        choices=("merge", "replace"),
        default="merge",
        help="merge 保留历史目标；replace 仅保留本次确认的 Node Exporter",
    )
    parser.add_argument(
        "--allow-empty",
        action="store_true",
        help="允许 replace 模式发布空目标集；默认拒绝，防止误清空",
    )
    parser.add_argument(
        "--yes",
        action="store_true",
        help="非交互确认，用于受控自动化执行",
    )
    parser.add_argument("--version", action="version", version=f"%(prog)s {TOOL_VERSION}")
    return parser.parse_args()


def parse_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return values
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key:
            values[key] = value
    return values


def service_active(service: str) -> bool:
    if not shutil.which("systemctl"):
        return False
    result = subprocess.run(
        ["systemctl", "is-active", "--quiet", service],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode == 0


def discover_instances() -> list[PrometheusInstance]:
    instances: list[PrometheusInstance] = []
    if not PROM_ROOT.is_dir():
        return instances

    for root in sorted(PROM_ROOT.glob("prometheus-*")):
        if not root.is_dir() or root.is_symlink():
            continue
        config = root / "etc" / "prometheus.yml"
        promtool = root / "bin" / "promtool"
        if (
            not config.is_file()
            or not promtool.is_file()
            or not os.access(promtool, os.X_OK)
            or config.is_symlink()
            or promtool.is_symlink()
        ):
            continue

        env_file = root / "etc" / "prometheus.env"
        env_values = parse_env_file(env_file) if env_file.is_file() else {}
        listen = env_values.get("PROM_LISTEN_ADDRESS", "")
        if not listen:
            match = re.fullmatch(r"prometheus-(\d+)", root.name)
            if match:
                listen = f"0.0.0.0:{match.group(1)}"
            else:
                listen = "unknown"

        instances.append(
            PrometheusInstance(
                name=root.name,
                root=root,
                config=config,
                promtool=promtool,
                env_file=env_file if env_file.is_file() else None,
                service=f"{root.name}.service",
                listen=listen,
            )
        )
    return instances


def normalize_instance_selector(value: str) -> str:
    value = value.strip()
    if value.isdigit():
        return f"prometheus-{value}"
    return value


def choose_instance(instances: Sequence[PrometheusInstance], requested: str | None) -> PrometheusInstance:
    if not instances:
        raise ValueError(
            f"未在 {PROM_ROOT}/prometheus-* 下发现 v5.x Prometheus 实例；请先安装 Prometheus。"
        )

    if requested:
        name = normalize_instance_selector(requested)
        for instance in instances:
            if instance.name == name:
                return instance
        raise ValueError(f"未找到 Prometheus 实例：{requested}")

    if len(instances) == 1:
        instance = instances[0]
        print(
            f"检测到 Prometheus 实例：{instance.name} "
            f"({'active' if service_active(instance.service) else 'inactive'}) "
            f"监听={instance.listen}"
        )
        return instance

    if not sys.stdin.isatty():
        raise ValueError("检测到多个 Prometheus 实例；非交互运行时必须使用 --instance 指定目标实例")

    print("检测到多个 Prometheus 实例：")
    for index, instance in enumerate(instances, start=1):
        state = "active" if service_active(instance.service) else "inactive"
        print(f"  {index}) {instance.name:<24} {state:<8} 监听={instance.listen}")

    while True:
        raw = input(f"请选择 Prometheus 实例 [1-{len(instances)}，q退出]: ").strip()
        if raw.lower() == "q":
            raise KeyboardInterrupt
        if raw.isdigit() and 1 <= int(raw) <= len(instances):
            return instances[int(raw) - 1]
        print("输入无效，请重新选择。")


def split_scope_values(values: Sequence[str] | None) -> list[str]:
    result: list[str] = []
    for raw in values or []:
        for item in raw.split(","):
            item = item.strip()
            if item:
                result.append(item)
    return result


def parse_common_labels(values: Sequence[str]) -> dict[str, str]:
    labels: dict[str, str] = {}
    for raw in values:
        if "=" not in raw:
            raise ValueError(f"--label 必须使用 KEY=VALUE 格式：{raw}")
        key, value = raw.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not PROM_LABEL_NAME_RE.fullmatch(key):
            raise ValueError(f"无效 Prometheus 标签名：{key}")
        if key.startswith("__") or key in RESERVED_LABELS:
            if key == ALERT_POLICY_LABEL:
                raise ValueError(
                    "alert_policy 由扫描器专门管理，请使用 --alert-policy prod|stress，"
                    "不要通过 --label 设置"
                )
            raise ValueError(
                f"标签 {key} 属于 Prometheus 身份标签、外部来源标签或 Node Exporter 原生标签，"
                "不允许通过 --label 设置"
            )
        if not value:
            raise ValueError(f"标签 {key} 的值不能为空")
        if len(value) > MAX_LABEL_VALUE_LENGTH:
            raise ValueError(
                f"标签 {key} 的值超过 {MAX_LABEL_VALUE_LENGTH} 字符"
            )
        labels[key] = value
    if len(labels) > MAX_CUSTOM_LABELS:
        raise ValueError(
            f"公共自定义标签最多允许 {MAX_CUSTOM_LABELS} 个，当前为 {len(labels)} 个"
        )
    return labels


def prompt_common_labels(values: Sequence[str]) -> dict[str, str]:
    """解析公共标签；交互运行时允许在无 --label 参数时补充资产标签。"""
    labels = parse_common_labels(values)
    if labels or not sys.stdin.isatty():
        return labels

    print()
    print("可选：为本次发现目标设置公共资产标签。")
    print("建议使用 environment/region/role/asset_group/business_system 等低基数标签。")
    print("扫描器维护 asset_ip 和 alert_policy；instance/job、外部来源标签及 Node Exporter 原生标签不可覆盖。")
    raw = input("公共标签 KEY=VALUE（多个用逗号分隔，回车跳过）: ").strip()
    if not raw:
        return {}
    items = [item.strip() for item in raw.split(",") if item.strip()]
    return parse_common_labels(items)


def validate_alert_policy(value: str, source: str = "alert_policy") -> str:
    """规范并校验告警策略值，限制为适合长期使用的低基数标签。"""
    policy = value.strip().lower()
    if not policy:
        raise ValueError(f"{source} 不能为空")
    if not ALERT_POLICY_VALUE_RE.fullmatch(policy):
        raise ValueError(
            f"{source}={value!r} 无效；必须以小写字母开头，只能包含小写字母、"
            "数字、下划线、点或连字符，长度不超过 64 个字符"
        )
    return policy


def prompt_alert_policy(value: str | None) -> str:
    """确定新目标的默认告警策略；已有目标的合法值由发布逻辑保留。"""
    if value is not None:
        return validate_alert_policy(value, "--alert-policy")
    if not sys.stdin.isatty():
        return DEFAULT_ALERT_POLICY

    print()
    print("请选择本次新发现目标的告警策略：")
    print("  1) prod（默认）：普通/生产服务器")
    print("  2) stress：高压或压力测试服务器，使用压测专用告警规则")
    print("  3) test：测试环境")
    print("  4) uat：用户验收测试环境")
    print("  5) dev：开发环境")
    print("  6) 手工输入自定义策略值")
    print("说明：当前只有 stress 会切换至压测专用规则；其他值使用本实例加载的常规规则。")
    print("已有合法值保持不变；生成后可在 JSON 中逐台调整。")
    preset_by_input = {
        "": "prod",
        "1": "prod",
        "prod": "prod",
        "2": "stress",
        "stress": "stress",
        "3": "test",
        "test": "test",
        "4": "uat",
        "uat": "uat",
        "5": "dev",
        "dev": "dev",
    }
    while True:
        raw = input("alert_policy [1/prod]: ").strip().lower()
        if raw == "q":
            raise KeyboardInterrupt
        if raw in preset_by_input:
            return preset_by_input[raw]
        if raw in {"6", "custom"}:
            custom = input("请输入自定义 alert_policy 值: ").strip()
            if custom.lower() == "q":
                raise KeyboardInterrupt
            try:
                return validate_alert_policy(custom, "自定义 alert_policy")
            except ValueError as exc:
                print(f"输入无效：{exc}")
                continue
        print("输入无效，请输入 1-6、预设值或 q 退出。")


def read_scope_file(path: Path) -> list[str]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise ValueError(f"无法读取扫描范围文件 {path}: {exc}") from exc
    result: list[str] = []
    for line_number, raw in enumerate(lines, start=1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if "," in line:
            raise ValueError(f"{path}:{line_number} 每行只能填写一个 IPv4/CIDR")
        result.append(line)
    return result


def interactive_scope() -> list[str]:
    if not sys.stdin.isatty():
        raise ValueError("未指定扫描范围；非交互运行时请使用 --networks 或 --input-file")
    print()
    print("请输入扫描范围，支持单个 IPv4、CIDR，多个范围使用逗号分隔。")
    print("示例：192.0.2.0/28,198.51.100.16/28,203.0.113.7（文档保留地址，仅示例）")
    raw = input("扫描范围: ").strip()
    if not raw:
        raise ValueError("扫描范围不能为空")
    return split_scope_values([raw])


def network_hosts(network: ipaddress.IPv4Network) -> Iterable[ipaddress.IPv4Address]:
    if network.prefixlen >= 31:
        yield from network
    else:
        yield from network.hosts()


def parse_exclusions(scope_items: Sequence[str]) -> list[ipaddress.IPv4Network]:
    exclusions: list[ipaddress.IPv4Network] = []
    for raw in scope_items:
        try:
            if "/" in raw:
                network = ipaddress.ip_network(raw, strict=False)
            else:
                address = ipaddress.ip_address(raw)
                network = ipaddress.ip_network(f"{address}/32")
        except ValueError as exc:
            raise ValueError(f"无效排除 IPv4/CIDR：{raw}") from exc
        if not isinstance(network, ipaddress.IPv4Network):
            raise ValueError(f"当前版本仅支持 IPv4 排除项：{raw}")
        exclusions.append(network)
    return exclusions


def expand_targets(
    scope_items: Sequence[str],
    max_hosts: int,
    allow_public: bool,
    exclusion_items: Sequence[str] = (),
) -> tuple[list[str], list[str]]:
    if max_hosts < 1:
        raise ValueError("--max-hosts 必须大于 0")

    exclusions = parse_exclusions(exclusion_items)
    addresses: dict[int, str] = {}
    normalized_scopes: list[str] = []
    for raw in scope_items:
        try:
            if "/" in raw:
                network = ipaddress.ip_network(raw, strict=False)
            else:
                address = ipaddress.ip_address(raw)
                network = ipaddress.ip_network(f"{address}/32")
        except ValueError as exc:
            raise ValueError(f"无效 IPv4/CIDR：{raw}") from exc

        if not isinstance(network, ipaddress.IPv4Network):
            raise ValueError(f"当前版本仅支持 IPv4：{raw}")
        normalized_scopes.append(str(network))

        for address in network_hosts(network):
            if any(address in exclusion for exclusion in exclusions):
                continue
            if address.is_global and not allow_public:
                raise ValueError(
                    f"扫描范围包含公网可路由地址 {address}；默认拒绝公网扫描。"
                    "如确有需要请显式使用 --allow-public。"
                )
            addresses[int(address)] = str(address)
            if len(addresses) > max_hosts:
                raise ValueError(
                    f"扫描地址数超过上限 {max_hosts}；请缩小范围或调整 --max-hosts。"
                )

    targets = [addresses[key] for key in sorted(addresses)]
    if not targets:
        raise ValueError("扫描范围展开后没有可用 IPv4 地址")
    return targets, normalized_scopes


def prompt_node_port(value: int | None) -> int:
    if value is not None:
        port = value
    elif sys.stdin.isatty():
        raw = input(f"Node Exporter 端口 [{DEFAULT_NODE_PORT}]: ").strip()
        if raw.lower() == "q":
            raise KeyboardInterrupt
        if not raw:
            port = DEFAULT_NODE_PORT
        else:
            try:
                port = int(raw)
            except ValueError as exc:
                raise ValueError(f"无效端口：{raw}") from exc
    else:
        port = DEFAULT_NODE_PORT

    if not 1 <= port <= 65535:
        raise ValueError("Node Exporter 端口必须为 1-65535")
    return port


def parse_prom_labels(label_text: str) -> dict[str, str]:
    labels: dict[str, str] = {}
    for match in LABEL_RE.finditer(label_text):
        value = match.group(2)
        value = value.replace(r"\n", "\n").replace(r'\"', '"').replace(r"\\", "\\")
        labels[match.group(1)] = value
    return labels


def extract_node_identity(metrics_text: str, fallback: str) -> tuple[str, str, str, str]:
    """返回 (display_name, os_nodename, name_source, exporter_version)。

    这些信息只用于识别 Node Exporter、扫描结果展示和运行态核验。
    Node Exporter 已在原始指标中提供 nodename 和 build_info，扫描器不再将其
    复制到 file_sd 目标标签，避免污染全部时序。
    """
    os_nodename = ""
    name_source = "scan_ip"
    display_name = fallback

    match = UNAME_LINE_RE.search(metrics_text)
    if match:
        os_nodename = parse_prom_labels(match.group(1)).get("nodename", "").strip().rstrip(".")
        if (
            os_nodename
            and os_nodename.lower() not in {"localhost", "localhost.localdomain", "unknown", "(none)"}
            and not any(char.isspace() for char in os_nodename)
        ):
            display_name = os_nodename
            name_source = "node_uname_info"

    version = ""
    build_match = BUILD_LINE_RE.search(metrics_text)
    if build_match:
        version = parse_prom_labels(build_match.group(1)).get("version", "").strip()

    return display_name, os_nodename, name_source, version


def tcp_state(ip: str, port: int, timeout: float) -> str:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        code = sock.connect_ex((ip, port))
    finally:
        sock.close()
    if code == 0:
        return "open"
    if code == errno.ECONNREFUSED:
        return "refused"
    return "unknown"


def fetch_node_metrics(ip: str, port: int) -> tuple[bool, str, str]:
    url = f"http://{ip}:{port}/metrics"
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    request = urllib.request.Request(
        url,
        headers={"User-Agent": f"{TOOL_NAME}/{TOOL_VERSION}"},
        method="GET",
    )
    try:
        with opener.open(request, timeout=DEFAULT_HTTP_TIMEOUT) as response:
            status = getattr(response, "status", 200)
            if status != 200:
                return False, "", f"HTTP {status}"
            body = response.read(MAX_METRICS_READ + 1)
    except urllib.error.HTTPError as exc:
        return False, "", f"HTTP {exc.code}"
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return False, "", f"metrics访问失败: {exc}"

    if len(body) > MAX_METRICS_READ:
        return False, "", "metrics响应超过读取上限"
    if not all(marker in body for marker in NODE_MARKERS):
        return False, "", "端口开放，但未识别为 Node Exporter"

    text = body.decode("utf-8", errors="replace")
    display_name, os_nodename, name_source, version = extract_node_identity(text, ip)
    detail = json.dumps(
        {
            "os_nodename": os_nodename,
            "name_source": name_source,
            "node_exporter_version": version,
        },
        ensure_ascii=False,
    )
    return True, display_name, detail


def ping_alive(ip: str) -> bool:
    ping = shutil.which("ping")
    if not ping:
        return False
    try:
        result = subprocess.run(
            [ping, "-n", "-c", "1", "-W", "1", ip],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=2,
            check=False,
        )
        return result.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def tcp_alive_fallback(ip: str) -> bool:
    for port in DEFAULT_ALIVE_PORTS:
        state = tcp_state(ip, port, DEFAULT_CONNECT_TIMEOUT)
        if state in {"open", "refused"}:
            return True
    return False


def scan_one(ip: str, node_port: int) -> ScanResult:
    state = tcp_state(ip, node_port, DEFAULT_CONNECT_TIMEOUT)
    if state == "open":
        ok, hostname, detail = fetch_node_metrics(ip, node_port)
        if ok:
            meta = json.loads(detail) if detail else {}
            return ScanResult(
                ip=ip,
                status="node_exporter",
                hostname=hostname,
                os_nodename=str(meta.get("os_nodename", "")),
                name_source=str(meta.get("name_source", "scan_ip")),
                node_exporter_version=str(meta.get("node_exporter_version", "")),
            )
        return ScanResult(ip=ip, status="alive_no_node", detail=detail)

    # Connection refused 本身即可证明该 IP 有主机响应，但目标端口没有服务。
    if state == "refused":
        return ScanResult(ip=ip, status="alive_no_node", detail=f"TCP/{node_port} connection refused")

    # 超时/不可达不能直接判断主机不存在；进一步通过 ICMP 和常见 TCP 端口确认。
    if ping_alive(ip):
        return ScanResult(ip=ip, status="alive_no_node", detail=f"主机可 ping，TCP/{node_port} 未确认")
    if tcp_alive_fallback(ip):
        return ScanResult(ip=ip, status="alive_no_node", detail=f"主机其他 TCP 端口可达，TCP/{node_port} 未确认")
    return ScanResult(ip=ip, status="unknown", detail="无法确认主机存活")


def scan_targets(targets: Sequence[str], node_port: int, workers: int) -> list[ScanResult]:
    if workers < 1 or workers > 512:
        raise ValueError("--workers 必须为 1-512")

    print()
    print(f"开始扫描：{len(targets)} 个 IPv4，Node Exporter TCP/{node_port}，并发={workers}")
    results: list[ScanResult] = []
    started = time.monotonic()
    progress_step = max(1, min(200, len(targets) // 20 or 1))

    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        futures = {executor.submit(scan_one, ip, node_port): ip for ip in targets}
        completed = 0
        for future in concurrent.futures.as_completed(futures):
            ip = futures[future]
            try:
                result = future.result()
            except Exception as exc:
                result = ScanResult(ip=ip, status="unknown", detail=f"扫描异常: {exc}")
            results.append(result)
            completed += 1

            if result.status == "node_exporter":
                print(
                    f"[发现] {result.ip}:{node_port}  "
                    f"nodename={result.os_nodename or '<missing>'}  "
                    f"node_exporter={result.node_exporter_version or '<unknown>'}",
                    flush=True,
                )
            elif result.status == "alive_no_node":
                print(f"[缺失] {result.ip}  {result.detail}", flush=True)

            if completed % progress_step == 0 or completed == len(targets):
                elapsed = time.monotonic() - started
                print(f"[进度] {completed}/{len(targets)} ({completed / len(targets):.0%})  耗时={elapsed:.1f}s", flush=True)

    return sorted(results, key=lambda row: ipaddress.ip_address(row.ip))


def acquire_instance_lock(instance: PrometheusInstance):
    lock_path = SCRIPT_DIR / f".prometheus_node_discovery_{instance.name}.lock"
    handle = lock_path.open("a+", encoding="utf-8")
    os.chmod(lock_path, 0o600)
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as exc:
        handle.close()
        raise ValueError(f"已有针对 {instance.name} 的扫描任务正在运行：{lock_path}") from exc
    return handle


def unique_output_path(directory: Path, stem: str, suffix: str = ".txt") -> Path:
    timestamp = time.strftime("%Y%m%d-%H%M%S")
    candidate = directory / f"{stem}_{timestamp}{suffix}"
    index = 1
    while candidate.exists():
        candidate = directory / f"{stem}_{timestamp}_{index:02d}{suffix}"
        index += 1
    return candidate


def assert_scrape_config_contract(instance: PrometheusInstance) -> None:
    """确认 node.yml 会被主配置实际加载，避免“写成功但未采集”。"""
    try:
        config_text = instance.config.read_text(encoding="utf-8")
    except OSError as exc:
        raise ValueError(f"无法读取 Prometheus 主配置：{exc}") from exc

    match = re.search(
        r"^scrape_config_files:[ \t]*(?:#.*)?\n(?P<body>(?:^[ \t]+.*(?:\n|$))*)",
        config_text,
        re.MULTILINE,
    )
    expected_dir = instance.root / "etc" / "scrape_configs"
    loaded = False
    if match:
        loaded = any(
            line.lstrip().startswith("-") and str(expected_dir) in line
            for line in match.group("body").splitlines()
        )
    if not loaded:
        raise ValueError(
            "Prometheus 主配置未加载标准模块目录，拒绝发布。请先加入：\n"
            "scrape_config_files:\n"
            f"  - '{expected_dir}/*.yml'\n"
            f"然后执行 {instance.promtool} check config {instance.config}。"
        )


def check_prometheus_contract(instance: PrometheusInstance) -> list[str]:
    """检查 rules / Grafana 的非阻断契约，不擅自修改业务规则。"""
    warnings: list[str] = []

    try:
        config_text = instance.config.read_text(encoding="utf-8")
    except OSError as exc:
        return [f"无法读取 Prometheus 主配置：{exc}"]

    rules_dir = instance.root / "etc" / "rules"

    if "rule_files:" not in config_text:
        warnings.append(
            f"prometheus.yml 未发现 rule_files；Grafana Top/P99 所需记录规则可能不会加载。"
        )

    legacy_node_jobs = [
        name
        for name in re.findall(
            r'(?m)^\s*-\s*job_name:\s*[\'\"]?([^\'\"\s]+)',
            config_text,
        )
        if name != "node_exporter" and name.lower().startswith("node")
    ]
    if legacy_node_jobs:
        warnings.append(
            "主配置仍含旧 Node Job（"
            + ", ".join(sorted(set(legacy_node_jobs)))
            + "）；完成迁移后应移除，避免与 node_exporter 重复采集。"
        )

    rule_text = ""
    rule_names: set[str] = set()
    if rules_dir.is_dir():
        chunks: list[str] = []
        for path in sorted(rules_dir.glob("*.yml")):
            try:
                chunks.append(path.read_text(encoding="utf-8"))
                rule_names.add(path.name)
            except OSError:
                continue
        rule_text = "\n".join(chunks)

    if not rule_text:
        warnings.append(f"未发现规则文件：{rules_dir}/*.yml")
    else:
        missing = [name for name in REQUIRED_RECORD_RULES if name not in rule_text]
        if missing:
            warnings.append(
                "Grafana 配套记录规则不完整，以下记录指标未在 rules/*.yml 中发现："
                + ", ".join(missing)
            )

        expected_common_rules = {
            "basic_alerts_v1.0.0.yml",
            "blackbox_ssl_expiry_reminders_rc1.1.yml",
            "node_usage_record_rules_v2.4.0.yml",
            "node_alerts_v1.0.0_stress.yml",
        }
        missing_common_rules = sorted(expected_common_rules - rule_names)
        if missing_common_rules:
            warnings.append(
                "按标准文件名未发现以下公共规则："
                + ", ".join(missing_common_rules)
            )

        old_node_rules = sorted(
            {
                "node_alerts_v2.1.0-rc2_prod.yml",
                "node_alerts_v2.1.0-rc2_nonprod.yml",
            }
            & rule_names
        )
        if old_node_rules:
            warnings.append(
                "发现待替换的旧 Node 告警规则："
                + ", ".join(old_node_rules)
                + "；应替换为 v2.2.0，确保排除 alert_policy=stress 目标。"
            )

        current_node_rules = {
            "node_alerts_v2.2.0_prod.yml",
            "node_alerts_v2.2.0_nonprod.yml",
        } & rule_names
        if not current_node_rules:
            warnings.append(
                "未发现 node_alerts_v2.2.0_prod.yml 或 "
                "node_alerts_v2.2.0_nonprod.yml；普通目标可能缺少 Node 告警基线。"
            )
        elif len(current_node_rules) > 1:
            warnings.append(
                "同一 Prometheus 同时加载 prod 与 nonprod Node 告警规则，"
                "普通目标可能重复告警；每个实例通常只应加载其中一套。"
            )
        if 'job="node-91"' in rule_text or "job='node-91'" in rule_text:
            warnings.append(
                '发现历史规则 job="node-91"，与扫描器标准 Job "node_exporter" 不一致。'
            )
        if "node_entropy_available_bytes" in rule_text:
            warnings.append(
                "发现旧指标 node_entropy_available_bytes；当前 Node Exporter 使用 node_entropy_available_bits。"
            )
        if "prometheus_remote_write_queue_highest_" in rule_text:
            warnings.append(
                "发现旧的 remote-write 队列指标名 prometheus_remote_write_queue_highest_*，请更新规则。"
            )

    return warnings


def validate_existing_node_job(job_file: Path, target_dir: Path) -> None:
    if not job_file.is_file():
        return
    try:
        text = job_file.read_text(encoding="utf-8")
    except OSError as exc:
        raise ValueError(f"无法读取现有 Node Exporter Job：{job_file}: {exc}") from exc

    if not re.search(r'(?m)^\s*-\s*job_name:\s*[\'"]?node_exporter[\'"]?\s*$', text):
        raise ValueError(
            f"现有 {job_file} 的 job_name 不是 node_exporter。"
            "生产扫描器不会静默覆盖，请人工确认后处理。"
        )
    if re.search(r'(?m)^\s*honor_labels:\s*true\s*(?:#.*)?$', text):
        raise ValueError(
            f"现有 {job_file} 启用了 honor_labels=true，会改变 Prometheus 标签冲突语义；"
            "请改为 false 后再运行扫描器。"
        )

    expected = f"{target_dir}/*.json"
    if expected not in text:
        raise ValueError(
            f"现有 {job_file} 未引用标准 file_sd 路径：{expected}。"
            "生产扫描器不会静默覆盖。"
        )


def reject_managed_symlinks(instance: PrometheusInstance) -> None:
    for path in (
        instance.root / "etc",
        instance.root / "etc" / "scrape_configs",
        instance.root / "etc" / "targets",
        instance.root / "etc" / "targets" / "node",
    ):
        if path.is_symlink():
            raise ValueError(f"受管目录不得为符号链接，拒绝继续：{path}")


def systemd_property(service: str, prop: str) -> str:
    result = subprocess.run(
        ["systemctl", "show", service, "-p", prop, "--value"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise ValueError(
            f"无法读取 systemd 服务属性 {service}:{prop}: "
            + (result.stderr.strip() or result.stdout.strip())
        )
    return result.stdout.strip()


def service_identity(instance: PrometheusInstance) -> tuple[str, str, int, int]:
    """读取 Prometheus 实际 systemd User/Group，并返回 uid/gid。"""
    import grp
    import pwd

    user = systemd_property(instance.service, "User") or "root"
    group = systemd_property(instance.service, "Group")
    try:
        pw = pwd.getpwnam(user)
    except KeyError as exc:
        raise ValueError(f"Prometheus systemd User 不存在：{user}") from exc

    if not group:
        try:
            group = grp.getgrgid(pw.pw_gid).gr_name
        except KeyError:
            group = str(pw.pw_gid)

    try:
        gid = grp.getgrnam(group).gr_gid
    except KeyError:
        if group.isdigit():
            gid = int(group)
        else:
            raise ValueError(f"Prometheus systemd Group 不存在：{group}")

    return user, group, pw.pw_uid, gid


def ensure_service_readable(path: Path, user: str) -> None:
    result = subprocess.run(
        ["runuser", "-u", user, "--", "test", "-r", str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise ValueError(f"Prometheus 运行用户 {user} 无法读取：{path}")


def promtool_check_as_service_user(
    instance: PrometheusInstance, user: str
) -> tuple[bool, str]:
    result = subprocess.run(
        [
            "runuser", "-u", user, "--",
            str(instance.promtool), "check", "config", str(instance.config),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    return result.returncode == 0, result.stdout.strip()


def ensure_target_dirs(instance: PrometheusInstance) -> tuple[Path, Path, str, str, int]:
    reject_managed_symlinks(instance)
    scrape_dir = instance.root / "etc" / "scrape_configs"
    target_dir = instance.root / "etc" / "targets" / "node"
    scrape_dir.mkdir(parents=True, exist_ok=True)
    target_dir.mkdir(parents=True, exist_ok=True)

    service_user, service_group, _uid, group_id = service_identity(instance)
    for directory in (scrape_dir, target_dir.parent, target_dir):
        os.chown(directory, 0, group_id)
        os.chmod(directory, 0o750)

    return scrape_dir, target_dir, service_user, service_group, group_id


def write_atomic_text(path: Path, content: str, mode: int, group_id: int | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    temp = Path(temp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp, mode)
        if group_id is not None:
            os.chown(temp, 0, group_id)
        os.replace(temp, path)
    finally:
        if temp.exists():
            temp.unlink(missing_ok=True)


def promtool_check_config(instance: PrometheusInstance) -> tuple[bool, str]:
    result = subprocess.run(
        [str(instance.promtool), "check", "config", str(instance.config)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    return result.returncode == 0, result.stdout.strip()


def create_node_job_if_needed(
    instance: PrometheusInstance,
    scrape_dir: Path,
    target_dir: Path,
    service_user: str,
    group_id: int,
) -> bool:
    job_file = scrape_dir / JOB_FILE_NAME
    if job_file.exists():
        validate_existing_node_job(job_file, target_dir)
        os.chown(job_file, 0, group_id)
        os.chmod(job_file, 0o640)
        ensure_service_readable(job_file, service_user)
        valid, output = promtool_check_as_service_user(instance, service_user)
        if not valid:
            raise ValueError(
                f"现有 Prometheus 配置无法由运行用户 {service_user} 校验，拒绝扫描发布。\n"
                + output
            )
        print(f"Node Exporter Job 已存在且运行身份校验通过，保持内容不变：{job_file}")
        return False

    content = f"""# Generated by {TOOL_NAME} {TOOL_VERSION}\n# 标签契约：job/instance 由 Prometheus 生成；site/origin_prometheus 由 external_labels 生成。\nscrape_configs:\n  - job_name: node_exporter\n    scheme: http\n    metrics_path: /metrics\n    scrape_interval: 30s\n    scrape_timeout: 10s\n    honor_labels: false\n    file_sd_configs:\n      - files:\n          - '{target_dir}/*.json'\n        refresh_interval: 30s\n"""

    write_atomic_text(job_file, content, 0o640, group_id)
    ensure_service_readable(job_file, service_user)

    valid, output = promtool_check_as_service_user(instance, service_user)
    if not valid:
        job_file.unlink(missing_ok=True)
        raise ValueError(
            f"自动创建 node_exporter Job 后，以运行用户 {service_user} 执行 promtool 校验失败，"
            "已删除新 Job 文件。\n" + output
        )

    print(f"已创建 Node Exporter Job：{job_file}")
    return True


def normalize_target_endpoint(target: str) -> str | None:
    """规范化 IPv4:端口目标；扫描器当前只管理 IPv4 Node Exporter。"""
    target = target.strip()
    if not target or target.startswith("[") or ":" not in target:
        return None
    host, port_text = target.rsplit(":", 1)
    try:
        address = ipaddress.ip_address(host)
        port = int(port_text)
    except (ValueError, TypeError):
        return None
    if not isinstance(address, ipaddress.IPv4Address) or not 1 <= port <= 65535:
        return None
    return f"{address}:{port}"


def endpoint_sort_key(endpoint: str) -> tuple[int, int]:
    host, port_text = endpoint.rsplit(":", 1)
    return int(ipaddress.IPv4Address(host)), int(port_text)


def load_existing_targets(path: Path) -> dict[str, dict[str, object]]:
    if not path.is_file():
        return {}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"现有 file_sd JSON 无法读取，拒绝覆盖：{path}: {exc}") from exc
    if not isinstance(payload, list):
        raise ValueError(f"现有 file_sd JSON 顶层不是数组，拒绝覆盖：{path}")

    existing: dict[str, dict[str, object]] = {}
    for item in payload:
        if not isinstance(item, dict):
            raise ValueError(f"现有 file_sd JSON 含非对象条目，拒绝覆盖：{path}")
        targets = item.get("targets")
        labels = item.get("labels", {})
        if not isinstance(targets, list) or not targets:
            raise ValueError(f"现有 file_sd JSON 含无效 targets，拒绝覆盖：{path}")
        if not isinstance(labels, dict):
            raise ValueError(f"现有 file_sd JSON 含无效 labels，拒绝覆盖：{path}")
        for key, value in labels.items():
            if not isinstance(key, str) or not PROM_LABEL_NAME_RE.fullmatch(key):
                raise ValueError(f"现有 file_sd JSON 含无效标签名 {key!r}，拒绝覆盖：{path}")
            if key.startswith("__") or key == "__name__":
                raise ValueError(f"现有 file_sd JSON 含保留标签 {key}，拒绝覆盖：{path}")
            if not isinstance(value, str):
                raise ValueError(f"现有 file_sd JSON 标签 {key} 不是字符串，拒绝覆盖：{path}")
        for raw_target in targets:
            endpoint = normalize_target_endpoint(str(raw_target))
            if endpoint is None:
                raise ValueError(
                    f"现有 file_sd JSON 含非标准 IPv4:端口目标 {raw_target!r}，"
                    f"拒绝自动迁移：{path}"
                )
            if endpoint in existing:
                raise ValueError(f"现有 file_sd JSON 含重复目标 {endpoint}，拒绝覆盖：{path}")
            existing[endpoint] = {
                "targets": [endpoint],
                "labels": dict(labels),
            }
    return existing


def migrate_existing_target_item(
    endpoint: str,
    item: dict[str, object],
    missing_alert_policy: str = DEFAULT_ALERT_POLICY,
) -> dict[str, object]:
    """迁移历史目标，并保留已有的合法 alert_policy。"""
    labels_raw = item.get("labels", {})
    labels = (
        {str(key): str(value) for key, value in labels_raw.items()}
        if isinstance(labels_raw, dict)
        else {}
    )
    for key in TARGET_LABELS_TO_REMOVE:
        labels.pop(key, None)
    host, _port = endpoint.rsplit(":", 1)
    labels["asset_ip"] = host
    policy = labels.get(ALERT_POLICY_LABEL, "").strip()
    if not policy:
        policy = missing_alert_policy
    policy = validate_alert_policy(policy, f"现有目标 {endpoint} 的 alert_policy")
    labels[ALERT_POLICY_LABEL] = policy
    return {"targets": [endpoint], "labels": labels}


def build_target_item(
    row: ScanResult,
    node_port: int,
    existing_item: dict[str, object] | None,
    common_labels: dict[str, str],
    alert_policy: str,
) -> dict[str, object]:
    """构造最小化、原生兼容的目标标签模型。

    约定：
      - instance：不写入 file_sd，由 Prometheus 按 __address__ 自动生成 IPv4:端口；
      - asset_ip：扫描器强制写入，供 Grafana 显示纯 IPv4；
      - alert_policy：扫描器强制写入；已有合法值保留，缺失时使用本次选择；
      - nodename/版本等信息继续使用 Node Exporter 原始指标，不复制为目标标签；
      - site/origin_prometheus/job：由 external_labels 和 scrape job 注入，扫描器会清理旧副本。
    """
    endpoint = f"{row.ip}:{node_port}"
    labels: dict[str, str] = {}
    if existing_item:
        migrated = migrate_existing_target_item(
            endpoint, existing_item, missing_alert_policy=alert_policy
        )
        existing_labels = migrated.get("labels", {})
        if isinstance(existing_labels, dict):
            labels.update({str(key): str(value) for key, value in existing_labels.items()})

    # merge 时保留用户既有业务标签，但必须清除所有旧版受管标签，
    # 否则 name 等标签会继续覆盖 Node Exporter 原生指标。
    for key in TARGET_LABELS_TO_REMOVE:
        labels.pop(key, None)

    labels.update(common_labels)
    labels["asset_ip"] = row.ip
    if ALERT_POLICY_LABEL not in labels:
        labels[ALERT_POLICY_LABEL] = alert_policy

    missing = [key for key in MANAGED_TARGET_LABELS if not str(labels.get(key, "")).strip()]
    if missing:
        raise ValueError(
            f"内部错误：目标 {row.ip}:{node_port} 的必要标签不完整：{', '.join(missing)}"
        )

    return {
        "targets": [endpoint],
        "labels": labels,
    }


def prune_target_backups(target_dir: Path) -> None:
    backups = sorted(
        (
            path
            for path in target_dir.glob(f"{TARGET_JSON_NAME}.bak_*")
            if path.is_file() and not path.is_symlink()
        ),
        key=lambda path: (path.stat().st_mtime_ns, path.name),
        reverse=True,
    )
    for stale in backups[DEFAULT_BACKUP_KEEP:]:
        stale.unlink()


def publish_results(
    instance: PrometheusInstance,
    target_dir: Path,
    results: Sequence[ScanResult],
    node_port: int,
    publish_mode: str,
    allow_empty: bool,
    common_labels: dict[str, str],
    alert_policy: str,
    group_id: int,
) -> tuple[Path, Path, int, int]:
    json_path = target_dir / TARGET_JSON_NAME

    existing_source = json_path
    if not json_path.exists():
        legacy_candidates = (
            target_dir.parent / "node_exporter_discovered.json",
            target_dir.parent / TARGET_JSON_NAME,
        )
        legacy_existing = [path for path in legacy_candidates if path.is_file()]
        if len(legacy_existing) > 1:
            raise ValueError(
                "发现多个旧版 Node Exporter 目标文件，无法安全判断来源："
                + ", ".join(str(path) for path in legacy_existing)
            )
        if legacy_existing:
            existing_source = legacy_existing[0]
            print(f"首次发布将导入旧版目标及其自定义标签：{existing_source}")

    existing_targets = load_existing_targets(existing_source)
    old_count = len(existing_targets)
    discovered = [row for row in results if row.status == "node_exporter"]
    if publish_mode == "replace" and not discovered and not allow_empty:
        raise ValueError(
            "replace 模式本次未确认任何 Node Exporter，拒绝清空目标。"
            "如确需清空，请同时使用 --allow-empty。"
        )

    targets_by_endpoint = (
        {
            endpoint: migrate_existing_target_item(
                endpoint, item, missing_alert_policy=DEFAULT_ALERT_POLICY
            )
            for endpoint, item in existing_targets.items()
        }
        if publish_mode == "merge"
        else {}
    )
    for row in discovered:
        endpoint = f"{row.ip}:{node_port}"
        targets_by_endpoint[endpoint] = build_target_item(
            row,
            node_port,
            existing_targets.get(endpoint),
            common_labels,
            alert_policy,
        )

    payload = [
        targets_by_endpoint[endpoint]
        for endpoint in sorted(targets_by_endpoint, key=endpoint_sort_key)
    ]
    json_content = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"

    # Prometheus 生效 JSON 使用固定文件名，但旧版本先保存为唯一时间戳备份，不静默覆盖备份。
    if json_path.exists():
        backup = unique_output_path(target_dir, f"{TARGET_JSON_NAME}.bak", "")
        shutil.copy2(json_path, backup)
        os.chmod(backup, 0o640)
        try:
            os.chown(backup, 0, group_id)
        except OSError:
            pass
        prune_target_backups(target_dir)

    write_atomic_text(json_path, json_content, 0o640, group_id)

    # 辅助 missing TXT 写到 .run 所在目录，文件名带实例和时间戳，不依赖额外输出目录。
    missing_ips = sorted(
        {row.ip for row in results if row.status == "alive_no_node"},
        key=ipaddress.ip_address,
    )
    missing_path = unique_output_path(SCRIPT_DIR, f"{instance.name}_node_exporter_missing")
    missing_content = "".join(f"{ip}\n" for ip in missing_ips)
    write_atomic_text(missing_path, missing_content, 0o600, None)

    return json_path, missing_path, old_count, len(payload)


def local_api_base(instance: PrometheusInstance) -> str:
    match = re.fullmatch(r"prometheus-(\d+)", instance.name)
    if not match:
        raise ValueError(f"无法从实例名确定 Prometheus HTTP 端口：{instance.name}")
    return f"http://127.0.0.1:{match.group(1)}"


def prometheus_api_json(instance: PrometheusInstance, path: str) -> dict[str, object]:
    url = local_api_base(instance) + path
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    request = urllib.request.Request(
        url, headers={"User-Agent": f"{TOOL_NAME}/{TOOL_VERSION}"}, method="GET"
    )
    try:
        with opener.open(request, timeout=5.0) as response:
            body = response.read(8 * 1024 * 1024)
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise ValueError(f"无法访问 Prometheus HTTP API {url}: {exc}") from exc
    try:
        payload = json.loads(body.decode("utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"Prometheus HTTP API 返回非 JSON：{url}") from exc
    if payload.get("status") != "success":
        raise ValueError(f"Prometheus HTTP API 返回失败：{url}: {payload}")
    return payload


def _check_metric_drop(instance: PrometheusInstance, metric_name: str) -> bool:
    """检查 Prometheus 主配置 + scrape_configs 中是否对 metric_name 配置了 drop。

    用于在 /api/v1/metadata 返回空时，区分"真的没 scrape 到"与"被 installer 主动 drop"。

    返回 True 表示在配置中找到对该 metric 的 action=drop 行。
    """
    candidates: list[Path] = [instance.config]
    scrape_root = instance.config.parent / "scrape_configs"
    if scrape_root.is_dir():
        candidates.extend(sorted(scrape_root.glob("*.yml")))
        candidates.extend(sorted(scrape_root.glob("*.yaml")))
    metric_pattern = re.escape(metric_name)
    for path in candidates:
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        if not text:
            continue
        # 按 metric_relabel_configs / relabel_configs 内的列表项切块：
        #   - source_labels: [...]
        #   - regex: '...'
        #   - action: drop
        # 块划分策略：找到 "      - source_labels" 起始行，连续到下一个 "- " 起始或空顶级字段。
        for block in re.split(
            r"(?m)^(?=\s{2,}-\s+source_labels\s*:)", text
        ):
            if "action: drop" not in block:
                continue
            # 提取所有 regex 行的字符串内容（去掉引号与 regex 关键字），
            # 把每条 regex 按 | 拆成 alternation 子项，删除末尾的 .* 与元字符，
            # 然后检查任一子项是否以 metric_name 开头（用于匹配
            # 'node_exporter_(build_info|memstats_).*' 这种 alternation 包
            # 含 'build_info' 子项的情形）。
            regex_texts = re.findall(
                r"regex\s*:\s*['\"]?([^'\"\n]+)['\"]?", block
            )
            # 把每条 regex 字符串编译为 re.Pattern（Anchored at ^ and $），验证
            # metric_name 是否会被该 regex 匹配。这是判断"installer 是否主动 drop
            # 该 metric"的最准确方式：例如 'node_exporter_(build_info|memstats_).*'
            # 经过 strip .* 与 compile 后，对 'node_exporter_build_info' 应 match。
            for regex_text in regex_texts:
                # 去除末尾 .*（drop 语义只关心 prefix 是否覆盖该 metric）
                cleaned = re.sub(r"\.\*+\s*$", "", regex_text)
                # 将正则字符串加 ^...$ 锚定
                try:
                    pattern = re.compile("^" + cleaned + "$")
                except re.error:
                    continue
                if pattern.fullmatch(metric_name):
                    return True
    return False


def reload_prometheus(instance: PrometheusInstance) -> None:
    if not service_active(instance.service):
        raise ValueError(f"Prometheus 服务未运行，无法验证发布结果：{instance.service}")
    result = subprocess.run(
        ["systemctl", "reload", instance.service],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise ValueError(
            f"reload {instance.service} 失败：" + (result.stdout.strip() or "无输出")
        )


def validate_external_label_contract(instance: PrometheusInstance) -> tuple[str, str]:
    """检查中心远程写入与 Grafana 依赖的 external_labels。"""
    try:
        config_text = instance.config.read_text(encoding="utf-8")
    except OSError as exc:
        raise ValueError(f"无法读取 Prometheus 主配置：{exc}") from exc
    origin_match = re.search(
        r'(?m)^\s*origin_prometheus:\s*[\'"]?([^\'"#\s]+)',
        config_text,
    )
    site_match = re.search(
        r'(?m)^\s*site:\s*[\'"]?([^\'"#\s]+)',
        config_text,
    )
    if not origin_match or not origin_match.group(1).strip():
        raise ValueError(
            "中心监控依赖 external_labels.origin_prometheus，但当前 prometheus.yml 未发现有效值。"
        )
    if not site_match or not site_match.group(1).strip():
        raise ValueError(
            "中心监控依赖 external_labels.site，但当前 prometheus.yml 未发现有效值。"
        )
    return origin_match.group(1).strip(), site_match.group(1).strip()


def verify_runtime_config_contract(
    instance: PrometheusInstance, origin_prometheus: str, site: str
) -> str:
    """验证运行中的 Prometheus 主配置已 reload，并核对中心监控所需 external labels。

    注意：scrape_config_files 中的 scrape job 由 Prometheus 运行时单独读取，
    /api/v1/status/config 返回的 YAML 不保证展开这些外部分片。因此这里不能
    以 status/config 是否出现 job_name=node_exporter 作为运行态生效依据。
    node_exporter 是否真正加载由 verify_runtime_targets() 通过 /api/v1/targets
    进行权威验证。
    """
    payload = prometheus_api_json(instance, "/api/v1/status/config")
    data = payload.get("data", {})
    yaml_text = data.get("yaml", "") if isinstance(data, dict) else ""
    if not isinstance(yaml_text, str) or not yaml_text.strip():
        raise ValueError("Prometheus /api/v1/status/config 未返回有效运行配置")

    expected_scrape_glob = str(instance.root / "etc" / "scrape_configs" / "*.yml")
    if expected_scrape_glob not in yaml_text:
        raise ValueError(
            "运行中的 Prometheus 主配置未发现预期 scrape_config_files 路径："
            f"{expected_scrape_glob}；拒绝继续运行态验收。"
        )

    match = re.search(
        r'(?m)^\s*origin_prometheus:\s*[\'"]?([^\'"#\s]+)',
        yaml_text,
    )
    runtime_origin = match.group(1).strip() if match else ""
    if runtime_origin != origin_prometheus:
        raise ValueError(
            "运行配置中的 origin_prometheus 与磁盘配置不一致："
            f"runtime={runtime_origin or '<missing>'}, disk={origin_prometheus}"
        )
    site_match = re.search(
        r'(?m)^\s*site:\s*[\'"]?([^\'"#\s]+)',
        yaml_text,
    )
    runtime_site = site_match.group(1).strip() if site_match else ""
    if runtime_site != site:
        raise ValueError(
            "运行配置中的 site 与磁盘配置不一致："
            f"runtime={runtime_site or '<missing>'}, disk={site}"
        )
    return (
        f"主配置已 reload：site={runtime_site}, origin_prometheus={runtime_origin}，"
        "scrape_config_files 已加载；"
        "node_exporter Job 由 /api/v1/targets 进行运行态验证"
    )


def runtime_target_snapshot(instance: PrometheusInstance) -> list[dict[str, object]]:
    payload = prometheus_api_json(instance, "/api/v1/targets?state=any")
    data = payload.get("data", {})
    if not isinstance(data, dict):
        return []
    rows: list[dict[str, object]] = []
    for key in ("activeTargets", "droppedTargets"):
        value = data.get(key, [])
        if isinstance(value, list):
            rows.extend(item for item in value if isinstance(item, dict))
    return rows


def published_alert_policies(path: Path) -> dict[str, str]:
    """读取刚发布的目标文件，并确认每个目标都有合法 alert_policy。"""
    result: dict[str, str] = {}
    for endpoint, item in load_existing_targets(path).items():
        labels = item.get("labels", {})
        policy = str(labels.get(ALERT_POLICY_LABEL, "")) if isinstance(labels, dict) else ""
        try:
            normalized_policy = validate_alert_policy(
                policy, f"发布文件中目标 {endpoint} 的 alert_policy"
            )
        except ValueError as exc:
            raise ValueError(
                f"{exc}；拒绝运行态验收"
            ) from exc
        if policy != normalized_policy:
            raise ValueError(
                f"发布文件中目标 {endpoint} 的 alert_policy 未规范化：{policy!r}；"
                "拒绝运行态验收"
            )
        result[endpoint] = normalized_policy
    return result


def verify_runtime_targets(
    instance: PrometheusInstance,
    discovered: Sequence[ScanResult],
    node_port: int,
    expected_policies: dict[str, str],
) -> tuple[int, int, str]:
    """验证本次发现目标及 alert_policy 已进入 Prometheus 运行态。"""
    expected = {f"{row.ip}:{node_port}" for row in discovered if row.status == "node_exporter"}
    if not expected:
        return 0, 0, "本次未发现 Node Exporter，跳过运行态目标命中校验"

    deadline = time.monotonic() + RUNTIME_VERIFY_TIMEOUT
    last_seen: set[str] = set()
    last_health: dict[str, str] = {}
    last_policies: dict[str, str] = {}
    while time.monotonic() < deadline:
        rows = runtime_target_snapshot(instance)
        seen: set[str] = set()
        health: dict[str, str] = {}
        policies: dict[str, str] = {}
        for item in rows:
            labels = item.get("labels", {})
            discovered_labels = item.get("discoveredLabels", {})
            if not isinstance(labels, dict):
                labels = {}
            if not isinstance(discovered_labels, dict):
                discovered_labels = {}
            job = str(labels.get("job") or discovered_labels.get("job") or "")
            if job != "node_exporter":
                continue
            address = str(
                discovered_labels.get("__address__")
                or labels.get("__address__")
                or item.get("scrapeUrl", "").replace("http://", "").split("/", 1)[0]
            )
            if address:
                seen.add(address)
                health[address] = str(item.get("health", ""))
                policies[address] = str(labels.get(ALERT_POLICY_LABEL, ""))
        last_seen = seen
        last_health = health
        last_policies = policies
        matched = expected & seen
        if matched == expected:
            mismatches = [
                f"{endpoint}={last_policies.get(endpoint) or '<missing>'}"
                f"(期望 {expected_policies.get(endpoint) or '<missing>'})"
                for endpoint in sorted(expected)
                if last_policies.get(endpoint) != expected_policies.get(endpoint)
            ]
            if mismatches:
                raise ValueError(
                    "Prometheus 已加载目标，但运行态 alert_policy 与发布文件不一致："
                    + "; ".join(mismatches[:10])
                )
            up_count = sum(last_health.get(addr) == "up" for addr in matched)
            return len(matched), up_count, "运行态 target 及 alert_policy 已加载"
        time.sleep(RUNTIME_VERIFY_INTERVAL)

    missing = expected - last_seen
    sample = ", ".join(sorted(missing or expected)[:5])
    raise ValueError(
        "file_sd JSON 已发布，但 Prometheus 运行态未完整加载本次 node_exporter 目标；"
        f"示例未命中目标：{sample}。请检查 node.yml、文件权限、reload 日志及 /api/v1/targets。"
    )


def verify_native_metric_chain(
    instance: PrometheusInstance,
    discovered: Sequence[ScanResult],
    node_port: int,
    expected_policies: dict[str, str],
) -> str:
    """验证 Prometheus 标准实例标签和 Node Exporter 原生标签未被覆盖。

    site/origin_prometheus 是 external labels，主要在 remote_write 到中心存储后出现，
    本地 Prometheus 验证 job、标准 instance、asset_ip、原生 nodename/build_info，
    并确认 external_labels 没有被错误写成目标标签。
    """
    sample = next((row for row in discovered if row.status == "node_exporter"), None)
    if sample is None:
        return "本次无 Node Exporter，跳过原生标签链校验"
    endpoint = f"{sample.ip}:{node_port}"
    query = urllib.parse.urlencode(
        {"query": f'node_uname_info{{job="node_exporter",instance="{endpoint}"}}'}
    )
    deadline = time.monotonic() + RUNTIME_VERIFY_TIMEOUT
    while time.monotonic() < deadline:
        payload = prometheus_api_json(instance, "/api/v1/query?" + query)
        data = payload.get("data", {})
        result = data.get("result", []) if isinstance(data, dict) else []
        if isinstance(result, list) and result:
            metric = result[0].get("metric", {}) if isinstance(result[0], dict) else {}
            if not isinstance(metric, dict):
                metric = {}
            required = {
                "job": "node_exporter",
                "instance": endpoint,
                "asset_ip": sample.ip,
                ALERT_POLICY_LABEL: expected_policies.get(endpoint, ""),
            }
            mismatches: list[str] = []
            for key, expected in required.items():
                actual = str(metric.get(key, ""))
                if actual != expected:
                    mismatches.append(f"{key}={actual or '<missing>'}(期望 {expected})")
            nodename = str(metric.get("nodename", "")).strip()
            if not nodename:
                mismatches.append("nodename=<missing>")

            leaked = sorted(
                key
                for key in (LEGACY_MANAGED_LABELS - {"instance"}) | {"site", "origin_prometheus"}
                if key in metric
            )
            if leaked:
                mismatches.append("仍含旧版全局标签=" + ",".join(leaked))

            # node_exporter_build_info 是 version+labels 元数据型 metric；
            # Prometheus v3 在 scrape 端会把它纳入 target_info 而非存为独立 series，
            # 且本项目 installer 会通过 metric_relabel_configs 收敛 cardinality，
            # 因此用 series query 会导致 false negative。
            # 改用 /api/v1/metadata：scrape 收到即会在 metadata 中出现条目，
            # 不依赖 tsdb 是否保留该 series。语义保持"确认 scrape 已收到 build_info"。
            build_payload = prometheus_api_json(
                instance,
                "/api/v1/metadata?metric=node_exporter_build_info",
            )
            build_data = build_payload.get("data", {})
            build_meta_list = (
                build_data.get("node_exporter_build_info", [])
                if isinstance(build_data, dict)
                else []
            )
            # metadata API 返回空可能由两种情况：
            #   (a) prom 真没收到该 metric → 视为契约缺失，应阻塞发布
            #   (b) prom 在 metric_relabel_configs 中主动 drop 该 metric →
            #       scrape 已收到但被过滤；用 /api/v1/metadata 是否能查是
            #       区分关键。直接在 prom 主配置 scrape_configs 中查找
            #       对该 metric 的 drop/action=drop 行；若存在则视为
            #       installer 主动设计，跳过 mismatches。
            if isinstance(build_meta_list, list) and build_meta_list:
                exporter_version = "received"
            else:
                drop_seen = _check_metric_drop(instance, "node_exporter_build_info")
                if drop_seen:
                    # installer 主动 drop，记录到 exporter_version 仅用于
                    # 用户输出，不进 mismatches；语义"确认 scrape 收到
                    # 或被 installer 主动 drop"，二者都满足契约。
                    exporter_version = "dropped_by_installer"
                else:
                    exporter_version = ""
            if not exporter_version:
                mismatches.append("node_exporter_build_info.version=<missing>")

            cpu_query = urllib.parse.urlencode(
                {"query": f'node_cpu_seconds_total{{job="node_exporter",instance="{endpoint}"}}'}
            )
            cpu_payload = prometheus_api_json(instance, "/api/v1/query?" + cpu_query)
            cpu_data = cpu_payload.get("data", {})
            cpu_result = cpu_data.get("result", []) if isinstance(cpu_data, dict) else []
            cpu_metric = (
                cpu_result[0].get("metric", {})
                if isinstance(cpu_result, list) and cpu_result and isinstance(cpu_result[0], dict)
                else {}
            )
            if not isinstance(cpu_metric, dict) or not cpu_metric:
                mismatches.append("node_cpu_seconds_total=<missing>")
            else:
                unexpected_native = sorted(
                    (NODE_EXPORTER_NATIVE_LABELS - {"cpu", "mode"}) & set(cpu_metric)
                )
                unexpected_source = sorted({"site", "origin_prometheus"} & set(cpu_metric))
                if unexpected_native:
                    mismatches.append("CPU指标含全局原生标签=" + ",".join(unexpected_native))
                if unexpected_source:
                    mismatches.append("CPU指标含错误目标来源标签=" + ",".join(unexpected_source))
            if mismatches:
                raise ValueError(
                    "Prometheus 已采集 node_uname_info，但原生标签契约不完整："
                    + "; ".join(mismatches)
                )
            return (
                f"原生标签链通过：job=node_exporter, instance={endpoint}, "
                f"asset_ip={sample.ip}, alert_policy={expected_policies.get(endpoint)}, "
                f"nodename={nodename}, node_exporter={exporter_version}"
            )
        time.sleep(RUNTIME_VERIFY_INTERVAL)
    raise ValueError(
        f"Prometheus 已加载 target，但未查询到 "
        f"node_uname_info{{job=\"node_exporter\",instance=\"{endpoint}\"}}；"
        "请检查 file_sd 标签迁移、抓取健康状态和 Node Exporter 原始指标。"
    )


def print_plan(
    instance: PrometheusInstance,
    scopes: Sequence[str],
    exclusions: Sequence[str],
    targets: Sequence[str],
    node_port: int,
    publish_mode: str,
    common_labels: dict[str, str],
    alert_policy: str,
) -> None:
    target_dir = instance.root / "etc" / "targets" / "node"
    print()
    print("=======================================================")
    print("Node Exporter 扫描确认")
    print("=======================================================")
    print(f"Prometheus实例 : {instance.name}")
    print(f"systemd服务    : {instance.service}")
    print(f"扫描范围       : {', '.join(scopes)}")
    print(f"排除范围       : {', '.join(exclusions) if exclusions else '无'}")
    print(f"扫描地址数     : {len(targets)}")
    print(f"Node端口       : {node_port}")
    print(f"发布模式       : {publish_mode}")
    print(f"默认告警策略   : alert_policy={alert_policy}")
    print(f"公共标签       : {json.dumps(common_labels, ensure_ascii=False) if common_labels else '无'}")
    print(f"Job配置        : {instance.root / 'etc' / 'scrape_configs' / JOB_FILE_NAME}")
    print(f"目标JSON       : {target_dir / TARGET_JSON_NAME}")
    print(f"缺失记录TXT    : {SCRIPT_DIR}/{instance.name}_node_exporter_missing_<时间戳>.txt")
    print()
    print("说明：")
    if publish_mode == "merge":
        print("  - merge：新增/更新本次确认的 Node Exporter，不自动删除历史目标。")
    else:
        print("  - replace：发布后只保留本次确认的 Node Exporter；现有同端点自定义标签会保留。")
    print(f"  - file_sd 自动备份最多保留 {DEFAULT_BACKUP_KEEP} 份，发布文件采用原子替换。")
    print("  - TXT 只记录扫描时已确认主机存活、但未确认 Node Exporter 的 IP。")
    print("  - 辅助 TXT 写在本 .run 所在目录，使用实例名+时间戳，绝不静默覆盖。")
    print("  - 发布后会以 Prometheus 实际运行用户执行 promtool，并通过 HTTP API 验证 target。")
    print("  - 中心身份链路：site → origin_prometheus → job → instance(IPv4:端口)。")
    print("  - Node Exporter 原生 nodename 保持不变；Grafana 通过 node_uname_info 获取主机名。")
    print("  - 每个目标均写入 asset_ip 和 alert_policy；旧版注入的 name/hostname 等标签会清理。")
    print("  - 本次策略只用于新目标或缺少标签的目标；已有合法值保持不变。")
    print("  - 生成后可逐台编辑 JSON 调整 alert_policy；后续 merge 扫描会保留合法值。")
    print("  - ICMP 和常见 TCP 端口均被阻断的主机可能无法确认存活，不会写入 TXT。")


def prompt_confirm(yes: bool) -> None:
    if yes:
        return
    if not sys.stdin.isatty():
        raise ValueError("非交互运行必须使用 --yes 明确确认扫描")
    raw = input("确认开始扫描？ [Y/q，默认 Y]: ").strip().lower()
    if raw == "q":
        raise KeyboardInterrupt
    if raw not in {"", "y", "yes"}:
        raise KeyboardInterrupt


def main() -> int:
    args = parse_args()
    try:
        require_root()
        instances = discover_instances()
        instance = choose_instance(instances, args.instance)
        scan_lock = acquire_instance_lock(instance)

        assert_scrape_config_contract(instance)
        origin_prometheus, site = validate_external_label_contract(instance)

        contract_warnings = check_prometheus_contract(instance)
        if contract_warnings:
            print()
            print("=======================================================")
            print("Prometheus / Rules / Grafana 配套检查警告")
            print("=======================================================")
            for warning in contract_warnings:
                print(f"[WARNING] {warning}")
            print()

        scopes = split_scope_values(args.networks)
        if args.input_file:
            scopes.extend(read_scope_file(args.input_file))
        if not scopes:
            scopes = interactive_scope()

        exclusions = split_scope_values(args.exclude)
        common_labels = prompt_common_labels(args.label)
        alert_policy = prompt_alert_policy(args.alert_policy)

        node_port = prompt_node_port(args.port)
        targets, normalized_scopes = expand_targets(
            scopes,
            max_hosts=args.max_hosts,
            allow_public=args.allow_public,
            exclusion_items=exclusions,
        )

        print_plan(
            instance,
            normalized_scopes,
            exclusions,
            targets,
            node_port,
            args.publish_mode,
            common_labels,
            alert_policy,
        )
        prompt_confirm(args.yes)

        scrape_dir, target_dir, service_user, service_group, group_id = ensure_target_dirs(instance)
        print(f"Prometheus身份 : {service_user}:{service_group}")
        print(f"中心外部标签   : site={site}, origin_prometheus={origin_prometheus}")
        create_node_job_if_needed(
            instance, scrape_dir, target_dir, service_user, group_id
        )

        results = scan_targets(targets, node_port, args.workers)
        json_path, missing_path, old_count, final_count = publish_results(
            instance,
            target_dir,
            results,
            node_port,
            args.publish_mode,
            args.allow_empty,
            common_labels,
            alert_policy,
            group_id,
        )
        expected_policies = published_alert_policies(json_path)

        ensure_service_readable(json_path, service_user)
        valid, output = promtool_check_as_service_user(instance, service_user)
        if not valid:
            raise ValueError(
                f"发布后 Prometheus 配置无法由运行用户 {service_user} 校验。\n" + output
            )

        reload_prometheus(instance)
        runtime_config_msg = verify_runtime_config_contract(
            instance, origin_prometheus, site
        )
        matched_count, up_count, runtime_msg = verify_runtime_targets(
            instance, results, node_port, expected_policies
        )
        native_chain_msg = verify_native_metric_chain(
            instance, results, node_port, expected_policies
        )

        found_count = sum(row.status == "node_exporter" for row in results)
        missing_count = sum(row.status == "alive_no_node" for row in results)
        unknown_count = sum(row.status == "unknown" for row in results)
        policy_values = set(expected_policies.values())
        ordered_policies = [
            policy for policy in ALERT_POLICY_PRESETS if policy in policy_values
        ] + sorted(policy_values - set(ALERT_POLICY_PRESETS))
        policy_counts = {
            policy: sum(value == policy for value in expected_policies.values())
            for policy in ordered_policies
        }

        print()
        print("=======================================================")
        print("扫描完成")
        print("=======================================================")
        print(f"扫描地址       : {len(results)}")
        print(f"确认NodeExporter: {found_count}")
        print(f"存活但未确认Node: {missing_count}")
        print(f"无法确认存活   : {unknown_count}")
        print(f"原有监控目标   : {old_count}")
        print(f"发布后监控目标 : {final_count}")
        print(
            "告警策略分布   : "
            + ", ".join(f"{key}={value}" for key, value in policy_counts.items())
        )
        print(f"Prometheus JSON: {json_path}")
        print(f"缺失记录 TXT   : {missing_path}")
        print(f"运行态已加载   : {matched_count}/{found_count}")
        print(f"当前健康(up)   : {up_count}/{matched_count}")
        print(f"运行配置验证   : {runtime_config_msg}")
        print(f"运行态验证     : {runtime_msg}")
        print(f"原生标签链     : {native_chain_msg}")
        print()
        print("file_sd JSON 使用原子替换；脚本已完成 Prometheus reload 与运行态验证。")
        print("注意：missing TXT 表示“扫描时未确认 Node Exporter”，可能是未安装、服务停止或防火墙阻断。")
        return 0

    except KeyboardInterrupt:
        eprint("操作已取消。")
        return 130
    except ValueError as exc:
        eprint(f"错误：{exc}")
        return 2
    except OSError as exc:
        eprint(f"系统或文件错误：{exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
