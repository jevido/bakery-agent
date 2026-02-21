#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
  echo "This installer requires bash. Run:" >&2
  echo "curl -fsSL https://raw.githubusercontent.com/jevido/bakery-agent/main/install.sh | bash" >&2
  exit 1
fi

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

: "${BAKERY_ROOT:=/etc/bakery}"
: "${BAKERY_LOG_ROOT:=/var/log/bakery}"
: "${BAKERY_USER:=bakery}"
: "${BAKERY_BIN:=/usr/local/bin/bakery}"

UPDATE_MODE=0
SOURCE_DIR="$ROOT_DIR"

while (($#)); do
  case "$1" in
    --update)
      UPDATE_MODE=1
      ;;
    --source-dir)
      shift
      [[ $# -gt 0 ]] || {
        echo "Missing value for --source-dir" >&2
        exit 1
      }
      SOURCE_DIR="$1"
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
  shift
done

require_root() {
  [[ "$(id -u)" -eq 0 ]] || {
    echo "install.sh must run as root" >&2
    exit 1
  }
}

warn_if_not_debian_13() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    if [[ "${ID:-}" != "debian" || "${VERSION_ID:-}" != "13" ]]; then
      echo "Warning: bakery-agent is tested on Debian 13; detected ${PRETTY_NAME:-unknown}" >&2
    fi
  fi
}

install_deps() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y podman nginx certbot python3-certbot-nginx openssl jq git curl logrotate
}

ensure_user() {
  if ! id "$BAKERY_USER" >/dev/null 2>&1; then
    useradd --system --create-home --shell /usr/sbin/nologin "$BAKERY_USER"
  fi
}

ensure_dirs() {
  mkdir -p "$BAKERY_ROOT/apps" "$BAKERY_LOG_ROOT/deploys"
  chown -R "$BAKERY_USER":"$BAKERY_USER" "$BAKERY_ROOT" "$BAKERY_LOG_ROOT"
  chmod 750 "$BAKERY_ROOT" "$BAKERY_LOG_ROOT"
}

install_agent_files() {
  local staging
  staging="$(mktemp -d /tmp/bakery-agent-src.XXXXXX)"

  cp -R "$SOURCE_DIR"/. "$staging"/

  rm -rf "$BAKERY_ROOT/agent"
  mkdir -p "$BAKERY_ROOT/agent"
  cp -R "$staging"/. "$BAKERY_ROOT/agent/"
  rm -rf "$staging"
  chown -R root:root "$BAKERY_ROOT/agent"
  chmod +x "$BAKERY_ROOT/agent/bin/bakery" "$BAKERY_ROOT/agent/install.sh"
}

ensure_key() {
  if [[ "$UPDATE_MODE" -eq 1 && -f "$BAKERY_ROOT/secrets.key" ]]; then
    return 0
  fi

  if [[ ! -f "$BAKERY_ROOT/secrets.key" ]]; then
    umask 077
    openssl rand -hex 64 > "$BAKERY_ROOT/secrets.key"
    chown "$BAKERY_USER":"$BAKERY_USER" "$BAKERY_ROOT/secrets.key"
    chmod 600 "$BAKERY_ROOT/secrets.key"
  fi
}

ensure_config() {
  if [[ ! -f "$BAKERY_ROOT/bakery.conf" ]]; then
    cat > "$BAKERY_ROOT/bakery.conf" <<'CFG'
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
    chown "$BAKERY_USER":"$BAKERY_USER" "$BAKERY_ROOT/bakery.conf"
    chmod 640 "$BAKERY_ROOT/bakery.conf"
  fi
}

install_bin() {
  ln -sfn "$BAKERY_ROOT/agent/bin/bakery" "$BAKERY_BIN"
}

install_systemd_unit() {
  cp "$BAKERY_ROOT/agent/systemd/bakery-agent.service" /etc/systemd/system/bakery-agent.service
  systemctl daemon-reload
  systemctl enable --now bakery-agent.service
}

install_logrotate_config() {
  cp "$BAKERY_ROOT/agent/logrotate/bakery-agent" /etc/logrotate.d/bakery-agent
  chmod 644 /etc/logrotate.d/bakery-agent
}

main() {
  require_root
  warn_if_not_debian_13
  install_deps
  ensure_user
  ensure_dirs
  install_agent_files
  ensure_key
  ensure_config
  install_bin
  install_logrotate_config
  install_systemd_unit

  echo "bakery-agent installed successfully"
  echo "CLI: $BAKERY_BIN"
  echo "Config: $BAKERY_ROOT/bakery.conf"
}

main
