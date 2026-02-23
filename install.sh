#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
  echo "This installer requires bash. Run:" >&2
  echo "curl -fsSL https://raw.githubusercontent.com/jevido/bakery-agent/main/install.sh | bash" >&2
  exit 1
fi

set -euo pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
if [[ -n "$SCRIPT_SOURCE" && "$SCRIPT_SOURCE" != "bash" && "$SCRIPT_SOURCE" != "-bash" ]]; then
  ROOT_DIR="$(cd -- "$(dirname -- "$SCRIPT_SOURCE")" && pwd)"
else
  ROOT_DIR="$(pwd)"
fi

: "${BAKERY_ROOT:=/etc/bakery}"
: "${BAKERY_LOG_ROOT:=/var/log/bakery}"
: "${BAKERY_USER:=bakery}"
: "${BAKERY_BIN:=/usr/local/bin/bakery}"
: "${BAKERY_INSTALL_REPO:=https://github.com/jevido/bakery-agent}"
: "${BAKERY_INSTALL_BRANCH:=main}"

UPDATE_MODE=0
SOURCE_DIR="$ROOT_DIR"
INSTALL_TMP_DIR=""

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

ensure_user() {
  if ! id "$BAKERY_USER" >/dev/null 2>&1; then
    useradd --system --create-home --shell /bin/bash "$BAKERY_USER"
    return 0
  fi

  local current_shell
  current_shell="$(getent passwd "$BAKERY_USER" | cut -d: -f7)"
  if [[ "$current_shell" == "/usr/sbin/nologin" || "$current_shell" == "/sbin/nologin" ]]; then
    usermod -s /bin/bash "$BAKERY_USER"
  fi
}

ensure_dirs() {
  mkdir -p "$BAKERY_ROOT/apps" "$BAKERY_LOG_ROOT/deploys"
  chown -R "$BAKERY_USER":"$BAKERY_USER" "$BAKERY_ROOT" "$BAKERY_LOG_ROOT"
  chmod 750 "$BAKERY_ROOT" "$BAKERY_LOG_ROOT"
}

cleanup_tmp() {
  if [[ -n "${INSTALL_TMP_DIR:-}" && -d "$INSTALL_TMP_DIR" ]]; then
    rm -rf "$INSTALL_TMP_DIR"
  fi
}

resolve_source_dir() {
  if [[ -f "$SOURCE_DIR/bin/bakery" && -f "$SOURCE_DIR/install.sh" ]]; then
    return 0
  fi

  command -v curl >/dev/null 2>&1 || {
    echo "curl is required to fetch bakery-agent source" >&2
    exit 1
  }
  command -v tar >/dev/null 2>&1 || {
    echo "tar is required to unpack bakery-agent source" >&2
    exit 1
  }

  INSTALL_TMP_DIR="$(mktemp -d /tmp/bakery-agent-src.XXXXXX)"
  trap cleanup_tmp EXIT

  local archive_url
  archive_url="${BAKERY_INSTALL_REPO%/}/archive/refs/heads/${BAKERY_INSTALL_BRANCH}.tar.gz"
  curl -fsSL "$archive_url" | tar -xz -C "$INSTALL_TMP_DIR"

  local extracted
  extracted="$(find "$INSTALL_TMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [[ -n "$extracted" ]] || {
    echo "Failed to resolve source directory from $archive_url" >&2
    exit 1
  }
  SOURCE_DIR="$extracted"
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
    if command -v openssl >/dev/null 2>&1; then
      openssl rand -hex 64 > "$BAKERY_ROOT/secrets.key"
    else
      head -c 48 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$BAKERY_ROOT/secrets.key"
    fi
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

install_bash_completion() {
  local src="$BAKERY_ROOT/agent/completions/bash/bakery"
  if [[ ! -f "$src" ]]; then
    return 0
  fi

  mkdir -p /etc/bash_completion.d
  cp "$src" /etc/bash_completion.d/bakery
  chmod 644 /etc/bash_completion.d/bakery
}

install_systemd_unit() {
  cp "$BAKERY_ROOT/agent/systemd/bakery-agent.service" /etc/systemd/system/bakery-agent.service
  systemctl daemon-reload
  systemctl enable bakery-agent.service
}

install_logrotate_config() {
  cp "$BAKERY_ROOT/agent/logrotate/bakery-agent" /etc/logrotate.d/bakery-agent
  chmod 644 /etc/logrotate.d/bakery-agent
}

install_sudoers_policy() {
  if [[ ! -d /etc/sudoers.d ]]; then
    return 0
  fi

  cat > /etc/sudoers.d/bakery-agent <<'CFG'
bakery ALL=(root) NOPASSWD: /usr/bin/cp, /usr/bin/ln, /usr/sbin/nginx, /bin/systemctl, /usr/bin/certbot
CFG
  chmod 440 /etc/sudoers.d/bakery-agent
}

main() {
  require_root
  warn_if_not_debian_13
  resolve_source_dir
  ensure_user
  ensure_dirs
  install_agent_files
  ensure_key
  ensure_config
  install_bin
  install_bash_completion
  install_logrotate_config
  install_sudoers_policy
  install_systemd_unit

  echo "bakery-agent installed successfully"
  echo "CLI: $BAKERY_BIN"
  echo "Config: $BAKERY_ROOT/bakery.conf"
  echo "Next: run 'bakery setup' as root to install podman/nginx/certbot and other runtime dependencies."
  echo "Then start the agent: systemctl start bakery-agent.service"
}

main
