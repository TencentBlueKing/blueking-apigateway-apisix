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
