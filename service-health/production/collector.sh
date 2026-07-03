#!/usr/bin/env bash
# 独立服务端口健康探针（与 ops 完全解耦，自行 cron / systemd 运行）
# TCP（如 MySQL 3306）、HTTP/HTTPS（如 80/443），HTTP 推送到 ops 后台
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

DEFAULT_PROBE_TARGETS='[
  {"service_id":"mysql","name":"MySQL","probe_type":"tcp","host":"127.0.0.1","port":3306},
  {"service_id":"http-80","name":"HTTP 80","probe_type":"http","host":"127.0.0.1","port":80},
  {"service_id":"https-443","name":"HTTPS 443","probe_type":"https","host":"127.0.0.1","port":443}
]'

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
  trap 'rm -f "$body"' RETURN

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
  printf '%s' "$json" | python3 -c "
import json, sys
obj = json.load(sys.stdin)
v = obj.get(sys.argv[1])
print('' if v is None else v)
" "$field" 2>/dev/null || true
}

parse_target_number() {
  local json=$1 field=$2
  printf '%s' "$json" | python3 -c "
import json, sys
obj = json.load(sys.stdin)
v = obj.get(sys.argv[1])
print('' if v is None else int(v))
" "$field" 2>/dev/null || true
}

split_targets() {
  local raw=${PROBE_TARGETS:-$DEFAULT_PROBE_TARGETS}
  export PROBE_TARGETS_JSON="$raw"
  python3 <<'PY'
import json, os, sys

raw = os.environ.get("PROBE_TARGETS_JSON", "").strip()
if not raw:
    sys.exit(0)
try:
    data = json.loads(raw)
except json.JSONDecodeError as e:
    print(f"invalid PROBE_TARGETS json: {e}", file=sys.stderr)
    sys.exit(1)
if isinstance(data, dict):
    data = [data]
if not isinstance(data, list):
    sys.exit(1)
for item in data:
    if isinstance(item, dict):
        print(json.dumps(item, ensure_ascii=False, separators=(",", ":")))
PY
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
  done < <(split_targets)

  if (( count == 0 )); then
    die "未配置有效探针目标（检查 PROBE_TARGETS）"
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
    echo "$payload" | python3 -m json.tool 2>/dev/null || echo "$payload"
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
