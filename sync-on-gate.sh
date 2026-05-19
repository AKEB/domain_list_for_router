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

GIT_REMOTE="${GIT_REMOTE:-origin}"
GIT_BRANCH="${GIT_BRANCH:-main}"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"

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

process_changes() {
  local old_head="$1" new_head="$2"
  local -a files=() deleted=()
  mapfile -t files < <(changed_list_files "$old_head" "$new_head")
  mapfile -t deleted < <(deleted_list_files "$old_head" "$new_head")

  if ((${#files[@]} == 0 && ${#deleted[@]} == 0)); then
    log "no list changes"
    return 0
  fi

  for rel in "${deleted[@]}"; do
    [[ -n "$rel" ]] || continue
    log "delete ${rel} on router via gate"
    "$REPO_DIR/scripts/delete-domain-list.sh" "$rel"
  done

  for rel in "${files[@]}"; do
    [[ -n "$rel" ]] || continue
    log "apply ${rel} on router via gate"
    "$REPO_DIR/scripts/apply-domain-list.sh" "$REPO_DIR/$rel"
  done
}

run_once() {
  local old_head new_remote_head new_head
  old_head="$(git rev-parse HEAD)"
  git fetch "$GIT_REMOTE" "$GIT_BRANCH" --quiet
  new_remote_head="$(git rev-parse "$GIT_REMOTE/$GIT_BRANCH")"

  if [[ "$old_head" == "$new_remote_head" ]]; then
    log "no git updates"
    return 0
  fi

  git merge --ff-only "$GIT_REMOTE/$GIT_BRANCH"
  new_head="$(git rev-parse HEAD)"
  log "updated: ${old_head:0:7} -> ${new_head:0:7}"
  process_changes "$old_head" "$new_head"
}

bootstrap_all() {
  local -a files=()
  local rel
  mapfile -t files < <(find lists -maxdepth 1 -type f -name "*.txt" | sort)
  for rel in "${files[@]}"; do
    [[ -n "$rel" ]] || continue
    log "bootstrap apply ${rel} on router via gate"
    "$REPO_DIR/scripts/apply-domain-list.sh" "$REPO_DIR/$rel"
  done
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
