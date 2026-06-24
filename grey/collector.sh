#!/usr/bin/env bash
# 独立服务器指标采集脚本（与 ops 完全解耦，自行 cron / systemd 运行）
# 只读采集 CPU / 内存 / 磁盘，HTTP 推送到 ops 运维后台
# 用法:
#   ./collector.sh              # 单次推送（适合 cron）
#   ./collector.sh --loop       # 持续推送（适合 systemd）
#   ./collector.sh --dry-run    # 仅打印 JSON，不推送

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SERVER_METRICS_ENV:-$SCRIPT_DIR/collector.env}"

DRY_RUN=0
LOOP=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1
[[ "${1:-}" == "--loop" ]] && LOOP=1
[[ "${2:-}" == "--dry-run" ]] && DRY_RUN=1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { log "ERROR: $*"; exit 1; }

[[ -f "$ENV_FILE" ]] || die "缺少 $ENV_FILE（复制 collector.env.example 为 collector.env）"
# shellcheck disable=SC1090
source "$ENV_FILE"

: "${OPS_PUSH_URL:?设置 OPS_PUSH_URL，如 https://ops-api.dev.iannil.net/api/v1/server/metrics/report}"
: "${METRICS_PUSH_TOKEN:?设置 METRICS_PUSH_TOKEN，与 ops/.env 中 METRICS_PUSH_TOKEN 一致}"
: "${SERVER_ENV:?设置 SERVER_ENV，如 staging 或 gray}"

SERVER_NAME="${SERVER_NAME:-$SERVER_ENV-server}"
DISK_PATH="${DISK_PATH:-/}"
CURL_TIMEOUT="${CURL_TIMEOUT:-10}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-30}"

json_escape() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

read_proc_stat() {
  awk '/^cpu / {
    idle = $5 + $6
    total = 0
    for (i = 2; i <= NF; i++) total += $i
    print idle, total
    exit
  }' /proc/stat
}

read_cpu_percent() {
  local a b idle_a total_a idle_b total_b idle_d total_d
  read -r idle_a total_a <<< "$(read_proc_stat)"
  sleep 0.2
  read -r idle_b total_b <<< "$(read_proc_stat)"
  idle_d=$((idle_b - idle_a))
  total_d=$((total_b - total_a))
  if (( total_d <= 0 )); then
    echo "null"
    return
  fi
  awk -v idle="$idle_d" -v total="$total_d" 'BEGIN { printf "%.1f", (1 - idle / total) * 100 }'
}

read_memory_percent() {
  local total_kb available_kb free_kb buffers_kb cached_kb used_kb
  total_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
  available_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  if [[ -z "$available_kb" || "$available_kb" == "0" ]]; then
    free_kb=$(awk '/^MemFree:/ {print $2}' /proc/meminfo)
    buffers_kb=$(awk '/^Buffers:/ {print $2}' /proc/meminfo)
    cached_kb=$(awk '/^Cached:/ {print $2}' /proc/meminfo)
    available_kb=$((free_kb + buffers_kb + cached_kb))
  fi
  if [[ -z "$total_kb" || "$total_kb" -le 0 ]]; then
    echo "null"
    return
  fi
  used_kb=$((total_kb - available_kb))
  if (( used_kb < 0 )); then used_kb=0; fi
  awk -v used="$used_kb" -v total="$total_kb" 'BEGIN { printf "%.1f", used / total * 100 }'
}

read_disk_percent() {
  local capacity
  capacity=$(df -P "$DISK_PATH" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
  if [[ -n "$capacity" && "$capacity" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    awk -v v="$capacity" 'BEGIN { printf "%.1f", v + 0 }'
    return
  fi
  echo "null"
}

host_info() {
  local hostname ip
  hostname=$(hostname 2>/dev/null || echo "unknown")
  ip=$(getent hosts "$hostname" 2>/dev/null | awk '{print $1; exit}')
  if [[ -z "$ip" || "$ip" == "127.0.0.1" ]]; then
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  fi
  [[ -z "$ip" ]] && ip="unknown"
  printf '%s\t%s' "$hostname" "$ip"
}

collect_payload() {
  local hostname ip cpu memory disk collected_at
  IFS=$'\t' read -r hostname ip <<< "$(host_info)"
  cpu=$(read_cpu_percent)
  memory=$(read_memory_percent)
  disk=$(read_disk_percent)
  collected_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  cat <<EOF
{
  "env": "$(json_escape "$SERVER_ENV")",
  "name": "$(json_escape "$SERVER_NAME")",
  "hostname": "$(json_escape "$hostname")",
  "ip": "$(json_escape "$ip")",
  "metrics": {
    "cpu": $cpu,
    "memory": $memory,
    "disk": $disk,
    "collected_at": "$collected_at",
    "source": "linux"
  }
}
EOF
}

push_once() {
  local payload http_code body container_count
  payload=$(collect_payload)

  if (( DRY_RUN )); then
    echo "$payload"
    return 0
  fi

  body=$(mktemp)
  trap 'rm -f "$body"' RETURN
  http_code=$(curl -sS -o "$body" -w "%{http_code}" \
    -X POST "$OPS_PUSH_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $METRICS_PUSH_TOKEN" \
    --connect-timeout "$CURL_TIMEOUT" \
    --max-time "$((CURL_TIMEOUT * 2))" \
    -d "$payload") || die "curl 失败"

  [[ "$http_code" =~ ^2 ]] || die "推送失败 HTTP $http_code: $(head -c 300 "$body")"
  log "[$SERVER_ENV] 推送成功 HTTP $http_code ($(echo "$payload" | tr -d '\n' | head -c 120)…)"
}

main() {
  [[ "$(uname -s)" == "Linux" ]] || die "仅支持 Linux"

  if (( LOOP )); then
    log "持续采集模式，间隔 ${INTERVAL_SECONDS}s，目标 $OPS_PUSH_URL"
    while true; do
      push_once || log "WARN: 本次推送失败，${INTERVAL_SECONDS}s 后重试"
      sleep "$INTERVAL_SECONDS"
    done
  else
    push_once
  fi
}

main "$@"
