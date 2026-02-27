#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=lib/config.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/config.sh"
# shellcheck source=lib/state.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/state.sh"
# shellcheck source=lib/ports.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/ports.sh"

DEPLOY_LOG_FILE=""
DEPLOY_LOCK_FD=""

run_privileged() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
    return $?
  fi

  if command -v sudo >/dev/null 2>&1; then
    sudo -n "$@"
    return $?
  fi

  "$@"
  return $?
}

acquire_deploy_lock() {
  local domain="$1"
  local lock_file
  lock_file="$(domain_dir "$domain")/.deploy.lock"
  mkdir -p "$(dirname "$lock_file")"

  exec {DEPLOY_LOCK_FD}>"$lock_file"
  if ! flock -w "$DEPLOY_LOCK_TIMEOUT" "$DEPLOY_LOCK_FD"; then
    cli_die "$CLI_EXIT_RUNTIME" "Another deploy is in progress for $domain (lock file: $lock_file)"
  fi
}

release_deploy_lock() {
  if [[ -n "${DEPLOY_LOCK_FD:-}" ]]; then
    flock -u "$DEPLOY_LOCK_FD" >/dev/null 2>&1 || true
    eval "exec ${DEPLOY_LOCK_FD}>&-"
    DEPLOY_LOCK_FD=""
  fi
}

restore_previous_routing() {
  local domain="$1"
  local previous_expose="$2"
  local previous_port="$3"

  if [[ "${previous_expose:-false}" != "true" || "$previous_port" == "0" || "${NGINX_ENABLED:-1}" != "1" ]]; then
    return 0
  fi

  generate_nginx_conf "$domain" "$previous_port"
  if command -v nginx >/dev/null 2>&1; then
    nginx -t
    systemctl reload nginx || nginx -s reload || true
  fi
}

rollback_deploy() {
  local domain="$1"
  local repo="$2"
  local branch="$3"
  local failed_container_id="$4"
  local failed_image_id="$5"
  local failed_port="$6"
  local failed_expose="$7"
  local previous_container_id="$8"
  local previous_image="$9"
  local previous_port="${10}"
  local previous_expose="${11}"

  if [[ -z "$failed_container_id" ]]; then
    return 0
  fi

  log "WARN" "Rolling back failed deploy for $domain"

  if [[ -n "$previous_container_id" ]]; then
    if ! podman_exec ps --noheading --filter "id=$previous_container_id" | grep -q .; then
      podman_exec start "$previous_container_id" >/dev/null 2>&1 || true
    fi

    restore_previous_routing "$domain" "$previous_expose" "$previous_port"

    state_write "$domain" "$repo" "$previous_container_id" "$previous_image" "$previous_port" "running" "$previous_expose" "$failed_container_id" "$branch"
    log "WARN" "Rollback complete for $domain; previous container restored: $previous_container_id"
    return 0
  fi

  state_write "$domain" "$repo" "$failed_container_id" "$failed_image_id" "$failed_port" "failed" "$failed_expose" "" "$branch"
  log "WARN" "No previous container available for $domain; failed container retained for debugging"
}

run_deploy_cleanup() {
  local rc="$1"
  local domain="$2"
  local repo="$3"
  local branch="$4"
  local failed_container_id="$5"
  local failed_image_id="$6"
  local failed_port="$7"
  local failed_expose="$8"
  local previous_container_id="$9"
  local previous_image="${10}"
  local previous_port="${11}"
  local previous_expose="${12}"
  local clone_dir="${13}"
  local env_tmp="${14}"

  # RETURN traps are global for subsequent function returns in this shell;
  # clear it immediately so cleanup only runs once for this deploy call.
  trap - RETURN

  if [[ "$rc" -ne 0 ]]; then
    rollback_deploy "$domain" "$repo" "$branch" "$failed_container_id" "$failed_image_id" "$failed_port" "$failed_expose" "$previous_container_id" "$previous_image" "$previous_port" "$previous_expose" || \
      log "ERROR" "Rollback encountered errors for $domain"
  fi

  release_deploy_lock
  rm -rf "$clone_dir" "$env_tmp"
}

cleanup_old_images() {
  local domain="$1"
  local keep_count="$2"
  local -a image_ids
  local idx

  if ! [[ "$keep_count" =~ ^[0-9]+$ ]] || (( keep_count < 1 )); then
    keep_count=2
  fi

  mapfile -t image_ids < <(
    podman_exec image ls \
      --filter "label=bakery.managed=true" \
      --filter "label=bakery.domain=$domain" \
      --sort created \
      --format '{{.ID}}'
  )

  if (( ${#image_ids[@]} <= keep_count )); then
    return 0
  fi

  for ((idx=0; idx<${#image_ids[@]}-keep_count; idx++)); do
    podman_exec rmi "${image_ids[$idx]}" >/dev/null 2>&1 || true
  done
}

cleanup_old_domain_containers() {
  local domain="$1"
  local keep_container_id="$2"
  local -a container_ids
  local cid

  mapfile -t container_ids < <(
    podman_exec ps -a \
      --no-trunc \
      --filter "label=bakery.domain=$domain" \
      --format '{{.ID}}'
  )

  for cid in "${container_ids[@]:-}"; do
    [[ -n "$cid" ]] || continue
    # Keep the active container; podman output may vary between short/full IDs.
    if [[ "$cid" != "$keep_container_id" && "$keep_container_id" != "$cid"* && "$cid" != "$keep_container_id"* ]]; then
      podman_exec rm -f "$cid" >/dev/null 2>&1 || true
    fi
  done
}

detect_repo() {
  local domain="$1"
  local explicit_repo="${2:-}"
  if [[ -n "$explicit_repo" ]]; then
    printf '%s\n' "$explicit_repo"
    return 0
  fi

  local repo
  repo="$(state_get_or_empty "$domain" repo | tr -d '"')"
  if [[ -n "$repo" ]]; then
    printf '%s\n' "$repo"
    return 0
  fi

  if [[ -n "${BAKERY_REPO:-}" ]]; then
    printf '%s\n' "$BAKERY_REPO"
    return 0
  fi

  die "No repo configured for $domain. Pass --repo <git-url> or set BAKERY_REPO"
}

is_github_https_repo() {
  local repo="$1"
  [[ "$repo" =~ ^https://github\.com/[^[:space:]]+\.git$ ]]
}

read_github_pat() {
  [[ -f "$BAKERY_GITHUB_PAT_FILE" ]] || return 1
  openssl enc -aes-256-cbc -pbkdf2 -d -in "$BAKERY_GITHUB_PAT_FILE" -out /dev/stdout -pass "file:$BAKERY_KEY_FILE" 2>/dev/null || return 1
}

clone_repo() {
  local domain="$1"
  local repo="$2"
  local branch="$3"
  local clone_dir="$4"
  local pat askpass_script had_xtrace=0

  if is_github_https_repo "$repo"; then
    pat="$(read_github_pat | tr -d '\r\n' || true)"
    if [[ -n "$pat" ]]; then
      askpass_script="$(mktemp "$BAKERY_TMP_ROOT/bakery-askpass-${domain}.XXXXXX")"
      cat > "$askpass_script" <<'ASKPASS'
#!/usr/bin/env bash
case "$1" in
  *Username*|*username*) printf '%s\n' "x-access-token" ;;
  *Password*|*password*) printf '%s\n' "${BAKERY_GIT_PAT:-}" ;;
  *) printf '\n' ;;
esac
ASKPASS
      chmod 700 "$askpass_script"

      case "$-" in
        *x*) had_xtrace=1; set +x ;;
      esac
      GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="$askpass_script" BAKERY_GIT_PAT="$pat" git clone --depth=1 --branch "$branch" --single-branch "$repo" "$clone_dir"
      local rc=$?
      [[ "$had_xtrace" -eq 1 ]] && set -x

      rm -f "$askpass_script"
      if [[ "$rc" -eq 0 ]]; then
        return 0
      fi
      die "Failed to clone $repo with stored GitHub PAT; verify PAT permissions and repo access"
    fi
  fi

  if ! git clone --depth=1 --branch "$branch" --single-branch "$repo" "$clone_dir"; then
    if is_github_https_repo "$repo"; then
      die "Failed to clone $repo. For private repos, store a PAT first: bakery pat set"
    fi
    die "Failed to clone repository: $repo"
  fi
}

load_domain_resource_config() {
  local domain="$1"
  local conf
  conf="$(app_conf_file "$domain")"

  DOMAIN_CPU_LIMIT=""
  DOMAIN_MEMORY_LIMIT=""

  if [[ -f "$conf" ]]; then
    local CPU_LIMIT="" MEMORY_LIMIT=""
    # shellcheck source=/dev/null
    source "$conf"
    DOMAIN_CPU_LIMIT="${CPU_LIMIT:-}"
    DOMAIN_MEMORY_LIMIT="${MEMORY_LIMIT:-}"
  fi
}

resolve_resource_limits() {
  local domain="$1"
  local cpu_override="${2:-}"
  local memory_override="${3:-}"

  load_domain_resource_config "$domain"

  EFFECTIVE_CPU_LIMIT="${cpu_override:-${DOMAIN_CPU_LIMIT:-${DEFAULT_CPU_LIMIT:-}}}"
  EFFECTIVE_MEMORY_LIMIT="${memory_override:-${DOMAIN_MEMORY_LIMIT:-${DEFAULT_MEMORY_LIMIT:-}}}"

  if [[ -n "$EFFECTIVE_CPU_LIMIT" ]] && [[ ! "$EFFECTIVE_CPU_LIMIT" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    cli_usage "invalid cpu limit: $EFFECTIVE_CPU_LIMIT (expected numeric value, e.g. 0.5 or 2)"
  fi

  if [[ -n "$EFFECTIVE_MEMORY_LIMIT" ]] && [[ ! "$EFFECTIVE_MEMORY_LIMIT" =~ ^[0-9]+([kKmMgGtTpP]([iI][bB]?)?|[bB])?$ ]]; then
    cli_usage "invalid memory limit: $EFFECTIVE_MEMORY_LIMIT (examples: 256m, 1g, 512MiB)"
  fi
}

deploy_log_setup() {
  local domain="$1"
  mkdir -p "$BAKERY_DEPLOY_LOG_DIR"
  DEPLOY_LOG_FILE="$BAKERY_DEPLOY_LOG_DIR/${domain}-$(date -u +"%Y%m%dT%H%M%SZ").log"
  touch "$DEPLOY_LOG_FILE"
}

run_stage() {
  local stage="$1"
  shift
  log "INFO" "[$stage] $*"
}

get_exposed_ports() {
  local image="$1"
  podman_exec image inspect "$image" | jq -r '
    .[0].Config.ExposedPorts // {}
    | keys
    | map(select(test("^[0-9]+/(tcp|udp)$")))
    | sort_by((split("/")[0] | tonumber), (split("/")[1]))
    | .[]
  '
}

select_primary_container_port() {
  local -a exposed_specs=("$@")
  local spec preferred
  local -a preferred_ports=(80 8080 3000 5000 5173)

  for preferred in "${preferred_ports[@]}"; do
    for spec in "${exposed_specs[@]}"; do
      if [[ "$spec" == "$preferred/tcp" ]]; then
        printf '%s\n' "$preferred"
        return 0
      fi
    done
  done

  for spec in "${exposed_specs[@]}"; do
    if [[ "$spec" == */tcp ]]; then
      printf '%s\n' "${spec%/*}"
      return 0
    fi
  done

  return 1
}

generate_nginx_conf() {
  local domain="$1"
  shift
  local -a routes=("$@")
  local app_conf
  app_conf="$(nginx_app_conf_file "$domain")"

  {
    cat <<CFG
server {
    listen 80;
    listen [::]:80;
    server_name $domain;
CFG
    local route path port
    for route in "${routes[@]}"; do
      path="${route%%|*}"
      port="${route##*|}"
      cat <<CFG
    location $path {
        proxy_pass http://127.0.0.1:$port;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }
CFG
    done
    printf '}\n'
  } > "$app_conf"

  if [[ -d "$NGINX_SITES_AVAILABLE" && -d "$NGINX_SITES_ENABLED" ]]; then
    run_privileged cp "$app_conf" "$NGINX_SITES_AVAILABLE/$domain.conf" || \
      die "Failed to write nginx site config. Ensure bakery can sudo cp (or run deploy as root)."
    run_privileged ln -sfn "$NGINX_SITES_AVAILABLE/$domain.conf" "$NGINX_SITES_ENABLED/$domain.conf" || \
      die "Failed to link nginx site config. Ensure bakery can sudo ln (or run deploy as root)."
  fi
}

setup_ssl() {
  local domain="$1"
  if [[ "$CERTBOT_ENABLED" != "1" ]]; then
    log "INFO" "SSL provisioning disabled by config"
    return 0
  fi

  if ! command -v certbot >/dev/null 2>&1; then
    log "WARN" "certbot not installed; skipping SSL provisioning"
    return 0
  fi

  if [[ -n "$CERTBOT_EMAIL" ]]; then
    run_privileged certbot --nginx -d "$domain" --non-interactive --agree-tos -m "$CERTBOT_EMAIL" || {
      log "WARN" "Certbot failed for $domain. Confirm DNS A/AAAA record points to this VPS and retry deploy."
    }
  else
    run_privileged certbot --nginx -d "$domain" --non-interactive --agree-tos --register-unsafely-without-email || {
      log "WARN" "Certbot failed for $domain. Set CERTBOT_EMAIL and confirm DNS points to this VPS."
    }
  fi
}

decrypt_env_to_file() {
  local domain="$1"
  local out_file="$2"
  local enc_file
  enc_file="$(env_enc_file "$domain")"

  if [[ -f "$enc_file" ]]; then
    openssl enc -aes-256-cbc -pbkdf2 -d -in "$enc_file" -out "$out_file" -pass "file:$BAKERY_KEY_FILE"
  else
    : > "$out_file"
  fi
}

health_check() {
  local domain="$1"
  local expose="$2"
  local port="$3"
  local container_id="$4"
  local custom_forwarding="${5:-false}"
  local attempts=0

  if [[ "$expose" == "true" && "$custom_forwarding" != "true" ]]; then
    while (( attempts < DEPLOY_HEALTH_RETRIES )); do
      if curl -fsS "http://127.0.0.1:$port/" >/dev/null 2>&1; then
        return 0
      fi
      attempts=$((attempts + 1))
      sleep "$DEPLOY_HEALTH_INTERVAL"
    done
    log "ERROR" "Health check failed for web app $domain on port $port"
    return 1
  fi

  sleep 10
  if podman_exec ps --noheading --filter "id=$container_id" | grep -q .; then
    return 0
  fi

  log "ERROR" "Container for $domain exited during non-web health check"
  return 1
}

verify_nginx_cutover() {
  local domain="$1"
  local attempts=0

  while (( attempts < DEPLOY_HEALTH_RETRIES )); do
    if curl -kfsS --resolve "$domain:443:127.0.0.1" "https://$domain/" >/dev/null 2>&1; then
      return 0
    fi
    if curl -fsS -H "Host: $domain" "http://127.0.0.1/" >/dev/null 2>&1; then
      return 0
    fi
    attempts=$((attempts + 1))
    sleep "$DEPLOY_HEALTH_INTERVAL"
  done

  log "ERROR" "Nginx cutover verification failed for $domain"
  return 1
}

ensure_container_persisted() {
  local domain="$1"
  local container_id="$2"

  if ! podman_exec container exists "$container_id" >/dev/null 2>&1; then
    die "Container missing before finalize for $domain (container_id=$container_id)"
  fi
}

run_deploy() {
  local domain="$1"
  shift

  load_config
  ensure_base_dirs

  if [[ "$(id -un)" != "bakery" ]]; then
    cli_die "$CLI_EXIT_PREREQ" "Deploy must run as bakery user (not root)"
  fi

  require_cmd git
  require_cmd jq
  require_cmd podman
  require_cmd openssl
  require_cmd flock
  podman_rootless_preflight

  local repo_override="" branch_override="" cpu_override="" memory_override=""
  local -a forward_specs=()
  while (($#)); do
    case "$1" in
      --repo)
        shift
        [[ $# -gt 0 ]] || die "Missing value for --repo"
        repo_override="$1"
        ;;
      --branch)
        shift
        [[ $# -gt 0 ]] || cli_usage "usage: bakery deploy <domain> [--repo <git-url>] [--branch <name>] [--cpu <cpus>] [--memory <limit>] [--forward <port>|<path:port>]"
        branch_override="$1"
        ;;
      --cpu)
        shift
        [[ $# -gt 0 ]] || cli_usage "usage: bakery deploy <domain> [--repo <git-url>] [--branch <name>] [--cpu <cpus>] [--memory <limit>] [--forward <port>|<path:port>]"
        cpu_override="$1"
        ;;
      --memory)
        shift
        [[ $# -gt 0 ]] || cli_usage "usage: bakery deploy <domain> [--repo <git-url>] [--branch <name>] [--cpu <cpus>] [--memory <limit>] [--forward <port>|<path:port>]"
        memory_override="$1"
        ;;
      --forward)
        shift
        [[ $# -gt 0 ]] || cli_usage "usage: bakery deploy <domain> [--repo <git-url>] [--branch <name>] [--cpu <cpus>] [--memory <limit>] [--forward <port>|<path:port>]"
        forward_specs+=("$1")
        ;;
      *)
        cli_usage "unknown deploy option: $1"
        ;;
    esac
    shift
  done

  local repo branch
  repo="$(detect_repo "$domain" "$repo_override")"
  branch="$(state_get_or_empty "$domain" branch | tr -d '"')"
  branch="${branch_override:-${branch:-${BAKERY_BRANCH:-main}}}"
  [[ -n "$branch" ]] || branch="main"

  deploy_log_setup "$domain"
  exec > >(tee -a "$DEPLOY_LOG_FILE") 2>&1

  acquire_deploy_lock "$domain"
  run_stage "0" "Acquired deploy lock for $domain"
  run_stage "0" "PUSH trigger acknowledged for $domain"

  local app_dir clone_dir image_name image_id expose port container_port env_tmp container_name container_id custom_forwarding
  local primary_container_port next_port host_port bind_addr spec protocol
  local effective_cpu_limit effective_memory_limit
  local -a common_run_args exposed_specs publish_args published_pairs nginx_routes
  local -A reserved_ports
  local previous_container_id previous_repo previous_branch previous_image previous_port previous_expose state_repo state_branch
  app_dir="$(domain_dir "$domain")"
  clone_dir="$(mktemp -d "$BAKERY_TMP_ROOT/bakery-src-${domain}.XXXXXX")"
  image_name="bakery/$domain:latest"
  image_id=""
  expose="false"
  port=0
  container_port=""
  env_tmp="$(mktemp "$BAKERY_TMP_ROOT/bakery-env-${domain}.XXXXXX")"
  container_name="bakery-$(echo "$domain" | tr '.' '-')-$(date +%s)"
  container_id=""
  custom_forwarding="false"
  nginx_routes=()

  # Podman is executed as the rootless bakery user; ensure staged files are readable there.
  if [[ "$(id -u)" -eq 0 ]] && id bakery >/dev/null 2>&1; then
    chown -R bakery:bakery "$clone_dir" >/dev/null 2>&1 || true
  fi

  previous_container_id="$(state_get_or_empty "$domain" container_id | tr -d '"')"
  previous_repo="$(state_get_or_empty "$domain" repo | tr -d '"')"
  previous_branch="$(state_get_or_empty "$domain" branch | tr -d '"')"
  previous_image="$(state_get_or_empty "$domain" image | tr -d '"')"
  previous_port="$(state_get_or_empty "$domain" port | tr -d '"')"
  previous_expose="$(state_get_or_empty "$domain" expose | tr -d '"')"
  state_repo="${repo_override:-${previous_repo:-$repo}}"
  state_branch="${branch_override:-${previous_branch:-$branch}}"

  [[ -n "$previous_port" ]] || previous_port=0
  [[ "$previous_expose" == "true" || "$previous_expose" == "false" ]] || previous_expose="false"
  resolve_resource_limits "$domain" "$cpu_override" "$memory_override"
  effective_cpu_limit="$EFFECTIVE_CPU_LIMIT"
  effective_memory_limit="$EFFECTIVE_MEMORY_LIMIT"

  trap 'run_deploy_cleanup $? "${domain:-}" "${state_repo:-}" "${state_branch:-}" "${container_id:-}" "${image_id:-}" "${port:-0}" "${expose:-false}" "${previous_container_id:-}" "${previous_image:-}" "${previous_port:-0}" "${previous_expose:-false}" "${clone_dir:-}" "${env_tmp:-}"' RETURN

  run_stage "1" "Cloning $repo (branch=$branch)"
  clone_repo "$domain" "$repo" "$branch" "$clone_dir"
  if [[ "$(id -u)" -eq 0 ]] && id bakery >/dev/null 2>&1; then
    chown -R bakery:bakery "$clone_dir" >/dev/null 2>&1 || true
  fi
  if [[ ! -f "$clone_dir/Dockerfile" && ! -f "$clone_dir/Containerfile" ]]; then
    die "No Dockerfile or Containerfile found in repository"
  fi

  run_stage "2" "Building image $image_name"
  podman_exec build \
    --label "bakery.managed=true" \
    --label "bakery.domain=$domain" \
    -t "$image_name" \
    "$clone_dir"
  image_id="$(podman_exec image inspect --format '{{.Id}}' "$image_name")"

  run_stage "3" "Cleaning cloned source"
  rm -rf "$clone_dir"

  run_stage "4" "Running container"
  mapfile -t exposed_specs < <(get_exposed_ports "$image_name")
  expose="false"
  port=0
  container_port=""
  publish_args=()
  published_pairs=()

  decrypt_env_to_file "$domain" "$env_tmp"
  if [[ "$(id -u)" -eq 0 ]] && id bakery >/dev/null 2>&1; then
    chown bakery:bakery "$env_tmp" >/dev/null 2>&1 || true
    chmod 600 "$env_tmp" >/dev/null 2>&1 || true
  fi
  common_run_args=(
    -d
    --restart unless-stopped
    --name "$container_name"
    --label "bakery.domain=$domain"
    --label "bakery.managed=true"
    --env-file "$env_tmp"
  )
  if [[ -n "$effective_cpu_limit" ]]; then
    common_run_args+=(--cpus "$effective_cpu_limit")
  fi
  if [[ -n "$effective_memory_limit" ]]; then
    common_run_args+=(--memory "$effective_memory_limit")
  fi

  if [[ -n "$effective_cpu_limit" || -n "$effective_memory_limit" ]]; then
    run_stage "4" "Applying resource limits cpu=${effective_cpu_limit:-none} memory=${effective_memory_limit:-none}"
  fi

  if ((${#exposed_specs[@]} > 0)); then
    primary_container_port="$(select_primary_container_port "${exposed_specs[@]}" || true)"
    next_port="$PORT_RANGE_START"

    for spec in "${exposed_specs[@]}"; do
      container_port="${spec%/*}"
      protocol="${spec#*/}"
      host_port=""

      while (( next_port <= PORT_RANGE_END )); do
        if [[ -n "${reserved_ports[$next_port]:-}" ]] || is_port_in_use "$next_port"; then
          next_port=$((next_port + 1))
          continue
        fi
        host_port="$next_port"
        reserved_ports["$host_port"]=1
        next_port=$((next_port + 1))
        break
      done

      [[ -n "$host_port" ]] || die "No free port available in configured range for ${container_port}/${protocol}"

      bind_addr="0.0.0.0"
      if [[ -n "$primary_container_port" && "$protocol" == "tcp" && "$container_port" == "$primary_container_port" ]]; then
        bind_addr="127.0.0.1"
        port="$host_port"
        expose="true"
      fi

      publish_args+=(-p "${bind_addr}:${host_port}:${container_port}/${protocol}")
      published_pairs+=("${container_port}/${protocol}->${bind_addr}:${host_port}")
    done
  fi

  container_id="$(podman_exec run "${common_run_args[@]}" "${publish_args[@]}" "$image_name")"

  if [[ "${#published_pairs[@]}" -gt 0 ]]; then
    run_stage "4" "Published ports: ${published_pairs[*]}"
  fi

  mkdir -p "$app_dir"
  state_write "$domain" "$state_repo" "$container_id" "$image_id" "$port" "starting" "$expose" "$previous_container_id" "$state_branch"

  if [[ "$expose" == "true" && "${#nginx_routes[@]}" -eq 0 ]]; then
    nginx_routes+=("/|$port")
  fi

  run_stage "5" "Health checking"
  if ! health_check "$domain" "$expose" "$port" "$container_id" "$custom_forwarding"; then
    die "Deployment failed health checks; failed container left running for debugging"
  fi

  if [[ "$expose" == "true" && "$NGINX_ENABLED" == "1" ]]; then
    run_stage "6" "Configuring nginx + SSL"
    generate_nginx_conf "$domain" "${nginx_routes[@]}"
    if command -v nginx >/dev/null 2>&1; then
      run_privileged nginx -t || die "Failed nginx config test; ensure bakery can sudo nginx (or run deploy as root)."
      run_privileged systemctl reload nginx || run_privileged nginx -s reload || true
    fi
    setup_ssl "$domain"
    if [[ "$custom_forwarding" == "true" ]]; then
      run_stage "6" "Skipping nginx cutover probe for custom forwarded routes"
    else
      run_stage "6" "Verifying nginx cutover"
      verify_nginx_cutover "$domain" || die "Nginx cutover failed; previous container kept running"
    fi
  else
    run_stage "6" "Skipping routing (no EXPOSE or nginx disabled)"
  fi

  ensure_container_persisted "$domain" "$container_id"

  run_stage "7" "Marking success"
  state_write "$domain" "$state_repo" "$container_id" "$image_id" "$port" "running" "$expose" "$previous_container_id" "$state_branch"

  cleanup_old_domain_containers "$domain" "$container_id"

  run_stage "7" "Applying image cleanup policy (keep latest ${IMAGE_RETENTION_COUNT})"
  cleanup_old_images "$domain" "$IMAGE_RETENTION_COUNT"

  log "INFO" "Deployment successful for $domain (container=$container_id image=$image_id)"
}
