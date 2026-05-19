#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_DIR="${REPO_DIR}/.sync-state"

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "error: required command not found: $cmd" >&2
    exit 1
  }
}

list_description() {
  local list_file="$1"
  basename "$list_file" .txt
}

read_domains_from_file() {
  local list_file="$1"
  grep -v '^[[:space:]]*#' "$list_file" | grep -v '^[[:space:]]*$' | sed 's/[[:space:]]*$//' || true
}

router_ssh() {
  require_cmd sshpass
  export SSHPASS="${ROUTER_PASSWORD:?ROUTER_PASSWORD is not set}"
  if (($# > 0)); then
    sshpass -e ssh \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=15 \
      "${ROUTER_USER:-admin}@${ROUTER_HOST:?ROUTER_HOST is not set}" "$@"
  else
    local line
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      sshpass -e ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 \
        "${ROUTER_USER:-admin}@${ROUTER_HOST:?ROUTER_HOST is not set}" "$line"
    done
  fi
}
