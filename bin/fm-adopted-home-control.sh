#!/usr/bin/env bash
# Serialized transport boundary for preserved homes.
# Usage: fm-adopted-home-control.sh <parent-id> <fm-command> [args...]
# fm-on adds this envelope only for a route with adopted-parent identity.
# All other remote commands into a preserved home are refused by the entrypoint.
# Rollback takes the same lock and fences before restoring ownership metadata.
# Preservation mode intentionally forbids automatic Git/config convergence,
# provisioning, retirement and arbitrary remote commands. Existing backlog and
# reply transports remain available to the one current parent.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME=${FM_HOME:?FM_HOME is required}
# shellcheck source=bin/fm-home-adoption-lib.sh
. "$SCRIPT_DIR/fm-home-adoption-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
[ "$#" -ge 2 ] || die 'parent identity and command required'
OWNER=$1 COMMAND=$2
shift 2
LOCK="$FM_HOME/.fm-secondmate-parent.lock"
fm_lock_acquire_wait "$LOCK" || die 'cannot lock preserved home'
trap 'fm_lock_release "$LOCK"' EXIT
fm_home_adoption_authorized "$FM_HOME" "$OWNER" || die 'parent displaced or adoption incomplete'
export FM_ADOPTION_PARENT_ID=$OWNER
case "$COMMAND" in
  fm-remote-secondmate-control.sh)
    case "${1:-}" in
      sync) printf 'preserved: tracked files unchanged\n'; exit 0 ;;
      update|retire) die "preserved home refuses $1" ;;
      launch|relaunch|state|route|send|key|capture|observe) ;;
      *) die 'unsupported preserved-home lifecycle verb' ;;
    esac ;;
  fm-remote-inherit.sh) printf 'preserved: inherited records unchanged\n'; exit 0 ;;
  fm-public-followup-collect.sh)
    case "${1:-}" in
      drain|drop) ;;
      *) die 'unsupported preserved-home follow-up collection verb' ;;
    esac ;;
  fm-x-followup.sh)
    [ "${1:-}" = --clear ] || die 'preserved home only permits follow-up link clearing' ;;
  fm-remote-doctor.sh|fm-backlog-receive.sh|fm-remote-delta-read.sh|fm-remote-file.sh) ;;
  *) die "preserved home refuses remote command $COMMAND" ;;
esac
"$SCRIPT_DIR/$COMMAND" "$@"
