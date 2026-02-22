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

resolve_current_user_home() {
  local user home
  user="$(id -un 2>/dev/null || true)"
  home="${HOME:-}"

  if [[ -n "$home" ]]; then
    printf '%s\n' "$home"
    return 0
  fi

  if [[ -n "$user" ]]; then
    home="$(getent passwd "$user" | cut -d: -f6 || true)"
    if [[ -n "$home" ]]; then
      printf '%s\n' "$home"
      return 0
    fi
  fi

  return 1
}

ensure_rootless_runtime_dir() {
  [[ "$(id -u)" -ne 0 ]] || return 0

  local uid user runtime_dir preferred_runtime_dir
  uid="$(id -u)"
  user="$(id -un 2>/dev/null || true)"
  preferred_runtime_dir="/run/user/$uid"

  if [[ "$user" == "bakery" ]]; then
    if [[ ! -d "$preferred_runtime_dir" || ! -w "$preferred_runtime_dir" ]]; then
      cli_die "$CLI_EXIT_PREREQ" "Rootless runtime dir unavailable at $preferred_runtime_dir for user bakery. Run 'sudo bakery setup' to enable lingering, then retry."
    fi
    runtime_dir="$preferred_runtime_dir"
  elif [[ -d "$preferred_runtime_dir" && -w "$preferred_runtime_dir" ]]; then
    runtime_dir="$preferred_runtime_dir"
  else
    runtime_dir="$BAKERY_TMP_ROOT/bakery-xdg-$uid"
    mkdir -p "$runtime_dir"
    chmod 700 "$runtime_dir" >/dev/null 2>&1 || true
  fi

  export XDG_RUNTIME_DIR="$runtime_dir"
}

ensure_rootless_podman_config() {
  [[ "$(id -u)" -ne 0 ]] || return 0

  local runtime_dir home cfg_dir storage_cfg containers_cfg graphroot
  runtime_dir="${XDG_RUNTIME_DIR:-}"
  [[ -n "$runtime_dir" ]] || return 0
  home="$(resolve_current_user_home || true)"
  [[ -n "$home" ]] || return 0

  cfg_dir="$home/.config/containers"
  graphroot="$home/.local/share/containers/storage"
  storage_cfg="$cfg_dir/storage.conf"
  containers_cfg="$cfg_dir/containers.conf"

  mkdir -p "$runtime_dir/containers" "$cfg_dir" "$graphroot"
  chmod 700 "$runtime_dir" >/dev/null 2>&1 || true
  chmod 700 "$runtime_dir/containers" >/dev/null 2>&1 || true

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
cgroup_manager = "cgroupfs"

[engine.runtimes]
crun = ["/usr/bin/crun", "/usr/sbin/crun", "/usr/local/bin/crun", "/usr/libexec/crun"]
CFG
  chmod 600 "$containers_cfg" >/dev/null 2>&1 || true
}

podman_exec_as_user() {
  local target_user="$1"
  shift

  id "$target_user" >/dev/null 2>&1 || cli_die "$CLI_EXIT_PREREQ" "User $target_user does not exist"
  local uid home runtime_dir graphroot cfg_dir storage_cfg containers_cfg
  uid="$(id -u "$target_user")"
  home="$(getent passwd "$target_user" | cut -d: -f6)"
  runtime_dir="/run/user/$uid"
  graphroot="$home/.local/share/containers/storage"
  cfg_dir="$home/.config/containers"
  storage_cfg="$cfg_dir/storage.conf"
  containers_cfg="$cfg_dir/containers.conf"

  if [[ "$(id -u)" -eq 0 ]]; then
    if command -v loginctl >/dev/null 2>&1; then
      loginctl enable-linger "$target_user" >/dev/null 2>&1 || true
      loginctl start-user "$target_user" >/dev/null 2>&1 || true
    fi
    mkdir -p "$runtime_dir" "$runtime_dir/containers" "$cfg_dir" "$graphroot"
    chown -R "$target_user:$target_user" "$runtime_dir" "$cfg_dir" "$graphroot" >/dev/null 2>&1 || true
    chmod 700 "$runtime_dir" "$runtime_dir/containers" >/dev/null 2>&1 || true
  fi

  [[ -d "$runtime_dir" && -w "$runtime_dir" ]] || cli_die "$CLI_EXIT_PREREQ" "Rootless runtime dir unavailable at $runtime_dir for user $target_user"

  cat > "$storage_cfg" <<CFG
[storage]
driver = "overlay"
runroot = "$runtime_dir/containers"
graphroot = "$graphroot"
CFG
  cat > "$containers_cfg" <<'CFG'
[engine]
runtime = "crun"
cgroup_manager = "cgroupfs"

[engine.runtimes]
crun = ["/usr/bin/crun", "/usr/sbin/crun", "/usr/local/bin/crun", "/usr/libexec/crun"]
CFG
  if [[ "$(id -u)" -eq 0 ]]; then
    chown "$target_user:$target_user" "$storage_cfg" "$containers_cfg" >/dev/null 2>&1 || true
  fi
  chmod 600 "$storage_cfg" "$containers_cfg" >/dev/null 2>&1 || true

  if [[ "$(id -u)" -eq 0 ]]; then
    (
      cd "$home" || exit 1
      sudo -u "$target_user" -H env XDG_RUNTIME_DIR="$runtime_dir" \
        podman --runtime /usr/bin/crun --cgroup-manager cgroupfs --runroot "$runtime_dir/containers" --root "$graphroot" "$@"
    )
    return $?
  fi

  env XDG_RUNTIME_DIR="$runtime_dir" \
    podman --runtime /usr/bin/crun --cgroup-manager cgroupfs --runroot "$runtime_dir/containers" --root "$graphroot" "$@"
}

podman_rootless_preflight() {
  [[ "$(id -u)" -ne 0 ]] || return 0
  [[ -n "${_BAKERY_ROOTLESS_READY:-}" ]] && return 0

  require_cmd podman
  ensure_rootless_runtime_dir
  ensure_rootless_podman_config

  local err_file
  err_file="$(mktemp "$BAKERY_TMP_ROOT/bakery-podman-info.XXXXXX")"

  if command podman info >/dev/null 2>"$err_file"; then
    rm -f "$err_file"
    _BAKERY_ROOTLESS_READY=1
    return 0
  fi

  if grep -Eq 'cannot re-exec process to join the existing user namespace|RunRoot is pointing to a path .* not writable|default OCI runtime "crun" not found|no subuid ranges found|exec: "newuidmap": executable file not found|setup network: could not find pasta' "$err_file"; then
    command podman system migrate >/dev/null 2>&1 || true
    if command podman info >/dev/null 2>"$err_file"; then
      rm -f "$err_file"
      _BAKERY_ROOTLESS_READY=1
      return 0
    fi
  fi

  local err_msg
  err_msg="$(sed -n '1,5p' "$err_file" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
  rm -f "$err_file"
  cli_die "$CLI_EXIT_PREREQ" "Rootless Podman is not healthy for user $(id -un). Run 'sudo bakery setup' and retry. Details: ${err_msg:-podman info failed}"
}

podman_exec() {
  podman_rootless_preflight
  if [[ "$(id -u)" -eq 0 ]]; then
    if id bakery >/dev/null 2>&1; then
      podman_exec_as_user bakery "$@"
      return $?
    fi
    command podman "$@"
    return $?
  fi

  local runtime_dir home graphroot
  runtime_dir="${XDG_RUNTIME_DIR:-}"
  home="$(resolve_current_user_home || true)"
  graphroot="$home/.local/share/containers/storage"

  command podman --runtime /usr/bin/crun --cgroup-manager cgroupfs --runroot "$runtime_dir/containers" --root "$graphroot" "$@"
}
