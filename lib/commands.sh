#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=lib/config.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/config.sh"
# shellcheck source=lib/state.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/state.sh"
# shellcheck source=lib/deploy.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/deploy.sh"

ensure_bakery_xdg_runtime_dir() {
  local bakery_uid runtime_dir
  bakery_uid="$(id -u bakery)"
  runtime_dir="$BAKERY_TMP_ROOT/bakery-xdg-$bakery_uid"
  mkdir -p "$runtime_dir"
  chown bakery:bakery "$runtime_dir" >/dev/null 2>&1 || true
  chmod 700 "$runtime_dir" >/dev/null 2>&1 || true
  printf '%s\n' "$runtime_dir"
}

ensure_bakery_rootless_podman_ready() {
  local bakery_home runtime_dir cfg_dir storage_cfg containers_cfg graphroot
  bakery_home="$(getent passwd bakery | cut -d: -f6)"
  runtime_dir="$(ensure_bakery_xdg_runtime_dir)"
  cfg_dir="$bakery_home/.config/containers"
  storage_cfg="$cfg_dir/storage.conf"
  containers_cfg="$cfg_dir/containers.conf"
  graphroot="$bakery_home/.local/share/containers/storage"

  mkdir -p "$cfg_dir" "$graphroot" "$runtime_dir/containers"
  cat > "$storage_cfg" <<CFG
[storage]
driver = "overlay"
runroot = "$runtime_dir/containers"
graphroot = "$graphroot"
CFG
  cat > "$containers_cfg" <<'CFG'
[engine]
runtime = "crun"

[engine.runtimes]
crun = ["/usr/bin/crun", "/usr/sbin/crun", "/usr/local/bin/crun", "/usr/libexec/crun"]
CFG
  chown -R bakery:bakery "$cfg_dir" "$graphroot" "$runtime_dir" >/dev/null 2>&1 || true
  chmod 700 "$runtime_dir" "$runtime_dir/containers" >/dev/null 2>&1 || true
  chmod 600 "$storage_cfg" "$containers_cfg" >/dev/null 2>&1 || true

  sudo -u bakery -H env XDG_RUNTIME_DIR="$runtime_dir" podman system migrate >/dev/null 2>&1 || true
}

podman_as_bakery() {
  local runtime_dir bakery_home graphroot
  ensure_bakery_rootless_podman_ready
  runtime_dir="$(ensure_bakery_xdg_runtime_dir)"
  bakery_home="$(getent passwd bakery | cut -d: -f6)"
  graphroot="$bakery_home/.local/share/containers/storage"
  sudo -u bakery -H env XDG_RUNTIME_DIR="$runtime_dir" \
    podman --runtime /usr/bin/crun --runroot "$runtime_dir/containers" --root "$graphroot" "$@"
}

podman_exec_for_container() {
  local container_id="$1"
  shift

  if [[ "$(id -u)" -eq 0 ]] && id bakery >/dev/null 2>&1; then
    if podman_as_bakery container exists "$container_id" >/dev/null 2>&1; then
      podman_as_bakery "$@"
      return $?
    fi
  fi

  if podman_exec container exists "$container_id" >/dev/null 2>&1; then
    podman_exec "$@"
    return $?
  fi

  return 1
}

print_usage() {
  cat <<'USAGE'
bakery - lightweight VPS deployment agent

Usage:
  bakery deploy <domain> [--repo <git-url>] [--branch <name>] [--cpu <cpus>] [--memory <limit>]
  bakery podman <podman-args...>
  bakery remove <domain>
  bakery bootstrap <domain> [--repo <git-url>] [--branch <name>] [--host <vps-host>] [--ssh-user <user>]
  bakery setup
  bakery pat set
  bakery pat get
  bakery list
  bakery status <domain>
  bakery status refresh [domain]
  bakery logs <domain>
  bakery stop <domain>
  bakery restart <domain>
  bakery env set <domain>
  bakery env get <domain>
  bakery update
  bakery daemon
USAGE
}

cmd_deploy() {
  local domain="${1:-}"
  [[ -n "$domain" ]] || cli_usage "usage: bakery deploy <domain> [--repo <git-url>] [--branch <name>] [--cpu <cpus>] [--memory <limit>]"
  shift || true
  run_deploy "$domain" "$@"
}

cmd_podman() {
  [[ $# -gt 0 ]] || cli_usage "usage: bakery podman <podman-args...>"
  require_cmd podman

  if [[ "$(id -u)" -eq 0 ]]; then
    id bakery >/dev/null 2>&1 || cli_die "$CLI_EXIT_PREREQ" "User bakery does not exist"
    podman_as_bakery "$@"
    return $?
  fi

  if [[ "$(id -un)" == "bakery" ]]; then
    podman_exec "$@"
    return $?
  fi

  cli_die "$CLI_EXIT_PREREQ" "Run as root or bakery user"
}

cmd_remove() {
  local domain="${1:-}"
  [[ -n "$domain" ]] || cli_usage "usage: bakery remove <domain>"

  load_config
  ensure_base_dirs
  require_cmd podman

  local app_dir state container_id prev_container_id
  local -a containers images
  app_dir="$(domain_dir "$domain")"
  state="$(state_file "$domain")"
  container_id=""
  prev_container_id=""

  if [[ -f "$state" ]] && state_validate_file "$state" "$domain"; then
    container_id="$(jq -r '.container_id // empty' "$state")"
    prev_container_id="$(jq -r '.previous_container_id // empty' "$state")"
  fi

  if [[ -n "$container_id" ]]; then
    containers+=("$container_id")
  fi
  if [[ -n "$prev_container_id" ]]; then
    containers+=("$prev_container_id")
  fi

  local podman_cmd="podman_exec"
  if [[ "$(id -u)" -eq 0 ]] && id bakery >/dev/null 2>&1; then
    podman_cmd="podman_as_bakery"
  fi

  while IFS= read -r cid; do
    [[ -n "$cid" ]] || continue
    if [[ ! " ${containers[*]} " =~ " ${cid} " ]]; then
      containers+=("$cid")
    fi
  done < <($podman_cmd ps -a --filter "label=bakery.domain=$domain" --format '{{.ID}}')

  local cid
  for cid in "${containers[@]:-}"; do
    $podman_cmd rm -f "$cid" >/dev/null 2>&1 || true
  done

  if [[ "$NGINX_ENABLED" == "1" ]]; then
    rm -f "$app_dir/nginx.conf"
    rm -f "$NGINX_SITES_ENABLED/$domain.conf"
    rm -f "$NGINX_SITES_AVAILABLE/$domain.conf"
    if command -v nginx >/dev/null 2>&1; then
      nginx -t >/dev/null 2>&1 && (systemctl reload nginx || nginx -s reload || true)
    fi
  fi

  while IFS= read -r img; do
    [[ -n "$img" ]] || continue
    images+=("$img")
  done < <($podman_cmd image ls --filter "label=bakery.managed=true" --filter "label=bakery.domain=$domain" --format '{{.ID}}')

  local img
  for img in "${images[@]:-}"; do
    $podman_cmd rmi "$img" >/dev/null 2>&1 || true
  done

  rm -rf "$app_dir"
  log "INFO" "Removed app resources for $domain"
}

detect_default_host() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [[ -n "$ip" ]]; then
    printf '%s\n' "$ip"
    return 0
  fi
  hostname -f 2>/dev/null || hostname
}

cmd_bootstrap() {
  local domain="${1:-}"
  [[ -n "$domain" ]] || cli_usage "usage: bakery bootstrap <domain> [--repo <git-url>] [--branch <name>] [--host <vps-host>] [--ssh-user <user>]"
  shift || true

  require_root
  require_cmd ssh-keygen
  load_config
  ensure_base_dirs

  local repo="" branch="" host="" ssh_user="bakery"
  while (($#)); do
    case "$1" in
      --repo)
        shift
        [[ $# -gt 0 ]] || cli_usage "missing value for --repo"
        repo="$1"
        ;;
      --branch)
        shift
        [[ $# -gt 0 ]] || cli_usage "missing value for --branch"
        branch="$1"
        ;;
      --host)
        shift
        [[ $# -gt 0 ]] || cli_usage "missing value for --host"
        host="$1"
        ;;
      --ssh-user)
        shift
        [[ $# -gt 0 ]] || cli_usage "missing value for --ssh-user"
        ssh_user="$1"
        ;;
      *)
        cli_usage "unknown bootstrap option: $1"
        ;;
    esac
    shift
  done

  if [[ -z "$repo" ]]; then
    repo="$(state_get_or_empty "$domain" repo | tr -d '"')"
  fi
  if [[ -z "$branch" ]]; then
    branch="$(state_get_or_empty "$domain" branch | tr -d '"')"
  fi
  branch="${branch:-${BAKERY_BRANCH:-main}}"
  host="${host:-$(detect_default_host)}"

  local dir key_file pub_file pub_key user_home auth_file
  dir="$(domain_dir "$domain")"
  mkdir -p "$dir"
  key_file="$dir/deploy_ssh_key"
  pub_file="$key_file.pub"

  if [[ ! -f "$key_file" || ! -f "$pub_file" ]]; then
    ssh-keygen -t ed25519 -N "" -f "$key_file" -C "bakery-${domain}-deploy" >/dev/null
  fi
  chmod 600 "$key_file"
  chmod 644 "$pub_file"

  if id "$ssh_user" >/dev/null 2>&1; then
    user_home="$(getent passwd "$ssh_user" | cut -d: -f6)"
    if [[ -n "$user_home" ]]; then
      mkdir -p "$user_home/.ssh"
      auth_file="$user_home/.ssh/authorized_keys"
      touch "$auth_file"
      chmod 700 "$user_home/.ssh"
      chmod 600 "$auth_file"
      chown -R "$ssh_user:$ssh_user" "$user_home/.ssh"
      pub_key="$(cat "$pub_file")"
      if ! grep -qxF "$pub_key" "$auth_file"; then
        printf '%s\n' "$pub_key" >> "$auth_file"
      fi
    fi
  else
    log "WARN" "SSH user $ssh_user does not exist; public key was not installed into authorized_keys"
  fi

  local deploy_cmd
  deploy_cmd="bakery deploy $domain"
  if [[ -n "$repo" ]]; then
    deploy_cmd+=" --repo $repo"
  fi
  if [[ -n "$branch" ]]; then
    deploy_cmd+=" --branch $branch"
  fi

  cat <<EOF
Bootstrap complete for $domain

SSH details:
- User: $ssh_user
- Private key file: $key_file
- Public key file: $pub_file
- Host: $host

Add this private key to GitHub secret VPS_SSH_KEY:
$(cat "$key_file")

GitHub Actions workflow template (.github/workflows/deploy.yml):
name: Deploy to VPS

on:
  push:
    branches: [$branch]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Deploy via bakery-agent
        uses: appleboy/ssh-action@v1
        with:
          host: "$host"
          username: "$ssh_user"
          key: \${{ secrets.VPS_SSH_KEY }}
          script: |
            $deploy_cmd
EOF
}

cmd_setup() {
  require_root

  if ! command -v apt-get >/dev/null 2>&1; then
    cli_die "$CLI_EXIT_PREREQ" "apt-get is required for setup on this host"
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y podman crun uidmap slirp4netns fuse-overlayfs passt nginx certbot python3-certbot-nginx openssl jq git curl logrotate sudo

  if id bakery >/dev/null 2>&1; then
    local subuid_start subgid_start bakery_uid bakery_home runtime_dir cfg_dir storage_cfg containers_cfg graphroot
    subuid_start="$(awk -F: 'BEGIN{m=100000} NF>=3 {e=$2+$3; if (e>m) m=e} END{print m}' /etc/subuid 2>/dev/null || echo 100000)"
    subgid_start="$(awk -F: 'BEGIN{m=100000} NF>=3 {e=$2+$3; if (e>m) m=e} END{print m}' /etc/subgid 2>/dev/null || echo 100000)"

    if ! grep -q '^bakery:' /etc/subuid 2>/dev/null; then
      printf 'bakery:%s:65536\n' "$subuid_start" >> /etc/subuid
    fi
    if ! grep -q '^bakery:' /etc/subgid 2>/dev/null; then
      printf 'bakery:%s:65536\n' "$subgid_start" >> /etc/subgid
    fi

    bakery_uid="$(id -u bakery)"
    bakery_home="$(getent passwd bakery | cut -d: -f6)"
    runtime_dir="$BAKERY_TMP_ROOT/bakery-xdg-$bakery_uid"
    cfg_dir="$bakery_home/.config/containers"
    storage_cfg="$cfg_dir/storage.conf"
    containers_cfg="$cfg_dir/containers.conf"
    graphroot="$bakery_home/.local/share/containers/storage"

    mkdir -p "$runtime_dir" "$runtime_dir/containers" "$cfg_dir" "$graphroot"
    chown -R bakery:bakery "$runtime_dir" "$cfg_dir" "$bakery_home/.local/share/containers"
    chmod 700 "$runtime_dir"

    cat > "$storage_cfg" <<CFG
[storage]
driver = "overlay"
runroot = "$runtime_dir/containers"
graphroot = "$graphroot"
CFG
    chown bakery:bakery "$storage_cfg"
    chmod 600 "$storage_cfg"

    cat > "$containers_cfg" <<'CFG'
[engine]
runtime = "crun"

[engine.runtimes]
crun = ["/usr/bin/crun", "/usr/sbin/crun", "/usr/local/bin/crun", "/usr/libexec/crun"]
CFG
    chown bakery:bakery "$containers_cfg"
    chmod 600 "$containers_cfg"

    sudo -u bakery -H env XDG_RUNTIME_DIR="$runtime_dir" podman system migrate >/dev/null 2>&1 || true
  fi

  mkdir -p /etc/containers/registries.conf.d
  cat > /etc/containers/registries.conf.d/010-bakery.conf <<'CFG'
unqualified-search-registries = ["docker.io", "ghcr.io", "quay.io"]
CFG

  log "INFO" "Installed bakery runtime dependencies"
}

cmd_pat_set() {
  command -v openssl >/dev/null 2>&1 || cli_die "$CLI_EXIT_PREREQ" "Required command not found: openssl"
  [[ -f "$BAKERY_KEY_FILE" ]] || cli_die "$CLI_EXIT_PREREQ" "Secrets key not found at $BAKERY_KEY_FILE"

  local pat tmp
  if [[ -t 0 ]]; then
    read -r -s -p "GitHub PAT: " pat
    printf '\n'
  else
    pat="$(cat)"
  fi
  pat="${pat//$'\r'/}"
  pat="${pat%$'\n'}"
  [[ -n "$pat" ]] || cli_usage "empty PAT provided"

  tmp="$(mktemp "$BAKERY_TMP_ROOT/bakery-pat.XXXXXX")"
  trap 'rm -f "${tmp:-}"' RETURN

  printf '%s' "$pat" > "$tmp"
  openssl enc -aes-256-cbc -pbkdf2 -in "$tmp" -out "$BAKERY_GITHUB_PAT_FILE" -pass "file:$BAKERY_KEY_FILE"
  chmod 600 "$BAKERY_GITHUB_PAT_FILE"

  log "INFO" "Stored encrypted GitHub PAT at $BAKERY_GITHUB_PAT_FILE"
}

cmd_pat_get() {
  command -v openssl >/dev/null 2>&1 || cli_die "$CLI_EXIT_PREREQ" "Required command not found: openssl"
  [[ -f "$BAKERY_KEY_FILE" ]] || cli_die "$CLI_EXIT_PREREQ" "Secrets key not found at $BAKERY_KEY_FILE"
  [[ -f "$BAKERY_GITHUB_PAT_FILE" ]] || cli_die "$CLI_EXIT_STATE" "No encrypted GitHub PAT found at $BAKERY_GITHUB_PAT_FILE"

  openssl enc -aes-256-cbc -pbkdf2 -d -in "$BAKERY_GITHUB_PAT_FILE" -out /dev/stdout -pass "file:$BAKERY_KEY_FILE"
}

cmd_list() {
  ensure_base_dirs
  printf '%-35s %-12s %-7s %-20s\n' "DOMAIN" "STATUS" "PORT" "DEPLOYED_AT"
  printf '%-35s %-12s %-7s %-20s\n' "------" "------" "----" "-----------"

  local file domain
  while IFS= read -r file; do
    domain="$(basename "$(dirname "$file")")"
    if ! state_validate_file "$file" "$domain"; then
      log "WARN" "Skipping invalid state file: $file"
      continue
    fi

    jq -r '[.domain, .status, (.port|tostring), .deployed_at] | @tsv' "$file" | \
      awk -F'\t' '{printf "%-35s %-12s %-7s %-20s\n", $1, $2, $3, $4}'
  done < <(state_list_files)
}

refresh_state_domain() {
  local domain="$1"
  local file container_id runtime_status

  file="$(state_file "$domain")"
  if ! state_validate_file "$file" "$domain"; then
    log "WARN" "Skipping invalid state file: $file"
    return 0
  fi

  container_id="$(jq -r '.container_id // empty' "$file")"
  if [[ -z "$container_id" ]]; then
    state_update_status "$domain" "missing"
    log "INFO" "Refreshed $domain status=missing (no container_id in state)"
    return 0
  fi

  if runtime_status="$(podman_exec_for_container "$container_id" container inspect --format '{{.State.Status}}' "$container_id" 2>/dev/null)"; then
    state_update_status "$domain" "$runtime_status"
    log "INFO" "Refreshed $domain status=$runtime_status"
    return 0
  fi

  state_update_status "$domain" "missing"
  log "INFO" "Refreshed $domain status=missing (container not found)"
}

cmd_status_refresh() {
  local domain="${1:-}"
  ensure_base_dirs

  if [[ -n "$domain" ]]; then
    state_require_valid "$domain"
    refresh_state_domain "$domain"
    return 0
  fi

  local file iter_domain
  while IFS= read -r file; do
    iter_domain="$(basename "$(dirname "$file")")"
    refresh_state_domain "$iter_domain"
  done < <(state_list_files)
}

cmd_status() {
  local domain="${1:-}"
  [[ -n "$domain" ]] || cli_usage "usage: bakery status <domain>"

  local file
  file="$(state_file "$domain")"
  state_require_valid "$domain"

  cat "$file"

  local container_id
  container_id="$(jq -r '.container_id' "$file")"
  if [[ -n "$container_id" && "$container_id" != "null" ]]; then
    log "INFO" "Container runtime status:"
    if ! podman_exec_for_container "$container_id" ps -a --filter "id=$container_id"; then
      cli_die "$CLI_EXIT_STATE" "No container found for $domain (container_id=$container_id)"
    fi
  fi
}

cmd_logs() {
  local domain="${1:-}"
  [[ -n "$domain" ]] || cli_usage "usage: bakery logs <domain>"
  state_require_valid "$domain"

  local container_id
  container_id="$(state_get "$domain" container_id | tr -d '"')"
  [[ -n "$container_id" ]] || cli_die "$CLI_EXIT_STATE" "No container found for $domain"
  if ! podman_exec_for_container "$container_id" logs -f "$container_id"; then
    cli_die "$CLI_EXIT_STATE" "No container found for $domain (container_id=$container_id)"
  fi
}

cmd_stop() {
  local domain="${1:-}"
  [[ -n "$domain" ]] || cli_usage "usage: bakery stop <domain>"
  state_require_valid "$domain"

  local container_id repo image port expose prev
  repo="$(state_get "$domain" repo | tr -d '"')"
  local branch
  branch="$(state_get_or_empty "$domain" branch | tr -d '"')"
  container_id="$(state_get "$domain" container_id | tr -d '"')"
  image="$(state_get "$domain" image | tr -d '"')"
  port="$(state_get "$domain" port)"
  expose="$(state_get "$domain" expose)"
  prev="$(state_get_or_empty "$domain" previous_container_id | tr -d '"')"

  if ! podman_exec_for_container "$container_id" stop "$container_id"; then
    cli_die "$CLI_EXIT_STATE" "No container found for $domain (container_id=$container_id)"
  fi
  state_write "$domain" "$repo" "$container_id" "$image" "$port" "stopped" "$expose" "$prev" "$branch"
}

cmd_restart() {
  local domain="${1:-}"
  [[ -n "$domain" ]] || cli_usage "usage: bakery restart <domain>"
  state_require_valid "$domain"

  local container_id repo image port expose prev
  repo="$(state_get "$domain" repo | tr -d '"')"
  local branch
  branch="$(state_get_or_empty "$domain" branch | tr -d '"')"
  container_id="$(state_get "$domain" container_id | tr -d '"')"
  image="$(state_get "$domain" image | tr -d '"')"
  port="$(state_get "$domain" port)"
  expose="$(state_get "$domain" expose)"
  prev="$(state_get_or_empty "$domain" previous_container_id | tr -d '"')"

  if ! podman_exec_for_container "$container_id" restart "$container_id"; then
    cli_die "$CLI_EXIT_STATE" "No container found for $domain (container_id=$container_id)"
  fi
  state_write "$domain" "$repo" "$container_id" "$image" "$port" "running" "$expose" "$prev" "$branch"
}

cmd_env_set() {
  local domain="${1:-}"
  [[ -n "$domain" ]] || cli_usage "usage: bakery env set <domain>"

  command -v openssl >/dev/null 2>&1 || cli_die "$CLI_EXIT_PREREQ" "Required command not found: openssl"
  [[ -f "$BAKERY_KEY_FILE" ]] || cli_die "$CLI_EXIT_PREREQ" "Secrets key not found at $BAKERY_KEY_FILE"

  local dir enc tmp
  dir="$(domain_dir "$domain")"
  enc="$(env_enc_file "$domain")"
  tmp="$(mktemp "$BAKERY_TMP_ROOT/bakery-env-edit-${domain}.XXXXXX")"
  mkdir -p "$dir"

  trap 'rm -f "${tmp:-}"' RETURN

  if [[ -f "$enc" ]]; then
    openssl enc -aes-256-cbc -pbkdf2 -d -in "$enc" -out "$tmp" -pass "file:$BAKERY_KEY_FILE"
  fi

  "${EDITOR:-vi}" "$tmp"

  openssl enc -aes-256-cbc -pbkdf2 -in "$tmp" -out "$enc" -pass "file:$BAKERY_KEY_FILE"
  chmod 600 "$enc"

  log "INFO" "Updated encrypted env for $domain"
}

cmd_env_get() {
  local domain="${1:-}"
  [[ -n "$domain" ]] || cli_usage "usage: bakery env get <domain>"

  local enc
  enc="$(env_enc_file "$domain")"
  [[ -f "$enc" ]] || cli_die "$CLI_EXIT_STATE" "No encrypted env file found for $domain"
  [[ -f "$BAKERY_KEY_FILE" ]] || cli_die "$CLI_EXIT_PREREQ" "Secrets key not found at $BAKERY_KEY_FILE"

  openssl enc -aes-256-cbc -pbkdf2 -d -in "$enc" -out /dev/stdout -pass "file:$BAKERY_KEY_FILE"
}

cmd_update() {
  load_config
  require_cmd git

  if [[ ! -d "$BAKERY_AGENT_DIR/.git" ]]; then
    mkdir -p "$BAKERY_ROOT"
    rm -rf "$BAKERY_AGENT_DIR"
    git clone --branch "$UPDATE_BRANCH" --single-branch "$UPDATE_REPO_URL" "$BAKERY_AGENT_DIR"
  fi

  git -C "$BAKERY_AGENT_DIR" remote set-url origin "$UPDATE_REPO_URL"
  git -C "$BAKERY_AGENT_DIR" fetch origin
  git -C "$BAKERY_AGENT_DIR" checkout "$UPDATE_BRANCH"
  git -C "$BAKERY_AGENT_DIR" pull --ff-only origin "$UPDATE_BRANCH"
  "$BAKERY_AGENT_DIR/install.sh" --update --source-dir "$BAKERY_AGENT_DIR"
}

cmd_daemon() {
  ensure_base_dirs
  local watchdog_enabled=0 watchdog_interval=30

  if [[ -n "${WATCHDOG_USEC:-}" && "${WATCHDOG_USEC:-0}" =~ ^[0-9]+$ ]] && (( WATCHDOG_USEC > 0 )); then
    watchdog_enabled=1
    watchdog_interval=$((WATCHDOG_USEC / 2000000))
    if (( watchdog_interval < 1 )); then
      watchdog_interval=1
    fi
  fi

  if command -v systemd-notify >/dev/null 2>&1; then
    systemd-notify --ready --status="bakery daemon ready" || true
  fi

  log "INFO" "bakery daemon started"
  while true; do
    sleep "$watchdog_interval"
    if (( watchdog_enabled )) && command -v systemd-notify >/dev/null 2>&1; then
      systemd-notify WATCHDOG=1 --status="bakery daemon heartbeat" || true
    fi
    log "INFO" "bakery daemon heartbeat"
  done
}
