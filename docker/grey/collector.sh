#!/usr/bin/env bash
# 独立 Docker 状态采集脚本（与 ops 完全解耦，自行 cron / systemd 运行）
# 本脚本在宿主机执行 docker ps，HTTP 推送到 ops 后台展示，不修改 ops 容器/配置
# 用法:
#   ./collector.sh              # 单次推送（适合 cron）
#   ./collector.sh --loop       # 持续推送（适合 systemd）
#   ./collector.sh --dry-run    # 仅打印 JSON，不推送

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${DOCKER_COLLECTOR_ENV:-$SCRIPT_DIR/collector.env}"

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

DOCKER_PUSH_TOKEN="${DOCKER_PUSH_TOKEN:-${METRICS_PUSH_TOKEN}}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
CURL_TIMEOUT="${CURL_TIMEOUT:-10}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-60}"

json_escape() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

parse_health() {
  case "$1" in
    *"(healthy)"*) echo "healthy" ;;
    *"(unhealthy)"*) echo "unhealthy" ;;
    *"(health: starting)"*) echo "starting" ;;
    *) echo "none" ;;
  esac
}

collect_containers_json() {
  command -v "$DOCKER_BIN" >/dev/null 2>&1 || die "找不到 docker: $DOCKER_BIN"
  "$DOCKER_BIN" info >/dev/null 2>&1 || die "无法执行 docker（请确认当前用户有权限）"

  local items="" name state status image health entry
  while IFS=$'\t' read -r name state status image; do
    [[ -z "$name" ]] && continue
    health=$(parse_health "$status")
    entry=$(printf '{"name":"%s","state":"%s","status":"%s","image":"%s","health":"%s"}' \
      "$(json_escape "$name")" "$(json_escape "$state")" \
      "$(json_escape "$status")" "$(json_escape "$image")" "$health")
    [[ -n "$items" ]] && items+=","
    items+="$entry"
  done < <("$DOCKER_BIN" ps -a --format '{{.Names}}\t{{.State}}\t{{.Status}}\t{{.Image}}' 2>/dev/null)

  echo "[$items]"
}

collect_payload() {
  local collected_at containers_json
  collected_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  containers_json=$(collect_containers_json)

  cat <<EOF
{"env":"$(json_escape "$SERVER_ENV")","containers":$containers_json,"collected_at":"$collected_at"}
EOF
}

push_once() {
  local payload http_code body container_count
  payload=$(collect_payload)
  container_count=$(printf '%s' "$payload" | grep -o '"name"' | wc -l | tr -d ' ')
  log "[$SERVER_ENV] 采集 $container_count 个容器"

  if (( DRY_RUN )); then
    echo "$payload"
    return 0
  fi

  body=$(mktemp)
  trap 'rm -f "$body"' RETURN
  http_code=$(curl -sS -o "$body" -w "%{http_code}" \
    -X POST "$OPS_PUSH_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $DOCKER_PUSH_TOKEN" \
    --connect-timeout "$CURL_TIMEOUT" \
    --max-time "$((CURL_TIMEOUT * 2))" \
    -d "$payload") || die "curl 失败"

  [[ "$http_code" =~ ^2 ]] || die "推送失败 HTTP $http_code: $(head -c 300 "$body")"
  log "[$SERVER_ENV] 推送成功 HTTP $http_code"
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
