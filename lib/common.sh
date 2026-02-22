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

ensure_rootless_podman_env() {
  [[ "$(id -u)" -ne 0 ]] || return 0
  [[ -n "${_BAKERY_ROOTLESS_READY:-}" ]] && return 0

  local uid user home runtime_dir cfg_dir storage_cfg containers_cfg graphroot
  uid="$(id -u)"
  user="$(id -un 2>/dev/null || true)"
  home="${HOME:-}"
  if [[ -z "$home" && -n "$user" ]]; then
    home="$(getent passwd "$user" | cut -d: -f6 || true)"
  fi

  runtime_dir="$BAKERY_TMP_ROOT/bakery-xdg-$uid"
  mkdir -p "$runtime_dir" "$runtime_dir/containers"
  chmod 700 "$runtime_dir" >/dev/null 2>&1 || true
  export XDG_RUNTIME_DIR="$runtime_dir"

  # The managed deployment user is bakery; keep its Podman config deterministic.
  if [[ "$user" == "bakery" && -n "$home" ]]; then
    cfg_dir="$home/.config/containers"
    graphroot="$home/.local/share/containers/storage"
    storage_cfg="$cfg_dir/storage.conf"
    containers_cfg="$cfg_dir/containers.conf"

    mkdir -p "$cfg_dir" "$graphroot"
    cat > "$storage_cfg" <<CFG
[storage]
driver = "overlay"
runroot = "$runtime_dir/containers"
graphroot = "$graphroot"
CFG
    chmod 600 "$storage_cfg" >/dev/null 2>&1 || true

    cat > "$containers_cfg" <<'CFG'
[engine]
runtime = "crun"

[engine.runtimes]
crun = ["/usr/bin/crun", "/usr/sbin/crun", "/usr/local/bin/crun", "/usr/libexec/crun"]
CFG
    chmod 600 "$containers_cfg" >/dev/null 2>&1 || true

  fi

  _BAKERY_ROOTLESS_READY=1
}

ensure_rootless_podman_env

podman() {
  if [[ "$(id -u)" -eq 0 ]]; then
    command podman "$@"
    return $?
  fi

  local out_file err_file rc
  out_file="$(mktemp "$BAKERY_TMP_ROOT/bakery-podman-out.XXXXXX")"
  err_file="$(mktemp "$BAKERY_TMP_ROOT/bakery-podman-err.XXXXXX")"

  if command podman "$@" >"$out_file" 2>"$err_file"; then
    cat "$out_file"
    rm -f "$out_file" "$err_file"
    return 0
  fi
  rc=$?

  if grep -q 'cannot re-exec process to join the existing user namespace' "$err_file"; then
    ensure_rootless_podman_env
    command podman system migrate >/dev/null 2>&1 || true

    : > "$out_file"
    : > "$err_file"
    if command podman "$@" >"$out_file" 2>"$err_file"; then
      cat "$out_file"
      rm -f "$out_file" "$err_file"
      return 0
    fi
    rc=$?
  fi

  cat "$out_file"
  cat "$err_file" >&2
  rm -f "$out_file" "$err_file"
  return "$rc"
}
