#!/usr/bin/env bash
# Adopt a populated home in place, without seeding, syncing or moving work.
# Usage:
#   FM_HOME=<parent> fm-home-adopt.sh identity
#   FM_HOME=<target> fm-home-adopt.sh prepare <id> <parent-id> <charter-file> --quiesced
#   FM_HOME=<target> fm-home-adopt.sh activate <id> <parent-id>
#   FM_HOME=<target> fm-home-adopt.sh rollback <id> <parent-id> --quiesced
#   FM_HOME=<target> fm-home-adopt.sh show
#
# Run prepare/activate/rollback ON THE TARGET HOST, never through the remote
# command plane. --quiesced attests that both parents, this home's agent and
# automatic maintenance have been stopped and outstanding channel obligations
# checkpointed. The session-lock check additionally refuses a live/unknown
# holder. Endpoint moves and transfers of tasks/replies are separate operations.
# The supplied charter is the reviewed new contact/role contract, not a seed.
# prepare snapshots ONLY identity, binding and charter; it publishes a permanent
# preservation fence before any ownership change. activate publishes the new
# binding then identity then active phase. Repeating either converges; rollback
# freezes first, restores only those snapshots, and permanently marks rolled-back
# so a delayed activate cannot undo rollback. Never delete the journal to retry.
# A new handoff after rollback requires separate reviewed maintenance.
# No Git, backlog, registry, config, worktree, lease or endpoint mutation occurs.
# Register the route separately using the adopted-parent field documented in
# docs/remote-secondmates.md, after activation and before starting the new parent.
set -eu
case "${1:-}" in -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME=${FM_HOME:?FM_HOME is required}
# shellcheck source=bin/fm-home-adoption-lib.sh
. "$SCRIPT_DIR/fm-home-adoption-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
safe_id() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac; }
[ ! -L "$FM_HOME" ] || die 'home must not be a symlink'
FM_HOME=$(cd "$FM_HOME" && pwd -P)
JOURNAL="$FM_HOME/.fm-home-adoption"
LOCK="$FM_HOME/.fm-secondmate-parent.lock"
STAGE=
LOCKED=0
cleanup() {
  [ -z "$STAGE" ] || rm -rf -- "$STAGE"
  [ "$LOCKED" = 0 ] || fm_lock_release "$LOCK"
}
trap cleanup EXIT
lock() { fm_lock_acquire_wait "$LOCK" || die 'cannot lock adoption'; LOCKED=1; }
ordinary() { [ -f "$1" ] && [ ! -L "$1" ]; }
quiesced() {
  [ "${1:-}" = --quiesced ] || die 'explicit --quiesced attestation required'
  fm_session_lock_inspect "$FM_HOME/state"
  case "$FM_LOCK_INSPECT_STATE" in free|stale) ;; *) die 'target session is live or unknown; stop and checkpoint it first' ;; esac
  local meta endpoint_state
  for meta in "$FM_HOME/state/parent-route/"*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    fm_backend_validate_task_endpoint "$meta" "$(basename "$meta" .meta)" || die 'unverified retained endpoint'
    [ "$FM_BACKEND_VALIDATED_BACKEND" = herdr ] || die 'retained endpoint requires a separately reviewed lifecycle handoff'
    endpoint_state=$(fm_backend_agent_state "$FM_BACKEND_VALIDATED_BACKEND" "$FM_BACKEND_VALIDATED_TARGET" 2>/dev/null || true)
    case "$endpoint_state" in dead|missing) ;; *) die 'retained endpoint is live or unknown; stop it before ownership changes' ;; esac
  done
}
phase_write() {
  printf '%s\n' "$1" > "$JOURNAL/phase.tmp"
  mv -f -- "$JOURNAL/phase.tmp" "$JOURNAL/phase"
}
validate_target() {
  ordinary "$FM_HOME/AGENTS.md" && [ -d "$FM_HOME/bin" ] && [ ! -L "$FM_HOME/bin" ] || die 'target is not a Firstmate checkout'
  local dir
  for dir in data state config projects; do
    [ ! -L "$FM_HOME/$dir" ] || die "unsafe $dir directory"
    [ ! -e "$FM_HOME/$dir" ] || [ -d "$FM_HOME/$dir" ] || die "unsafe $dir directory"
  done
  [ -d "$FM_HOME/data" ] && [ -d "$FM_HOME/state" ] || die 'target must be a populated operational home'
}
match_transaction() {
  [ "$(fm_home_adoption_read "$FM_HOME" id)" = "$ID" ] &&
    [ "$(fm_home_adoption_read "$FM_HOME" owner)" = "$OWNER" ] || die 'adoption belongs to a different identity'
}
restore_file() {
  local key=$1 dest=$2
  if ordinary "$JOURNAL/$key.before"; then
    cp "$JOURNAL/$key.before" "$dest.adopt-tmp"
    mv -f -- "$dest.adopt-tmp" "$dest"
  elif ordinary "$JOURNAL/$key.absent"; then
    rm -f -- "$dest"
  else die "missing rollback snapshot: $key"; fi
}
case "${1:-}" in
  identity)
    [ "$#" = 1 ] || die 'identity takes no arguments'
    lock
    if [ ! -e "$FM_HOME/.fm-parent-id" ] && [ ! -L "$FM_HOME/.fm-parent-id" ]; then
      od -An -N16 -tx1 /dev/urandom | tr -d ' \n' > "$FM_HOME/.fm-parent-id.tmp"
      printf '\n' >> "$FM_HOME/.fm-parent-id.tmp"
      mv "$FM_HOME/.fm-parent-id.tmp" "$FM_HOME/.fm-parent-id"
    fi
    ordinary "$FM_HOME/.fm-parent-id" || die 'unsafe parent identity'
    owner=$(cat "$FM_HOME/.fm-parent-id"); safe_id "$owner" || die 'invalid parent identity'
    printf '%s\n' "$owner"
    exit 0 ;;
  show)
    [ "$#" = 1 ] || die 'show takes no arguments'
    for key in id owner phase; do printf '%s=%s\n' "$key" "$(fm_home_adoption_read "$FM_HOME" "$key")"; done
    exit 0 ;;
  prepare) [ "$#" = 5 ] || die 'prepare requires id, parent-id, charter-file, --quiesced' ;;
  activate) [ "$#" = 3 ] || die 'activate requires id and parent-id' ;;
  rollback) [ "$#" = 4 ] || die 'rollback requires id, parent-id, --quiesced' ;;
  *) die 'use identity, prepare, activate, rollback or show (see script header)' ;;
esac
COMMAND=$1 ID=$2 OWNER=$3
safe_id "$ID" || die 'unsafe adoption identity'
safe_id "$OWNER" || die 'unsafe adoption identity'
validate_target
lock
if [ "$COMMAND" = prepare ]; then
  quiesced "$5"
  ordinary "$4" || die 'charter must be an ordinary file'
  if fm_home_adoption_present "$FM_HOME"; then
    match_transaction
    cmp -s "$4" "$JOURNAL/charter.new" || die 'retry changed the charter'
    case "$(fm_home_adoption_read "$FM_HOME" phase)" in prepared|active) exit 0 ;; *) die 'transaction cannot be prepared again' ;; esac
  fi
  # Retain the identity of an existing secondmate. A former primary has none.
  if [ -e "$FM_HOME/.fm-secondmate-home" ] || [ -L "$FM_HOME/.fm-secondmate-home" ]; then
    ordinary "$FM_HOME/.fm-secondmate-home" && [ "$(cat "$FM_HOME/.fm-secondmate-home")" = "$ID" ] || die 'existing secondmate identity differs'
  fi
  if [ -e "$FM_HOME/.fm-secondmate-parent" ] || [ -L "$FM_HOME/.fm-secondmate-parent" ]; then
    fm_secondmate_parent_record_parse "$FM_HOME/.fm-secondmate-parent" || die 'unsafe prior binding'
  fi
  STAGE=$(mktemp -d "$FM_HOME/.fm-adoption-stage.XXXXXX")
  printf '%s\n' "$ID" > "$STAGE/id"
  printf '%s\n' "$OWNER" > "$STAGE/owner"
  printf 'prepared\n' > "$STAGE/phase"
  cp "$4" "$STAGE/charter.new"
  for pair in 'marker:.fm-secondmate-home' 'binding:.fm-secondmate-parent' 'charter:data/charter.md'; do
    key=${pair%%:*}; rel=${pair#*:}
    if [ -e "$FM_HOME/$rel" ] || [ -L "$FM_HOME/$rel" ]; then
      ordinary "$FM_HOME/$rel" || die "unsafe ownership file: $rel"
      cp "$FM_HOME/$rel" "$STAGE/$key.before"
    else : > "$STAGE/$key.absent"; fi
  done
  mv "$STAGE" "$JOURNAL"; STAGE=
  printf 'prepared: %s (all ordinary operations remain fenced)\n' "$ID"
  exit 0
fi
match_transaction
PHASE=$(fm_home_adoption_read "$FM_HOME" phase)
if [ "$COMMAND" = activate ]; then
  case "$PHASE" in active) exit 0 ;; prepared) ;; *) die 'activation refused after rollback or corrupt phase' ;; esac
  # Repeat the session liveness check after an interrupted preparation.
  quiesced --quiesced
  fm_secondmate_parent_record_render remote > "$JOURNAL/binding.new"
  printf 'parent_id=%s\n' "$OWNER" >> "$JOURNAL/binding.new"
  cp "$JOURNAL/charter.new" "$FM_HOME/data/charter.md.adopt-tmp"
  mv -f "$FM_HOME/data/charter.md.adopt-tmp" "$FM_HOME/data/charter.md"
  cp "$JOURNAL/binding.new" "$FM_HOME/.fm-secondmate-parent.adopt-tmp"
  mv -f "$FM_HOME/.fm-secondmate-parent.adopt-tmp" "$FM_HOME/.fm-secondmate-parent"
  printf '%s\n' "$ID" > "$FM_HOME/.fm-secondmate-home.adopt-tmp"
  mv -f "$FM_HOME/.fm-secondmate-home.adopt-tmp" "$FM_HOME/.fm-secondmate-home"
  phase_write active
  printf 'active: %s parent=%s\n' "$ID" "$OWNER"
else
  quiesced "$4"
  case "$PHASE" in rolled-back) exit 0 ;; prepared|active|rolling-back) ;; *) die 'invalid rollback phase' ;; esac
  phase_write rolling-back
  restore_file binding "$FM_HOME/.fm-secondmate-parent"
  restore_file marker "$FM_HOME/.fm-secondmate-home"
  restore_file charter "$FM_HOME/data/charter.md"
  phase_write rolled-back
  printf 'rolled-back: %s (new parent remains fenced)\n' "$ID"
fi
