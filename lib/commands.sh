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

print_usage() {
  cat <<'USAGE'
bakery - lightweight VPS deployment agent

Usage:
  bakery deploy <domain> [--repo <git-url>] [--branch <name>] [--cpu <cpus>] [--memory <limit>]
  bakery pat set
  bakery pat get
  bakery list
  bakery status <domain>
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
    podman ps -a --filter "id=$container_id"
  fi
}

cmd_logs() {
  local domain="${1:-}"
  [[ -n "$domain" ]] || cli_usage "usage: bakery logs <domain>"
  state_require_valid "$domain"

  local container_id
  container_id="$(state_get "$domain" container_id | tr -d '"')"
  [[ -n "$container_id" ]] || cli_die "$CLI_EXIT_STATE" "No container found for $domain"
  podman logs -f "$container_id"
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

  podman stop "$container_id"
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

  podman restart "$container_id"
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

  if [[ -d "$BAKERY_AGENT_DIR/.git" ]]; then
    git -C "$BAKERY_AGENT_DIR" fetch origin
    git -C "$BAKERY_AGENT_DIR" checkout "$UPDATE_BRANCH"
    git -C "$BAKERY_AGENT_DIR" pull --ff-only origin "$UPDATE_BRANCH"
    "$BAKERY_AGENT_DIR/install.sh" --update --source-dir "$BAKERY_AGENT_DIR"
    return 0
  fi

  cli_die "$CLI_EXIT_PREREQ" "Agent source not found at $BAKERY_AGENT_DIR; reinstall first"
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
