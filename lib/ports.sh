#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

is_port_in_use() {
  local port="$1"
  ss -ltn "( sport = :$port )" 2>/dev/null | tail -n +2 | grep -q .
}

next_free_port() {
  local start="$1"
  local end="$2"
  local port

  for ((port=start; port<=end; port++)); do
    if is_port_in_use "$port"; then
      continue
    fi
    printf '%s\n' "$port"
    return 0
  done

  return 1
}
