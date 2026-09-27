#!/usr/bin/env bash
# shellcheck disable=SC2034 # parsed fields are output globals for sourcing callers.
# Parse the durable parent binding written into a seeded secondmate home.
#
# The fm-secondmate-parent.v1 record contains exactly one schema and route.
# A local route contains exactly one absolute parent_home and no parent_host.
# A remote route contains no parent_home; current provisioning includes its SSH
# alias as diagnostic-only parent_host, while legacy-compatible manifests may
# omit that field.
# Unknown fields are reserved for forward-compatible additions.
# Duplicate schema or route fields, a malformed local binding, an unsupported
# route or schema, a NUL-bearing record, and a symlinked record fail closed.
# Writers publish this record before .fm-secondmate-home so that the identity
# marker remains the seed-completion point.

fm_secondmate_parent_record_parse() {
  local file=$1 line schema='' route='' parent_home='' parent_host=''
  local schema_count=0 route_count=0 parent_home_count=0 parent_host_count=0

  FM_SECONDMATE_PARENT_ROUTE=
  FM_SECONDMATE_PARENT_HOME=
  FM_SECONDMATE_PARENT_HOST=

  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  # bash's read drops NUL bytes, and different bash generations disagree on the
  # result (3.2 truncates the value at the NUL, 5.x splices the surrounding
  # bytes together), so a NUL-bearing parent_home can resolve to a home the
  # record's bytes never name contiguously. Reject the whole record as corrupt
  # before any field parsing instead of letting the interpreter pick a home.
  [ "$(wc -c < "$file")" -eq "$(LC_ALL=C tr -d '\0' < "$file" | wc -c)" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      schema=*)
        schema_count=$((schema_count + 1))
        schema=${line#schema=}
        ;;
      route=*)
        route_count=$((route_count + 1))
        route=${line#route=}
        ;;
      parent_home=*)
        parent_home_count=$((parent_home_count + 1))
        parent_home=${line#parent_home=}
        ;;
      parent_host=*)
        parent_host_count=$((parent_host_count + 1))
        parent_host=${line#parent_host=}
        ;;
    esac
  done < "$file"

  [ "$schema_count" -eq 1 ] || return 1
  [ "$route_count" -eq 1 ] || return 1
  [ "$schema" = fm-secondmate-parent.v1 ] || return 1
  case "$route" in
    local)
      [ "$parent_home_count" -eq 1 ] || return 1
      [ "$parent_host_count" -eq 0 ] || return 1
      case "$parent_home" in /*) ;; *) return 1 ;; esac
      FM_SECONDMATE_PARENT_HOME=$parent_home
      ;;
    remote)
      [ "$parent_home_count" -eq 0 ] || return 1
      ;;
    *) return 1 ;;
  esac

  FM_SECONDMATE_PARENT_ROUTE=$route
  FM_SECONDMATE_PARENT_HOST=$parent_host
}

# Parent checks/rendering adapted from upstream c4a18945 (takeover proposal).
# Preserved adoption uses fm-home-adopt.sh instead of the proposal's toggling
# restore operation and its route-only remote authority.

FM_SECONDMATE_PARENT_ERROR=

fm_secondmate_parent_path() { printf '%s/.fm-secondmate-parent\n' "$1"; }

# A record field occupies one line, so a value carrying a line break would forge
# a second field. A NUL cannot survive a shell variable, and the parser above
# rejects a NUL-bearing file outright, so line framing is all this has to guard.
_fm_secondmate_parent_field_safe() { # <value>
  case ${1-} in *$'\n'*|*$'\r'*) return 1 ;; esac
}

# The real path of <path>, or <path> unchanged when it cannot be resolved, so a
# parent home that has since been removed still compares as its recorded string.
_fm_secondmate_parent_realpath() { # <path>
  local resolved
  if resolved=$(CDPATH='' cd -- "$1" 2>/dev/null && pwd -P) && [ -n "$resolved" ]; then
    printf '%s\n' "$resolved"
  else
    printf '%s\n' "$1"
  fi
}

# Render the legacy binding format for local seeds and preserved adoption.
fm_secondmate_parent_record_render() { # <route> [parent_home] [parent_host]
  local route=$1 parent_home=${2-} parent_host=${3-}
  _fm_secondmate_parent_field_safe "$parent_home" || return 1
  _fm_secondmate_parent_field_safe "$parent_host" || return 1
  case "$route" in
    local)
      case "$parent_home" in /*) ;; *) return 1 ;; esac
      [ -z "$parent_host" ] || return 1
      printf 'schema=fm-secondmate-parent.v1\n'
      printf 'route=local\n'
      printf 'parent_home=%s\n' "$parent_home"
      ;;
    remote)
      [ -z "$parent_home" ] || return 1
      printf 'schema=fm-secondmate-parent.v1\n'
      printf 'route=remote\n'
      [ -z "$parent_host" ] || printf 'parent_host=%s\n' "$parent_host"
      ;;
    *) return 1 ;;
  esac
}

# Does <home>'s live parent binding name the caller as its parent?
# <expect-route> is local for a primary on the mate's own filesystem, which must
# also match <claiming-home>, and remote for a primary reaching the mate over the
# remote transport, which the route alone confirms.
# Returns 0 when it does. Returns 1 otherwise, with FM_SECONDMATE_PARENT_ERROR
# describing the displacement in plain words for the refusing caller to report.
fm_secondmate_parent_binding_names() { # <home> <expect-route> [claiming-home]
  local home=$1 expect=$2 claiming=${3-} record bound_home
  FM_SECONDMATE_PARENT_ERROR=
  if [ -e "$home/.fm-home-adoption" ] || [ -L "$home/.fm-home-adoption" ]; then
    # shellcheck source=bin/fm-home-adoption-lib.sh
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-home-adoption-lib.sh"
    if ! fm_home_adoption_local_guard "$home"; then
      FM_SECONDMATE_PARENT_ERROR="preserved home is fenced against this parent: $home"
      return 1
    fi
    # Host-local spawn/send/control execute underneath the identified envelope;
    # their synthetic parent-route state does not change the durable remote role.
    if fm_home_adoption_authorized "$home" "${FM_ADOPTION_PARENT_ID:-}"; then return 0; fi
  fi
  record=$(fm_secondmate_parent_path "$home")
  # A home with no record at all names no parent, so there is no displacement to
  # report: homes seeded before this record existed keep working, and the missing
  # record already surfaces on its own through the parent channel, which cannot
  # resolve a destination without it. A record that exists but cannot be trusted
  # is the opposite case and fails closed here.
  if [ ! -e "$record" ] && [ ! -L "$record" ]; then
    return 0
  fi
  if ! fm_secondmate_parent_record_parse "$record"; then
    FM_SECONDMATE_PARENT_ERROR="secondmate home $home has no usable parent binding: $record is malformed, symlinked, or corrupt"
    return 1
  fi
  case "$expect" in
    local)
      if [ "$FM_SECONDMATE_PARENT_ROUTE" != local ]; then
        FM_SECONDMATE_PARENT_ERROR="secondmate home $home is currently bound to a parent that reaches it over the remote route, not to this home"
        return 1
      fi
      bound_home=$(_fm_secondmate_parent_realpath "$FM_SECONDMATE_PARENT_HOME")
      claiming=$(_fm_secondmate_parent_realpath "$claiming")
      if [ "$bound_home" != "$claiming" ]; then
        FM_SECONDMATE_PARENT_ERROR="secondmate home is bound to parent $bound_home, not requested parent $claiming"
        return 1
      fi
      ;;
    remote)
      if [ "$FM_SECONDMATE_PARENT_ROUTE" != remote ]; then
        FM_SECONDMATE_PARENT_ERROR="secondmate home $home is currently bound to the firstmate home $FM_SECONDMATE_PARENT_HOME on its own host, not to a parent reaching it over the remote route"
        return 1
      fi
      ;;
    *)
      FM_SECONDMATE_PARENT_ERROR="unsupported expected parent route: $expect"
      return 1
      ;;
  esac
}
