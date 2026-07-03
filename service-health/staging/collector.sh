#!/usr/bin/env bash
# 独立服务端口健康探针（与 ops 完全解耦，自行 cron / systemd 运行）
# 默认自动采集本机所有 TCP 监听端口（ss -tlnH）；可选 PROBE_TARGETS 手动覆盖、PROBE_EXCLUDE_PORTS 排除端口
# 用法:
#   ./collector.sh              # 单次推送（适合 cron）
#   ./collector.sh --loop       # 持续探针（适合 systemd）
#   ./collector.sh --dry-run    # 仅打印 JSON，不推送

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SERVICE_HEALTH_COLLECTOR_ENV:-$SCRIPT_DIR/collector.env}"

DRY_RUN=0
LOOP=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1
[[ "${1:-}" == "--loop" ]] && LOOP=1
[[ "${2:-}" == "--dry-run" ]] && DRY_RUN=1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { log "ERROR: $*"; exit 1; }

[[ -f "$ENV_FILE" ]] || die "缺少 $ENV_FILE"
# shellcheck disable=SC1090
source "$ENV_FILE"

: "${OPS_PUSH_URL:?设置 OPS_PUSH_URL}"
: "${METRICS_PUSH_TOKEN:?设置 METRICS_PUSH_TOKEN，与 ops/.env 一致}"
: "${SERVER_ENV:?设置 SERVER_ENV，如 staging、gray 或 production}"

PROBE_TIMEOUT="${PROBE_TIMEOUT:-3}"
CURL_TIMEOUT="${CURL_TIMEOUT:-5}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-30}"

json_escape() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

now_ms() {
  local ns
  ns=$(date +%s%N 2>/dev/null || echo "")
  if [[ -n "$ns" && "$ns" =~ ^[0-9]+$ ]]; then
    echo $((ns / 1000000))
  else
    echo $(($(date +%s) * 1000))
  fi
}

probe_tcp() {
  local host=$1 port=$2
  local start end elapsed
  start=$(now_ms)
  if timeout "$PROBE_TIMEOUT" bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null; then
    exec 3>&- 2>/dev/null || true
    end=$(now_ms)
    elapsed=$((end - start))
    echo "up|null|${elapsed}|"
    return 0
  fi
  end=$(now_ms)
  elapsed=$((end - start))
  echo "down|null|${elapsed}|connection refused or timeout"
}

probe_http() {
  local scheme=$1 host=$2 port=$3
  local url="${scheme}://${host}:${port}/"
  local start end elapsed http_code body err
  start=$(now_ms)
  body=$(mktemp)
  cleanup() { rm -f "$body"; }
  trap cleanup RETURN

  local curl_opts=(-sS -o "$body" -w "%{http_code}" --connect-timeout "$PROBE_TIMEOUT" --max-time "$CURL_TIMEOUT")
  if [[ "$scheme" == "https" ]]; then
    curl_opts+=(-k)
  fi

  if ! http_code=$(curl "${curl_opts[@]}" "$url" 2>/dev/null); then
    end=$(now_ms)
    elapsed=$((end - start))
    err=$(head -c 200 "$body" 2>/dev/null || echo "curl failed")
    echo "down|null|${elapsed}|$(json_escape "$err")"
    return 0
  fi

  end=$(now_ms)
  elapsed=$((end - start))

  if [[ "$http_code" =~ ^[23][0-9]{2}$ ]]; then
    echo "up|${http_code}|${elapsed}|"
  elif [[ "$http_code" =~ ^[45][0-9]{2}$ ]]; then
    echo "degraded|${http_code}|${elapsed}|HTTP ${http_code}"
  else
    echo "down|${http_code}|${elapsed}|HTTP ${http_code}"
  fi
}

parse_target_field() {
  local json=$1 field=$2
  local match
  match=$(printf '%s' "$json" | grep -oE "\"${field}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\"" | head -1)
  [[ -z "$match" ]] && return 0
  printf '%s' "$match" | sed -E 's/^"[^"]+"[[:space:]]*:[[:space:]]*"([^"]*)"$/\1/'
}

parse_target_number() {
  local json=$1 field=$2
  local match
  match=$(printf '%s' "$json" | grep -oE "\"${field}\"[[:space:]]*:[[:space:]]*[0-9]+" | head -1)
  [[ -z "$match" ]] && return 0
  printf '%s' "$match" | sed -E 's/^"[^"]+"[[:space:]]*:[[:space:]]*//'
}

port_excluded() {
  local port=$1 exclude="${PROBE_EXCLUDE_PORTS:-}"
  [[ -z "$exclude" ]] && return 1
  [[ ",${exclude}," == *",${port},"* ]]
}

infer_probe_type() {
  case "$1" in
    80) echo http ;;
    443|8443) echo https ;;
    *) echo tcp ;;
  esac
}

list_listening_endpoints() {
  command -v ss >/dev/null 2>&1 || die "需要 ss 命令（iproute2）"
  ss -tlnH 2>/dev/null | awk '
    {
      local_addr = $4
      n = split(local_addr, p, ":")
      port = p[n]
      if (port !~ /^[0-9]+$/) next
      addr = p[1]
      for (i = 2; i < n; i++) addr = addr ":" p[i]
      gsub(/[\[\]]/, "", addr)
      if (addr == "" || addr == "*" || addr == "0.0.0.0" || addr == "::") addr = "127.0.0.1"
      print addr "\t" port
    }
  '
}

list_discovered_targets() {
  declare -A seen_port preferred_host
  local host port probe_type sorted_ports

  while IFS=$'\t' read -r host port; do
    [[ -z "$port" ]] && continue
    port_excluded "$port" && continue

    if [[ -n "${seen_port[$port]:-}" ]]; then
      [[ "$host" == "127.0.0.1" ]] && preferred_host[$port]="$host"
      continue
    fi

    seen_port[$port]=1
    preferred_host[$port]="$host"
  done < <(list_listening_endpoints)

  sorted_ports=$(
    for port in "${!seen_port[@]}"; do
      printf '%s\n' "$port"
    done | sort -n
  )

  while IFS= read -r port; do
    [[ -z "$port" ]] && continue
    host=${preferred_host[$port]}
    probe_type=$(infer_probe_type "$port")
    printf '{"service_id":"port-%s","name":"Port %s","probe_type":"%s","host":"%s","port":%s}\n' \
      "$port" "$port" "$probe_type" "$host" "$port"
  done <<< "$sorted_ports"
}

split_manual_targets() {
  local raw=${PROBE_TARGETS:?}
  raw=$(printf '%s' "$raw" | tr -d '\n\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  raw=${raw#\[}
  raw=${raw%\]}

  local rest="$raw" chunk
  while [[ -n "$rest" ]]; do
    rest="${rest#"${rest%%[![:space:]]*}"}"
    if [[ "$rest" == *'},'* ]]; then
      chunk="${rest%%\},*}"
      rest="${rest#*\},}"
    else
      chunk="$rest"
      rest=""
    fi
    chunk=$(printf '%s' "$chunk" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "$chunk" ]] && continue
    [[ "$chunk" != \{* ]] && chunk="{${chunk}"
    [[ "$chunk" != *\} ]] && chunk="${chunk}}"
    printf '%s\n' "$chunk"
  done
}

list_probe_target_items() {
  if [[ -n "${PROBE_TARGETS:-}" ]]; then
    split_manual_targets
  else
    list_discovered_targets
  fi
}

build_services_json() {
  local checked_at services_json="" item count=0
  checked_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  while IFS= read -r item; do
    [[ -z "$item" ]] && continue
    item=$(printf '%s' "$item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    local service_id name probe_type host port status http_status response_ms error_msg
    service_id=$(parse_target_field "$item" service_id)
    name=$(parse_target_field "$item" name)
    probe_type=$(parse_target_field "$item" probe_type)
    host=$(parse_target_field "$item" host)
    port=$(parse_target_number "$item" port)

    [[ -z "$service_id" || -z "$port" ]] && continue
    [[ -z "$name" ]] && name="$service_id"
    [[ -z "$host" ]] && host="127.0.0.1"
    [[ -z "$probe_type" ]] && probe_type="tcp"

    case "$probe_type" in
      tcp)
        IFS='|' read -r status http_status response_ms error_msg <<< "$(probe_tcp "$host" "$port")"
        ;;
      http|https)
        IFS='|' read -r status http_status response_ms error_msg <<< "$(probe_http "$probe_type" "$host" "$port")"
        ;;
      *)
        continue
        ;;
    esac

    count=$((count + 1))

    local http_field="null"
    [[ -n "$http_status" && "$http_status" != "null" ]] && http_field="$http_status"

    local err_field="null"
    [[ -n "$error_msg" ]] && err_field="\"$(json_escape "$error_msg")\""

    local entry
    entry=$(cat <<EOF
{"service_id":"$(json_escape "$service_id")","name":"$(json_escape "$name")","probe_type":"$(json_escape "$probe_type")","host":"$(json_escape "$host")","port":$port,"status":"$status","http_status":$http_field,"response_time_ms":$response_ms,"error_message":$err_field}
EOF
)
    if [[ -n "$services_json" ]]; then
      services_json="${services_json},${entry}"
    else
      services_json="$entry"
    fi
  done < <(list_probe_target_items)

  if (( count == 0 )); then
    if [[ -n "${PROBE_TARGETS:-}" ]]; then
      die "未配置有效探针目标（检查 PROBE_TARGETS）"
    fi
    die "未发现可探针的 TCP 监听端口（检查 ss -tlnH 或 PROBE_EXCLUDE_PORTS）"
  fi

  cat <<EOF
{"env":"$(json_escape "$SERVER_ENV")","checked_at":"$checked_at","services":[$services_json]}
EOF
}

push_once() {
  local payload http_code body target_count
  payload=$(build_services_json)
  target_count=$(printf '%s' "$payload" | grep -o '"service_id"' | wc -l | tr -d ' ')
  log "[$SERVER_ENV] 探针 $target_count 个目标"

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
  log "[$SERVER_ENV] 推送成功 HTTP $http_code"
}

main() {
  [[ "$(uname -s)" == "Linux" ]] || die "仅支持 Linux"

  if (( LOOP )); then
    log "持续探针模式，间隔 ${INTERVAL_SECONDS}s，推送 $OPS_PUSH_URL"
    while true; do
      push_once || log "WARN: 本次探针失败，${INTERVAL_SECONDS}s 后重试"
      sleep "$INTERVAL_SECONDS"
    done
  else
    push_once
  fi
}

main "$@"
