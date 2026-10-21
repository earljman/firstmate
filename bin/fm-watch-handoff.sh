#!/usr/bin/env bash
# Claude handling-successor owner; internal entry point of the Stop hook.
# Covers the handling turn with one ordinary arm while confirming each delivered
# wake for a bounded window, beginning with the hook's own exit-2 rewake.
# The hook passes FM_WATCH_HANDOFF_GEN, SESSION, IDENTITY, and REASON (the
# actionable line its rewake carried), binding this owner to its existing autoarm
# generation and session-lock process. FM_WATCH_HANDOFF_HOST=1 identifies a
# committed host return; MESSAGE_FILE preserves its full banner, including outcomes
# and away posture. That initial obligation confirms only at a newer Stop:
# queue consumption may belong to the branch, not main. A newer Stop claim
# supersedes it. The same .claude-autoarm.lock micro-mutex serializes its
# home-scoped .watch-handoff-owner claim; no lock is held while waiting/sending.
# .watch-handoff-delivery records time/home/reason/sequence of the delivery under
# confirmation. Progress evidence, polled every second independent of the
# watcher's own poll loop: a newer Stop claim, the delivered queue row consumed,
# or a healthy watcher other than this owner's own arm. At each window's end a
# primary observed handling (for an ordinary wake, its drain has claimed the
# sequence into .main-eligible-rows, or the busy probe/capture reports it busy) restarts the
# window without consuming an attempt; only an idle primary that has neither
# claimed nor acknowledged the delivery for a full window is retried.
# FM_WATCH_HANDOFF_GRACE: positive integer seconds of silence per attempt, 180.
# FM_WATCH_HANDOFF_RETRIES: positive integer count of silent retries, 3.
# Other values use the default. After each grace window it re-sends the same
# typed watcher reason once, via the existing backend primitives, only to a
# verified empty, non-busy primary composer, each call bounded to ten seconds; a
# failed/deferred send still consumes the attempt. A retry never appends a
# duplicate queue row. After the retry budget it writes .watch-handoff-escalation
# and appends one durable queue row (check, key watch-handoff-escalation) for the
# primary's next drain; no task-namespace status file is written. The dot-file is
# historical evidence, not a health claim; bin/fm-daily-summary.py reads it.
# AFK/quiet and a changed/dead session lock end this owner without disturbing a
# live arm, which keeps supervising under the ordinary watcher lifecycle; only a
# caught HUP/INT/TERM tears the arm down. A superseding claim ends confirmation
# but keeps an owned live arm until its close, since the newer Stop attaches
# to that cycle; an attached observer can exit without stopping the watcher.
# Once exhausted, ordinary arms continue under this owner until superseded without repeating the notification episode; a failed arm rearms
# only after one grace window.
set -u
if [ "$#" -gt 0 ]; then
  printf 'Usage: fm-watch-handoff.sh (internal Claude Stop-hook successor)\n'
  case "$1" in -h|--help) exit 0 ;; *) exit 2 ;; esac
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$SCRIPT_DIR/fm-composer-lib.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$SCRIPT_DIR/fm-supervisor-target-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
GEN=${FM_WATCH_HANDOFF_GEN:-}
SESSION=${FM_WATCH_HANDOFF_SESSION:-}
IDENTITY=${FM_WATCH_HANDOFF_IDENTITY:-}
DELIVERED_REASON=${FM_WATCH_HANDOFF_REASON:-}
HOST_RETURN=${FM_WATCH_HANDOFF_HOST:-0}
DELIVERED_MESSAGE=$DELIVERED_REASON
if [ "$HOST_RETURN" = 1 ]; then
  # Read before reporting startup. The hook removes its temporary file once
  # startup is confirmed; passing a path avoids the exec environment size cap.
  DELIVERED_MESSAGE=$(cat "${FM_WATCH_HANDOFF_MESSAGE_FILE:-}") || exit 1
fi
OWNER_PID=${BASHPID:-$$}
OWNER_IDENTITY=$(fm_pid_identity "$OWNER_PID") || exit 1
OWNER_FILE="$STATE/.watch-handoff-owner"
OWNER_LOCK="$STATE/.claude-autoarm.lock"
ARM=
ARM_ATTACHED=0
OUT=

session_eligible() {
  [ ! -e "$STATE/.afk" ] || return 1
  [ -n "$IDENTITY" ] && [ -n "$GEN" ] || return 1
  [ "$(cat "$STATE/.lock" 2>/dev/null)" = "$SESSION" ] || return 1
  fm_pid_alive "$SESSION" || return 1
  [ "$(fm_pid_identity "$SESSION")" = "$IDENTITY" ] || return 1
}
eligible() {
  session_eligible || return 1
  fm_autoarm_ledger_read "$STATE" || return 1
  [ "$FM_AUTOARM_GEN" = "$GEN" ] || return 1
  case "$FM_AUTOARM_OUTCOME" in arming|rewake) return 0 ;; *) return 1 ;; esac
}
owned() {
  eligible || return 1
  [ "$(head -1 "$OWNER_FILE" 2>/dev/null)" = "$GEN $OWNER_PID" ]
}
cleanup() {
  [ -z "$ARM" ] || { kill -TERM "$ARM" 2>/dev/null || true; wait "$ARM" 2>/dev/null || true; }
  [ -z "$OUT" ] || rm -f "$OUT"
}
trap cleanup EXIT
trap 'exit 0' HUP INT TERM

eligible || exit 0
claim_attempt=0
while ! fm_lock_try_acquire "$OWNER_LOCK"; do
  claim_attempt=$((claim_attempt + 1))
  if [ "$claim_attempt" -ge 20 ]; then
    printf 'watcher: FAILED - delivery confirmation owner claim contended\n'
    exit 1
  fi
  sleep 0.02
done
if ! eligible; then fm_lock_release "$OWNER_LOCK"; exit 0; fi
old_gen='' old_pid=''
if [ -f "$OWNER_FILE" ]; then read -r old_gen old_pid < "$OWNER_FILE" || true; fi
old_identity=$(sed -n '2p' "$OWNER_FILE" 2>/dev/null || true)
if [ "${old_gen:-}" = "$GEN" ] && [ -n "$old_identity" ] \
  && fm_pid_alive "${old_pid:-}" && [ "$(fm_pid_identity "$old_pid")" = "$old_identity" ]; then
  fm_lock_release "$OWNER_LOCK"
  exit 0
fi
printf '%s %s\n%s\n' "$GEN" "$OWNER_PID" "$OWNER_IDENTITY" > "$OWNER_FILE"
fm_lock_release "$OWNER_LOCK"

positive_env() {
  case "$1" in ''|*[!0-9]*|0*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}
GRACE=$(positive_env "${FM_WATCH_HANDOFF_GRACE:-}" 180)
RETRIES=$(positive_env "${FM_WATCH_HANDOFF_RETRIES:-}" 3)
TARGET=$(discover_supervisor_target) || TARGET=
BACKEND=$(discover_supervisor_backend) || BACKEND=

# Bound every external backend operation, including capture/composer probes.
# A stalled transport must consume a retry rather than strand this owner.
backend_call() {
  # shellcheck disable=SC2016 # The bounded child expands its positional arguments.
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" fm_run_timed 10 bash -c \
    '. "$1/fm-backend.sh"; shift; "$@"' bash "$SCRIPT_DIR" "$@"
}

# 0: the primary is handling (claimed row or busy pane); 1: verified idle;
# 2: unobservable, so the attempt is consumed without typing into it.
primary_handling() {
  local native tail40
  if [ -n "$PENDING_SEQ" ] && grep -qx "$PENDING_SEQ" "$STATE/.main-eligible-rows" 2>/dev/null; then
    return 0
  fi
  [ -n "$TARGET" ] && [ -n "$BACKEND" ] || return 2
  backend_call fm_backend_target_exists "$BACKEND" "$TARGET" || return 2
  native=$(backend_call fm_backend_busy_state "$BACKEND" "$TARGET" 2>/dev/null) || return 2
  [ "$native" != busy ] || return 0
  tail40=$(backend_call fm_backend_capture "$BACKEND" "$TARGET" 40 2>/dev/null) || return 2
  if printf '%s' "$tail40" | fm_busy_lines_match claude; then return 0; fi
  return 1
}

retry_delivery() {
  local composer msg
  owned || return 1
  [ -n "$TARGET" ] && [ -n "$BACKEND" ] || return 1
  backend_call fm_backend_target_exists "$BACKEND" "$TARGET" || return 1
  composer=$(backend_call fm_backend_composer_state "$BACKEND" "$TARGET" 2>/dev/null) || return 1
  [ "$composer" = empty ] || return 1
  # The primary is Claude Code by construction (only the Claude Stop hook
  # launches this owner); it strips the typed envelope's invisible mark and
  # holds the text for a review Enter, so the retry travels as a record plus
  # the ASCII doorbell, exactly as bin/fm-supervise-daemon.sh delivers to it.
  fm_operational_record_write "$STATE" watcher "$PENDING_MESSAGE Run bin/fm-wake-drain.sh, handle and acknowledge the pending wake." msg || return 1
  owned || return 1
  backend_call fm_backend_send_text_submit "$BACKEND" "$TARGET" "$msg" 1 1 1 >/dev/null
}

PENDING=0
PENDING_REASON=
PENDING_MESSAGE=
PENDING_HOST=0
PENDING_SEQ=
RECORD=
ATTEMPT=0
DEADLINE=0
escalated=0
superseded=0
OWN_WATCHER=
reported=0
REARM_AT=0

progress_seen() {
  local queued
  [ "$PENDING_HOST" -eq 0 ] || return 1
  # A host-left watcher (or its replacement) proves coverage, not a main turn.
  if [ "$HOST_RETURN" != 1 ] && fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "${FM_GUARD_GRACE:-300}" "$FM_HOME" \
    && { [ -n "$OWN_WATCHER" ] || [ -z "$ARM" ]; } \
    && [ "$FM_WATCHER_HEALTHY_PID" != "$OWN_WATCHER" ]; then
    return 0
  fi
  [ -n "$PENDING_SEQ" ] || return 1
  queued=$(fm_wake_rows_queued "$PENDING_SEQ") || return 1
  [ -z "$queued" ]
}

open_confirmation() {
  [ "$escalated" -eq 0 ] && [ "$PENDING" -eq 0 ] || return 0
  PENDING_REASON=$1
  PENDING_HOST=${2:-0}
  PENDING_MESSAGE=${3:-$PENDING_REASON}
  PENDING_SEQ=
  if [ "$PENDING_HOST" -eq 0 ]; then
    PENDING_SEQ=$(awk -F '\t' -v reason="$PENDING_REASON" '$5 == reason { seq=$2 } END {print seq}' "$FM_WAKE_QUEUE" 2>/dev/null || true)
    if [ -z "$PENDING_SEQ" ]; then
      # Some delivered reasons summarize several rows (including decision rows).
      # Handling any current row proves progress even when its payload differs.
      PENDING_SEQ=$(awk -F '\t' 'NF >= 5 && $2 ~ /^[0-9]+$/ { if ($2 > seq) seq=$2 } END {print seq}' "$FM_WAKE_QUEUE" 2>/dev/null || true)
    fi
  fi
  RECORD=$(printf 'time=%s\thome=%s\treason=%s\tsequence=%s' "$(date +%s)" "$FM_HOME" "$PENDING_REASON" "${PENDING_SEQ:-none}")
  printf '%s\n' "$RECORD" > "$STATE/.watch-handoff-delivery"
  ATTEMPT=0
  DEADLINE=$(( $(date +%s) + GRACE ))
  PENDING=1
}

confirmation_tick() {
  local handling
  [ "$PENDING" -eq 1 ] || return 0
  if progress_seen; then PENDING=0; return 0; fi
  [ "$(date +%s)" -ge "$DEADLINE" ] || return 0
  primary_handling; handling=$?
  if [ "$handling" -eq 0 ]; then
    DEADLINE=$(( $(date +%s) + GRACE ))
    return 0
  fi
  if [ "$ATTEMPT" -ge "$RETRIES" ]; then
    fm_wake_append check watch-handoff-escalation "check: watcher handoff unconfirmed: $RECORD" || true
    printf '%s\tretries=%s\tescalated_at=%s\n' "$RECORD" "$ATTEMPT" "$(date +%s)" > "$STATE/.watch-handoff-escalation"
    escalated=1
    PENDING=0
    return 0
  fi
  [ "$handling" -ne 1 ] || retry_delivery || true
  ATTEMPT=$((ATTEMPT + 1))
  DEADLINE=$(( $(date +%s) + GRACE ))
}

start_arm() {
  OUT=$(mktemp "$STATE/.watch-handoff-output.XXXXXX") || exit 1
  "$SCRIPT_DIR/fm-watch-arm.sh" > "$OUT" 2>&1 &
  ARM=$!
  ARM_ATTACHED=0
  OWN_WATCHER=
  reported=0
}

# Relay the initial status to the Stop hook's bounded startup confirmation and
# learn this owner's own watcher pid, which never counts as progress evidence.
report_arm_status() {
  local line
  [ "$reported" -eq 0 ] || return 0
  line=$(grep -E '^watcher: (started|attached) pid=[0-9]+' "$OUT" | head -1)
  [ -n "$line" ] || return 0
  printf '%s\n' "$line"
  case "$line" in 'watcher: attached '*) ARM_ATTACHED=1 ;; esac
  OWN_WATCHER=$(printf '%s' "$line" | sed -E 's/^watcher: (started|attached) pid=([0-9]+).*/\2/')
  reported=1
}

close_arm() {
  local rc reason
  wait "$ARM"; rc=$?
  export FM_WATCH_PREDECESSOR_ARM_PID=$ARM
  ARM=
  report_arm_status
  grep '^watcher: FAILED' "$OUT" || true
  reason=$(grep -E '^(signal:|stale:|check:|heartbeat($|:))' "$OUT" | head -1)
  rm -f "$OUT"; OUT=
  # A broken arm must not turn recovery into a hot process-spawn loop.
  [ "$rc" -eq 0 ] || REARM_AT=$(( $(date +%s) + GRACE ))
  [ "$superseded" -eq 0 ] && [ -n "$reason" ] || return 0
  open_confirmation "$reason"
}

open_confirmation "$DELIVERED_REASON" "$HOST_RETURN" "$DELIVERED_MESSAGE"
while :; do
  if ! owned; then
    if ! session_eligible; then
      # Preserve an owned watcher, but retire an attached observer: it owns
      # no watcher and otherwise follows a replacement session's cycles.
      [ "$ARM_ATTACHED" -eq 1 ] || ARM=
      exit 0
    fi
    # A newer Stop can attach to this already-running watcher. Preserve that
    # cycle until it closes; the superseded owner then exits without side effects.
    superseded=1
    PENDING=0
    # An attached arm owns no watcher child. Retire that observer immediately
    # rather than following the new host's successors forever. EXIT only
    # terminates our arm wrapper, preserving the new owner's healthy cycle.
    [ "$ARM_ATTACHED" -eq 0 ] || exit 0
    [ -n "$ARM" ] || exit 0
  fi
  if [ -z "$ARM" ] && [ "$superseded" -eq 0 ] && [ "$(date +%s)" -ge "$REARM_AT" ]; then
    start_arm
  fi
  if [ -n "$ARM" ]; then
    report_arm_status
    fm_pid_alive "$ARM" || close_arm
  fi
  [ "$superseded" -eq 1 ] || confirmation_tick
  if [ -n "$ARM" ] && [ "$reported" -eq 0 ]; then sleep 0.2; else sleep 1; fi
done
