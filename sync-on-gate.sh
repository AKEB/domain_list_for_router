#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="/root/domain_list_for_router"
cd "$REPO_DIR"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"

GIT_REMOTE="${GIT_REMOTE:-origin}"
GIT_BRANCH="${GIT_BRANCH:-main}"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
ROUTER_COMMAND_DELAY="${ROUTER_COMMAND_DELAY:-0.1}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

changed_list_files() {
  local from="$1" to="$2"
  git diff --name-only --diff-filter=ACMR "$from" "$to" -- lists/ | grep '\.txt$' || true
}

deleted_list_files() {
  local from="$1" to="$2"
  git diff --name-only --diff-filter=D "$from" "$to" -- lists/ | grep '\.txt$' || true
}

load_router_snapshot() {
  local config_file="$1"
  local records_file="$2"
  log "load router running-config once"
  router_ssh "show running-config" >"$config_file"
  awk '
    /^object-group fqdn / {
      group = $3
      print "GROUP\t" group "\t"
      next
    }
    group != "" && /^[[:space:]]+description / {
      line = $0
      sub(/^[[:space:]]+description /, "", line)
      if (line ~ /^".*"$/) {
        sub(/^"/, "", line)
        sub(/"$/, "", line)
      }
      print "DESC\t" group "\t" line
      next
    }
    group != "" && /^[[:space:]]+include / {
      print "INCLUDE\t" group "\t" $2
      next
    }
    /^[^[:space:]]/ && $1 != "object-group" {
      group = ""
    }
    /^[[:space:]]+route object-group / {
      print "ROUTE\t" $3 "\t" $4
      next
    }
  ' "$config_file" >"$records_file"
}

load_router_indexes() {
  local records_file="$1"
  local includes_dir="$2"
  local type group value

  declare -gA DESC_TO_GROUP=()
  declare -gA GROUP_TO_DESC=()
  declare -gA GROUP_ROUTE=()
  declare -gA USED_GROUP=()
  declare -g ROUTER_GROUP_COUNT=0

  mkdir -p "$includes_dir"
  while IFS=$'\t' read -r type group value; do
    [[ -n "${type:-}" && -n "${group:-}" ]] || continue
    case "$type" in
      GROUP)
        USED_GROUP["$group"]=1
        ROUTER_GROUP_COUNT=$((ROUTER_GROUP_COUNT + 1))
        ;;
      DESC)
        DESC_TO_GROUP["$value"]="$group"
        GROUP_TO_DESC["$group"]="$value"
        USED_GROUP["$group"]=1
        ;;
      INCLUDE)
        USED_GROUP["$group"]=1
        printf '%s\n' "$value" >>"$includes_dir/$group"
        ;;
      ROUTE)
        GROUP_ROUTE["$group"]="$value"
        USED_GROUP["$group"]=1
        ;;
    esac
  done <"$records_file"

  local file
  for file in "$includes_dir"/*; do
    [[ -f "$file" ]] || continue
    sort -u "$file" -o "$file"
  done

  log "router snapshot: ${ROUTER_GROUP_COUNT} object groups, ${#DESC_TO_GROUP[@]} descriptions"
}

next_free_group_from_snapshot() {
  local i group
  for ((i = 0; i <= 99; i++)); do
    group="domain-list${i}"
    if [[ -z "${USED_GROUP[$group]:-}" ]]; then
      USED_GROUP["$group"]=1
      printf '%s' "$group"
      return 0
    fi
  done
  echo "error: no free domain-list slot (0-99)" >&2
  return 1
}

description_command() {
  local group="$1"
  local description="$2"
  if [[ "$description" == *" "* ]]; then
    printf '%s\n' "object-group fqdn ${group} description \"${description}\""
  else
    printf '%s\n' "object-group fqdn ${group} description ${description}"
  fi
}

write_list_state() {
  local rel="$1"
  local state_file
  mkdir -p "$STATE_DIR"
  state_file="${STATE_DIR}/$(list_description "$rel").domains"
  read_domains_from_file "$REPO_DIR/$rel" | sort -u >"$state_file"
}

normalize_domains_for_compare() {
  sed -E 's#^([0-9]{1,3}(\.[0-9]{1,3}){3})/32$#\1#'
}

build_batch_commands() {
  local commands_file="$1"
  local includes_dir="$2"
  shift 2
  local -a files=()
  local -a deleted=()
  local mode rel description group iface
  local new_file old_file add_file remove_file domain

  while (($# > 0)); do
    case "$1" in
      --files)
        mode="files"
        ;;
      --deleted)
        mode="deleted"
        ;;
      *)
        if [[ "$mode" == "files" ]]; then
          files+=("$1")
        elif [[ "$mode" == "deleted" ]]; then
          deleted+=("$1")
        else
          echo "error: internal build_batch_commands mode missing" >&2
          return 1
        fi
        ;;
    esac
    shift
  done

  : >"$commands_file"

  for rel in "${deleted[@]}"; do
    [[ -n "$rel" ]] || continue
    description="$(basename "$rel" .txt)"
    group="${DESC_TO_GROUP[$description]:-}"
    if [[ -z "$group" ]]; then
      log "delete ${rel}: not on router"
      rm -f "${STATE_DIR}/${description}.domains"
      continue
    fi
    iface="${GROUP_ROUTE[$group]:-}"
    log "delete ${rel}: ${group}"
    if [[ -n "$iface" ]]; then
      printf '%s\n' "dns-proxy no route object-group ${group} ${iface} auto" >>"$commands_file"
    fi
    printf '%s\n' "no object-group fqdn ${group}" >>"$commands_file"
    rm -f "${STATE_DIR}/${description}.domains"
  done

  for rel in "${files[@]}"; do
    [[ -n "$rel" ]] || continue
    description="$(list_description "$rel")"
    group="${DESC_TO_GROUP[$description]:-}"
    new_file="$(mktemp)"
    old_file="$(mktemp)"
    add_file="$(mktemp)"
    remove_file="$(mktemp)"
    read_domains_from_file "$REPO_DIR/$rel" | normalize_domains_for_compare | sort -u >"$new_file"

    if [[ -z "$group" ]]; then
      group="$(next_free_group_from_snapshot)"
      DESC_TO_GROUP["$description"]="$group"
      GROUP_TO_DESC["$group"]="$description"
      log "create ${rel}: ${group} ($(wc -l <"$new_file") domains)"
      printf '%s\n' "object-group fqdn ${group}" >>"$commands_file"
      description_command "$group" "$description" >>"$commands_file"
      while IFS= read -r domain; do
        [[ -n "$domain" ]] || continue
        printf '%s\n' "object-group fqdn ${group} include ${domain}" >>"$commands_file"
      done <"$new_file"
      printf '%s\n' "dns-proxy route object-group ${group} ${ROUTER_DNS_ROUTE_INTERFACE:-Wireguard0} auto" >>"$commands_file"
      cp "$new_file" "$includes_dir/$group"
      write_list_state "$rel"
      rm -f "$new_file" "$old_file" "$add_file" "$remove_file"
      continue
    fi

    if [[ -f "$includes_dir/$group" ]]; then
      normalize_domains_for_compare <"$includes_dir/$group" | sort -u >"$old_file"
    else
      : >"$old_file"
    fi

    comm -23 "$old_file" "$new_file" >"$remove_file"
    comm -13 "$old_file" "$new_file" >"$add_file"

    if [[ ! -s "$remove_file" && ! -s "$add_file" ]]; then
      log "apply ${rel}: ${group} no changes"
      write_list_state "$rel"
      rm -f "$new_file" "$old_file" "$add_file" "$remove_file"
      continue
    fi

    log "apply ${rel}: ${group} remove $(wc -l <"$remove_file"), add $(wc -l <"$add_file")"
    while IFS= read -r domain; do
      [[ -n "$domain" ]] || continue
      printf '%s\n' "object-group fqdn ${group} no include ${domain}" >>"$commands_file"
    done <"$remove_file"
    while IFS= read -r domain; do
      [[ -n "$domain" ]] || continue
      printf '%s\n' "object-group fqdn ${group} include ${domain}" >>"$commands_file"
    done <"$add_file"
    cp "$new_file" "$includes_dir/$group"
    write_list_state "$rel"
    rm -f "$new_file" "$old_file" "$add_file" "$remove_file"
  done
}

execute_batch_commands() {
  local commands_file="$1"
  local count line
  if [[ ! -s "$commands_file" ]]; then
    log "router commands: 0"
    return 0
  fi

  count="$(wc -l <"$commands_file")"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log "router commands: ${count} + save (dry-run)"
    sed -n '1,120p' "$commands_file"
    return 0
  fi

  log "router commands: ${count} + save"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    router_ssh "$line" < /dev/null
    sleep "$ROUTER_COMMAND_DELAY"
  done <"$commands_file"
  router_ssh "system configuration save" >/dev/null
  invalidate_router_map_cache
}

apply_batch() {
  local -a files=("$@")
  local -a changed=()
  local -a deleted=()
  local tmpdir config_file records_file commands_file includes_dir rel

  while ((${#files[@]} > 0)); do
    rel="${files[0]}"
    files=("${files[@]:1}")
    case "$rel" in
      --deleted)
        while ((${#files[@]} > 0)); do
          deleted+=("${files[0]}")
          files=("${files[@]:1}")
        done
        ;;
      *)
        changed+=("$rel")
        ;;
    esac
  done

  if ((${#changed[@]} == 0 && ${#deleted[@]} == 0)); then
    return 0
  fi

  tmpdir="$(mktemp -d)"
  config_file="$tmpdir/running-config"
  records_file="$tmpdir/router-records.tsv"
  commands_file="$tmpdir/router-commands.txt"
  includes_dir="$tmpdir/includes"

  load_router_snapshot "$config_file" "$records_file"
  load_router_indexes "$records_file" "$includes_dir"
  if ((${#changed[@]} > 0 && ROUTER_GROUP_COUNT == 0)); then
    echo "error: router snapshot has no object groups; refusing to build commands" >&2
    rm -rf "$tmpdir"
    return 1
  fi
  build_batch_commands "$commands_file" "$includes_dir" --files "${changed[@]}" --deleted "${deleted[@]}"
  execute_batch_commands "$commands_file"
  rm -rf "$tmpdir"
}

run_once() {
  local old_head new_remote_head new_head
  local -a files=() deleted=()
  old_head="$(git rev-parse HEAD)"
  git fetch "$GIT_REMOTE" "$GIT_BRANCH" --quiet
  new_remote_head="$(git rev-parse "$GIT_REMOTE/$GIT_BRANCH")"

  if [[ "$old_head" == "$new_remote_head" ]]; then
    log "no git updates"
    return 0
  fi

  mapfile -t files < <(changed_list_files "$old_head" "$new_remote_head")
  mapfile -t deleted < <(deleted_list_files "$old_head" "$new_remote_head")

  if ((${#files[@]} == 0 && ${#deleted[@]} == 0)); then
    git merge --ff-only "$GIT_REMOTE/$GIT_BRANCH"
    log "git updated: ${old_head:0:7} -> ${new_remote_head:0:7}, no list changes — skip router"
    return 0
  fi

  git merge --ff-only "$GIT_REMOTE/$GIT_BRANCH"
  new_head="$(git rev-parse HEAD)"
  log "updated: ${old_head:0:7} -> ${new_head:0:7}, lists: ${#files[@]} changed, ${#deleted[@]} deleted"
  apply_batch "${files[@]}" --deleted "${deleted[@]}"
}

bootstrap_all() {
  local -a files=()
  mapfile -t files < <(find lists -maxdepth 1 -type f -name "*.txt" | sort)
  apply_batch "${files[@]}"
}

case "${1:-watch}" in
  once)
    run_once
    ;;
  bootstrap-all)
    bootstrap_all
    ;;
  watch)
    log "watching ${GIT_REMOTE}/${GIT_BRANCH} every ${CHECK_INTERVAL}s via gate"
    while true; do
      run_once || true
      sleep "$CHECK_INTERVAL"
    done
    ;;
  *)
    echo "Usage: $0 [once|watch|bootstrap-all]" >&2
    exit 1
    ;;
esac
