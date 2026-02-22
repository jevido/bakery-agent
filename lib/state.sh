#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

state_validate_file() {
  local file="$1"
  local expected_domain="${2:-}"

  [[ -f "$file" ]] || return 1

  jq -e --arg expected_domain "$expected_domain" '
    type == "object" and
    (.domain | type == "string" and length > 0) and
    (.repo | type == "string") and
    ((has("branch") | not) or (.branch | type == "string")) and
    (.container_id | type == "string") and
    (.image | type == "string") and
    (.port | type == "number") and
    (.status | type == "string") and
    (.expose | type == "boolean") and
    (.deployed_at | type == "string") and
    (.previous_container_id | type == "string") and
    ($expected_domain == "" or .domain == $expected_domain)
  ' "$file" >/dev/null
}

state_require_valid() {
  local domain="$1"
  local file
  file="$(state_file "$domain")"
  [[ -f "$file" ]] || cli_die "$CLI_EXIT_STATE" "No state found for $domain"
  state_validate_file "$file" "$domain" || cli_die "$CLI_EXIT_STATE" "Invalid state schema for $domain ($file)"
}

state_exists() {
  [[ -f "$(state_file "$1")" ]]
}

state_get() {
  local domain="$1"
  local key="$2"
  local file
  file="$(state_file "$domain")"
  [[ -f "$file" ]] || return 1
  state_validate_file "$file" "$domain" || return 1
  jq -er ".$key" "$file"
}

state_get_or_empty() {
  local domain="$1"
  local key="$2"
  state_get "$domain" "$key" 2>/dev/null || true
}

state_write_json() {
  local domain="$1"
  local json="$2"
  local dir tmp
  dir="$(domain_dir "$domain")"
  tmp="$(mktemp "$dir/state.XXXXXX")"
  printf '%s\n' "$json" > "$tmp"
  mv -f "$tmp" "$(state_file "$domain")"
}

state_write() {
  local domain="$1"
  local repo="$2"
  local container_id="$3"
  local image="$4"
  local port="$5"
  local status="$6"
  local expose="$7"
  local previous_container_id="$8"
  local branch="${9:-}"

  local dir
  dir="$(domain_dir "$domain")"
  mkdir -p "$dir"

  local json
  json="$(jq -n \
    --arg domain "$domain" \
    --arg repo "$repo" \
    --arg branch "$branch" \
    --arg container_id "$container_id" \
    --arg image "$image" \
    --argjson port "$port" \
    --arg status "$status" \
    --argjson expose "$expose" \
    --arg deployed_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg previous_container_id "$previous_container_id" \
    '{
      domain: $domain,
      repo: $repo,
      branch: $branch,
      container_id: $container_id,
      image: $image,
      port: $port,
      status: $status,
      expose: $expose,
      deployed_at: $deployed_at,
      previous_container_id: $previous_container_id
    }')"

  state_write_json "$domain" "$json"
}

state_update_status() {
  local domain="$1"
  local status="$2"
  local file json

  file="$(state_file "$domain")"
  [[ -f "$file" ]] || return 1
  state_validate_file "$file" "$domain" || return 1

  json="$(jq --arg status "$status" '.status = $status' "$file")"
  state_write_json "$domain" "$json"
}

state_list_files() {
  find "$BAKERY_APPS_DIR" -mindepth 2 -maxdepth 2 -name state.json 2>/dev/null | sort
}
