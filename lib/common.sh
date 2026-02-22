#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${BAKERY_TRACE:-}" ]]; then
  set -x
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

: "${BAKERY_ROOT:=/etc/bakery}"
: "${BAKERY_LOG_ROOT:=/var/log/bakery}"
: "${BAKERY_TMP_ROOT:=/tmp}"

BAKERY_APPS_DIR="$BAKERY_ROOT/apps"
BAKERY_AGENT_DIR="$BAKERY_ROOT/agent"
BAKERY_CONF_FILE="$BAKERY_ROOT/bakery.conf"
BAKERY_KEY_FILE="$BAKERY_ROOT/secrets.key"
BAKERY_GITHUB_PAT_FILE="$BAKERY_ROOT/.github-pat.enc"
BAKERY_DEPLOY_LOG_DIR="$BAKERY_LOG_ROOT/deploys"

CLI_EXIT_USAGE=2
CLI_EXIT_STATE=3
CLI_EXIT_PREREQ=4
CLI_EXIT_RUNTIME=5

log() {
  local level="$1"
  shift
  local msg="$*"
  printf '%s [%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$level" "$msg"
}

cli_error() {
  printf 'bakery: error: %s\n' "$*" >&2
}

cli_die() {
  local code="$1"
  shift
  cli_error "$*"
  exit "$code"
}

cli_usage() {
  cli_die "$CLI_EXIT_USAGE" "$@"
}

die() {
  log "ERROR" "$*" >&2
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "This command must run as root"
}

sanitize_domain() {
  local domain="$1"
  printf '%s' "$domain" | tr -cd 'a-zA-Z0-9.-'
}

domain_dir() {
  local domain
  domain="$(sanitize_domain "$1")"
  printf '%s/%s' "$BAKERY_APPS_DIR" "$domain"
}

state_file() {
  printf '%s/state.json' "$(domain_dir "$1")"
}

env_enc_file() {
  printf '%s/.env.enc' "$(domain_dir "$1")"
}

nginx_app_conf_file() {
  printf '%s/nginx.conf' "$(domain_dir "$1")"
}

app_conf_file() {
  printf '%s/app.conf' "$(domain_dir "$1")"
}

ensure_base_dirs() {
  mkdir -p "$BAKERY_APPS_DIR" "$BAKERY_DEPLOY_LOG_DIR"
}

json_escape() {
  printf '%s' "$1" | jq -Rr @json
}

# Rootless podman often requires a writable XDG_RUNTIME_DIR in non-interactive SSH sessions.
if [[ "$(id -u)" -ne 0 ]]; then
  if [[ -z "${XDG_RUNTIME_DIR:-}" || ! -d "${XDG_RUNTIME_DIR:-}" || ! -w "${XDG_RUNTIME_DIR:-}" ]]; then
    XDG_RUNTIME_DIR="$BAKERY_TMP_ROOT/bakery-xdg-$(id -u)"
    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR" || true
    export XDG_RUNTIME_DIR
  fi
fi
