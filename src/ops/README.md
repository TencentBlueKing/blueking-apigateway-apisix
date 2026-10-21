# nginx-health-check

`nginx-health-check.sh` is a single-file Bash health check for an NGINX proxy running in Kubernetes or directly on a host.

It supports three execution modes:

- `pod`: run inside the NGINX container to check process health, connection pressure, file descriptors, cgroup memory/CPU throttle, and log growth
- `node`: run on the Kubernetes node to check conntrack, ephemeral ports, TCP backlog drops, softnet/NIC drops, file handles, node pressure, and container log growth
- `host`: run on a host where NGINX is installed directly to check the NGINX service itself plus host-level conntrack, backlog, packet-drop, disk, inode, and PSI pressure

It also supports a remote-handoff mode:

- write `summary.txt`, `summary.json`, and `meta.txt` into a bundle directory
- write an `AGENTS.md` guide into the bundle root so a third party knows how to read it
- optionally save raw evidence under `raw/` and `top/`, so someone without shell access can still review the incident
- automatically create a sibling `tar.gz` archive for easy transfer

## Files

- [`nginx-health-check.sh`](./nginx-health-check.sh)

## Why these checks

The script is aimed at the three failure patterns described for NGINX-as-proxy workloads:

1. Large volumes of short-lived connections consume ephemeral ports and leave too many sockets in `TIME-WAIT`
2. `conntrack` reaches its limit and starts dropping packets, which can surface as intermittent `504`
3. Log files grow too large and contribute to pod memory pressure or hidden disk usage

## Prerequisites

### Common

Required:

- `bash`
- `awk`
- `grep`
- `sed`
- `ps`
- `du`
- `df`
- `find`
- `ss` or `netstat`

Optional but recommended:

- `lsof`
- `sort`
- `head`
- `timeout` from GNU coreutils when using `--probe`

### Pod mode

Recommended:

- `curl` or `wget` if you want to use `--status-url`

If `nginx.conf` or log directories are custom, pass them explicitly:

- `--nginx-conf /custom/path/nginx.conf`
- `--log-path /custom/log/dir`

The tool set you already listed is enough for the script:

```bash
yum install -y tar m4 findutils procps less iproute traceroute telnet lsof \
  net-tools tcpdump mtr vim bind-utils libyaml-devel hostname gawk iputils \
  python3 python3-pip sudo wget unzip patch make
```

### Node mode

Recommended:

- run as `root` or through `sudo`
- `dmesg` access enabled

If you need extra node-local evidence beyond the default system logs, pass it explicitly:

- `--log-path /var/log/messages`
- `--log-path /var/log/kubelet.log`
- `--log-path /path/to/a/specific/pod-or-service-log`

### Host mode

Recommended:

- run as `root` or through `sudo`
- `curl` or `wget` if you want to use `--status-url`

If `nginx.conf` or log directories are custom, pass them explicitly:

- `--nginx-conf /etc/nginx/nginx.conf`
- `--log-path /var/log/nginx`

## Usage

### Pod mode

Basic:

```bash
bash ./nginx-health-check.sh --mode pod
```

With custom nginx config and log paths:

```bash
bash ./nginx-health-check.sh --mode pod \
  --nginx-conf /data/nginx/conf/nginx.conf \
  --log-path /data/nginx/logs \
  --log-path /data/nginx/custom-logs
```

With `stub_status`:

```bash
bash ./nginx-health-check.sh --mode pod \
  --status-url http://127.0.0.1:8080/nginx_status
```

With a TCP probe:

```bash
bash ./nginx-health-check.sh --mode pod --probe 10.0.0.12:8080
```

### Node mode

Basic:

```bash
sudo bash ./nginx-health-check.sh --mode node
```

Longer delta window:

```bash
sudo bash ./nginx-health-check.sh --mode node --delta-seconds 5
```

Probe an upstream dependency:

```bash
sudo bash ./nginx-health-check.sh --mode node --probe 10.0.0.12:8080
```

Include a specific host log in the bundle:

```bash
sudo bash ./nginx-health-check.sh --mode node \
  --log-path /var/log/messages \
  --bundle-dir /tmp/nginx-check-node \
  --include-raw
```

### Host mode

Basic:

```bash
sudo bash ./nginx-health-check.sh --mode host
```

With custom nginx config and log paths:

```bash
sudo bash ./nginx-health-check.sh --mode host \
  --nginx-conf /etc/nginx/nginx.conf \
  --log-path /var/log/nginx
```

With `stub_status`:

```bash
sudo bash ./nginx-health-check.sh --mode host \
  --nginx-conf /etc/nginx/nginx.conf \
  --status-url http://127.0.0.1/nginx_status
```

Probe an upstream dependency:

```bash
sudo bash ./nginx-health-check.sh --mode host --probe 10.0.0.12:8080
```

### Remote handoff bundle

Pod bundle with raw evidence:

```bash
bash ./nginx-health-check.sh --mode pod \
  --nginx-conf /data/nginx/conf/nginx.conf \
  --log-path /data/nginx/logs \
  --bundle-dir /tmp/nginx-check-pod \
  --include-raw
```

Node bundle with raw evidence:

```bash
sudo bash ./nginx-health-check.sh --mode node \
  --bundle-dir /tmp/nginx-check-node \
  --include-raw
```

Host bundle with raw evidence:

```bash
sudo bash ./nginx-health-check.sh --mode host \
  --nginx-conf /etc/nginx/nginx.conf \
  --bundle-dir /tmp/nginx-check-host \
  --include-raw
```

Config loading note:

- `pod` and `host` mode read nginx config files directly and do not execute `nginx -T`
- `node` mode does not load nginx config

JSON output to stdout:

```bash
bash ./nginx-health-check.sh --mode pod --format json
```

## Output and exit code

The report prints:

- current value
- system limit or threshold
- state: `OK`, `WARN`, `CRIT`, or `INFO`
- a short explanation of the risk

For example, `ephemeral_ports` now prints direct capacity numbers such as `used`, `free`, `TW`, `range`, and `total`, so remote reviewers do not need to calculate them manually.

Pod-mode check names and what they look at:

- `nginx_process`: counts master, worker, cache manager/loader, and privileged agent processes
- `nginx_listen`: compares configured listen ports with active sockets
- `nginx_capacity`: worker_processes × worker_connections
- `tcp_states`: ESTAB/TIME-WAIT/CLOSE-WAIT/SYN-RECV mix and top remote peer
- `ephemeral_ports`: local port range and TIME-WAIT pressure
- `fd_usage`: file descriptor ratio of the busiest visible nginx process
- `memory`: cgroup memory usage, limit, and oom/failcnt
- `cpu_throttle`: cgroup CPU throttle delta over the sample window
- `listen_queues`: accept-queue depth (Recv-Q) vs max backlog (Send-Q) per LISTEN socket
- `log_volume`: total size of visible log paths; largest path
- `error_log_signals`: count of high-signal strings (worker_connections exhausted, Too many open files, upstream timed out, no live upstreams, TLS handshake, etc.) in the last `--tail-lines` lines of nginx error_log
- `deleted_open_logs`: deleted-but-open files held by nginx
- `stub_status`: live active/reading/writing/waiting plus **accepts/sec**, **requests/sec**, and **dropped_accepts** across the delta window
- `tcp_probe`: optional outbound TCP connect

Node-mode check names: `conntrack`, `ephemeral_ports`, `sockstat`, `file_handles`, `listen_backlog`, `packet_drop`, `node_memory`, `disk_root`, `inode_root`, `container_logs`, `psi_cpu`, `psi_memory`, `psi_io`, `tcp_probe`.

Host-mode check names: `nginx_process`, `nginx_listen`, `nginx_capacity`, `tcp_states`, `ephemeral_ports`, `fd_usage`, `memory`, `listen_queues`, `log_volume`, `error_log_signals`, `deleted_open_logs`, `stub_status`, `conntrack`, `sockstat`, `file_handles`, `listen_backlog`, `packet_drop`, `disk_root`, `inode_root`, `psi_cpu`, `psi_memory`, `psi_io`, `tcp_probe`.

Bundle output:

- `summary.txt`: plain-text report for humans
- `summary.json`: machine-readable summary for agents or automation
- `meta.txt`: execution context, kernel/user/mode/settings, and environment identity hints
- `AGENTS.md`: a reading guide for third-party humans or agents, including a decision map and common diagnosis paths
- `raw/`: raw command outputs such as `ss`, `sockstat`, `netstat`, `sysctl`, `meminfo`, cgroup data, resolved nginx config text from direct file scans in `pod`/`host` mode, filtered `dmesg`, explicit node system logs like `/var/log/messages` or `/var/log/syslog`, `/proc/pressure/*`, per-worker `status`/`wchan`, nginx upstream inventory, `/etc/resolv.conf`, `ethtool -S`/`ethtool -g` (node mode), and any explicit `--log-path` captures
- `top/`: ranked views such as busy remote peers, local ports, largest targeted log files, container log inventory, and most frequent normalized error-log messages
- `<bundle-dir>.tar.gz`: auto-generated archive for sharing the full bundle

Exit codes:

- `0`: all checks are `OK`
- `1`: at least one `WARN`
- `2`: at least one `CRIT`, or required tools are missing

## Notes

- This is a snapshot-style troubleshooting script, not a replacement for Prometheus or continuous monitoring.
- By default it samples delta-style counters across `3` seconds so it can catch active TCP backlog drops, softnet drops, and CPU throttling.
- `pod` mode assumes the container can read `/proc` and `/sys/fs/cgroup`.
- `node` mode focuses on node-level pressure. It does not try to enumerate every pod or container runtime detail.
- `host` mode focuses on a host-installed NGINX service plus the host pressure that can affect it. It does not use pod cgroup memory/CPU throttle semantics.
- `pod` mode keeps raw log capture narrow by default: nginx-discovered log paths, `/var/log/nginx`, and explicit `--log-path` overrides.
- `node` mode captures targeted host system logs by default and only tails extra node logs when you pass them explicitly with `--log-path`.
- `host` mode captures nginx-discovered log paths, `/var/log/nginx`, explicit `--log-path` overrides, and targeted host system logs in raw bundles.
- When `--include-raw` is used without `--bundle-dir`, the script auto-creates a bundle directory under the current working directory.

# apisix-diag：轻量现场证据采集

这是独立于上面综合健康检查的手动工具，不运行 HTTP/网络探测、不读取业务日志或配置，
不改变 APISIX 请求路径、不新增常驻进程。镜像内任意目录均可运行：

```bash
apisix-diag --cpu
apisix-diag --memory
apisix-diag --io
apisix-diag --all
```

必须且只能选择一个模式。`--help` 不采集；唯一额外参数是
`--output-dir /your/private/writable/directory`（默认 `/tmp/apisix-diag`，该父目录须为当前用户所有、0700）。
每次生成独立 `run-*` 目录，不压缩、不上传、不删除历史包。
固定 `/tmp/apisix-diag-control` 控制目录必须可写，不能通过换输出目录绕过单实例及 60 秒冷却。
同一容器不要混用不同 UID；只读根文件系统需要已有可写 `/tmp` 挂载。

| 模式 | 证据与边界 |
| --- | --- |
| `--cpu` | 两秒 worker CPU 增量，单核百分比和可见 cgroup quota 口径分开；验收通过后才对最忙的一个稳定 worker 做 19 Hz、10 秒用户态 IP 采样 |
| `--memory` | 十秒首尾 cgroup/worker 内存统计；只有验收通过且余量足够才读取首轮 RSS 最高 worker 的 smaps_rollup |
| `--io` | 十秒进程 I/O、可见 cgroup I/O 和当前网络命名空间计数；不等于物理磁盘吞吐、网关 RPS 或上游延迟 |
| `--all` | 基础发现 → CPU → memory/io 共用十秒窗口，昂贵步骤串行，最长预算 40 秒 |

单模式期限预算 20 秒，普通文本总预算 2 MiB，perf 文件 16 MiB，目录 24 MiB；
最多发现 1024 个 PID、纳入 64 个 worker。进程识别要求唯一 master、固定 nginx 可执行文件、
`-p /usr/local/apisix`、相同 cgroup 及父子关系；无法确认会跳过，不猜 PID。
会记录截断、计数重置、身份变化及缺失；期限不是不可中断内核读取的实时保证。

**当前默认只提供基础快照：** [支持矩阵](diag-supported.json) 初始为空。
perf 和 smaps_rollup 分别要求精确匹配 Build ID、采集器摘要、架构、宿主机内核、perf 版本、
预算版本和安全策略的验收记录；CLI 没有绕过开关。
`combination_not_validated` 表示没有对应验收，不能当作健康结论。
即使已验收，权限不足、OOM 增量、内存或磁盘余量不足、目标变化等也会停止或跳过昂贵步骤。
不会自动提权、改 sysctl、安装工具或换另一 worker 重试。
[验证记录与未完成验收](diag-validation.md) 列出当前范围。

| 返回码 | 含义 |
| --- | --- |
| 0 | 请求的采集范围完整完成，不代表已确定根因 |
| 10 | 已产出部分证据；缺失项见 summary/manifest |
| 20 | 无法安全开始、内部错误或无法完成报告 |
| 64 | 缺少模式、多个模式或其他参数错误 |
| 75 | 已有采集或 60 秒冷却未结束 |
| 130 | 用户中断，尽力保留部分证据 |

CPU 模式会突出“CPU 原生采样未完成”；即使生成 perf.data，采集端也不宣称有有效样本，
仍需外部同版本 perf 验证可解析性、非零样本及 lost 状态。
工具不收集 Lua 调用栈、Lua 对象/引用链或内核热点。原生锁热点不能自动归因为 Prometheus；
短期 RSS 增长不能确认 Lua 泄漏；worker RSS 不能简单相加为容器实际占用。

## 拷出和外部分析

整个包为 **PRIVATE**，可能含 PID、地址、路径和内核标识。未提供“全包脱敏”选项，
公开 issue 前需另行脱敏。采集结束后从已授权运维终端拷一次：

```bash
NAMESPACE='your-namespace'
POD='your-pod'
CONTAINER='apisix-container'
REMOTE_RUN='/tmp/apisix-diag/run-actual-value'
LOCAL_RUN='./apisix-diag-evidence'
kubectl cp -n "$NAMESPACE" -c "$CONTAINER" "$POD:$REMOTE_RUN" "$LOCAL_RUN"
```

或仅在本地压缩（不分配 TTY）：

```bash
set -o pipefail
kubectl exec -n "$NAMESPACE" "$POD" -c "$CONTAINER" -- \
  tar -C "$REMOTE_RUN" -cf - . | gzip -1 > ./apisix-diag-evidence.tar.gz
```

只认可整条 pipeline 成功的归档。外来 tar 需安全解包，拒绝绝对路径、`..`、symlink/hardlink。
分析器接收已经安全解包的目录，不自行解压，也不执行证据内字符串：

```bash
python3 src/ops/analyze-diag.py ./apisix-diag-evidence
python3 src/ops/analyze-diag.py ./apisix-diag-evidence --symbols ./matching-symbol-root
```

校验 schema、大小、路径 allowlist 和全部 checksums 后，在旁边新建 `*-analysis-*` 目录，
生成 analysis.md；不改原始证据。checksums 检测传输损坏，不证明来源真实性。
没有 Linux/perf/符号时仍汇总 JSON；符号化只把 Build ID 匹配的 ELF 复制到临时 symfs，
隔离 HOME、perf 配置、符号缓存及 debuginfod。热点表区分样本条数和 period 权重，
lost 无法确定时保持 unknown。不生成声称包含调用关系的火焰图。

## 构建和匹配符号材料

镜像安装固定 TencentOS perf 包；patch 和插件复制后生成 `ops/diag-build.json`，包含最终 Lua hashes、
ELF Build ID/SHA256、Python/perf/RPM/OpenResty/LuaJIT 版本及采集器摘要。
`DIAG_SOURCE_REVISION` 默认 unknown；只有源树确实对应 revision 时才传入提交号。
镜像 digest 由外部运维终端另外记录，不从容器内猜测。

```bash
docker build --build-arg DIAG_SOURCE_REVISION=YOUR_VERIFIED_REVISION -t your-apisix:production .
```

生产 Dockerfile 只构建运行镜像。需要离线符号材料时，单独使用 `Dockerfile.diag`，
通过 `APISIX_IMAGE` 指定上面已构建的生产镜像；发布场景应使用实际部署镜像的 registry digest。

```bash
docker build -f Dockerfile.diag --build-arg APISIX_IMAGE=your-apisix:production \
  -t your-apisix:diag-symbols .
SYMBOL_CONTAINER=$(docker create your-apisix:diag-symbols)
docker cp "$SYMBOL_CONTAINER:/diag-symbols" ./matching-symbol-root
docker rm "$SYMBOL_CONTAINER"
```

调试归档直接复制指定生产镜像内的文件，按该镜像已有清单校验哈希，不重新构建 APISIX。
生产镜像不包含这份重复归档。独立调试镜像用于导出原 ELF/DSO 和最终 Lua 源码，
未获得供应方独立 debug 包时在清单中记录缺失，不用重新编译的“同版本”替代。
基础快照无需启用部署特权或修改安全策略。

## 开发验证

```bash
PYTHONPATH=src/ops python3 -m unittest discover -s src/ops/tests -p 'test_diag_*.py' -v
python3 -m compileall -q src/ops/diag src/ops/analyze-diag.py src/build/bin/build-diag-manifest.py
python3 src/ops/apisix-diag --help
```

独立 CI 使用 Python 3.9 / 3.11，不运行 Lua 测试。单元测试使用合成 proc/cgroup/ELF 和本地
自建子进程；它们不能替代相同镜像/内核/安全策略下的配对负载与尾延迟验收。
