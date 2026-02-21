#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/smoke-single-app-deploy.sh [--domain <domain>] [--keep]

Runs a local integration smoke test for a single web app deploy:
- Creates an isolated bakery environment under /tmp
- Builds a temporary local git repo with a simple Dockerfile app
- Runs bakery deploy against the local repo
- Verifies state.json, deploy logs, and HTTP health check
USAGE
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$1" >&2
    exit 1
  }
}

DOMAIN="smoke.local"
KEEP=0

while (($#)); do
  case "$1" in
    --domain)
      shift
      [[ $# -gt 0 ]] || {
        printf 'missing value for --domain\n' >&2
        exit 2
      }
      DOMAIN="$1"
      ;;
    --keep)
      KEEP=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

require_cmd bash
require_cmd git
require_cmd jq
require_cmd podman
require_cmd curl

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BAKERY_BIN="$ROOT_DIR/bin/bakery"
[[ -x "$BAKERY_BIN" ]] || {
  printf 'bakery binary not executable: %s\n' "$BAKERY_BIN" >&2
  exit 1
}

TMP_ROOT="$(mktemp -d /tmp/bakery-smoke.XXXXXX)"
BAKERY_ROOT="$TMP_ROOT/etc-bakery"
BAKERY_LOG_ROOT="$TMP_ROOT/var-log-bakery"
BAKERY_TMP_ROOT="$TMP_ROOT/tmp"
APP_REPO="$TMP_ROOT/repo"

cleanup() {
  if [[ -f "$BAKERY_ROOT/apps/$DOMAIN/state.json" ]]; then
    local container_id
    container_id="$(jq -r '.container_id // empty' "$BAKERY_ROOT/apps/$DOMAIN/state.json" 2>/dev/null || true)"
    if [[ -n "$container_id" ]]; then
      podman rm -f "$container_id" >/dev/null 2>&1 || true
    fi
  fi

  if [[ "$KEEP" -eq 0 ]]; then
    rm -rf "$TMP_ROOT"
  else
    printf 'kept smoke test files: %s\n' "$TMP_ROOT"
  fi
}
trap cleanup EXIT

mkdir -p "$BAKERY_ROOT" "$BAKERY_LOG_ROOT" "$BAKERY_TMP_ROOT" "$APP_REPO"

cat > "$BAKERY_ROOT/bakery.conf" <<'CFG'
PORT_RANGE_START=3101
PORT_RANGE_END=3200
NGINX_ENABLED=0
CERTBOT_ENABLED=0
DEPLOY_HEALTH_RETRIES=15
DEPLOY_HEALTH_INTERVAL=1
CFG

cat > "$APP_REPO/Dockerfile" <<'DOCKERFILE'
FROM python:3.12-alpine
WORKDIR /app
RUN printf 'bakery-smoke\n' > index.html
EXPOSE 8000
CMD ["python", "-m", "http.server", "8000"]
DOCKERFILE

git -C "$APP_REPO" init -q
git -C "$APP_REPO" config user.email "smoke@local"
git -C "$APP_REPO" config user.name "bakery-smoke"
git -C "$APP_REPO" add Dockerfile
git -C "$APP_REPO" commit -q -m "smoke app"

export BAKERY_ROOT BAKERY_LOG_ROOT BAKERY_TMP_ROOT

"$BAKERY_BIN" deploy "$DOMAIN" --repo "$APP_REPO"

STATE_FILE="$BAKERY_ROOT/apps/$DOMAIN/state.json"
[[ -f "$STATE_FILE" ]] || {
  printf 'state file not found: %s\n' "$STATE_FILE" >&2
  exit 1
}

PORT="$(jq -r '.port' "$STATE_FILE")"
STATUS="$(jq -r '.status' "$STATE_FILE")"
EXPOSE="$(jq -r '.expose' "$STATE_FILE")"

[[ "$STATUS" == "running" ]] || {
  printf 'unexpected status: %s\n' "$STATUS" >&2
  exit 1
}
[[ "$EXPOSE" == "true" ]] || {
  printf 'unexpected expose value: %s\n' "$EXPOSE" >&2
  exit 1
}
[[ "$PORT" =~ ^[0-9]+$ ]] || {
  printf 'invalid port in state: %s\n' "$PORT" >&2
  exit 1
}

HTTP_BODY="$(curl -fsS "http://127.0.0.1:$PORT/")"
[[ "$HTTP_BODY" == *"bakery-smoke"* ]] || {
  printf 'unexpected HTTP response body\n' >&2
  exit 1
}

LOG_COUNT="$(find "$BAKERY_LOG_ROOT/deploys" -type f -name "${DOMAIN}-*.log" | wc -l | tr -d ' ')"
[[ "$LOG_COUNT" -ge 1 ]] || {
  printf 'expected at least one deploy log file\n' >&2
  exit 1
}

printf 'smoke test passed for %s (port=%s)\n' "$DOMAIN" "$PORT"
