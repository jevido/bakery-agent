#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_config() {
  PORT_RANGE_START=3001
  PORT_RANGE_END=4000
  NGINX_ENABLED=1
  CERTBOT_ENABLED=1
  CERTBOT_EMAIL=""
  NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
  NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
  UPDATE_REPO_URL="https://github.com/jevido/bakery-agent.git"
  UPDATE_BRANCH="main"
  BAKERY_BRANCH="main"
  DEPLOY_HEALTH_RETRIES=10
  DEPLOY_HEALTH_INTERVAL=5
  DEPLOY_LOCK_TIMEOUT=0
  DEFAULT_CPU_LIMIT=""
  DEFAULT_MEMORY_LIMIT=""
  IMAGE_RETENTION_COUNT=2

  if [[ -f "$BAKERY_CONF_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$BAKERY_CONF_FILE"
  fi
}

write_default_config() {
  mkdir -p "$BAKERY_ROOT"
  if [[ -f "$BAKERY_CONF_FILE" ]]; then
    return 0
  fi

  cat > "$BAKERY_CONF_FILE" <<'CFG'
# bakery-agent configuration
PORT_RANGE_START=3001
PORT_RANGE_END=4000
NGINX_ENABLED=1
CERTBOT_ENABLED=1
CERTBOT_EMAIL=""
NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
UPDATE_REPO_URL="https://github.com/jevido/bakery-agent.git"
UPDATE_BRANCH="main"
BAKERY_BRANCH="main"
DEPLOY_HEALTH_RETRIES=10
DEPLOY_HEALTH_INTERVAL=5
DEPLOY_LOCK_TIMEOUT=0
DEFAULT_CPU_LIMIT=""
DEFAULT_MEMORY_LIMIT=""
IMAGE_RETENTION_COUNT=2
CFG
}
