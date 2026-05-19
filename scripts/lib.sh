#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_DIR="${REPO_DIR}/.sync-state"
ROUTER_MAP_CACHE="${STATE_DIR}/router-map.cache"
ROUTER_MAP_MAX_AGE="${ROUTER_MAP_MAX_AGE:-300}"

load_env() {
  local env_file="${REPO_DIR}/.env"
  if [[ -f "$env_file" ]]; then
    # shellcheck disable=SC1090
    set -a && source "$env_file" && set +a
  fi
}

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

refresh_router_map_cache() {
  mkdir -p "$STATE_DIR"
  router_ssh "show running-config" | awk '
    /^object-group fqdn / {
      if (group != "" && desc != "") print desc "\t" group
      group = $3
      desc = ""
      next
    }
    /^[[:space:]]+description / {
      line = $0
      sub(/^[[:space:]]+description /, "", line)
      if (line ~ /^".*"$/) {
        sub(/^"/, "", line)
        sub(/"$/, "", line)
      }
      desc = line
      next
    }
    END {
      if (group != "" && desc != "") print desc "\t" group
    }
  ' >"${ROUTER_MAP_CACHE}.tmp"
  mv "${ROUTER_MAP_CACHE}.tmp" "$ROUTER_MAP_CACHE"
}

router_map_cache_fresh() {
  [[ -f "$ROUTER_MAP_CACHE" ]] || return 1
  local now mtime age
  now=$(date +%s)
  if stat -f %m "$ROUTER_MAP_CACHE" >/dev/null 2>&1; then
    mtime=$(stat -f %m "$ROUTER_MAP_CACHE")
  else
    mtime=$(stat -c %Y "$ROUTER_MAP_CACHE")
  fi
  age=$((now - mtime))
  (( age < ROUTER_MAP_MAX_AGE ))
}

ensure_router_map_cache() {
  if router_map_cache_fresh; then
    return 0
  fi
  refresh_router_map_cache
}

invalidate_router_map_cache() {
  rm -f "$ROUTER_MAP_CACHE"
}

lookup_domain_list() {
  local description="$1"
  local group=""
  ensure_router_map_cache
  group="$(awk -F'\t' -v desc="$description" '$1 == desc { print $2; exit }' "$ROUTER_MAP_CACHE")"
  if [[ -z "$group" ]]; then
    refresh_router_map_cache
    group="$(awk -F'\t' -v desc="$description" '$1 == desc { print $2; exit }' "$ROUTER_MAP_CACHE")"
  fi
  if [[ -z "$group" ]]; then
    echo "error: on router no object-group with description: ${description}" >&2
    return 1
  fi
  printf '%s' "$group"
}

try_lookup_domain_list() {
  lookup_domain_list "$1" 2>/dev/null || true
}

list_used_domain_lists() {
  router_ssh "show running-config" | awk '/^object-group fqdn domain-list[0-9]+/ { print $3 }' | sort -u
}

find_next_free_domain_list() {
  local -a used=()
  local i g found
  mapfile -t used < <(list_used_domain_lists)
  for ((i = 0; i <= 99; i++)); do
    g="domain-list${i}"
    found=0
    for u in "${used[@]}"; do
      [[ "$u" == "$g" ]] && found=1 && break
    done
    if ((found == 0)); then
      printf '%s' "$g"
      return 0
    fi
  done
  echo "error: no free domain-list slot (0-99)" >&2
  return 1
}

get_dns_route_interface() {
  local group="$1"
  router_ssh "show running-config" \
    | awk -v g="$group" '$0 ~ ("route object-group " g " ") { print $4; exit }'
}

build_create_domain_list_commands() {
  local group="$1"
  local description="$2"
  local -n _domains="$3"
  local iface="${ROUTER_DNS_ROUTE_INTERFACE:-Wireguard0}"

  echo "object-group fqdn ${group}"
  format_description_command "$group" "$description"
  for domain in "${_domains[@]}"; do
    [[ -n "$domain" ]] || continue
    echo "object-group fqdn ${group} include ${domain}"
  done
  echo "dns-proxy route object-group ${group} ${iface} auto"
  echo "system configuration save"
}

build_delete_domain_list_commands() {
  local group="$1"
  local iface="$2"

  if [[ -n "$iface" ]]; then
    echo "no dns-proxy route object-group ${group} ${iface} auto"
  fi
  echo "no object-group fqdn ${group}"
  echo "system configuration save"
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

router_shell_ssh() {
  router_ssh "$@"
}

fetch_router_includes() {
  local group="$1"
  router_ssh "show running-config" \
    | awk -v g="$group" '
      $0 == "object-group fqdn " g { in_group = 1; next }
      in_group && /^object-group fqdn / { in_group = 0 }
      in_group && /^[[:space:]]+include / { print $2 }
    ' || true
}

format_description_command() {
  local group="$1"
  local description="$2"
  if [[ "$description" == *" "* ]]; then
    printf '%s\n' "object-group fqdn ${group} description \"${description}\""
  else
    printf '%s\n' "object-group fqdn ${group} description ${description}"
  fi
}

format_description_line() {
  local description="$1"
  if [[ "$description" == *" "* ]]; then
    printf '%s\n' "    description \"${description}\""
  else
    printf '%s\n' "    description ${description}"
  fi
}
build_router_commands() {
  local group="$1"
  local description="$2"
  local -n _remove="$3"
  local -n _add="$4"

  format_description_command "$group" "$description"
  for domain in "${_remove[@]}"; do
    [[ -n "$domain" ]] || continue
    echo "no object-group fqdn ${group} include ${domain}"
  done
  for domain in "${_add[@]}"; do
    [[ -n "$domain" ]] || continue
    echo "object-group fqdn ${group} include ${domain}"
  done
  echo "system configuration save"
}
