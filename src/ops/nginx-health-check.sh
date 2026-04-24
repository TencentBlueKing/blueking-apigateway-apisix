#!/usr/bin/env bash

set -u

SCRIPT_NAME="$(basename "$0")"
MODE=""
DELTA_SECONDS=3
STATUS_URL=""
TCP_PROBE=""
PROBE_TIMEOUT=2
CHECK_PREREQS_ONLY=0
NGINX_CONF=""
OUTPUT_FORMAT="table"
BUNDLE_DIR=""
INCLUDE_RAW=0
TAIL_LINES=500
RUN_TIME=""
RUN_STAMP=""
RUN_HOST=""
PREREQ_TO_STDOUT=1
ARCHIVE_PATH=""

declare -a CHECK_NAMES=() CHECK_VALUES=() CHECK_LIMITS=() CHECK_STATUSES=() CHECK_DETAILS=()
declare -a NOTES=()
declare -a EXTRA_LOG_PATHS=()

TCP_SNAPSHOT_LOADED=0
TCP_SNAPSHOT_CACHE=""
LISTEN_SNAPSHOT_LOADED=0
LISTEN_SNAPSHOT_CACHE=""

OVERALL_CODE=0
COLOR_OK=""
COLOR_WARN=""
COLOR_CRIT=""
COLOR_INFO=""
COLOR_RESET=""

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  COLOR_OK=$'\033[32m'
  COLOR_WARN=$'\033[33m'
  COLOR_CRIT=$'\033[31m'
  COLOR_INFO=$'\033[36m'
  COLOR_RESET=$'\033[0m'
fi

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME --mode pod|node [options]

Options:
  --mode MODE            Run in "pod" or "node" mode. Required.
  --delta-seconds N      Sample delta counters over N seconds. Default: 3.
  --nginx-conf PATH      Optional nginx config path for custom layouts.
  --log-path PATH        Optional extra log file or directory to inspect.
                         Repeat this option for multiple custom paths.
  --bundle-dir PATH      Write summary files into PATH for remote handoff.
  --include-raw          When bundle output is enabled, also save raw evidence.
  --format FMT           Output format: table, json, or both. Default: table.
  --tail-lines N         Tail N lines from evidence logs. Default: 500.
  --status-url URL       Optional nginx stub_status URL, for example:
                         http://127.0.0.1:8080/nginx_status
  --probe HOST:PORT      Optional TCP probe target, for example:
                         10.0.0.12:8080
  --probe-timeout SEC    TCP probe timeout in seconds. Default: 2.
  --check-prereqs        Only print prerequisite status and exit.
  -h, --help             Show this help.

Exit codes:
  0 = all checks OK
  1 = warning state
  2 = critical state or prerequisite failure
EOF
}

status_rank() {
  case "$1" in
    OK) echo 0 ;;
    WARN) echo 1 ;;
    CRIT) echo 2 ;;
    INFO) echo 0 ;;
    *) echo 0 ;;
  esac
}

merge_status() {
  local current="$1"
  local candidate="$2"
  if [ "$(status_rank "$candidate")" -gt "$(status_rank "$current")" ]; then
    echo "$candidate"
  else
    echo "$current"
  fi
}

format_status() {
  case "$1" in
    OK) printf "%s%s%s" "$COLOR_OK" "$1" "$COLOR_RESET" ;;
    WARN) printf "%s%s%s" "$COLOR_WARN" "$1" "$COLOR_RESET" ;;
    CRIT) printf "%s%s%s" "$COLOR_CRIT" "$1" "$COLOR_RESET" ;;
    INFO) printf "%s%s%s" "$COLOR_INFO" "$1" "$COLOR_RESET" ;;
    *) printf "%s" "$1" ;;
  esac
}

add_note() {
  NOTES+=("$1")
}

add_result() {
  local name="$1"
  local value="$2"
  local limit="$3"
  local status="$4"
  local detail="$5"

  CHECK_NAMES+=("$name")
  CHECK_VALUES+=("$value")
  CHECK_LIMITS+=("$limit")
  CHECK_STATUSES+=("$status")
  CHECK_DETAILS+=("$detail")

  local rank
  rank="$(status_rank "$status")"
  if [ "$rank" -gt "$OVERALL_CODE" ]; then
    OVERALL_CODE="$rank"
  fi
}

prereq_log() {
  if [ "$PREREQ_TO_STDOUT" -eq 1 ]; then
    printf '%s\n' "$1"
  else
    printf '%s\n' "$1" >&2
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

resolve_nginx_binary() {
  if [ -n "${NGINX_RUNTIME_BIN:-}" ]; then
    printf "%s" "$NGINX_RUNTIME_BIN"
    return
  fi

  local candidate=""
  if command_exists nginx; then
    candidate="$(command -v nginx)"
  elif command_exists openresty; then
    candidate="$(command -v openresty)"
  else
    candidate="$(ps -eo args= 2>/dev/null | sed -n 's/^nginx: master process //p' | awk 'NR == 1 {print $1}')"
    if [ -z "$candidate" ] || [ ! -x "$candidate" ]; then
      for candidate in \
        /usr/local/openresty/bin/openresty \
        /usr/local/openresty/nginx/sbin/nginx \
        /usr/local/nginx/sbin/nginx; do
        if [ -x "$candidate" ]; then
          break
        fi
      done
    fi
  fi

  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    NGINX_RUNTIME_BIN="$candidate"
    printf "%s" "$NGINX_RUNTIME_BIN"
  fi
}

join_by() {
  local separator="$1"
  shift
  local first=1
  local item
  for item in "$@"; do
    if [ "$first" -eq 1 ]; then
      printf "%s" "$item"
      first=0
    else
      printf "%s%s" "$separator" "$item"
    fi
  done
}

human_bytes() {
  local bytes="${1:-0}"
  local units=("B" "KiB" "MiB" "GiB" "TiB")
  local unit_index=0
  local whole="$bytes"
  local remainder=0

  if [ -z "$bytes" ] || [ "$bytes" = "unlimited" ]; then
    printf "%s" "${bytes:-0}"
    return
  fi

  if [ "$bytes" -lt 1024 ]; then
    printf "%sB" "$bytes"
    return
  fi

  while [ "$whole" -ge 1024 ] && [ "$unit_index" -lt 4 ]; do
    remainder=$(( whole % 1024 ))
    whole=$(( whole / 1024 ))
    unit_index=$(( unit_index + 1 ))
  done

  local decimal=$(( remainder * 10 / 1024 ))
  if [ "$whole" -ge 10 ] || [ "$unit_index" -eq 0 ]; then
    printf "%s%s" "$whole" "${units[$unit_index]}"
  else
    printf "%s.%s%s" "$whole" "$decimal" "${units[$unit_index]}"
  fi
}

human_seconds_us() {
  local usec="${1:-0}"
  if [ "$usec" -lt 1000 ]; then
    printf "%sus" "$usec"
  elif [ "$usec" -lt 1000000 ]; then
    printf "%sms" "$(( usec / 1000 ))"
  else
    printf "%ss" "$(( usec / 1000000 ))"
  fi
}

percent_of() {
  local value="${1:-0}"
  local max="${2:-0}"
  if [ -z "$max" ] || [ "$max" -le 0 ]; then
    printf "n/a"
    return
  fi
  printf "%s%%" "$(( value * 100 / max ))"
}

format_ephemeral_current() {
  local used="${1:-0}"
  local total="${2:-0}"
  local time_wait="${3:-0}"
  local free=0
  if [ "$total" -gt 0 ]; then
    free=$(( total - used ))
    if [ "$free" -lt 0 ]; then
      free=0
    fi
  fi
  printf "used=%s free=%s TW=%s" "$used" "$free" "$time_wait"
}

format_ephemeral_limit() {
  local low="${1:-0}"
  local high="${2:-0}"
  local total="${3:-0}"
  printf "range=%s-%s total=%s" "$low" "$high" "$total"
}

free_of() {
  local total="${1:-0}"
  local used="${2:-0}"
  local free=0
  if [ "$total" -gt 0 ]; then
    free=$(( total - used ))
    if [ "$free" -lt 0 ]; then
      free=0
    fi
  fi
  printf "%s" "$free"
}

ratio_text() {
  local used="${1:-0}"
  local total="${2:-0}"
  printf "%s" "$(percent_of "$used" "$total")"
}

safe_percent() {
  local used="${1:-0}"
  local total="${2:-0}"
  if [ "$total" -le 0 ]; then
    printf "unknown"
  else
    printf "%s" "$(percent_of "$used" "$total")"
  fi
}

format_usage_pair() {
  local used="$1"
  local total="$2"
  local label="${3:-used}"
  local free
  free="$(free_of "$total" "$used")"
  printf "%s=%s free=%s" "$label" "$used" "$free"
}

format_limit_usage() {
  local total="$1"
  local used="$2"
  local label="${3:-limit}"
  if [ -z "$total" ] || [ "$total" -le 0 ]; then
    printf "%s unavailable" "$label"
  else
    printf "%s=%s usage=%s" "$label" "$total" "$(percent_of "$used" "$total")"
  fi
}

format_state_ratio() {
  local count="$1"
  local total="$2"
  local label="$3"
  printf "%s=%s (%s)" "$label" "$count" "$(safe_percent "$count" "$total")"
}

status_by_ratio() {
  local value="${1:-0}"
  local max="${2:-0}"
  local warn_pct="${3:-70}"
  local crit_pct="${4:-85}"

  if [ -z "$max" ] || [ "$max" -le 0 ]; then
    printf "INFO"
    return
  fi

  local pct=$(( value * 100 / max ))
  if [ "$pct" -ge "$crit_pct" ]; then
    printf "CRIT"
  elif [ "$pct" -ge "$warn_pct" ]; then
    printf "WARN"
  else
    printf "OK"
  fi
}

status_by_threshold() {
  local value="${1:-0}"
  local warn="${2:-0}"
  local crit="${3:-0}"

  if [ "$crit" -gt 0 ] && [ "$value" -ge "$crit" ]; then
    printf "CRIT"
  elif [ "$warn" -gt 0 ] && [ "$value" -ge "$warn" ]; then
    printf "WARN"
  else
    printf "OK"
  fi
}

safe_read_first_line() {
  local file="$1"
  if [ -r "$file" ]; then
    sed -n '1p' "$file" 2>/dev/null
  fi
}

safe_read_trimmed() {
  local file="$1"
  if [ -r "$file" ]; then
    tr -d '[:space:]' <"$file" 2>/dev/null
  fi
}

get_mode_required_commands() {
  local mode="$1"
  local required=("awk" "grep" "sed" "ps" "du" "df" "find")
  if ! command_exists ss && ! command_exists netstat; then
    required+=("ss_or_netstat")
  fi
  if [ "$mode" = "node" ]; then
    required+=("dmesg")
  fi
  printf "%s\n" "${required[@]}"
}

get_mode_optional_commands() {
  local mode="$1"
  local optional=("lsof" "sort" "head")
  if [ "$mode" = "pod" ]; then
    optional+=("nginx_or_openresty" "curl_or_wget")
  else
    optional+=("sysctl")
  fi
  printf "%s\n" "${optional[@]}"
}

check_prereqs() {
  local mode="$1"
  local missing_required=()
  local missing_optional=()
  local cmd

  while IFS= read -r cmd; do
    case "$cmd" in
      ss_or_netstat)
        if ! command_exists ss && ! command_exists netstat; then
          missing_required+=("ss or netstat")
        fi
        ;;
      curl_or_wget)
        if ! command_exists curl && ! command_exists wget; then
          missing_optional+=("curl or wget (only needed for --status-url)")
        fi
        ;;
      *)
        if ! command_exists "$cmd"; then
          missing_required+=("$cmd")
        fi
        ;;
    esac
  done < <(get_mode_required_commands "$mode")

  while IFS= read -r cmd; do
    case "$cmd" in
      nginx_or_openresty)
        if [ -z "$(resolve_nginx_binary)" ]; then
          missing_optional+=("nginx or openresty runtime binary")
        fi
        ;;
      curl_or_wget)
        if ! command_exists curl && ! command_exists wget; then
          missing_optional+=("curl or wget (only needed for --status-url)")
        fi
        ;;
      *)
        if ! command_exists "$cmd"; then
          missing_optional+=("$cmd")
        fi
        ;;
    esac
  done < <(get_mode_optional_commands "$mode")

  if [ "${#missing_required[@]}" -gt 0 ]; then
    prereq_log "Missing required commands for ${mode} mode: $(join_by ", " "${missing_required[@]}")"
    return 1
  fi

  prereq_log "Prerequisites for ${mode} mode: OK"
  if [ "${#missing_optional[@]}" -gt 0 ]; then
    prereq_log "Optional commands not found: $(join_by ", " "${missing_optional[@]}")"
  fi
  return 0
}

get_tcp_snapshot() {
  if [ "$TCP_SNAPSHOT_LOADED" -eq 0 ]; then
    if command_exists ss; then
      TCP_SNAPSHOT_CACHE="$(ss -tanH 2>/dev/null | awk '{print $1 "\t" $4 "\t" $5}')"
    else
      TCP_SNAPSHOT_CACHE="$(netstat -tan 2>/dev/null | awk '
        NR > 2 {
          state = $6
          if (state == "ESTABLISHED") state = "ESTAB"
          else if (state == "TIME_WAIT") state = "TIME-WAIT"
          else if (state == "CLOSE_WAIT") state = "CLOSE-WAIT"
          else if (state == "SYN_RECV") state = "SYN-RECV"
          else if (state == "SYN_SENT") state = "SYN-SENT"
          else if (state == "FIN_WAIT1") state = "FIN-WAIT-1"
          else if (state == "FIN_WAIT2") state = "FIN-WAIT-2"
          else if (state == "LAST_ACK") state = "LAST-ACK"
          print state "\t" $4 "\t" $5
        }
      ')"
    fi
    TCP_SNAPSHOT_LOADED=1
  fi
  if [ -n "$TCP_SNAPSHOT_CACHE" ]; then
    printf "%s\n" "$TCP_SNAPSHOT_CACHE"
  fi
}

get_listen_snapshot() {
  if [ "$LISTEN_SNAPSHOT_LOADED" -eq 0 ]; then
    if command_exists ss; then
      # ss -lntH: state recv-q send-q local-addr:port peer-addr:port
      LISTEN_SNAPSHOT_CACHE="$(ss -lntH 2>/dev/null | awk '{print $2 "\t" $3 "\t" $4}')"
    else
      # netstat -lnt: Proto Recv-Q Send-Q Local Foreign State
      LISTEN_SNAPSHOT_CACHE="$(netstat -lnt 2>/dev/null | awk 'NR > 2 && $6 == "LISTEN" {print $2 "\t" $3 "\t" $4}')"
    fi
    LISTEN_SNAPSHOT_LOADED=1
  fi
  if [ -n "$LISTEN_SNAPSHOT_CACHE" ]; then
    printf "%s\n" "$LISTEN_SNAPSHOT_CACHE"
  fi
}

count_tcp_state() {
  local state="$1"
  get_tcp_snapshot | awk -F'\t' -v state="$state" '$1 == state {count++} END {print count + 0}'
}

count_total_tcp() {
  get_tcp_snapshot | awk 'END {print NR + 0}'
}

count_unique_ephemeral_ports() {
  local low="$1"
  local high="$2"
  get_tcp_snapshot | awk -F'\t' -v low="$low" -v high="$high" '
    function local_port(addr, port) {
      sub(/^.*:/, "", addr)
      gsub(/[^0-9]/, "", addr)
      port = addr + 0
      return port
    }
    {
      port = local_port($2)
      if (port >= low && port <= high) {
        seen[port] = 1
      }
    }
    END {
      for (port in seen) {
        count++
      }
      print count + 0
    }
  '
}

read_ip_local_port_range() {
  if [ -r /proc/sys/net/ipv4/ip_local_port_range ]; then
    awk '{print $1, $2}' /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null
  fi
}

read_proc_value() {
  local file="$1"
  local default_value="${2:-0}"
  local value
  value="$(safe_read_trimmed "$file")"
  if [ -z "$value" ]; then
    printf "%s" "$default_value"
  else
    printf "%s" "$value"
  fi
}

read_sysctl_value() {
  local key="$1"
  local file="/proc/sys/${key//./\/}"
  if [ -r "$file" ]; then
    safe_read_trimmed "$file"
  elif command_exists sysctl; then
    sysctl -n "$key" 2>/dev/null
  fi
}

load_nginx_config() {
  # Captures `nginx -T` stdout (the merged config) separately from stderr so
  # a failing `-T` (syntax error, include not readable, etc.) surfaces in
  # NGINX_CONFIG_ERROR instead of being silently treated as empty config.
  if [ -z "${NGINX_CONFIG_LOADED:-}" ]; then
    NGINX_CONFIG_LOADED=1
    NGINX_CONFIG_TEXT=""
    NGINX_CONFIG_SOURCE="nginx/openresty -T"
    NGINX_CONFIG_ERROR=""
    local nginx_bin stderr_tmp rc=0
    nginx_bin="$(resolve_nginx_binary)"

    if [ -z "$nginx_bin" ]; then
      if [ -n "$NGINX_CONF" ]; then
        NGINX_CONFIG_ERROR="nginx/openresty runtime binary missing, cannot load custom config: $NGINX_CONF"
      fi
      return
    fi

    if [ -n "$NGINX_CONF" ]; then
      NGINX_CONFIG_SOURCE="$nginx_bin -T -c $NGINX_CONF"
      if [ ! -r "$NGINX_CONF" ]; then
        NGINX_CONFIG_ERROR="custom nginx config not readable: $NGINX_CONF"
        return
      fi
    else
      NGINX_CONFIG_SOURCE="$nginx_bin -T"
    fi

    stderr_tmp="$(mktemp 2>/dev/null)" || stderr_tmp=""
    if [ -n "$stderr_tmp" ]; then
      if [ -n "$NGINX_CONF" ]; then
        NGINX_CONFIG_TEXT="$("$nginx_bin" -T -c "$NGINX_CONF" 2>"$stderr_tmp")"
      else
        NGINX_CONFIG_TEXT="$("$nginx_bin" -T 2>"$stderr_tmp")"
      fi
      rc=$?
    else
      if [ -n "$NGINX_CONF" ]; then
        NGINX_CONFIG_TEXT="$("$nginx_bin" -T -c "$NGINX_CONF" 2>/dev/null)"
      else
        NGINX_CONFIG_TEXT="$("$nginx_bin" -T 2>/dev/null)"
      fi
      rc=$?
    fi

    if [ "$rc" -ne 0 ]; then
      local stderr_head=""
      if [ -n "$stderr_tmp" ] && [ -s "$stderr_tmp" ]; then
        stderr_head="$(head -c 400 "$stderr_tmp" 2>/dev/null | tr '\n' ';' | tr -s ';' | sed 's/;$//')"
      fi
      if [ -n "$stderr_head" ]; then
        NGINX_CONFIG_ERROR="nginx -T exited ${rc}: ${stderr_head}"
      else
        NGINX_CONFIG_ERROR="nginx -T exited ${rc}"
      fi
    fi
    [ -n "$stderr_tmp" ] && rm -f "$stderr_tmp"
  fi
}

extract_nginx_value() {
  local directive="$1"
  load_nginx_config
  if [ -z "$NGINX_CONFIG_TEXT" ]; then
    return
  fi
  printf "%s\n" "$NGINX_CONFIG_TEXT" | awk -v directive="$directive" '
    $0 !~ /^[[:space:]]*#/ && $1 == directive {
      gsub(/;/, "", $2)
      print $2
      exit
    }
  '
}

extract_nginx_listen_bindings() {
  # Emits one binding per line:
  #   *:PORT         wildcard (`listen 80;`, `listen 0.0.0.0:80;`, `listen [::]:80;`)
  #   IP:PORT        specific IPv4   (`listen 127.0.0.1:8080;`)
  #   [IPv6]:PORT    specific IPv6   (`listen [fe80::1]:8080;`)
  # This lets the listener check detect "config says 127.0.0.1 only but we
  # need 0.0.0.0" regressions, not just port-is-alive-somewhere.
  load_nginx_config
  if [ -z "$NGINX_CONFIG_TEXT" ]; then
    return
  fi
  printf "%s\n" "$NGINX_CONFIG_TEXT" | awk '
    $0 !~ /^[[:space:]]*#/ && $1 == "listen" {
      token = $2
      gsub(/;/, "", token)
      if (token ~ /^unix:/) next

      # Bare port, e.g. "listen 80;"
      if (token ~ /^[0-9]+$/) {
        print "*:" token
        next
      }

      # IPv6 form: [addr]:port
      if (token ~ /^\[[^]]+\]:[0-9]+$/) {
        port = token; sub(/^.*:/, "", port)
        addr = token; sub(/:[0-9]+$/, "", addr)
        # Wildcard IPv6 renders as *
        if (addr == "[::]" || addr == "[0:0:0:0:0:0:0:0]") {
          print "*:" port
        } else {
          print addr ":" port
        }
        next
      }

      # IPv4 form: ip:port
      if (token ~ /^[0-9a-fA-F.:]+:[0-9]+$/) {
        port = token; sub(/^.*:/, "", port)
        addr = token; sub(/:[0-9]+$/, "", addr)
        if (addr == "0.0.0.0" || addr == "::" || addr == "*") {
          print "*:" port
        } else {
          print addr ":" port
        }
        next
      }
    }
  ' | sort -u
}

# True if a given config binding (*:port or ip:port) has a matching LISTEN
# socket. For wildcard bindings any bind-address on that port counts; for
# specific bindings the socket must match exactly.
listener_present() {
  local binding="$1"
  local addresses
  addresses="$(get_listen_snapshot | awk -F'\t' '{print $3}')"
  case "$binding" in
    \*:*)
      local port="${binding#*:}"
      printf "%s\n" "$addresses" | awk -v p=":$port" '
        {
          n = length($0); k = length(p)
          if (n >= k && substr($0, n - k + 1) == p) { found = 1 }
        }
        END { exit found ? 0 : 1 }
      '
      ;;
    *)
      printf "%s\n" "$addresses" | awk -v b="$binding" '$0 == b { found = 1 } END { exit found ? 0 : 1 }'
      ;;
  esac
}

extract_nginx_log_paths() {
  load_nginx_config
  if [ -z "$NGINX_CONFIG_TEXT" ]; then
    return
  fi
  printf "%s\n" "$NGINX_CONFIG_TEXT" | awk '
    $0 !~ /^[[:space:]]*#/ && ($1 == "access_log" || $1 == "error_log") {
      if ($2 == "off" || $2 ~ /^syslog:/) {
        next
      }
      gsub(/;/, "", $2)
      print $2
    }
  ' | sort -u
}

resolve_worker_processes() {
  local raw
  raw="$(extract_nginx_value "worker_processes")"
  case "$raw" in
    "" )
      printf "0"
      ;;
    auto)
      if command_exists nproc; then
        nproc
      else
        awk '/^processor[[:space:]]*:/ {count++} END {print count + 0}' /proc/cpuinfo 2>/dev/null
      fi
      ;;
    *)
      printf "%s" "$raw"
      ;;
  esac
}

sum_proc_rss_bytes() {
  # Prefer Pss (proportional set size, smaps_rollup) so shared pages between
  # nginx master and workers aren't triple-counted. Falls back to VmRSS per
  # PID when smaps_rollup is unreadable (old kernel, privileges). Returns
  # "BYTES KIND" so the caller can display whether Pss or VmRSS was used.
  local pid
  local total_kb=0
  local kind="Pss"
  local any_pss=0 any_rss=0 kb
  for pid in "$@"; do
    kb=""
    if [ -r "/proc/$pid/smaps_rollup" ]; then
      kb="$(awk '/^Pss:/ {print $2; exit}' "/proc/$pid/smaps_rollup" 2>/dev/null)"
      if [ -n "$kb" ]; then
        total_kb=$(( total_kb + kb ))
        any_pss=1
        continue
      fi
    fi
    if [ -r "/proc/$pid/status" ]; then
      kb="$(awk '/^VmRSS:/ {print $2; exit}' "/proc/$pid/status" 2>/dev/null)"
      if [ -n "$kb" ]; then
        total_kb=$(( total_kb + kb ))
        any_rss=1
      fi
    fi
  done
  if [ "$any_pss" -eq 0 ] && [ "$any_rss" -eq 1 ]; then
    kind="VmRSS"
  elif [ "$any_pss" -eq 1 ] && [ "$any_rss" -eq 1 ]; then
    kind="Pss+VmRSS"
  fi
  printf "%s %s" "$(( total_kb * 1024 ))" "$kind"
}

max_proc_fd_usage() {
  # For each PID, pair its own open count with its own limit. Report the
  # process whose (open / limit) ratio is highest so the caller never mixes
  # values from two different PIDs. When no PID has a numeric limit, fall
  # back to the highest open count and highest limit we saw separately.
  local pid open_count limit ratio
  local best_ratio=-1 best_pid="" best_open=0 best_limit=0
  local fallback_open=0 fallback_limit=0
  for pid in "$@"; do
    open_count=0
    limit=0
    if [ -d "/proc/$pid/fd" ]; then
      open_count="$(find "/proc/$pid/fd" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | awk '{print $1+0}')"
      [ -z "$open_count" ] && open_count=0
    fi
    if [ -r "/proc/$pid/limits" ]; then
      limit="$(awk '/Max open files/ {print $(NF-1); exit}' "/proc/$pid/limits" 2>/dev/null)"
      if [ -z "$limit" ] || [ "$limit" = "unlimited" ]; then
        limit=0
      fi
    fi
    if [ "$open_count" -gt "$fallback_open" ]; then
      fallback_open="$open_count"
    fi
    if [ "$limit" -gt "$fallback_limit" ]; then
      fallback_limit="$limit"
    fi
    if [ "$limit" -gt 0 ]; then
      ratio=$(( open_count * 10000 / limit ))
      if [ "$ratio" -gt "$best_ratio" ]; then
        best_ratio="$ratio"
        best_pid="$pid"
        best_open="$open_count"
        best_limit="$limit"
      fi
    fi
  done
  if [ -n "$best_pid" ]; then
    printf "%s %s %s" "$best_open" "$best_limit" "$best_pid"
  else
    printf "%s %s %s" "$fallback_open" "$fallback_limit" ""
  fi
}

discover_pod_cgroup_files() {
  if [ -r /sys/fs/cgroup/cgroup.controllers ]; then
    CGROUP_MEMORY_CURRENT="/sys/fs/cgroup/memory.current"
    CGROUP_MEMORY_MAX="/sys/fs/cgroup/memory.max"
    CGROUP_MEMORY_EVENTS="/sys/fs/cgroup/memory.events"
    CGROUP_CPU_STAT="/sys/fs/cgroup/cpu.stat"
  else
    CGROUP_MEMORY_CURRENT="/sys/fs/cgroup/memory/memory.usage_in_bytes"
    CGROUP_MEMORY_MAX="/sys/fs/cgroup/memory/memory.limit_in_bytes"
    CGROUP_MEMORY_EVENTS="/sys/fs/cgroup/memory/memory.failcnt"
    CGROUP_CPU_STAT="/sys/fs/cgroup/cpu/cpu.stat"
    if [ ! -r "$CGROUP_CPU_STAT" ] && [ -r /sys/fs/cgroup/cpu,cpuacct/cpu.stat ]; then
      CGROUP_CPU_STAT="/sys/fs/cgroup/cpu,cpuacct/cpu.stat"
    fi
  fi
}

read_pod_memory_usage() {
  discover_pod_cgroup_files
  local current max
  current="$(read_proc_value "$CGROUP_MEMORY_CURRENT" "0")"
  max="$(safe_read_trimmed "$CGROUP_MEMORY_MAX")"
  case "$max" in
    ""|max|9223372036854771712)
      max="0"
      ;;
  esac
  printf "%s %s" "$current" "$max"
}

read_pod_memory_events() {
  discover_pod_cgroup_files
  if [ -r "$CGROUP_MEMORY_EVENTS" ]; then
    if [ "$CGROUP_MEMORY_EVENTS" = "/sys/fs/cgroup/memory/memory.failcnt" ]; then
      local failcnt
      failcnt="$(read_proc_value "$CGROUP_MEMORY_EVENTS" "0")"
      printf "failcnt=%s" "$failcnt"
    else
      tr '\n' ' ' <"$CGROUP_MEMORY_EVENTS" 2>/dev/null
    fi
  fi
}

read_cpu_throttle_snapshot() {
  discover_pod_cgroup_files
  if [ -r "$CGROUP_CPU_STAT" ]; then
    awk '
      /^nr_throttled / {nr = $2}
      /^throttled_usec / {usec = $2}
      END {print (nr + 0) " " (usec + 0)}
    ' "$CGROUP_CPU_STAT" 2>/dev/null
  else
    printf "0 0"
  fi
}

sum_paths_bytes() {
  local total=0
  local path
  for path in "$@"; do
    if [ -f "$path" ] || [ -d "$path" ]; then
      local size
      size="$(du -sb "$path" 2>/dev/null | awk 'NR == 1 {print $1}')"
      if [ -n "$size" ]; then
        total=$(( total + size ))
      fi
    fi
  done
  printf "%s" "$total"
}

largest_existing_path() {
  local biggest_path=""
  local biggest_size=0
  local path
  for path in "$@"; do
    if [ -f "$path" ] || [ -d "$path" ]; then
      local size
      size="$(du -sb "$path" 2>/dev/null | awk 'NR == 1 {print $1}')"
      if [ -n "$size" ] && [ "$size" -gt "$biggest_size" ]; then
        biggest_size="$size"
        biggest_path="$path"
      fi
    fi
  done
  printf "%s %s" "$biggest_size" "$biggest_path"
}

read_stub_status() {
  local url="$1"
  local body=""
  if command_exists curl; then
    body="$(curl -fsS --max-time 2 "$url" 2>/dev/null || true)"
  elif command_exists wget; then
    body="$(wget -q -T 2 -O - "$url" 2>/dev/null || true)"
  fi
  printf "%s" "$body"
}

# Parses one body of nginx stub_status into seven space-separated integers:
# active reading writing waiting accepts handled requests
parse_stub_status_values() {
  local body="$1"
  if [ -z "$body" ]; then
    printf "0 0 0 0 0 0 0"
    return
  fi
  printf "%s\n" "$body" | awk '
    /Active connections:/ { active = $3 }
    NR == 3 && NF >= 3 { accepts = $1; handled = $2; requests = $3 }
    /Reading:/ { reading = $2; writing = $4; waiting = $6 }
    END {
      printf "%d %d %d %d %d %d %d",
        (active + 0), (reading + 0), (writing + 0), (waiting + 0),
        (accepts + 0), (handled + 0), (requests + 0)
    }
  '
}

filter_error_log_levels() {
  awk '/\[(error|crit|emerg|alert)\]/'
}

append_filtered_error_log_lines() {
  local tail_lines="$1"
  shift
  local path
  for path in "$@"; do
    if [ -r "$path" ]; then
      tail -n "$tail_lines" "$path" 2>/dev/null | filter_error_log_levels || true
    fi
  done
}

# Scans the last N lines of every known nginx error_log for a curated set of
# high-signal strings (connection limit, FD exhaustion, conntrack full, upstream
# issues, SSL handshake failure, etc). Returns "total_hits\t<per-pattern summary>".
scan_error_log_signals() {
  local tail_lines="$1"
  shift
  local -a paths=("$@")
  if [ "${#paths[@]}" -eq 0 ]; then
    printf "0\t"
    return
  fi

  local tmp
  tmp="$(mktemp 2>/dev/null)" || tmp=""
  if [ -z "$tmp" ]; then
    printf "0\t"
    return
  fi

  local path
  append_filtered_error_log_lines "$tail_lines" "${paths[@]}" >>"$tmp"

  local -a patterns=(
    "worker_connections are not enough"
    "Too many open files"
    "accept4() failed"
    "accept() failed"
    "upstream timed out"
    "Cannot assign requested address"
    "no live upstreams"
    "SSL_do_handshake() failed"
    "Connection reset by peer"
    "upstream prematurely closed connection"
    "could not be resolved"
    "nf_conntrack: table full"
    "conntrack table full"
    "server returned error: 502"
    "server returned error: 504"
  )

  local total=0
  local summary=""
  local pattern count
  for pattern in "${patterns[@]}"; do
    count="$(grep -Fc -- "$pattern" "$tmp" 2>/dev/null)"
    count="${count:-0}"
    if [ "$count" -gt 0 ]; then
      total=$(( total + count ))
      if [ -n "$summary" ]; then
        summary="${summary}; "
      fi
      summary="${summary}${pattern}=${count}"
    fi
  done

  rm -f "$tmp" 2>/dev/null || true
  printf "%s\t%s" "$total" "$summary"
}

# Picks the LISTEN socket with the highest (recv-q / send-q) ratio.
# Returns: max_ratio_pct max_recv_q max_send_q max_addr total_listeners
analyze_listen_queues() {
  local recv send addr
  local max_ratio=0 max_rq=0 max_sq=0 max_addr=""
  local total=0
  while IFS=$'\t' read -r recv send addr; do
    [ -z "$recv" ] && continue
    [ -z "$send" ] && continue
    total=$(( total + 1 ))
    local sq_int="${send%%[!0-9]*}"
    local rq_int="${recv%%[!0-9]*}"
    [ -z "$sq_int" ] && sq_int=0
    [ -z "$rq_int" ] && rq_int=0
    if [ "$sq_int" -gt 0 ]; then
      local ratio=$(( rq_int * 100 / sq_int ))
      if [ "$ratio" -gt "$max_ratio" ]; then
        max_ratio="$ratio"
        max_rq="$rq_int"
        max_sq="$sq_int"
        max_addr="$addr"
      fi
    fi
  done < <(get_listen_snapshot)
  printf "%s %s %s %s %s" "$max_ratio" "$max_rq" "$max_sq" "${max_addr:-n/a}" "$total"
}

run_tcp_probe() {
  local target="$1"
  local timeout_seconds="$2"
  local host="${target%:*}"
  local port="${target##*:}"
  if [ -z "$host" ] || [ -z "$port" ] || [ "$host" = "$port" ]; then
    printf "invalid"
    return
  fi
  if ! command_exists timeout; then
    printf "missing-timeout"
    return
  fi
  if timeout "$timeout_seconds" bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
    printf "ok"
  else
    printf "failed"
  fi
}

read_netstat_counter() {
  local key="$1"
  awk -v lookup="$key" '
    $1 == "TcpExt:" {
      count++
      if (count == 1) {
        for (i = 2; i <= NF; i++) {
          names[i] = $i
        }
      } else if (count == 2) {
        for (i = 2; i <= NF; i++) {
          if (names[i] == lookup) {
            print $i
            exit
          }
        }
      }
    }
  ' /proc/net/netstat 2>/dev/null
}

read_softnet_drops_total() {
  local total=0
  if [ -r /proc/net/softnet_stat ]; then
    while read -r line; do
      set -- $line
      total=$(( total + 16#$2 ))
    done </proc/net/softnet_stat
  fi
  printf "%s" "$total"
}

read_nic_drop_totals() {
  local rx_total=0
  local tx_total=0
  local iface
  for iface in /sys/class/net/*; do
    iface="$(basename "$iface")"
    if [ "$iface" = "lo" ]; then
      continue
    fi
    local rx_file="/sys/class/net/$iface/statistics/rx_dropped"
    local tx_file="/sys/class/net/$iface/statistics/tx_dropped"
    if [ -r "$rx_file" ]; then
      rx_total=$(( rx_total + $(read_proc_value "$rx_file" "0") ))
    fi
    if [ -r "$tx_file" ]; then
      tx_total=$(( tx_total + $(read_proc_value "$tx_file" "0") ))
    fi
  done
  printf "%s %s" "$rx_total" "$tx_total"
}

read_psi_avg10() {
  local file="$1"
  local line_type="$2"
  if [ -r "$file" ]; then
    awk -v target="$line_type" '
      $1 == target {
        for (i = 2; i <= NF; i++) {
          if ($i ~ /^avg10=/) {
            split($i, pair, "=")
            print pair[2]
            exit
          }
        }
      }
    ' "$file" 2>/dev/null
  fi
}

read_meminfo_value_kb() {
  local key="$1"
  awk -v lookup="$key" '$1 == lookup ":" {print $2; exit}' /proc/meminfo 2>/dev/null
}

read_df_usage_pct() {
  local path="$1"
  df -P "$path" 2>/dev/null | awk 'NR == 2 {gsub(/%/, "", $5); print $5}'
}

read_df_inode_pct() {
  local path="$1"
  df -Pi "$path" 2>/dev/null | awk 'NR == 2 {gsub(/%/, "", $5); print $5}'
}

read_df_bytes_triplet() {
  local path="$1"
  df -P -B1 "$path" 2>/dev/null | awk 'NR == 2 {print $2, $3, $4}'
}

read_df_inode_triplet() {
  local path="$1"
  df -Pi "$path" 2>/dev/null | awk 'NR == 2 {print $2, $3, $4}'
}

shell_quote() {
  printf '%q' "$1"
}

json_escape() {
  local value="${1:-}"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

get_overall_text() {
  case "$OVERALL_CODE" in
    1) printf "WARN" ;;
    2) printf "CRIT" ;;
    *) printf "OK" ;;
  esac
}

ensure_parent_dir() {
  local target="$1"
  mkdir -p "$(dirname "$target")"
}

collect_pod_log_paths() {
  local -a paths=()
  local path

  while IFS= read -r path; do
    [ -n "$path" ] && paths+=("$path")
  done < <(extract_nginx_log_paths)

  if [ "${#EXTRA_LOG_PATHS[@]}" -gt 0 ]; then
    paths+=("${EXTRA_LOG_PATHS[@]}")
  fi

  # Keep pod-mode capture narrow by default: nginx-discovered log files,
  # explicit --log-path overrides, and the conventional /var/log/nginx dir.
  for path in /var/log/nginx; do
    if [ -e "$path" ]; then
      paths+=("$path")
    fi
  done

  if [ "${#paths[@]}" -gt 0 ]; then
    printf "%s\n" "${paths[@]}" | sort -u
  fi
}

extract_nginx_error_log_paths() {
  load_nginx_config
  if [ -z "${NGINX_CONFIG_TEXT:-}" ]; then
    return
  fi
  printf "%s\n" "$NGINX_CONFIG_TEXT" | awk '
    $0 !~ /^[[:space:]]*#/ && $1 == "error_log" {
      if ($2 ~ /^syslog:/) {
        next
      }
      gsub(/;/, "", $2)
      print $2
    }
  ' | sort -u
}

collect_node_container_log_dirs() {
  local candidate
  for candidate in /var/log/containers /var/log/pods /var/lib/docker/containers; do
    if [ -d "$candidate" ]; then
      printf "%s\n" "$candidate"
    fi
  done
}

collect_node_system_log_files() {
  local candidate
  for candidate in /var/log/messages /var/log/syslog /var/log/kern.log /var/log/dmesg; do
    if [ -f "$candidate" ]; then
      printf "%s\n" "$candidate"
    fi
  done
}

collect_node_extra_log_paths() {
  if [ "${#EXTRA_LOG_PATHS[@]}" -gt 0 ]; then
    printf "%s\n" "${EXTRA_LOG_PATHS[@]}" | sort -u
  fi
}

print_selected_env_identity() {
  env 2>/dev/null | sort | grep -E '^(HOSTNAME|HOST_IP|NODE_NAME|POD_IP|POD_NAME|POD_NAMESPACE|KUBERNETES_.*)=' || true
}

print_selected_sysctls() {
  local key
  for key in \
    net.core.somaxconn \
    net.ipv4.ip_local_port_range \
    net.ipv4.tcp_fin_timeout \
    net.ipv4.tcp_max_orphans \
    net.ipv4.tcp_max_syn_backlog \
    net.ipv4.tcp_tw_reuse \
    net.netfilter.nf_conntrack_count \
    net.netfilter.nf_conntrack_max \
    net.netfilter.nf_conntrack_buckets \
    net.netfilter.nf_conntrack_tcp_timeout_time_wait \
    fs.file-max; do
    printf "%s=%s\n" "$key" "$(read_sysctl_value "$key")"
  done
}

print_conntrack_snapshot() {
  printf "nf_conntrack_count=%s\n" "$(read_proc_value /proc/sys/net/netfilter/nf_conntrack_count 0)"
  printf "nf_conntrack_max=%s\n" "$(read_proc_value /proc/sys/net/netfilter/nf_conntrack_max 0)"
  printf "nf_conntrack_buckets=%s\n" "$(read_proc_value /proc/sys/net/netfilter/nf_conntrack_buckets 0)"
  printf "nf_conntrack_tcp_timeout_time_wait=%s\n" "$(read_sysctl_value net.netfilter.nf_conntrack_tcp_timeout_time_wait)"
}

print_nic_stats() {
  local iface
  printf "iface\trx_dropped\ttx_dropped\trx_errors\ttx_errors\n"
  for iface in /sys/class/net/*; do
    iface="$(basename "$iface")"
    printf "%s\t%s\t%s\t%s\t%s\n" \
      "$iface" \
      "$(read_proc_value "/sys/class/net/$iface/statistics/rx_dropped" 0)" \
      "$(read_proc_value "/sys/class/net/$iface/statistics/tx_dropped" 0)" \
      "$(read_proc_value "/sys/class/net/$iface/statistics/rx_errors" 0)" \
      "$(read_proc_value "/sys/class/net/$iface/statistics/tx_errors" 0)"
  done
}

print_host_context() {
  printf "[loadavg]\n"
  cat /proc/loadavg 2>/dev/null || true
  printf "\n[uptime]\n"
  cat /proc/uptime 2>/dev/null || true
  printf "\n[stat_head]\n"
  head -1 /proc/stat 2>/dev/null || true
  printf "\n[cpuinfo_count]\n"
  awk '/^processor[[:space:]]*:/ {c++} END {print c + 0}' /proc/cpuinfo 2>/dev/null || true
}

print_pod_worker_status_dump() {
  # Per-PID State, VmRSS, thread count, context switches, wchan. Useful when
  # a worker is stuck in D state or blocking on a specific kernel function.
  local pid
  while read -r pid; do
    [ -z "$pid" ] && continue
    printf "===== pid=%s =====\n" "$pid"
    if [ -r "/proc/$pid/status" ]; then
      grep -E '^(Name|State|Threads|VmRSS|VmSize|RssAnon|RssFile|FDSize|voluntary_ctxt_switches|nonvoluntary_ctxt_switches):' \
        "/proc/$pid/status" 2>/dev/null || true
    fi
    if [ -r "/proc/$pid/wchan" ]; then
      printf "wchan="
      cat "/proc/$pid/wchan" 2>/dev/null
      printf "\n"
    fi
    if [ -r "/proc/$pid/stat" ]; then
      # tcomm, state, utime, stime, num_threads, starttime
      awk '{
        tcomm = $2; gsub(/[()]/, "", tcomm)
        print "stat tcomm=" tcomm " state=" $3 " utime=" $14 " stime=" $15 " threads=" $20
      }' "/proc/$pid/stat" 2>/dev/null || true
    fi
    printf "\n"
  done < <(ps -eo pid=,args= 2>/dev/null | awk '/nginx: (master|worker|cache|privileged)/ {print $1}')
}

extract_nginx_upstreams() {
  # Prints one line per referenced upstream target:
  #   upstream_name\tserver_host:port
  # plus every distinct proxy_pass target. Useful for remotely reasoning
  # about which upstreams a failing ingress is talking to.
  load_nginx_config
  if [ -z "${NGINX_CONFIG_TEXT:-}" ]; then
    return
  fi
  printf "%s\n" "$NGINX_CONFIG_TEXT" | awk '
    $0 !~ /^[[:space:]]*#/ && $1 == "upstream" {
      name = $2
      in_block = 1
      next
    }
    in_block == 1 && $1 == "}" { in_block = 0; name = ""; next }
    in_block == 1 && $1 == "server" {
      target = $2; gsub(/;/, "", target)
      print name "\tserver " target
      next
    }
    $0 !~ /^[[:space:]]*#/ && $1 == "proxy_pass" {
      target = $2; gsub(/;/, "", target)
      print "(proxy_pass)\t" target
    }
  ' | sort -u
}

print_resolv_conf() {
  if [ -r /etc/resolv.conf ]; then
    cat /etc/resolv.conf 2>/dev/null || true
  else
    printf "/etc/resolv.conf not readable\n"
  fi
}

print_node_ethtool_dump() {
  if ! command_exists ethtool; then
    printf "ethtool not installed\n"
    return
  fi
  local iface
  for iface in /sys/class/net/*; do
    iface="$(basename "$iface")"
    [ "$iface" = "lo" ] && continue
    printf "===== %s (ethtool -S) =====\n" "$iface"
    ethtool -S "$iface" 2>/dev/null \
      | grep -Ei 'drop|err|missed|buffer|fifo|discard|no_dma_resource|over' \
      || printf "(no drop/err counters reported)\n"
    printf "\n"
    printf "===== %s (ethtool -g) =====\n" "$iface"
    ethtool -g "$iface" 2>/dev/null || printf "(ring buffer info unavailable)\n"
    printf "\n"
  done
}

print_error_log_top_messages() {
  # Ranked view: last N lines across all error_logs, normalized (IPs/ports/
  # connection-ids collapsed), uniq -c | sort -nr | head. Gives reviewer a
  # short list of "the top errors right now" without scanning raw tails.
  local tail_lines="$1"
  shift
  local path tmp
  tmp="$(mktemp 2>/dev/null)" || { printf "mktemp failed\n"; return; }
  append_filtered_error_log_lines "$tail_lines" "$@" >>"$tmp"
  if [ ! -s "$tmp" ]; then
    printf "no readable error log\n"
    rm -f "$tmp" 2>/dev/null || true
    return
  fi
  awk '
    {
      msg = $0
      # Strip "YYYY/MM/DD HH:MM:SS [level] PID#TID: *CONN "
      sub(/^[0-9]{4}\/[0-9]{2}\/[0-9]{2} [0-9:]+ \[[a-z]+\] [0-9]+#[0-9]+: (\*[0-9]+ )?/, "", msg)
      # Normalize common variable parts
      gsub(/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+/, "IP:PORT", msg)
      gsub(/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/, "IP", msg)
      gsub(/"[^"]*"/, "\"S\"", msg)
      gsub(/[0-9]+/, "N", msg)
      if (length(msg) > 240) msg = substr(msg, 1, 240) "..."
      print msg
    }
  ' "$tmp" | sort | uniq -c | sort -nr | head -30
  rm -f "$tmp" 2>/dev/null || true
}

print_tcp_top_local_ports() {
  local state="$1"
  printf "count\tlocal_port\n"
  get_tcp_snapshot | awk -F'\t' -v state="$state" '
    function port_of(addr) {
      sub(/^.*:/, "", addr)
      gsub(/[^0-9]/, "", addr)
      return addr
    }
    $1 == state {
      port = port_of($2)
      if (port != "") {
        count[port]++
      }
    }
    END {
      for (port in count) {
        print count[port] "\t" port
      }
    }
  ' | sort -nr | head -20
}

print_tcp_top_remote_peers() {
  local state="$1"
  printf "count\tremote_peer\n"
  get_tcp_snapshot | awk -F'\t' -v state="$state" '
    function peer_of(addr) {
      gsub(/^\[/, "", addr)
      gsub(/\]$/, "", addr)
      sub(/:[0-9]+$/, "", addr)
      return addr
    }
    $1 == state {
      peer = peer_of($3)
      if (peer != "") {
        count[peer]++
      }
    }
    END {
      for (peer in count) {
        print count[peer] "\t" peer
      }
    }
  ' | sort -nr | head -20
}

top_tcp_remote_peer_line() {
  local state="$1"
  print_tcp_top_remote_peers "$state" | awk 'NR == 2 {print $0}'
}

format_top_tcp_peer() {
  local state="$1"
  local line count peer
  line="$(top_tcp_remote_peer_line "$state")"
  if [ -z "$line" ]; then
    printf "none"
    return
  fi
  count="$(printf "%s\n" "$line" | awk -F'\t' '{print $1}')"
  peer="$(printf "%s\n" "$line" | awk -F'\t' '{print $2}')"
  printf "%s=%s (%s)" "$state" "${peer:-unknown}" "${count:-0}"
}

print_path_inventory() {
  local path file size
  for path in "$@"; do
    if [ -f "$path" ]; then
      size="$(wc -c <"$path" 2>/dev/null | awk '{print $1}')"
      [ -n "$size" ] && printf "%s\t%s\n" "$size" "$path"
    elif [ -d "$path" ]; then
      while IFS= read -r file; do
        size="$(wc -c <"$file" 2>/dev/null | awk '{print $1}')"
        [ -n "$size" ] && printf "%s\t%s\n" "$size" "$file"
      done < <(find "$path" -type f 2>/dev/null)
    fi
  done | sort -nr | head -50
}

top_path_inventory_line() {
  print_path_inventory "$@" | awk 'NR == 1 {print $0}'
}

format_top_path_hint() {
  local line size path
  line="$(top_path_inventory_line "$@")"
  if [ -z "$line" ]; then
    printf "largest=n/a"
    return
  fi
  size="$(printf "%s\n" "$line" | awk -F'\t' '{print $1}')"
  path="$(printf "%s\n" "$line" | awk -F'\t' '{print $2}')"
  printf "largest=%s (%s)" "${path:-n/a}" "$(human_bytes "${size:-0}")"
}

print_top_file_tails() {
  local lines="$1"
  shift
  print_path_inventory "$@" | head -5 | while IFS=$'\t' read -r size file; do
    if [ -f "$file" ]; then
      printf "===== %s (%s bytes, last %s lines) =====\n" "$file" "$size" "$lines"
      tail -n "$lines" "$file" 2>&1 || true
      printf "\n"
    fi
  done
}

print_error_log_tails() {
  local lines="$1"
  shift
  print_path_inventory "$@" | head -5 | while IFS=$'\t' read -r size file; do
    if [ -f "$file" ]; then
      printf "===== %s (%s bytes, last %s lines, filtered to error/crit/alert/emerg) =====\n" "$file" "$size" "$lines"
      tail -n "$lines" "$file" 2>&1 | filter_error_log_levels || true
      printf "\n"
    fi
  done
}

print_pod_cgroup_memory() {
  discover_pod_cgroup_files
  printf "memory_current_file=%s\n" "$CGROUP_MEMORY_CURRENT"
  printf "memory_max_file=%s\n" "$CGROUP_MEMORY_MAX"
  printf "memory_events_file=%s\n" "$CGROUP_MEMORY_EVENTS"
  printf "\n[current]\n"
  cat "$CGROUP_MEMORY_CURRENT" 2>/dev/null || true
  printf "\n[max]\n"
  cat "$CGROUP_MEMORY_MAX" 2>/dev/null || true
  printf "\n[events]\n"
  cat "$CGROUP_MEMORY_EVENTS" 2>/dev/null || true
}

print_pod_cgroup_cpu() {
  discover_pod_cgroup_files
  printf "cpu_stat_file=%s\n" "$CGROUP_CPU_STAT"
  printf "\n[cpu.stat]\n"
  cat "$CGROUP_CPU_STAT" 2>/dev/null || true
}

print_nginx_config_dump() {
  load_nginx_config
  if [ -n "${NGINX_CONFIG_TEXT:-}" ]; then
    printf "%s\n" "$NGINX_CONFIG_TEXT"
  elif [ -n "${NGINX_CONFIG_ERROR:-}" ]; then
    printf "%s\n" "$NGINX_CONFIG_ERROR"
  else
    printf "nginx config unavailable\n"
  fi
}

print_stub_status_dump() {
  if [ -n "$STATUS_URL" ]; then
    read_stub_status "$STATUS_URL"
  fi
}

print_probe_result() {
  if [ -n "$TCP_PROBE" ]; then
    printf "target=%s\n" "$TCP_PROBE"
    printf "result=%s\n" "$(run_tcp_probe "$TCP_PROBE" "$PROBE_TIMEOUT")"
  fi
}

prepare_bundle_dir() {
  if [ -z "$BUNDLE_DIR" ] && [ "$INCLUDE_RAW" -eq 1 ]; then
    local safe_host
    safe_host="$(printf "%s" "$RUN_HOST" | tr -cs 'A-Za-z0-9._-' '-')"
    BUNDLE_DIR="$PWD/nginx-health-check-${MODE}-${safe_host}-${RUN_STAMP}"
  fi

  if [ -n "$BUNDLE_DIR" ]; then
    mkdir -p "$BUNDLE_DIR" || {
      printf "Failed to create bundle dir: %s\n" "$BUNDLE_DIR" >&2
      exit 2
    }
  fi
}

capture_shell_output() {
  local rel_path="$1"
  local command_text="$2"
  local target
  [ -n "$BUNDLE_DIR" ] || return 0
  target="$BUNDLE_DIR/$rel_path"
  ensure_parent_dir "$target"
  bash -lc "$command_text" >"$target" 2>&1 || true
}

capture_function_output() {
  local rel_path="$1"
  shift
  local target
  [ -n "$BUNDLE_DIR" ] || return 0
  target="$BUNDLE_DIR/$rel_path"
  ensure_parent_dir "$target"
  "$@" >"$target" 2>&1 || true
}

emit_report_text() {
  local plain="${1:-0}"
  local overall_text overall_display state_display note i
  overall_text="$(get_overall_text)"
  overall_display="$overall_text"
  if [ "$plain" -eq 0 ]; then
    overall_display="$(format_status "$overall_text")"
  fi

  printf "== nginx proxy health check ==\n"
  printf "mode: %s\n" "$MODE"
  printf "host: %s\n" "$RUN_HOST"
  printf "time: %s\n" "$RUN_TIME"
  printf "overall: %s\n" "$overall_display"
  printf "\n"

  if [ "${#NOTES[@]}" -gt 0 ]; then
    printf "Notes:\n"
    for note in "${NOTES[@]}"; do
      printf "  - %s\n" "$note"
    done
    printf "\n"
  fi

  printf "%-18s %-24s %-24s %-7s %s\n" "CHECK" "CURRENT" "LIMIT" "STATE" "DETAIL"
  printf "%-18s %-24s %-24s %-7s %s\n" "-----" "-------" "-----" "-----" "------"

  for (( i = 0; i < ${#CHECK_NAMES[@]}; i++ )); do
    state_display="${CHECK_STATUSES[$i]}"
    if [ "$plain" -eq 0 ]; then
      state_display="$(format_status "${CHECK_STATUSES[$i]}")"
    fi
    printf "%-18s %-24s %-24s %-7s %s\n" \
      "${CHECK_NAMES[$i]}" \
      "${CHECK_VALUES[$i]}" \
      "${CHECK_LIMITS[$i]}" \
      "$state_display" \
      "${CHECK_DETAILS[$i]}"
  done

  printf "\n"
  case "$OVERALL_CODE" in
    0)
      printf "Summary: no critical signals found in this snapshot.\n"
      ;;
    1)
      printf "Summary: warning signals detected. Check the WARN rows before traffic grows.\n"
      ;;
    2)
      printf "Summary: critical signals detected. Treat the CRIT rows as immediate investigation items.\n"
      ;;
  esac
}

emit_report_json() {
  local overall_text
  local i
  overall_text="$(get_overall_text)"

  printf "{\n"
  printf '  "script": "%s",\n' "$(json_escape "$SCRIPT_NAME")"
  printf '  "mode": "%s",\n' "$(json_escape "$MODE")"
  printf '  "host": "%s",\n' "$(json_escape "$RUN_HOST")"
  printf '  "time": "%s",\n' "$(json_escape "$RUN_TIME")"
  printf '  "overall": "%s",\n' "$(json_escape "$overall_text")"
  printf '  "exit_code": %s,\n' "$OVERALL_CODE"
  printf '  "delta_seconds": %s,\n' "$DELTA_SECONDS"
  printf '  "tail_lines": %s,\n' "$TAIL_LINES"
  printf '  "bundle_dir": "%s",\n' "$(json_escape "${BUNDLE_DIR:-}")"
  printf '  "notes": ['
  for (( i = 0; i < ${#NOTES[@]}; i++ )); do
    if [ "$i" -gt 0 ]; then
      printf ', '
    fi
    printf '"%s"' "$(json_escape "${NOTES[$i]}")"
  done
  printf '],\n'
  printf '  "checks": [\n'
  for (( i = 0; i < ${#CHECK_NAMES[@]}; i++ )); do
    printf '    {"name":"%s","current":"%s","limit":"%s","status":"%s","detail":"%s"}' \
      "$(json_escape "${CHECK_NAMES[$i]}")" \
      "$(json_escape "${CHECK_VALUES[$i]}")" \
      "$(json_escape "${CHECK_LIMITS[$i]}")" \
      "$(json_escape "${CHECK_STATUSES[$i]}")" \
      "$(json_escape "${CHECK_DETAILS[$i]}")"
    if [ "$i" -lt $(( ${#CHECK_NAMES[@]} - 1 )) ]; then
      printf ','
    fi
    printf '\n'
  done
  printf '  ]\n'
  printf '}\n'
}

emit_meta_text() {
  printf "script=%s\n" "$SCRIPT_NAME"
  printf "mode=%s\n" "$MODE"
  printf "run_time=%s\n" "$RUN_TIME"
  printf "run_stamp=%s\n" "$RUN_STAMP"
  printf "host=%s\n" "$RUN_HOST"
  printf "overall=%s\n" "$(get_overall_text)"
  printf "exit_code=%s\n" "$OVERALL_CODE"
  printf "cwd=%s\n" "$PWD"
  printf "delta_seconds=%s\n" "$DELTA_SECONDS"
  printf "tail_lines=%s\n" "$TAIL_LINES"
  printf "status_url=%s\n" "${STATUS_URL:-}"
  printf "tcp_probe=%s\n" "${TCP_PROBE:-}"
  printf "nginx_conf=%s\n" "${NGINX_CONF:-}"
  printf "bundle_dir=%s\n" "${BUNDLE_DIR:-}"
  printf "archive_path=%s\n" "${ARCHIVE_PATH:-}"
  printf "user=%s\n" "$(id -un 2>/dev/null || echo unknown)"
  printf "uid=%s\n" "$(id -u 2>/dev/null || echo unknown)"
  printf "gid=%s\n" "$(id -g 2>/dev/null || echo unknown)"
  printf "kernel=%s\n" "$(uname -a 2>/dev/null || echo unknown)"
  printf "hostname_env=%s\n" "${HOSTNAME:-}"
  printf "pod_name=%s\n" "${POD_NAME:-}"
  printf "pod_namespace=%s\n" "${POD_NAMESPACE:-}"
  printf "node_name=%s\n" "${NODE_NAME:-}"
  printf "pod_ip=%s\n" "${POD_IP:-}"
  printf "host_ip=%s\n" "${HOST_IP:-}"
  if [ "${#EXTRA_LOG_PATHS[@]}" -gt 0 ]; then
    printf "extra_log_paths=%s\n" "$(join_by "," "${EXTRA_LOG_PATHS[@]}")"
  fi
  local nginx_bin
  nginx_bin="$(resolve_nginx_binary)"
  if [ -n "$nginx_bin" ]; then
    printf "nginx_runtime_bin=%s\n" "$nginx_bin"
    printf "nginx_version=%s\n" "$("$nginx_bin" -v 2>&1)"
  fi
}

emit_bundle_agents_md() {
  cat <<EOF
# AGENTS.md

This bundle is intended for remote reviewers and agents who do not have shell access to the original pod or node.

## Goal

Use this bundle to answer four questions:

1. Is NGINX itself unhealthy, overloaded, or misconfigured?
2. Is the pod close to a resource limit such as memory, CPU quota, FD limit, or log growth?
3. Is the node dropping or delaying traffic because of conntrack, socket pressure, backlog drops, softnet drops, NIC drops, or system pressure?
4. Which upstream, peer, port, or log file is the most likely next investigation target?

## Reading order

1. Read \`summary.txt\` for the human-readable verdict.
2. Read \`summary.json\` if you want a machine-readable summary.
3. Read \`meta.txt\` to understand mode, host, runtime settings, and identity hints.
4. If any check is \`WARN\` or \`CRIT\`, use the decision map below to find the supporting evidence.
5. Inspect \`top/\` before scanning large raw files; it usually identifies the most interesting peers, ports, or logs.
6. Inspect \`raw/\` to verify the original source data behind suspicious checks.

## Fast triage

- If \`overall\` is \`CRIT\`, start with every \`CRIT\` row in \`summary.txt\`; do not average the signals together.
- If \`overall\` is \`WARN\`, check whether the warning is already close to a hard limit or whether multiple warnings point to the same subsystem.
- If \`overall\` is \`OK\` but users saw failures, this snapshot may have missed a short spike. Ask the on-site executor to rerun with a larger \`--delta-seconds\`, such as 10 or 30.
- If this is one of many pods or nodes, compare \`meta.txt\` across bundles first to avoid mixing evidence from different places.

## Root files

- \`summary.txt\`: plain-text report with the final status table.
- \`summary.json\`: JSON summary for automation or another agent.
- \`meta.txt\`: execution context, host identity hints, kernel/user data, and script settings.
- \`AGENTS.md\`: this guide.

## Decision map

Use this table to map summary checks to evidence files and likely interpretations.

| Summary check | First evidence to read | How to interpret |
| --- | --- | --- |
| \`nginx_process\` | \`raw/nginx_processes.txt\`, \`raw/nginx_T.txt\` | Missing master or workers means NGINX is not serving normally. If config exists but no process exists, investigate startup/reload failure. |
| \`nginx_listen\` | \`raw/listen_bindings.txt\`, \`raw/ss_listen.txt\`, \`raw/nginx_T.txt\` | Comparison is now \`*:PORT\` (any bind) vs \`IP:PORT\` (exact). A missing specific binding flags a bind-address regression even when the port is alive somewhere else. |
| \`nginx_capacity\` | \`raw/nginx_T.txt\`, \`summary.json\` | Compare \`worker_processes * worker_connections\` with active connections and FD limits. |
| \`tcp_states\` | \`raw/ss_summary.txt\`, \`raw/tcp_snapshot.txt\`, \`top/*remote-peers.txt\` | High \`ESTAB\` means load or long-lived connections. High \`CLOSE-WAIT\` suggests one side is not closing sockets. High \`SYN-RECV\` points to backlog or handshake pressure. |
| \`ephemeral_ports\` | \`raw/ip_local_port_range.txt\`, \`top/time-wait-local-ports.txt\`, \`top/time-wait-remote-peers.txt\` | High used-port or \`TIME-WAIT\` ratio suggests high short-connection churn and possible local port exhaustion. |
| \`fd_usage\` | \`raw/nginx_processes.txt\`, \`raw/nginx_T.txt\` | FD usage close to limit can cause accept/connect/open failures even if CPU and memory are fine. Detail contains the hottest pid for focused investigation. |
| \`listen_queues\` | \`raw/ss_listen.txt\`, \`raw/netstat.txt\` | Recv-Q close to Send-Q on a LISTEN socket means the accept queue is filling; correlate with \`ListenOverflows\` under \`listen_backlog\`. |
| \`error_log_signals\` | \`raw/error_log_tails.txt\`, \`raw/nginx_T.txt\` | Aggregated hit counts of known fatal strings (worker_connections exhausted, Too many open files, upstream timed out, no live upstreams, TLS handshake, conntrack table full). Use the counts to pick which raw tail to read. |
| \`memory\` | \`raw/cgroup_memory.txt\`, \`raw/log_tails.txt\`, \`top/log_files.txt\` | Look for cgroup OOM events, memory close to limit, and large logs contributing to pressure. |
| \`cpu_throttle\` | \`raw/cgroup_cpu.txt\` | Increasing throttle counters mean the pod may be CPU-limited, which can surface as latency or 504. |
| \`log_volume\` | \`top/log_files.txt\`, \`raw/log_tails.txt\`, \`raw/error_log_tails.txt\` | Large or fast-growing logs can cause disk pressure, memory pressure, or hidden deleted-open-file usage. |
| \`deleted_open_logs\` | \`raw/deleted_open_logs.txt\` | Deleted but open files still consume disk until NGINX closes/reopens them. Reload or restart may be needed after log rotation. |
| \`stub_status\` | \`raw/stub_status.txt\` | Summary reports live active + delta-window accepts/sec, requests/sec, handled/sec, and \`dropped_accepts\` (non-zero means the accept queue overflowed during the window). High active/writing with low waiting suggests active upstream work. High waiting can indicate idle keepalive-heavy traffic. |
| \`tcp_probe\` | \`raw/tcp_probe.txt\` | Failed TCP probe means the selected path or upstream was unavailable from this runtime context. |
| \`conntrack\` | \`raw/conntrack.txt\`, \`raw/system_log_tails.txt\`, \`raw/dmesg_filtered.txt\` | Count close to max or table-full messages can cause packet drops and intermittent 504. |
| \`sockstat\` | \`raw/sockstat.txt\`, \`raw/sysctl_network.txt\` | High \`tw\`, \`orphan\`, or allocation pressure points to node-wide TCP/socket pressure. |
| \`listen_backlog\` | \`raw/netstat.txt\`, \`raw/snmp.txt\` | Increasing \`ListenDrops\`, \`ListenOverflows\`, or \`TCPBacklogDrop\` means the node is dropping queued connections. |
| \`packet_drop\` | \`raw/softnet_stat.txt\`, \`raw/nic_stats.txt\`, \`raw/system_log_tails.txt\`, \`raw/dmesg_filtered.txt\` | Softnet or NIC drops mean packets may be lost before reaching NGINX or upstream. |
| \`node_memory\` | \`raw/meminfo.txt\`, \`raw/pressure_memory.txt\`, \`raw/system_log_tails.txt\`, \`raw/dmesg_filtered.txt\` | Low available memory or OOM messages can explain broad latency, drops, or restarts. |
| \`disk_root\`, \`inode_root\` | \`raw/df.txt\`, \`raw/df_inode.txt\`, \`top/container_log_files.txt\` | Disk or inode pressure can break logging, container runtime behavior, or node stability. |
| \`container_logs\` | \`top/container_log_files.txt\`, \`raw/node_extra_log_tails.txt\` | Large container logs can explain node disk pressure. Use the inventory first; if you need a specific pod or service log tail, rerun with an explicit \`--log-path\`. |
| \`psi_cpu\`, \`psi_memory\`, \`psi_io\` | \`raw/pressure_cpu.txt\`, \`raw/pressure_memory.txt\`, \`raw/pressure_io.txt\` | PSI shows time lost waiting for CPU, memory, or IO and is useful when ordinary utilization looks acceptable. |

## Common diagnosis paths

### Intermittent 504 or upstream timeout

1. Check \`summary.txt\` for \`conntrack\`, \`packet_drop\`, \`listen_backlog\`, \`tcp_states\`, and \`cpu_throttle\`.
2. On node bundles, read \`raw/dmesg_filtered.txt\`, \`raw/system_log_tails.txt\`, \`raw/conntrack.txt\`, \`raw/netstat.txt\`, and \`raw/softnet_stat.txt\`.
3. On pod bundles, read \`raw/error_log_tails.txt\`, \`top/estab-remote-peers.txt\`, and \`top/close-wait-remote-peers.txt\`.
4. If only one upstream appears hot in \`top/*remote-peers.txt\`, treat that upstream path as the leading suspect.

### High short-connection pressure or port exhaustion

1. Check \`ephemeral_ports\` and \`tcp_states\`.
2. Read \`raw/ip_local_port_range.txt\`, \`top/time-wait-local-ports.txt\`, and \`top/time-wait-remote-peers.txt\`.
3. Compare \`TIME-WAIT\` volume with the local port range. A high ratio means connection churn may be consuming available ports.
4. If this appears only on nodes, inspect \`raw/sockstat.txt\` to see whether the pressure is node-wide.

### conntrack table pressure

1. Read \`summary.txt\` for \`conntrack\`.
2. Verify exact values in \`raw/conntrack.txt\`.
3. Look for historical evidence in \`raw/system_log_tails.txt\` and \`raw/dmesg_filtered.txt\`; the count may have recovered by the time the script ran.
4. If table-full messages exist, treat intermittent packet loss as plausible even when the current count is below the max.

### Pod OOM or log-growth issue

1. Check \`memory\`, \`log_volume\`, and \`deleted_open_logs\`.
2. Read \`raw/cgroup_memory.txt\` for \`oom\`, \`oom_kill\`, or fail counters.
3. Read \`top/log_files.txt\` to find the largest files or directories.
4. Read \`raw/deleted_open_logs.txt\`; deleted-open files still consume disk space.
5. Read \`raw/error_log_tails.txt\` and \`raw/log_tails.txt\` for repeated errors or log storms.

### CPU throttling or resource-limit latency

1. Check \`cpu_throttle\`, \`psi_cpu\`, and \`node_memory\`.
2. For pod bundles, read \`raw/cgroup_cpu.txt\`.
3. For node bundles, read \`raw/pressure_cpu.txt\`, \`raw/pressure_memory.txt\`, and \`raw/pressure_io.txt\`.
4. If throttle counters increased during the sampling window, latency may come from quota pressure rather than network faults.

### Node network-stack drops

1. Check \`listen_backlog\` and \`packet_drop\`.
2. Read \`raw/netstat.txt\` for \`ListenDrops\`, \`ListenOverflows\`, and \`TCPBacklogDrop\`.
3. Read \`raw/softnet_stat.txt\` and \`raw/nic_stats.txt\`.
4. Read \`raw/system_log_tails.txt\` and \`raw/dmesg_filtered.txt\` for NIC, TCP, or kernel drop messages.

## raw/

This directory stores original evidence captured at run time. Prefer these files when you need to verify the summary or explain why a check is \`WARN\` or \`CRIT\`.

Common files you may see:

- \`raw/ss_summary.txt\`, \`raw/ss_tcp.txt\`, \`raw/ss_listen.txt\`, \`raw/tcp_snapshot.txt\`
- \`raw/sockstat.txt\`
- \`raw/env_identity.txt\`, \`raw/uname.txt\`, \`raw/id.txt\`
- \`raw/host_context.txt\` (loadavg, uptime, first /proc/stat line, CPU count)

Pod-mode files you may see:

- \`raw/nginx_T.txt\` (stdout of \`nginx -T\`; stderr is surfaced in \`summary.txt\` as config_error)
- \`raw/nginx_processes.txt\` (master / worker / cache manager|loader / privileged agent)
- \`raw/nginx_worker_status.txt\` (per-PID State, RSS, threads, ctx switches, wchan)
- \`raw/nginx_upstreams.txt\` (upstream blocks + proxy_pass targets)
- \`raw/listen_bindings.txt\` (canonical \`*:PORT\` / \`IP:PORT\` / \`[IPv6]:PORT\` from config)
- \`raw/resolv.conf.txt\`
- \`raw/cgroup_memory.txt\`, \`raw/cgroup_cpu.txt\`
- \`raw/pressure_cpu.txt\`, \`raw/pressure_memory.txt\`, \`raw/pressure_io.txt\` (node PSI visible from inside the pod)
- \`raw/error_log_tails.txt\`, \`raw/log_tails.txt\`
- \`top/error_log_top_messages.txt\` (most frequent normalized error-log messages)
- \`raw/stub_status.txt\`

Node-mode files you may see:

- \`raw/conntrack.txt\`
- \`raw/sysctl_network.txt\`
- \`raw/netstat.txt\`, \`raw/snmp.txt\`
- \`raw/softnet_stat.txt\`, \`raw/nic_stats.txt\`
- \`raw/system_log_paths.txt\`, \`raw/system_log_tails.txt\` (targeted host logs such as \`/var/log/messages\`, \`/var/log/syslog\`, or \`/var/log/kern.log\`)
- \`raw/node_extra_log_paths.txt\`, \`raw/node_extra_log_tails.txt\` (explicit \`--log-path\` captures)
- \`raw/ethtool_stats.txt\` (\`ethtool -S\` drop/err/miss counters and \`ethtool -g\` ring sizes when the tool is present)
- \`raw/dmesg_filtered.txt\`, \`raw/dmesg_tail.txt\`
- \`raw/node_container_log_dirs.txt\`, \`top/container_log_files.txt\`

## top/

This directory stores ranked views that are easier to scan than raw dumps, for example:

- high-frequency remote peers
- local ports with many \`TIME-WAIT\` sockets
- largest visible log files

## How to reason about the bundle

- Treat \`summary.txt\` or \`summary.json\` as the entry point, not the final truth.
- Use \`meta.txt\` to confirm whether the bundle came from a pod or a node and whether custom paths were used.
- When a check is \`WARN\` or \`CRIT\`, go to the most relevant file in \`raw/\` or \`top/\` and verify the underlying evidence.
- For accumulated kernel counters, prefer deltas reported in \`summary.txt\`; raw files may show lifetime totals.
- For missing files, do not assume the signal was healthy. It may simply mean the command, kernel file, or configured path was unavailable in this runtime.
- If a file mentioned here is missing, assume the command was unavailable, the path did not exist, or the mode did not apply.

## Constraints

- This bundle is read-only evidence collected at one point in time.
- The original environment may already have changed after the bundle was created.
- The bundle may contain hostnames, IP addresses, paths, and excerpts from logs. Handle it as operationally sensitive data.
- Do not assume you can ask follow-up shell questions unless the on-site executor can run the script again.
EOF
}

write_common_raw_bundle() {
  capture_shell_output "raw/uname.txt" "uname -a"
  capture_shell_output "raw/id.txt" "id"
  capture_function_output "raw/env_identity.txt" print_selected_env_identity
  capture_shell_output "raw/os-release.txt" "cat /etc/os-release"
  capture_function_output "raw/host_context.txt" print_host_context
  if command_exists ip; then
    capture_shell_output "raw/ip_address.txt" "ip address"
    capture_shell_output "raw/ip_route.txt" "ip route"
  fi
  if command_exists ss; then
    capture_shell_output "raw/ss_summary.txt" "ss -s"
    capture_shell_output "raw/ss_tcp.txt" "ss -tan"
    capture_shell_output "raw/ss_listen.txt" "ss -lntp"
  else
    capture_shell_output "raw/netstat_tcp.txt" "netstat -tan"
    capture_shell_output "raw/netstat_listen.txt" "netstat -lntp"
  fi
  capture_function_output "raw/tcp_snapshot.txt" get_tcp_snapshot
  capture_shell_output "raw/sockstat.txt" "cat /proc/net/sockstat /proc/net/sockstat6"
  capture_function_output "top/time-wait-local-ports.txt" print_tcp_top_local_ports "TIME-WAIT"
  capture_function_output "top/time-wait-remote-peers.txt" print_tcp_top_remote_peers "TIME-WAIT"
  capture_function_output "top/close-wait-remote-peers.txt" print_tcp_top_remote_peers "CLOSE-WAIT"
  capture_function_output "top/estab-remote-peers.txt" print_tcp_top_remote_peers "ESTAB"
}

write_pod_raw_bundle() {
  local -a log_paths=()
  local -a error_log_paths=()
  local log_path quoted_conf nginx_bin

  nginx_bin="$(resolve_nginx_binary)"
  if [ -n "$nginx_bin" ]; then
    capture_shell_output "raw/nginx_version.txt" "$(shell_quote "$nginx_bin") -V"
  fi
  capture_function_output "raw/nginx_T.txt" print_nginx_config_dump
  capture_shell_output "raw/nginx_processes.txt" "ps -eo pid,ppid,etime,%cpu,%mem,args | grep -E 'nginx: (master|worker|cache|privileged)' | grep -v grep"
  capture_shell_output "raw/ip_local_port_range.txt" "cat /proc/sys/net/ipv4/ip_local_port_range"
  capture_function_output "raw/cgroup_memory.txt" print_pod_cgroup_memory
  capture_function_output "raw/cgroup_cpu.txt" print_pod_cgroup_cpu
  capture_function_output "raw/pod_log_paths.txt" collect_pod_log_paths
  capture_function_output "raw/error_log_paths.txt" extract_nginx_error_log_paths

  mapfile -t log_paths < <(collect_pod_log_paths)
  mapfile -t error_log_paths < <(extract_nginx_error_log_paths)
  if [ "${#log_paths[@]}" -gt 0 ]; then
    capture_function_output "top/log_files.txt" print_path_inventory "${log_paths[@]}"
    capture_function_output "raw/log_tails.txt" print_top_file_tails "$TAIL_LINES" "${log_paths[@]}"
  fi
  if [ "${#error_log_paths[@]}" -gt 0 ]; then
    capture_function_output "raw/error_log_tails.txt" print_error_log_tails "$TAIL_LINES" "${error_log_paths[@]}"
    capture_function_output "top/error_log_top_messages.txt" print_error_log_top_messages "$TAIL_LINES" "${error_log_paths[@]}"
  fi

  capture_function_output "raw/nginx_worker_status.txt" print_pod_worker_status_dump
  capture_function_output "raw/nginx_upstreams.txt" extract_nginx_upstreams
  capture_function_output "raw/resolv.conf.txt" print_resolv_conf
  capture_function_output "raw/listen_bindings.txt" extract_nginx_listen_bindings

  # Node-observable signals that are usually readable from inside a pod too.
  capture_shell_output "raw/pressure_cpu.txt" "cat /proc/pressure/cpu"
  capture_shell_output "raw/pressure_memory.txt" "cat /proc/pressure/memory"
  capture_shell_output "raw/pressure_io.txt" "cat /proc/pressure/io"

  if command_exists lsof; then
    capture_shell_output "raw/deleted_open_logs.txt" "lsof -nP +L1 | grep nginx"
  fi
  if [ -n "$STATUS_URL" ]; then
    capture_function_output "raw/stub_status.txt" print_stub_status_dump
  fi
  if [ -n "$TCP_PROBE" ]; then
    capture_function_output "raw/tcp_probe.txt" print_probe_result
  fi
  if [ -n "$nginx_bin" ]; then
    capture_shell_output "raw/nginx_runtime_bin.txt" "ls -l $(shell_quote "$nginx_bin")"
  fi
  if [ -n "$NGINX_CONF" ]; then
    quoted_conf="$(shell_quote "$NGINX_CONF")"
    capture_shell_output "raw/nginx_config_path.txt" "ls -l $quoted_conf"
  fi
}

write_node_raw_bundle() {
  local -a container_log_dirs=()
  local -a system_log_files=()
  local -a extra_log_paths=()

  capture_function_output "raw/sysctl_network.txt" print_selected_sysctls
  capture_function_output "raw/conntrack.txt" print_conntrack_snapshot
  capture_shell_output "raw/netstat.txt" "cat /proc/net/netstat"
  capture_shell_output "raw/snmp.txt" "cat /proc/net/snmp"
  capture_shell_output "raw/softnet_stat.txt" "cat /proc/net/softnet_stat"
  capture_function_output "raw/nic_stats.txt" print_nic_stats
  capture_function_output "raw/ethtool_stats.txt" print_node_ethtool_dump
  capture_shell_output "raw/file_nr.txt" "cat /proc/sys/fs/file-nr"
  capture_shell_output "raw/meminfo.txt" "cat /proc/meminfo"
  capture_shell_output "raw/pressure_cpu.txt" "cat /proc/pressure/cpu"
  capture_shell_output "raw/pressure_memory.txt" "cat /proc/pressure/memory"
  capture_shell_output "raw/pressure_io.txt" "cat /proc/pressure/io"
  capture_shell_output "raw/df.txt" "df -h"
  capture_shell_output "raw/df_inode.txt" "df -ih"
  capture_shell_output "raw/dmesg_tail.txt" "dmesg | tail -n $(shell_quote "$TAIL_LINES")"
  capture_shell_output "raw/dmesg_filtered.txt" "dmesg | grep -Ei 'conntrack|nf_conntrack|oom|killed process|drop|timeout|tcp|memory' | tail -n $(shell_quote "$TAIL_LINES")"

  mapfile -t container_log_dirs < <(collect_node_container_log_dirs)
  if [ "${#container_log_dirs[@]}" -gt 0 ]; then
    capture_function_output "raw/node_container_log_dirs.txt" collect_node_container_log_dirs
    capture_function_output "top/container_log_files.txt" print_path_inventory "${container_log_dirs[@]}"
  fi

  mapfile -t system_log_files < <(collect_node_system_log_files)
  if [ "${#system_log_files[@]}" -gt 0 ]; then
    capture_function_output "raw/system_log_paths.txt" collect_node_system_log_files
    capture_function_output "raw/system_log_tails.txt" print_top_file_tails "$TAIL_LINES" "${system_log_files[@]}"
  fi

  mapfile -t extra_log_paths < <(collect_node_extra_log_paths)
  if [ "${#extra_log_paths[@]}" -gt 0 ]; then
    capture_function_output "raw/node_extra_log_paths.txt" collect_node_extra_log_paths
    capture_function_output "top/node_extra_log_files.txt" print_path_inventory "${extra_log_paths[@]}"
    capture_function_output "raw/node_extra_log_tails.txt" print_top_file_tails "$TAIL_LINES" "${extra_log_paths[@]}"
  fi

  if [ -n "$TCP_PROBE" ]; then
    capture_function_output "raw/tcp_probe.txt" print_probe_result
  fi
}

write_bundle_index_files() {
  [ -n "$BUNDLE_DIR" ] || return 0

  emit_report_text 1 >"$BUNDLE_DIR/summary.txt"
  emit_report_json >"$BUNDLE_DIR/summary.json"
  emit_meta_text >"$BUNDLE_DIR/meta.txt"
  emit_bundle_agents_md >"$BUNDLE_DIR/AGENTS.md"
}

write_bundle_raw_files() {
  [ -n "$BUNDLE_DIR" ] || return 0
  if [ "$INCLUDE_RAW" -eq 1 ]; then
    mkdir -p "$BUNDLE_DIR/raw" "$BUNDLE_DIR/top"
    write_common_raw_bundle
    case "$MODE" in
      pod)
        write_pod_raw_bundle
        ;;
      node)
        write_node_raw_bundle
        ;;
    esac
  fi
}

create_bundle_archive() {
  [ -n "$BUNDLE_DIR" ] || return 0

  if ! command_exists tar; then
    return 1
  fi

  ARCHIVE_PATH="${BUNDLE_DIR%/}.tar.gz"
  tar -czf "$ARCHIVE_PATH" -C "$(dirname "$BUNDLE_DIR")" "$(basename "$BUNDLE_DIR")" >/dev/null 2>&1
}

write_bundle_outputs() {
  [ -n "$BUNDLE_DIR" ] || return 0

  write_bundle_index_files
  write_bundle_raw_files

  if create_bundle_archive; then
    add_note "Bundle archive: $ARCHIVE_PATH"
  else
    if command_exists tar; then
      add_note "Bundle archive creation failed."
    else
      add_note "tar not found: bundle archive was not created."
    fi
  fi

  write_bundle_index_files
}

check_pod_mode() {
  local pod_status="OK"
  local nginx_master_pid=""
  local -a nginx_worker_pids=()
  local -a nginx_cache_pids=()
  local -a nginx_privileged_pids=()
  local -a nginx_all_pids=()

  # Only match real nginx process titles. Avoids self-matching ("bash
  # nginx-health-check.sh"), editor buffers, and other false positives.
  while read -r pid cmdline; do
    if [ -z "$pid" ]; then
      continue
    fi
    nginx_all_pids+=("$pid")
    case "$cmdline" in
      *"nginx: master process"*)
        nginx_master_pid="$pid"
        ;;
      *"nginx: worker process"*)
        nginx_worker_pids+=("$pid")
        ;;
      *"nginx: cache manager process"*|*"nginx: cache loader process"*)
        nginx_cache_pids+=("$pid")
        ;;
      *"nginx: privileged agent process"*|*"nginx: privileged process"*)
        nginx_privileged_pids+=("$pid")
        ;;
    esac
  done < <(ps -eo pid=,args= 2>/dev/null | awk '/nginx: (master|worker|cache|privileged)/ {print $1 "\t" substr($0, index($0, $2))}')

  if [ "${#nginx_all_pids[@]}" -eq 0 ]; then
    add_result "nginx_process" "not found" "must exist" "CRIT" \
      "No nginx process is visible inside this container."
    return
  fi

  local worker_count="${#nginx_worker_pids[@]}"
  local cache_count="${#nginx_cache_pids[@]}"
  local privileged_count="${#nginx_privileged_pids[@]}"
  local process_value
  process_value="master=${nginx_master_pid:-none}, workers=${worker_count}, cache=${cache_count}, privileged=${privileged_count}"
  local process_status="OK"
  if [ -z "$nginx_master_pid" ] || [ "$worker_count" -eq 0 ]; then
    process_status="WARN"
  fi
  add_result "nginx_process" "$process_value" "master + worker processes" "$process_status" \
    "Counts cover master, worker, cache manager/loader, and privileged agent processes."

  # Populate NGINX_CONFIG_{TEXT,SOURCE,ERROR} in the parent shell so later
  # checks (nginx_capacity, nginx_listen, error_log_signals, ...) see real
  # values. Without this every caller went through $() subshells and the
  # globals never propagated back.
  load_nginx_config

  local configured_workers
  configured_workers="$(resolve_worker_processes)"
  local worker_connections
  worker_connections="$(extract_nginx_value "worker_connections")"
  local worker_nofile
  worker_nofile="$(extract_nginx_value "worker_rlimit_nofile")"
  local theoretical_capacity=0
  if [ -n "$configured_workers" ] && [ "$configured_workers" -gt 0 ] && [ -n "$worker_connections" ]; then
    theoretical_capacity=$(( configured_workers * worker_connections ))
  fi
  local capacity_detail="worker_processes=${configured_workers:-unknown}, worker_connections=${worker_connections:-unknown}"
  if [ -n "$worker_nofile" ]; then
    capacity_detail="$capacity_detail, worker_rlimit_nofile=$worker_nofile"
  fi
  if [ -n "${NGINX_CONFIG_SOURCE:-}" ]; then
    capacity_detail="$capacity_detail, config_source=${NGINX_CONFIG_SOURCE}"
  fi
  if [ -n "${NGINX_CONFIG_ERROR:-}" ]; then
    capacity_detail="$capacity_detail, config_error=${NGINX_CONFIG_ERROR}"
  fi
  add_result "nginx_capacity" \
    "$( [ "$theoretical_capacity" -gt 0 ] && printf "%s" "$theoretical_capacity" || printf "unknown" )" \
    "config-derived theoretical max" "INFO" "$capacity_detail"

  local -a listen_bindings=()
  while IFS= read -r binding; do
    [ -n "$binding" ] && listen_bindings+=("$binding")
  done < <(extract_nginx_listen_bindings)
  local listen_value="unknown"
  local listen_status="OK"
  local listen_detail="nginx/openresty -T unavailable, skipped config-based listen check."
  if [ "${#listen_bindings[@]}" -gt 0 ]; then
    local -a missing_bindings=()
    local b
    for b in "${listen_bindings[@]}"; do
      if ! listener_present "$b"; then
        missing_bindings+=("$b")
      fi
    done
    listen_value="$(join_by "," "${listen_bindings[@]}")"
    listen_detail="Configured bindings from ${NGINX_CONFIG_SOURCE:-nginx config}. *:PORT matches any bind-address on that port; IP:PORT requires exact match."
    if [ "${#missing_bindings[@]}" -gt 0 ]; then
      listen_status="CRIT"
      listen_detail="Configured bindings missing from listen sockets: $(join_by "," "${missing_bindings[@]}")"
    fi
  elif [ -n "${NGINX_CONFIG_ERROR:-}" ]; then
    listen_detail="$NGINX_CONFIG_ERROR"
  fi
  add_result "nginx_listen" "$listen_value" "configured listen bindings" "$listen_status" "$listen_detail"

  local tcp_total estab time_wait close_wait syn_recv
  tcp_total="$(count_total_tcp)"
  estab="$(count_tcp_state "ESTAB")"
  time_wait="$(count_tcp_state "TIME-WAIT")"
  close_wait="$(count_tcp_state "CLOSE-WAIT")"
  syn_recv="$(count_tcp_state "SYN-RECV")"

  local connection_status="OK"
  local connection_limit="state mix sanity"
  local connection_detail="$(format_state_ratio "$estab" "$tcp_total" "ESTAB"), $(format_state_ratio "$time_wait" "$tcp_total" "TIME-WAIT"), $(format_state_ratio "$close_wait" "$tcp_total" "CLOSE-WAIT"), $(format_state_ratio "$syn_recv" "$tcp_total" "SYN-RECV"), top_estab_peer=$(format_top_tcp_peer "ESTAB")"
  if [ "$theoretical_capacity" -gt 0 ]; then
    local capacity_status
    capacity_status="$(status_by_ratio "$estab" "$theoretical_capacity" 70 85)"
    connection_status="$(merge_status "$connection_status" "$capacity_status")"
    connection_limit="ESTAB/${theoretical_capacity}"
  fi
  if [ "$close_wait" -ge 1000 ]; then
    connection_status="$(merge_status "$connection_status" "CRIT")"
  elif [ "$close_wait" -ge 200 ]; then
    connection_status="$(merge_status "$connection_status" "WARN")"
  fi
  if [ "$syn_recv" -ge 1024 ]; then
    connection_status="$(merge_status "$connection_status" "CRIT")"
  elif [ "$syn_recv" -ge 256 ]; then
    connection_status="$(merge_status "$connection_status" "WARN")"
  fi
  add_result "tcp_states" "total=$tcp_total" "$connection_limit" "$connection_status" "$connection_detail"

  local port_low port_high port_span ephemeral_used
  read -r port_low port_high <<<"$(read_ip_local_port_range)"
  if [ -n "${port_low:-}" ] && [ -n "${port_high:-}" ]; then
    port_span=$(( port_high - port_low + 1 ))
    ephemeral_used="$(count_unique_ephemeral_ports "$port_low" "$port_high")"
    local ephemeral_status
    ephemeral_status="$(status_by_ratio "$ephemeral_used" "$port_span" 60 80)"
    if [ "$time_wait" -gt 0 ]; then
      local tw_status
      tw_status="$(status_by_ratio "$time_wait" "$port_span" 40 60)"
      ephemeral_status="$(merge_status "$ephemeral_status" "$tw_status")"
    fi
    add_result "ephemeral_ports" \
      "$(format_ephemeral_current "$ephemeral_used" "$port_span" "$time_wait")" \
      "$(format_ephemeral_limit "$port_low" "$port_high" "$port_span")" \
      "$ephemeral_status" \
      "Used ratio=$(percent_of "$ephemeral_used" "$port_span"). High TIME-WAIT or used-port ratio means short-connection churn may exhaust client ports."
  else
    add_result "ephemeral_ports" "unknown" "ip_local_port_range" "INFO" \
      "Cannot read /proc/sys/net/ipv4/ip_local_port_range inside this container."
  fi

  local max_fd_used max_fd_limit max_fd_pid
  read -r max_fd_used max_fd_limit max_fd_pid <<<"$(max_proc_fd_usage "${nginx_all_pids[@]}")"
  local fd_status="INFO"
  local fd_limit_display="process limits unavailable"
  local fd_value_display="$max_fd_used open"
  if [ -n "$worker_nofile" ] && [ "$worker_nofile" -gt 0 ]; then
    max_fd_limit="$worker_nofile"
  fi
  if [ -n "$max_fd_limit" ] && [ "$max_fd_limit" -gt 0 ]; then
    fd_status="$(status_by_ratio "$max_fd_used" "$max_fd_limit" 70 85)"
    fd_value_display="$(format_usage_pair "$max_fd_used" "$max_fd_limit" "used")"
    fd_limit_display="$(format_limit_usage "$max_fd_limit" "$max_fd_used" "limit")"
  fi
  local fd_detail="Highest FD ratio across visible nginx processes."
  if [ -n "$max_fd_pid" ]; then
    fd_detail="${fd_detail} Hottest pid=${max_fd_pid}."
  fi
  add_result "fd_usage" "$fd_value_display" "$fd_limit_display" "$fd_status" "$fd_detail"

  local memory_current memory_max
  read -r memory_current memory_max <<<"$(read_pod_memory_usage)"
  local nginx_rss nginx_rss_kind
  read -r nginx_rss nginx_rss_kind <<<"$(sum_proc_rss_bytes "${nginx_all_pids[@]}")"
  local memory_status="INFO"
  local memory_limit_display="unlimited"
  local memory_value_display="$(human_bytes "$memory_current")"
  if [ "$memory_max" -gt 0 ]; then
    memory_status="$(status_by_ratio "$memory_current" "$memory_max" 80 90)"
    memory_value_display="used=$(human_bytes "$memory_current") free=$(human_bytes "$(free_of "$memory_max" "$memory_current")")"
    memory_limit_display="limit=$(human_bytes "$memory_max") usage=$(percent_of "$memory_current" "$memory_max")"
  fi
  local memory_events
  memory_events="$(read_pod_memory_events)"
  local memory_detail="cgroup current=$(human_bytes "$memory_current"), nginx ${nginx_rss_kind}=$(human_bytes "$nginx_rss")"
  if printf "%s" "$memory_events" | grep -Eq 'oom_kill [1-9]'; then
    memory_status="CRIT"
    memory_detail="$memory_detail, memory.events reports oom_kill > 0"
  elif printf "%s" "$memory_events" | grep -Eq 'oom [1-9]'; then
    memory_status="$(merge_status "$memory_status" "WARN")"
    memory_detail="$memory_detail, memory.events reports oom > 0"
  elif printf "%s" "$memory_events" | grep -Eq 'failcnt=[1-9]'; then
    memory_status="$(merge_status "$memory_status" "WARN")"
    memory_detail="$memory_detail, memory failcnt > 0"
  fi
  add_result "memory" "$memory_value_display" "$memory_limit_display" "$memory_status" "$memory_detail"

  # Sample delta-style counters (cpu throttle, stub_status) once before the
  # sleep and once after so stub_status can report rates without a second
  # sleep.
  local throttle_nr_before throttle_usec_before throttle_nr_after throttle_usec_after
  read -r throttle_nr_before throttle_usec_before <<<"$(read_cpu_throttle_snapshot)"
  local stub_body_before=""
  if [ -n "$STATUS_URL" ]; then
    stub_body_before="$(read_stub_status "$STATUS_URL")"
  fi

  if [ "$DELTA_SECONDS" -gt 0 ]; then
    sleep "$DELTA_SECONDS"
  fi

  read -r throttle_nr_after throttle_usec_after <<<"$(read_cpu_throttle_snapshot)"
  local stub_body_after=""
  if [ -n "$STATUS_URL" ]; then
    stub_body_after="$(read_stub_status "$STATUS_URL")"
  fi

  local throttle_nr_delta=$(( throttle_nr_after - throttle_nr_before ))
  local throttle_usec_delta=$(( throttle_usec_after - throttle_usec_before ))
  local cpu_status="OK"
  if [ "$throttle_nr_delta" -ge 10 ] || [ "$throttle_usec_delta" -ge 500000 ]; then
    cpu_status="CRIT"
  elif [ "$throttle_nr_delta" -gt 0 ] || [ "$throttle_usec_delta" -gt 100000 ]; then
    cpu_status="WARN"
  fi
  add_result "cpu_throttle" \
    "nr_throttled +$throttle_nr_delta" \
    "throttled ${DELTA_SECONDS}s delta" \
    "$cpu_status" \
    "throttled_time_delta=$(human_seconds_us "$throttle_usec_delta")"

  # listen queue pressure (Recv-Q close to Send-Q on a LISTEN socket is an
  # accept-queue backup; it tightly correlates with ListenOverflows).
  local lq_ratio lq_rq lq_sq lq_addr lq_total
  read -r lq_ratio lq_rq lq_sq lq_addr lq_total <<<"$(analyze_listen_queues)"
  if [ "${lq_total:-0}" -gt 0 ]; then
    local lq_status="OK"
    if [ "${lq_ratio:-0}" -ge 80 ]; then
      lq_status="CRIT"
    elif [ "${lq_ratio:-0}" -ge 50 ]; then
      lq_status="WARN"
    fi
    add_result "listen_queues" \
      "max_recvq=${lq_rq:-0}/${lq_sq:-0} (${lq_ratio:-0}%)" \
      "${lq_total:-0} listen sockets" \
      "$lq_status" \
      "Hottest listener: ${lq_addr:-n/a}. Recv-Q near Send-Q means the accept queue is backing up; watch ListenOverflows."
  else
    add_result "listen_queues" "no listeners" "ss/netstat listen" "INFO" \
      "No LISTEN sockets visible; ss/netstat may be restricted in this container."
  fi

  local -a log_paths=()
  mapfile -t log_paths < <(collect_pod_log_paths)
  local total_log_bytes=0
  local biggest_log_bytes=0
  local biggest_log_path=""
  if [ "${#log_paths[@]}" -gt 0 ]; then
    total_log_bytes="$(sum_paths_bytes "${log_paths[@]}")"
    read -r biggest_log_bytes biggest_log_path <<<"$(largest_existing_path "${log_paths[@]}")"
  fi
  local log_status="OK"
  if [ "$total_log_bytes" -ge $(( 2 * 1024 * 1024 * 1024 )) ]; then
    log_status="CRIT"
  elif [ "$total_log_bytes" -ge $(( 512 * 1024 * 1024 )) ]; then
    log_status="WARN"
  fi
  if [ "$memory_max" -gt 0 ]; then
    local relative_log_status
    relative_log_status="$(status_by_ratio "$total_log_bytes" "$memory_max" 25 50)"
    log_status="$(merge_status "$log_status" "$relative_log_status")"
  fi
  add_result "log_volume" \
    "$(human_bytes "$total_log_bytes")" \
    "$( [ "$memory_max" -gt 0 ] && printf "memory limit %s" "$(human_bytes "$memory_max")" || printf "warn>512MiB crit>2GiB" )" \
    "$log_status" \
    "Largest visible log path: ${biggest_log_path:-n/a} ($(human_bytes "$biggest_log_bytes")). top1=$(format_top_path_hint "${log_paths[@]}"). Sources include nginx config, --log-path overrides, and common defaults."

  # Scan nginx error_log tails for high-signal patterns (connection limit,
  # FD exhaustion, conntrack full, upstream issues, TLS handshake errors).
  local -a error_log_paths=()
  mapfile -t error_log_paths < <(extract_nginx_error_log_paths)
  if [ "${#error_log_paths[@]}" -gt 0 ]; then
    local signal_raw signal_total signal_summary
    signal_raw="$(scan_error_log_signals "$TAIL_LINES" "${error_log_paths[@]}")"
    signal_total="${signal_raw%%$'\t'*}"
    signal_summary="${signal_raw#*$'\t'}"
    local signal_status="OK"
    if [ "${signal_total:-0}" -ge 50 ]; then
      signal_status="CRIT"
    elif [ "${signal_total:-0}" -gt 0 ]; then
      signal_status="WARN"
    fi
    local signal_detail="Scanned last ${TAIL_LINES} lines across ${#error_log_paths[@]} error_log files."
    if [ -n "$signal_summary" ]; then
      signal_detail="${signal_detail} Hits: ${signal_summary}."
    fi
    add_result "error_log_signals" "${signal_total:-0} hits" "last ${TAIL_LINES} lines" \
      "$signal_status" "$signal_detail"
  else
    add_result "error_log_signals" "no error_log" "nginx -T required" "INFO" \
      "No nginx error_log paths resolved from config; scan skipped."
  fi

  if command_exists lsof; then
    local deleted_count deleted_bytes
    # lsof prints the executable in $1 (usually "nginx"). Size column is
    # not always numeric (pipes, sockets, anon_inode). Skip non-numeric.
    read -r deleted_count deleted_bytes <<<"$(
      lsof -nP +L1 2>/dev/null | awk '
        NR > 1 && $NF == "(deleted)" && $1 == "nginx" {
          count++
          if ($7 ~ /^[0-9]+$/) {
            bytes += $7
          }
        }
        END {print count + 0, bytes + 0}
      '
    )"
    local deleted_status="OK"
    if [ "$deleted_bytes" -ge $(( 256 * 1024 * 1024 )) ]; then
      deleted_status="CRIT"
    elif [ "$deleted_count" -gt 0 ]; then
      deleted_status="WARN"
    fi
    add_result "deleted_open_logs" \
      "$deleted_count files" \
      "0 expected" \
      "$deleted_status" \
      "Deleted-but-open bytes=$(human_bytes "$deleted_bytes"). These files keep disk space until nginx closes them."
  else
    add_result "deleted_open_logs" "skipped" "requires lsof" "INFO" \
      "Install lsof to detect deleted-but-open log files."
  fi

  if [ -n "$STATUS_URL" ]; then
    if [ -z "$stub_body_after" ]; then
      add_result "stub_status" "unreachable" "$STATUS_URL" "WARN" \
        "Failed to fetch nginx stub_status endpoint."
    else
      local a_active a_reading a_writing a_waiting a_accepts a_handled a_requests
      local b_active b_reading b_writing b_waiting b_accepts b_handled b_requests
      read -r a_active a_reading a_writing a_waiting a_accepts a_handled a_requests \
        <<<"$(parse_stub_status_values "$stub_body_after")"
      read -r b_active b_reading b_writing b_waiting b_accepts b_handled b_requests \
        <<<"$(parse_stub_status_values "${stub_body_before:-$stub_body_after}")"

      local accepts_delta=$(( a_accepts - b_accepts ))
      local handled_delta=$(( a_handled - b_handled ))
      local requests_delta=$(( a_requests - b_requests ))
      local dropped_delta=$(( accepts_delta - handled_delta ))
      [ "$dropped_delta" -lt 0 ] && dropped_delta=0

      local rate_denom="$DELTA_SECONDS"
      local rate_detail="rate window=${DELTA_SECONDS}s"
      if [ "${rate_denom:-0}" -le 0 ]; then
        rate_denom=1
        rate_detail="no rate window (--delta-seconds=0)"
      fi
      local accepts_rate=$(( accepts_delta / rate_denom ))
      local handled_rate=$(( handled_delta / rate_denom ))
      local requests_rate=$(( requests_delta / rate_denom ))

      local stub_status="OK"
      if [ "$theoretical_capacity" -gt 0 ]; then
        stub_status="$(status_by_ratio "$a_active" "$theoretical_capacity" 70 85)"
      fi
      if [ "$dropped_delta" -gt 0 ]; then
        stub_status="$(merge_status "$stub_status" "WARN")"
      fi

      add_result "stub_status" \
        "active=${a_active} req/s=${requests_rate}" \
        "${STATUS_URL}" \
        "$stub_status" \
        "reading=${a_reading}, writing=${a_writing}, waiting=${a_waiting}, accepts/s=${accepts_rate}, handled/s=${handled_rate}, dropped_accepts=${dropped_delta} (${rate_detail})."
    fi
  fi

  if [ -n "$TCP_PROBE" ]; then
    local probe_result
    probe_result="$(run_tcp_probe "$TCP_PROBE" "$PROBE_TIMEOUT")"
    case "$probe_result" in
      ok)
        add_result "tcp_probe" "connect ok" "$TCP_PROBE" "OK" "Simple TCP connect succeeded."
        ;;
      failed)
        add_result "tcp_probe" "connect failed" "$TCP_PROBE" "CRIT" "Simple TCP connect failed."
        ;;
      missing-timeout)
        add_result "tcp_probe" "skipped" "requires timeout" "INFO" "Install coreutils timeout to enable --probe."
        ;;
      *)
        add_result "tcp_probe" "invalid target" "$TCP_PROBE" "WARN" "Use host:port format."
        ;;
    esac
  fi
}

check_node_mode() {
  local conntrack_count conntrack_max
  conntrack_count="$(read_proc_value /proc/sys/net/netfilter/nf_conntrack_count 0)"
  conntrack_max="$(read_proc_value /proc/sys/net/netfilter/nf_conntrack_max 0)"
  local conntrack_status="INFO"
  if [ "$conntrack_max" -gt 0 ]; then
    conntrack_status="$(status_by_ratio "$conntrack_count" "$conntrack_max" 70 85)"
  fi
  local conntrack_detail="nf_conntrack_count=${conntrack_count}"
  if command_exists dmesg; then
    local table_full_hits
    table_full_hits="$(dmesg 2>/dev/null | grep -ci 'nf_conntrack: table full' || true)"
    if [ "${table_full_hits:-0}" -gt 0 ]; then
      conntrack_status="$(merge_status "$conntrack_status" "WARN")"
      conntrack_detail="$conntrack_detail, dmesg has ${table_full_hits} 'table full' hits"
    fi
  fi
  local conntrack_value_display="$conntrack_count"
  local conntrack_limit_display="${conntrack_max:-unknown}"
  if [ "$conntrack_max" -gt 0 ]; then
    conntrack_value_display="$(format_usage_pair "$conntrack_count" "$conntrack_max" "used")"
    conntrack_limit_display="$(format_limit_usage "$conntrack_max" "$conntrack_count" "max")"
  fi
  add_result "conntrack" "$conntrack_value_display" "$conntrack_limit_display" "$conntrack_status" \
    "$conntrack_detail"

  local port_low port_high port_span ephemeral_used time_wait
  read -r port_low port_high <<<"$(read_ip_local_port_range)"
  time_wait="$(count_tcp_state "TIME-WAIT")"
  if [ -n "${port_low:-}" ] && [ -n "${port_high:-}" ]; then
    port_span=$(( port_high - port_low + 1 ))
    ephemeral_used="$(count_unique_ephemeral_ports "$port_low" "$port_high")"
    local ephemeral_status
    ephemeral_status="$(status_by_ratio "$ephemeral_used" "$port_span" 60 80)"
    local tw_status
    tw_status="$(status_by_ratio "$time_wait" "$port_span" 40 60)"
    ephemeral_status="$(merge_status "$ephemeral_status" "$tw_status")"
    add_result "ephemeral_ports" \
      "$(format_ephemeral_current "$ephemeral_used" "$port_span" "$time_wait")" \
      "$(format_ephemeral_limit "$port_low" "$port_high" "$port_span")" \
      "$ephemeral_status" \
      "Used ratio=$(percent_of "$ephemeral_used" "$port_span"). High used-port or TIME-WAIT ratio means the node may run short of client ports under short-connection bursts."
  else
    add_result "ephemeral_ports" "unknown" "ip_local_port_range" "INFO" \
      "Cannot read /proc/sys/net/ipv4/ip_local_port_range."
  fi

  local sockstat_line tcp_inuse tcp_orphan tcp_tw tcp_alloc tcp_mem
  sockstat_line="$(awk '/^TCP:/ {print $0; exit}' /proc/net/sockstat 2>/dev/null)"
  tcp_inuse="$(printf "%s\n" "$sockstat_line" | awk '{for (i = 1; i <= NF; i++) if ($i == "inuse") print $(i + 1)}')"
  tcp_orphan="$(printf "%s\n" "$sockstat_line" | awk '{for (i = 1; i <= NF; i++) if ($i == "orphan") print $(i + 1)}')"
  tcp_tw="$(printf "%s\n" "$sockstat_line" | awk '{for (i = 1; i <= NF; i++) if ($i == "tw") print $(i + 1)}')"
  tcp_alloc="$(printf "%s\n" "$sockstat_line" | awk '{for (i = 1; i <= NF; i++) if ($i == "alloc") print $(i + 1)}')"
  tcp_mem="$(printf "%s\n" "$sockstat_line" | awk '{for (i = 1; i <= NF; i++) if ($i == "mem") print $(i + 1)}')"
  local tcp_max_orphans
  tcp_max_orphans="$(read_sysctl_value net.ipv4.tcp_max_orphans)"
  local sock_status="OK"
  if [ -n "$tcp_max_orphans" ] && [ "$tcp_max_orphans" -gt 0 ]; then
    sock_status="$(merge_status "$sock_status" "$(status_by_ratio "${tcp_orphan:-0}" "$tcp_max_orphans" 50 80)")"
  elif [ "${tcp_orphan:-0}" -ge 30000 ]; then
    sock_status="CRIT"
  elif [ "${tcp_orphan:-0}" -ge 10000 ]; then
    sock_status="WARN"
  fi
  local tcp_total_node
  tcp_total_node="$(count_total_tcp)"
  add_result "sockstat" \
    "inuse=${tcp_inuse:-0}, tw=${tcp_tw:-0}, orphan=${tcp_orphan:-0}" \
    "orphan<${tcp_max_orphans:-unknown}" \
    "$sock_status" \
    "alloc=${tcp_alloc:-0}, mem=${tcp_mem:-0}, ratios: $(format_state_ratio "${tcp_inuse:-0}" "$tcp_total_node" "inuse"), $(format_state_ratio "${tcp_tw:-0}" "$tcp_total_node" "tw"), top_estab_peer=$(format_top_tcp_peer "ESTAB")"

  local files_allocated files_limit
  read -r files_allocated _ files_limit <<<"$(awk '{print $1, $2, $3}' /proc/sys/fs/file-nr 2>/dev/null)"
  files_allocated="${files_allocated:-0}"
  files_limit="${files_limit:-0}"
  local file_status="INFO"
  local file_limit_display="unavailable"
  local file_value_display="$files_allocated open"
  if [ -n "$files_limit" ] && [ "$files_limit" -gt 0 ]; then
    file_status="$(status_by_ratio "$files_allocated" "$files_limit" 70 85)"
    file_value_display="$(format_usage_pair "$files_allocated" "$files_limit" "used")"
    file_limit_display="$(format_limit_usage "$files_limit" "$files_allocated" "limit")"
  fi
  add_result "file_handles" "$file_value_display" "$file_limit_display" "$file_status" \
    "System-wide file handle usage from /proc/sys/fs/file-nr."

  local listen_overflows_before listen_drops_before backlog_drop_before syncookies_before tcp_timeouts_before
  listen_overflows_before="$(read_netstat_counter ListenOverflows)"
  listen_drops_before="$(read_netstat_counter ListenDrops)"
  backlog_drop_before="$(read_netstat_counter TCPBacklogDrop)"
  syncookies_before="$(read_netstat_counter SyncookiesSent)"
  tcp_timeouts_before="$(read_netstat_counter TCPTimeouts)"
  local softnet_before nic_rx_before nic_tx_before
  softnet_before="$(read_softnet_drops_total)"
  read -r nic_rx_before nic_tx_before <<<"$(read_nic_drop_totals)"

  if [ "$DELTA_SECONDS" -gt 0 ]; then
    sleep "$DELTA_SECONDS"
  fi

  local listen_overflows_after listen_drops_after backlog_drop_after syncookies_after tcp_timeouts_after
  listen_overflows_after="$(read_netstat_counter ListenOverflows)"
  listen_drops_after="$(read_netstat_counter ListenDrops)"
  backlog_drop_after="$(read_netstat_counter TCPBacklogDrop)"
  syncookies_after="$(read_netstat_counter SyncookiesSent)"
  tcp_timeouts_after="$(read_netstat_counter TCPTimeouts)"
  local softnet_after nic_rx_after nic_tx_after
  softnet_after="$(read_softnet_drops_total)"
  read -r nic_rx_after nic_tx_after <<<"$(read_nic_drop_totals)"

  local listen_overflows_delta=$(( ${listen_overflows_after:-0} - ${listen_overflows_before:-0} ))
  local listen_drops_delta=$(( ${listen_drops_after:-0} - ${listen_drops_before:-0} ))
  local backlog_drop_delta=$(( ${backlog_drop_after:-0} - ${backlog_drop_before:-0} ))
  local syncookies_delta=$(( ${syncookies_after:-0} - ${syncookies_before:-0} ))
  local tcp_timeouts_delta=$(( ${tcp_timeouts_after:-0} - ${tcp_timeouts_before:-0} ))
  local softnet_delta=$(( softnet_after - softnet_before ))
  local nic_rx_delta=$(( nic_rx_after - nic_rx_before ))
  local nic_tx_delta=$(( nic_tx_after - nic_tx_before ))

  local backlog_status="OK"
  if [ "$listen_overflows_delta" -gt 0 ] || [ "$listen_drops_delta" -gt 0 ] || [ "$backlog_drop_delta" -gt 0 ]; then
    backlog_status="CRIT"
  elif [ "$syncookies_delta" -gt 100 ] || [ "$tcp_timeouts_delta" -gt 100 ]; then
    backlog_status="WARN"
  fi
  local backlog_total_bad_delta=$(( listen_drops_delta + listen_overflows_delta + backlog_drop_delta ))
  add_result "listen_backlog" \
    "drop=${listen_drops_delta}, overflow=${listen_overflows_delta}, bad=${backlog_total_bad_delta}" \
    "${DELTA_SECONDS}s delta" \
    "$backlog_status" \
    "TCPBacklogDrop=${backlog_drop_delta}, SyncookiesSent=${syncookies_delta}, TCPTimeouts=${tcp_timeouts_delta}"

  local softnet_status="OK"
  if [ "$softnet_delta" -gt 100 ] || [ "$nic_rx_delta" -gt 100 ] || [ "$nic_tx_delta" -gt 100 ]; then
    softnet_status="CRIT"
  elif [ "$softnet_delta" -gt 0 ] || [ "$nic_rx_delta" -gt 0 ] || [ "$nic_tx_delta" -gt 0 ]; then
    softnet_status="WARN"
  fi
  local packet_total_delta=$(( softnet_delta + nic_rx_delta + nic_tx_delta ))
  add_result "packet_drop" \
    "softnet=${softnet_delta}, rx=${nic_rx_delta}, tx=${nic_tx_delta}, total=${packet_total_delta}" \
    "${DELTA_SECONDS}s delta" \
    "$softnet_status" \
    "Any sustained increase means the node network stack or NIC is dropping packets."

  local mem_total_kb mem_available_kb mem_used_kb
  mem_total_kb="$(read_meminfo_value_kb MemTotal)"
  mem_available_kb="$(read_meminfo_value_kb MemAvailable)"
  mem_total_kb="${mem_total_kb:-0}"
  mem_available_kb="${mem_available_kb:-0}"
  mem_used_kb=$(( mem_total_kb - mem_available_kb ))
  local mem_status="INFO"
  local mem_limit_display="unavailable"
  local mem_value_display="unavailable"
  local mem_detail="MemAvailable unavailable."
  if [ "$mem_total_kb" -gt 0 ]; then
    mem_status="$(status_by_ratio "$mem_used_kb" "$mem_total_kb" 85 95)"
    mem_limit_display="total=$(human_bytes "$(( mem_total_kb * 1024 ))") usage=$(percent_of "$mem_used_kb" "$mem_total_kb")"
    mem_value_display="used=$(human_bytes "$(( mem_used_kb * 1024 ))") free=$(human_bytes "$(( mem_available_kb * 1024 ))")"
    mem_detail="MemAvailable=$(human_bytes "$(( mem_available_kb * 1024 ))")."
  fi
  add_result "node_memory" "$mem_value_display" "$mem_limit_display" "$mem_status" "$mem_detail"

  local root_usage inode_usage
  root_usage="$(read_df_usage_pct /)"
  inode_usage="$(read_df_inode_pct /)"
  local root_total_bytes root_used_bytes root_avail_bytes
  read -r root_total_bytes root_used_bytes root_avail_bytes <<<"$(read_df_bytes_triplet /)"
  local disk_root_value="${root_usage:-unknown}%"
  local disk_root_limit="warn>=80 crit>=90"
  if [ -n "${root_total_bytes:-}" ] && [ "$root_total_bytes" -gt 0 ]; then
    disk_root_value="used=${root_usage:-unknown}% free=$(human_bytes "${root_avail_bytes:-0}")"
    disk_root_limit="total=$(human_bytes "$root_total_bytes") used=$(human_bytes "${root_used_bytes:-0}")"
  fi
  add_result "disk_root" "$disk_root_value" "$disk_root_limit" \
    "$(status_by_threshold "${root_usage:-0}" 80 90)" \
    "Filesystem usage for /."
  local inode_total inode_used inode_free
  read -r inode_total inode_used inode_free <<<"$(read_df_inode_triplet /)"
  local inode_root_value="${inode_usage:-unknown}%"
  local inode_root_limit="warn>=80 crit>=90"
  if [ -n "${inode_total:-}" ] && [ "$inode_total" -gt 0 ]; then
    inode_root_value="used=${inode_usage:-unknown}% free=${inode_free:-0}"
    inode_root_limit="total=${inode_total:-0} used=${inode_used:-0}"
  fi
  add_result "inode_root" "$inode_root_value" "$inode_root_limit" \
    "$(status_by_threshold "${inode_usage:-0}" 80 90)" \
    "Inode usage for /."

  local -a log_dirs=()
  mapfile -t log_dirs < <(collect_node_container_log_dirs)
  if [ "${#log_dirs[@]}" -gt 0 ]; then
    local total_node_logs biggest_node_log_bytes biggest_node_log_path
    total_node_logs="$(sum_paths_bytes "${log_dirs[@]}")"
    read -r biggest_node_log_bytes biggest_node_log_path <<<"$(largest_existing_path "${log_dirs[@]}")"
    local log_dir_status="OK"
    if [ "$total_node_logs" -ge $(( 30 * 1024 * 1024 * 1024 )) ]; then
      log_dir_status="CRIT"
    elif [ "$total_node_logs" -ge $(( 10 * 1024 * 1024 * 1024 )) ]; then
      log_dir_status="WARN"
    fi
    add_result "container_logs" "$(human_bytes "$total_node_logs")" "warn>10GiB crit>30GiB" "$log_dir_status" \
      "Largest visible log path: ${biggest_node_log_path:-n/a} ($(human_bytes "$biggest_node_log_bytes")). top1=$(format_top_path_hint "${log_dirs[@]}")."
  else
    add_result "container_logs" "not found" "/var/log/containers or /var/log/pods" "INFO" \
      "Common Kubernetes log directories are not present on this node."
  fi

  local cpu_some_avg10 mem_full_avg10 io_full_avg10
  cpu_some_avg10="$(read_psi_avg10 /proc/pressure/cpu some)"
  mem_full_avg10="$(read_psi_avg10 /proc/pressure/memory full)"
  io_full_avg10="$(read_psi_avg10 /proc/pressure/io full)"
  if [ -n "$cpu_some_avg10" ]; then
    add_result "psi_cpu" "${cpu_some_avg10} avg10" "warn>=20 crit>=50" \
      "$(awk -v v="$cpu_some_avg10" 'BEGIN { if (v + 0 >= 50) print "CRIT"; else if (v + 0 >= 20) print "WARN"; else print "OK" }')" \
      "CPU pressure avg10 from /proc/pressure/cpu."
  fi
  if [ -n "$mem_full_avg10" ]; then
    add_result "psi_memory" "${mem_full_avg10} avg10" "warn>0 crit>=1" \
      "$(awk -v v="$mem_full_avg10" 'BEGIN { if (v + 0 >= 1) print "CRIT"; else if (v + 0 > 0) print "WARN"; else print "OK" }')" \
      "Memory full pressure avg10 from /proc/pressure/memory."
  fi
  if [ -n "$io_full_avg10" ]; then
    add_result "psi_io" "${io_full_avg10} avg10" "warn>=1 crit>=5" \
      "$(awk -v v="$io_full_avg10" 'BEGIN { if (v + 0 >= 5) print "CRIT"; else if (v + 0 >= 1) print "WARN"; else print "OK" }')" \
      "IO full pressure avg10 from /proc/pressure/io."
  fi

  if [ -n "$TCP_PROBE" ]; then
    local probe_result
    probe_result="$(run_tcp_probe "$TCP_PROBE" "$PROBE_TIMEOUT")"
    case "$probe_result" in
      ok)
        add_result "tcp_probe" "connect ok" "$TCP_PROBE" "OK" "Simple TCP connect succeeded."
        ;;
      failed)
        add_result "tcp_probe" "connect failed" "$TCP_PROBE" "CRIT" "Simple TCP connect failed."
        ;;
      missing-timeout)
        add_result "tcp_probe" "skipped" "requires timeout" "INFO" "Install coreutils timeout to enable --probe."
        ;;
      *)
        add_result "tcp_probe" "invalid target" "$TCP_PROBE" "WARN" "Use host:port format."
        ;;
    esac
  fi
}

print_report() {
  emit_report_text 0
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mode)
        MODE="${2:-}"
        shift 2
        ;;
      --delta-seconds)
        DELTA_SECONDS="${2:-}"
        shift 2
        ;;
      --nginx-conf)
        NGINX_CONF="${2:-}"
        shift 2
        ;;
      --log-path)
        EXTRA_LOG_PATHS+=("${2:-}")
        shift 2
        ;;
      --bundle-dir)
        BUNDLE_DIR="${2:-}"
        shift 2
        ;;
      --include-raw)
        INCLUDE_RAW=1
        shift
        ;;
      --format)
        OUTPUT_FORMAT="${2:-}"
        shift 2
        ;;
      --tail-lines)
        TAIL_LINES="${2:-}"
        shift 2
        ;;
      --status-url)
        STATUS_URL="${2:-}"
        shift 2
        ;;
      --probe)
        TCP_PROBE="${2:-}"
        shift 2
        ;;
      --probe-timeout)
        PROBE_TIMEOUT="${2:-}"
        shift 2
        ;;
      --check-prereqs)
        CHECK_PREREQS_ONLY=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        printf "Unknown argument: %s\n\n" "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done

  case "$MODE" in
    pod|node) ;;
    *)
      printf '%s\n\n' "--mode pod|node is required." >&2
      usage >&2
      exit 2
      ;;
  esac

  if ! printf "%s" "$DELTA_SECONDS" | grep -Eq '^[0-9]+$'; then
    printf '%s\n' "--delta-seconds must be a non-negative integer." >&2
    exit 2
  fi

  if ! printf "%s" "$PROBE_TIMEOUT" | grep -Eq '^[0-9]+$'; then
    printf '%s\n' "--probe-timeout must be a non-negative integer." >&2
    exit 2
  fi

  if ! printf "%s" "$TAIL_LINES" | grep -Eq '^[0-9]+$'; then
    printf '%s\n' "--tail-lines must be a non-negative integer." >&2
    exit 2
  fi

  if [ -n "$NGINX_CONF" ] && [ "$MODE" != "pod" ]; then
    printf '%s\n' "--nginx-conf is only supported in pod mode." >&2
    exit 2
  fi

  case "$OUTPUT_FORMAT" in
    table|json|both) ;;
    *)
      printf '%s\n' "--format must be one of: table, json, both." >&2
      exit 2
      ;;
  esac
}

main() {
  parse_args "$@"

  if [ "$CHECK_PREREQS_ONLY" -eq 0 ] && [ "$OUTPUT_FORMAT" = "json" ]; then
    PREREQ_TO_STDOUT=0
  fi

  RUN_TIME="$(date '+%Y-%m-%d %H:%M:%S %z')"
  RUN_STAMP="$(date '+%Y%m%d-%H%M%S')"
  RUN_HOST="$(hostname 2>/dev/null || echo unknown)"

  if ! check_prereqs "$MODE"; then
    exit 2
  fi

  if [ "$CHECK_PREREQS_ONLY" -eq 1 ]; then
    exit 0
  fi

  prepare_bundle_dir

  if ! command_exists lsof; then
    add_note "lsof not found: deleted-open log check will be skipped."
  fi
  if [ -n "$STATUS_URL" ] && ! command_exists curl && ! command_exists wget; then
    add_note "--status-url provided but curl/wget missing: status probe will be skipped."
  fi
  if [ -n "$NGINX_CONF" ]; then
    add_note "Using custom nginx config path: $NGINX_CONF"
  fi
  if [ "${#EXTRA_LOG_PATHS[@]}" -gt 0 ]; then
    add_note "Using extra log paths: $(join_by ", " "${EXTRA_LOG_PATHS[@]}")"
  fi
  if [ -n "$BUNDLE_DIR" ]; then
    add_note "Bundle directory: $BUNDLE_DIR"
    if [ "$INCLUDE_RAW" -eq 1 ]; then
      add_note "Raw evidence capture enabled."
    fi
  fi

  case "$MODE" in
    pod)
      check_pod_mode
      ;;
    node)
      check_node_mode
      ;;
  esac

  write_bundle_outputs

  case "$OUTPUT_FORMAT" in
    table)
      print_report
      ;;
    json)
      emit_report_json
      ;;
    both)
      print_report
      printf "\n"
      emit_report_json
      ;;
  esac

  exit "$OVERALL_CODE"
}

main "$@"
