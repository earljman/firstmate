#!/usr/bin/env bash
# Preserved-home adoption safety boundary. fm-home-adopt.sh owns the transaction.
# An existing .fm-home-adoption directory is a permanent preservation fence,
# including interrupted and rolled-back transactions. Never infer permission
# from its mere presence: active authority requires matching immutable identity
# and an active phase. Identity is routing identity, not an authentication secret.
# Identified transport callers hold the same directory lock throughout
# an authorized operation; adoption/rollback serialize on that lock too.

fm_home_adoption_present() {
  [ -e "$1/.fm-home-adoption" ] || [ -L "$1/.fm-home-adoption" ]
}

fm_home_adoption_read() { # <home> <field>
  local dir="$1/.fm-home-adoption" file="$1/.fm-home-adoption/$2"
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ -f "$file" ] && [ ! -L "$file" ] || return 1
  cat "$file"
}

fm_home_adoption_authorized() { # <home> <parent-id>
  local home=$1 parent=$2 phase owner
  phase=$(fm_home_adoption_read "$home" phase) || return 1
  owner=$(fm_home_adoption_read "$home" owner) || return 1
  [ "$phase" = active ] && [ -n "$parent" ] && [ "$owner" = "$parent" ] || return 1
  if ! declare -F fm_secondmate_parent_record_parse >/dev/null; then
    # shellcheck source=bin/fm-secondmate-parent-lib.sh
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-secondmate-parent-lib.sh"
  fi
  fm_secondmate_parent_record_parse "$home/.fm-secondmate-parent" || return 1
  [ "$(grep -c '^route=remote$' "$home/.fm-secondmate-parent")" = 1 ] || return 1
  [ "$(grep -c '^parent_id=' "$home/.fm-secondmate-parent")" = 1 ] || return 1
  [ "$(sed -n 's/^parent_id=//p' "$home/.fm-secondmate-parent")" = "$owner" ] || return 1
  [ -f "$home/.fm-secondmate-home" ] && [ ! -L "$home/.fm-secondmate-home" ] || return 1
  [ "$(cat "$home/.fm-secondmate-home")" = "$(fm_home_adoption_read "$home" id)" ]
}

fm_home_adoption_local_guard() { # <target-home>
  fm_home_adoption_present "$1" || return 0
  if [ "$(fm_home_adoption_read "$1" phase)" = rolled-back ] && [ -z "${FM_ADOPTION_PARENT_ID:-}" ]; then
    return 0
  fi
  if fm_home_adoption_authorized "$1" "${FM_ADOPTION_PARENT_ID:-}"; then return 0; fi
  printf 'error: preserved home is fenced against this parent: %s\n' "$1" >&2
  return 1
}

fm_home_adoption_preserve() { # <target-home> <operation>
  fm_home_adoption_present "$1" || return 0
  printf 'error: preserved home refuses %s: %s\n' "$2" "$1" >&2
  return 1
}
