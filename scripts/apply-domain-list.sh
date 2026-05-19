#!/usr/bin/env bash
# Apply one list file to Keenetic router (run on router or anywhere with ROUTER_* in .env).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

load_env
require_cmd sshpass

usage() {
  echo "Usage: $0 <lists/some-list.txt>" >&2
  exit 1
}

[[ $# -eq 1 ]] || usage

LIST_FILE="$1"
if [[ ! -f "$LIST_FILE" ]]; then
  LIST_FILE="${REPO_DIR}/lists/$(basename "$LIST_FILE")"
fi
[[ -f "$LIST_FILE" ]] || { echo "error: file not found: $1" >&2; exit 1; }

DESCRIPTION="$(list_description "$LIST_FILE")"
STATE_FILE="${STATE_DIR}/${DESCRIPTION}.domains"

mkdir -p "$STATE_DIR"

mapfile -t NEW_DOMAINS < <(read_domains_from_file "$LIST_FILE")

GROUP="$(try_lookup_domain_list "$DESCRIPTION")"
if [[ -z "$GROUP" ]]; then
  GROUP="$(find_next_free_domain_list)"
  echo "create: ${DESCRIPTION} (${GROUP}) — ${#NEW_DOMAINS[@]} domains"
  build_create_domain_list_commands "$GROUP" "$DESCRIPTION" NEW_DOMAINS | router_ssh
  printf '%s\n' "${NEW_DOMAINS[@]}" >"$STATE_FILE"
  invalidate_router_map_cache
  echo "ok: ${DESCRIPTION} (${GROUP}) — created"
  exit 0
fi

OLD_DOMAINS=()
if [[ -f "$STATE_FILE" ]]; then
  mapfile -t OLD_DOMAINS < "$STATE_FILE"
elif ROUTER_INCLUDES="$(fetch_router_includes "$GROUP")" && [[ -n "$ROUTER_INCLUDES" ]]; then
  mapfile -t OLD_DOMAINS <<<"$ROUTER_INCLUDES"
fi

TO_REMOVE=()
TO_ADD=()

# Domains to remove: in old but not in new
for old in "${OLD_DOMAINS[@]}"; do
  [[ -n "$old" ]] || continue
  found=0
  for new in "${NEW_DOMAINS[@]}"; do
    if [[ "$old" == "$new" ]]; then
      found=1
      break
    fi
  done
  if ((found == 0)); then
    TO_REMOVE+=("$old")
  fi
done

# Domains to add: in new but not in old
for new in "${NEW_DOMAINS[@]}"; do
  [[ -n "$new" ]] || continue
  found=0
  for old in "${OLD_DOMAINS[@]}"; do
    if [[ "$new" == "$old" ]]; then
      found=1
      break
    fi
  done
  if ((found == 0)); then
    TO_ADD+=("$new")
  fi
done

if ((${#TO_REMOVE[@]} == 0 && ${#TO_ADD[@]} == 0)); then
  echo "ok: ${DESCRIPTION} (${GROUP}) — no changes"
  exit 0
fi

echo "apply: ${DESCRIPTION} (${GROUP}) — remove ${#TO_REMOVE[@]}, add ${#TO_ADD[@]}"

build_router_commands "$GROUP" "$DESCRIPTION" TO_REMOVE TO_ADD | router_ssh

printf '%s\n' "${NEW_DOMAINS[@]}" >"$STATE_FILE"
invalidate_router_map_cache
echo "ok: ${DESCRIPTION} (${GROUP}) — saved"
