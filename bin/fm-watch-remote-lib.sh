#!/usr/bin/env bash
# fm-watch-remote-lib.sh - local deadlines for supervision's remote calls.
# Sourced by liveness, crew state, pending replies, the reply mirror, and
# public followup.
# fm_watch_remote_run <command...> preserves command status, including the
# fm_run_timed timeout status (124/137); it never publishes a watcher beacon.
# FM_WATCH_REMOTE_TIMEOUT accepts whole seconds 1..120; invalid values use
# FM_WATCH_REMOTE_TIMEOUT_DEFAULT. The upper limit leaves headroom below the
# ordinary watcher grace. Keep this above FM_REMOTE_REPLY_WAIT_SECONDS if
# empty reply polls must complete their caught-up watermark. SSH keepalives
# remain the transport's own contract.

FM_WATCH_REMOTE_TIMEOUT_DEFAULT=60
# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/fm-timeout-lib.sh"

fm_watch_remote_timeout() {
  local seconds=${FM_WATCH_REMOTE_TIMEOUT:-}
  case "$seconds" in
    ''|*[!0-9]*|0*) seconds=$FM_WATCH_REMOTE_TIMEOUT_DEFAULT ;;
    *)
      if [ "${#seconds}" -gt 3 ] || [ "$seconds" -gt 120 ]; then
        seconds=$FM_WATCH_REMOTE_TIMEOUT_DEFAULT
      fi
      ;;
  esac
  printf '%s\n' "$seconds"
}

fm_watch_remote_run() {
  fm_run_timed "$(fm_watch_remote_timeout)" "$@"
}
