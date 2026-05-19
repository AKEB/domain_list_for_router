#!/usr/bin/env bash
# Watch git repo, pull updates, push changed lists to Keenetic and apply.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

load_env

GIT_REMOTE="${GIT_REMOTE:-origin}"
GIT_BRANCH="${GIT_BRANCH:-main}"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
REMOTE_REPO_DIR="${REMOTE_REPO_DIR:-/opt/domain_list_for_router}"

require_cmd git
require_cmd sshpass

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

ensure_repo() {
  if [[ ! -d "${REPO_DIR}/.git" ]]; then
    log "clone repo into ${REPO_DIR}"
    mkdir -p "$(dirname "$REPO_DIR")"
    git clone --branch "$GIT_BRANCH" "git@github.com:AKEB/domain_list_for_router.git" "$REPO_DIR"
  fi
  cd "$REPO_DIR"
}

git_pull_if_changed() {
  local old_head new_head
  old_head="$(git rev-parse HEAD)"
  git fetch "$GIT_REMOTE" "$GIT_BRANCH" --quiet
  new_head="$(git rev-parse "${GIT_REMOTE}/${GIT_BRANCH}")"

  if [[ "$old_head" == "$new_head" ]]; then
    return 1
  fi

  git merge --ff-only "${GIT_REMOTE}/${GIT_BRANCH}"
  log "updated: ${old_head:0:7} -> ${new_head:0:7}"
  return 0
}

changed_list_files() {
  local from="$1" to="$2"
  if [[ "$from" == "0000000000000000000000000000000000000000" ]]; then
    find lists -maxdepth 1 -type f -name '*.txt' | sort
    return
  fi
  git diff --name-only --diff-filter=ACMR "$from" "$to" -- lists/ | grep '\.txt$' || true
}

deleted_list_files() {
  local from="$1" to="$2"
  git diff --name-only --diff-filter=D "$from" "$to" -- lists/ | grep '\.txt$' || true
}

sync_file_to_router_shell() {
  local rel="$1"
  local remote_path="${REMOTE_REPO_DIR}/${rel}"
  log "copy ${rel} -> ${ROUTER_HOST}:${remote_path}"
  export SSHPASS="${ROUTER_PASSWORD}"
  sshpass -e scp \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "${REPO_DIR}/${rel}" \
    "${ROUTER_USER:-admin}@${ROUTER_HOST}:${remote_path}"
}

apply_on_router_shell() {
  local rel="$1"
  log "apply ${rel} on ${ROUTER_HOST}"
  router_shell_ssh "cd '${REMOTE_REPO_DIR}' && bash scripts/apply-domain-list.sh '${rel}'"
}

delete_on_router_shell() {
  local rel="$1"
  log "delete ${rel} on ${ROUTER_HOST}"
  router_shell_ssh "cd '${REMOTE_REPO_DIR}' && bash scripts/delete-domain-list.sh '${rel}'"
}

prepare_remote_repo() {
  router_shell_ssh "mkdir -p '${REMOTE_REPO_DIR}/lists' '${REMOTE_REPO_DIR}/scripts' '${REMOTE_REPO_DIR}/.sync-state'"
  export SSHPASS="${ROUTER_PASSWORD}"
  sshpass -e scp -q \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "${REPO_DIR}/scripts/lib.sh" \
    "${REPO_DIR}/scripts/apply-domain-list.sh" \
    "${REPO_DIR}/scripts/delete-domain-list.sh" \
    "${ROUTER_USER:-admin}@${ROUTER_HOST}:${REMOTE_REPO_DIR}/scripts/"
  router_shell_ssh "chmod +x '${REMOTE_REPO_DIR}/scripts/'*.sh"
  if [[ -f "${REPO_DIR}/.env" ]]; then
    sshpass -e scp -q \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      "${REPO_DIR}/.env" \
      "${ROUTER_USER:-admin}@${ROUTER_HOST}:${REMOTE_REPO_DIR}/.env"
  fi
}

process_changes() {
  local old_head="$1" new_head="$2"
  local -a files=() deleted=()
  mapfile -t files < <(changed_list_files "$old_head" "$new_head")
  mapfile -t deleted < <(deleted_list_files "$old_head" "$new_head")

  if ((${#files[@]} == 0 && ${#deleted[@]} == 0)); then
    log "no list changes"
    return
  fi

  prepare_remote_repo

  for rel in "${deleted[@]}"; do
    [[ -n "$rel" ]] || continue
    delete_on_router_shell "$rel"
    router_shell_ssh "rm -f '${REMOTE_REPO_DIR}/${rel}'" || true
  done

  for rel in "${files[@]}"; do
    [[ -n "$rel" ]] || continue
    sync_file_to_router_shell "$rel"
    apply_on_router_shell "$rel"
  done
}

run_once() {
  ensure_repo
  local old_head
  old_head="$(git rev-parse HEAD)"

  if git_pull_if_changed; then
    local new_head
    new_head="$(git rev-parse HEAD)"
    process_changes "$old_head" "$new_head"
  else
    log "no git updates"
  fi
}

main() {
  case "${1:-watch}" in
    once)
      run_once
      ;;
    watch)
      log "watching ${GIT_REMOTE}/${GIT_BRANCH} every ${CHECK_INTERVAL}s"
      while true; do
        run_once || true
        sleep "$CHECK_INTERVAL"
      done
      ;;
    *)
      echo "Usage: $0 [once|watch]" >&2
      exit 1
      ;;
  esac
}

main "$@"
