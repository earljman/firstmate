#!/usr/bin/env bash
# fm-watch-remote-lib.sh - local deadlines for supervision's remote calls.
# Sourced by liveness, crew state, pending replies, the reply mirror, and
# public followup.
# The bound applies to crew-state reads, pending-reply observations, mirror
# reads and document fetches, and public-followup collection and link cleanup,
# including calls outside the watcher. Liveness uses it only in poll mode;
# the watcher also applies it to remote relaunches. The full startup sweep
# retains the transport's own bound.
# fm_watch_remote_run <command...> preserves command status, including the
# fm_run_timed timeout status (124/137); it never publishes a watcher beacon.
# FM_WATCH_REMOTE_TIMEOUT accepts whole seconds 1..120; unset or empty uses
# FM_WATCH_REMOTE_TIMEOUT_DEFAULT. Invalid values fail with status 125 before
# executing the command. The upper limit leaves headroom below the
# ordinary watcher grace. Keep this above FM_REMOTE_REPLY_WAIT_SECONDS if
# empty reply polls must complete their caught-up watermark. SSH keepalives
# remain the transport's own contract.

FM_WATCH_REMOTE_TIMEOUT_DEFAULT=60
# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/fm-timeout-lib.sh"

fm_watch_remote_timeout() {
  local seconds=${FM_WATCH_REMOTE_TIMEOUT:-$FM_WATCH_REMOTE_TIMEOUT_DEFAULT}
  case "$seconds" in
    *[!0-9]*|0*) ;;
    *)
      if [ "${#seconds}" -le 3 ] && [ "$seconds" -le 120 ]; then
        printf '%s\n' "$seconds"
        return 0
      fi
      ;;
  esac
  printf 'fm-watch-remote: FM_WATCH_REMOTE_TIMEOUT must be whole seconds from 1 to 120\n' >&2
  return 125
}

fm_watch_remote_run() {
  local seconds
  seconds=$(fm_watch_remote_timeout) || return $?
  fm_run_timed "$seconds" "$@"
}
