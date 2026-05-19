#!/usr/bin/env bash
# Remove object-group and dns-proxy route for a deleted list file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

load_env
require_cmd sshpass

usage() {
  echo "Usage: $0 <lists/some-list.txt|some-list>" >&2
  exit 1
}

[[ $# -eq 1 ]] || usage

INPUT="$1"
DESCRIPTION="$(basename "$INPUT" .txt)"
STATE_FILE="${STATE_DIR}/${DESCRIPTION}.domains"

GROUP="$(try_lookup_domain_list "$DESCRIPTION")"
if [[ -z "$GROUP" ]]; then
  refresh_router_map_cache
  GROUP="$(try_lookup_domain_list "$DESCRIPTION")"
fi

if [[ -z "$GROUP" ]]; then
  echo "ok: ${DESCRIPTION} — not on router, nothing to delete"
  rm -f "$STATE_FILE"
  exit 0
fi

IFACE="$(get_dns_route_interface "$GROUP")"
echo "delete: ${DESCRIPTION} (${GROUP}) route=${IFACE:-none}"

build_delete_domain_list_commands "$GROUP" "$IFACE" | router_ssh

rm -f "$STATE_FILE"
invalidate_router_map_cache
echo "ok: ${DESCRIPTION} (${GROUP}) — deleted"
