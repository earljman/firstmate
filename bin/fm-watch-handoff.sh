#!/usr/bin/env bash
# Claude handling-successor owner; internal entry point of the Stop hook.
# Runs one ordinary arm, then confirms each delivered wake for a bounded window.
# The hook passes FM_WATCH_HANDOFF_GEN, SESSION, and IDENTITY, binding this owner
# to its existing autoarm generation and session-lock process. A newer Stop
# claim supersedes it. The same .claude-autoarm.lock micro-mutex serializes its
# home-scoped .watch-handoff-owner claim; no lock is held while waiting/sending.
# .watch-handoff-delivery records time/home/reason/sequence before confirmation.
# .watch-handoff-escalation preserves the latest exhausted delivery, also emitted
# to watch-handoff.status and the durable wake queue. It is historical evidence,
# not a health claim; daily-summary samples expose it alongside the beacon age.
# FM_WATCH_HANDOFF_GRACE / config/watch-handoff-grace: positive seconds, 180.
# FM_WATCH_HANDOFF_RETRIES / config/watch-handoff-retries: positive count, 3.
# A retry never appends a duplicate queue row. It re-sends the same typed watcher
# reason only to a verified empty, non-busy primary composer using the existing
# backend primitives, each bounded to ten seconds. A failed/deferred send still
# consumes the bounded attempt.
# New claims, a healthy ordinary watcher, or disappearance of the captured queue
# row confirm progress. AFK/quiet and a changed/dead session lock exit inert.
# Once exhausted, ordinary arms continue under this owner until superseded;
# subsequent closes rearm without repeating the exhausted notification episode.
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
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$SCRIPT_DIR/fm-supervisor-target-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
GEN=${FM_WATCH_HANDOFF_GEN:-}
SESSION=${FM_WATCH_HANDOFF_SESSION:-}
IDENTITY=${FM_WATCH_HANDOFF_IDENTITY:-}
OWNER_PID=${BASHPID:-$$}
OWNER_IDENTITY=$(fm_pid_identity "$OWNER_PID") || exit 1
OWNER_FILE="$STATE/.watch-handoff-owner"
OWNER_LOCK="$STATE/.claude-autoarm.lock"
ARM=
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

positive_config() {
  local value=$1 path=$2 fallback=$3
  [ -n "$value" ] || value=$(cat "$path" 2>/dev/null || true)
  case "$value" in ''|*[!0-9]*|0) value=$fallback ;; esac
  value=$(printf '%s' "$value" | sed 's/^0*//')
  [ -n "$value" ] || value=$fallback
  printf '%s' "$value"
}
GRACE=$(positive_config "${FM_WATCH_HANDOFF_GRACE:-}" "$CONFIG/watch-handoff-grace" 180)
RETRIES=$(positive_config "${FM_WATCH_HANDOFF_RETRIES:-}" "$CONFIG/watch-handoff-retries" 3)
TARGET=$(discover_supervisor_target) || TARGET=
BACKEND=$(discover_supervisor_backend) || BACKEND=

# Bound every external backend operation, including capture/composer probes.
# A stalled transport must consume a retry rather than strand this owner.
backend_call() {
  # shellcheck disable=SC2016 # The bounded child expands its positional arguments.
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" fm_run_timed 10 bash -c \
    '. "$1/fm-backend.sh"; shift; "$@"' bash "$SCRIPT_DIR" "$@"
}

retry_delivery() {
  local native tail40 composer msg
  owned || return 1
  [ -n "$TARGET" ] && [ -n "$BACKEND" ] || return 1
  backend_call fm_backend_target_exists "$BACKEND" "$TARGET" || return 1
  native=$(backend_call fm_backend_busy_state "$BACKEND" "$TARGET" 2>/dev/null) || return 1
  [ "$native" != busy ] || return 1
  tail40=$(backend_call fm_backend_capture "$BACKEND" "$TARGET" 40 2>/dev/null) || return 1
  if printf '%s' "$tail40" | fm_busy_lines_match claude; then return 1; fi
  composer=$(backend_call fm_backend_composer_state "$BACKEND" "$TARGET" 2>/dev/null) || return 1
  [ "$composer" = empty ] || return 1
  fm_operational_input_encode watcher "$REASON Run bin/fm-wake-drain.sh, handle and acknowledge the pending wake." msg || return 1
  owned || return 1
  backend_call fm_backend_send_text_submit "$BACKEND" "$TARGET" "$msg" 1 1 1 >/dev/null
}

confirmed() {
  local pending
  if fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "${FM_GUARD_GRACE:-300}" "$FM_HOME"; then
    return 0
  fi
  [ -n "$SEQ" ] || return 1
  pending=$(fm_wake_rows_queued "$SEQ") || return 1
  [ -z "$pending" ]
}

escalated=0
while owned; do
  OUT=$(mktemp "$STATE/.watch-handoff-output.XXXXXX") || exit 1
  FM_WATCH_CONFIRMATION_PID=$OWNER_PID "$SCRIPT_DIR/fm-watch-arm.sh" > "$OUT" 2>&1 &
  ARM=$!
  # Relay the initial status to the Stop hook's bounded startup confirmation.
  # Later output is read only after close; no live second watcher is started.
  reported=0
  while fm_pid_alive "$ARM"; do
    if [ "$reported" -eq 0 ] && grep -Eq '^watcher: (started|attached) pid=' "$OUT"; then
      grep -E '^watcher: (started|attached) pid=' "$OUT" | head -1
      reported=1
    fi
    # A newer Stop can attach to this already-running watcher. Preserve that
    # cycle until it closes; the superseded owner then exits without side effects.
    session_eligible || exit 0
    if [ "$reported" -eq 1 ]; then sleep 1; else sleep 0.2; fi
  done
  wait "$ARM"; rc=$?
  export FM_WATCH_PREDECESSOR_ARM_PID=$ARM
  ARM=
  owned || exit 0
  if [ "$reported" -eq 0 ]; then
    grep -E '^watcher: (started|attached) pid=' "$OUT" | head -1
  fi
  grep '^watcher: FAILED' "$OUT" || true
  REASON=$(grep -E '^(signal:|stale:|check:|heartbeat($|:))' "$OUT" | head -1)
  rm -f "$OUT"; OUT=
  if [ "$escalated" -ne 0 ]; then
    # A broken arm must not turn recovery into a hot process-spawn loop.
    if [ "$rc" -ne 0 ]; then
      deadline=$(( $(date +%s) + GRACE ))
      while [ "$(date +%s)" -lt "$deadline" ]; do owned || exit 0; sleep 1; done
    fi
    continue
  fi
  # A failed arm also needs an audible, bounded recovery path.
  [ -n "$REASON" ] || REASON="check: watcher handoff arm failed (exit $rc)"
  SEQ=$(awk -F '\t' -v reason="$REASON" '$5 == reason { seq=$2 } END {print seq}' "$FM_WAKE_QUEUE" 2>/dev/null || true)
  if [ -z "$SEQ" ]; then
    # Some delivered reasons summarize several rows (including decision rows).
    # Handling any current row proves progress even when its payload differs.
    SEQ=$(awk -F '\t' 'NF >= 5 && $2 ~ /^[0-9]+$/ { if ($2 > seq) seq=$2 } END {print seq}' "$FM_WAKE_QUEUE" 2>/dev/null || true)
  fi
  delivered_at=$(date +%s)
  record=$(printf 'time=%s\thome=%s\treason=%s\tsequence=%s' "$delivered_at" "$FM_HOME" "$REASON" "${SEQ:-none}")
  owned || exit 0
  printf '%s\n' "$record" > "$STATE/.watch-handoff-delivery"
  attempt=0
  while owned; do
    deadline=$(( $(date +%s) + GRACE ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
      owned || exit 0
      confirmed && exit 0
      sleep 1
    done
    owned || exit 0
    confirmed && exit 0
    if [ "$attempt" -ge "$RETRIES" ]; then
      owned || exit 0
      printf '%s\tretries=%s\tescalated_at=%s\n' "$record" "$attempt" "$(date +%s)" > "$STATE/.watch-handoff-escalation"
      printf 'failed [at=%s]: watcher handoff unconfirmed: %s\n' "$(date +%s)" "$record" >> "$STATE/watch-handoff.status"
      fm_wake_append check watch-handoff "check: watcher handoff unconfirmed: $record" || true
      escalated=1
      break
    fi
    retry_delivery || true
    attempt=$((attempt + 1))
  done
  # Ordinary arm owns singleton acquisition and fresh beacon publication.
done
