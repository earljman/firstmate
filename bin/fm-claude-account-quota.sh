#!/usr/bin/env bash
# Read the primary and fallback Claude account quotas and select the account for
# new Claude launches.
#
# Usage: fm-claude-account-quota.sh [--check]
#
# Profiles come from gitignored config/claude-account-profiles under FM_HOME.
# Each nonblank, non-comment line is `<label> <config-dir>`, in priority order.
# Exactly two profiles are required. Use `default` for the normal Claude profile,
# which means CLAUDE_CONFIG_DIR is unset, or an absolute path for another profile.
# When the file is absent, the profiles are `shiftcare default` and
# `teohcapital $HOME/.claude-teohcapital`.
#
# quota-axi is invoked once per profile with `--provider claude --json` and
# `--no-credential-refresh`. A failed profile remains in the summary with
# authState=unreadable. The first profile is recommended while both its session
# and weekly scopes have more than 20 percent remaining. At or below 20 percent
# on either scope, the second profile is recommended if it is readable and above
# the same threshold. When neither profile qualifies, the verdict is `none`.
# Existing workers are unaffected because this command only reports the selector
# for a future launch.
#
# Normal output is one compact JSON summary followed by one `SWITCH VERDICT`
# line. `--check`, or execution from a filename ending in `.check.sh`, stores
# only the verdict fields in
# state/claude-account-quota.verdict and prints the verdict line only when those
# fields change. A total read failure exits nonzero and does not update the
# marker. No quota-axi diagnostic or account identity is copied to output.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROFILE_FILE="$FM_HOME/config/claude-account-profiles"
THRESHOLD=20
CHECK_MODE=0

case "${BASH_SOURCE[0]##*/}" in
  *.check.sh) CHECK_MODE=1 ;;
esac

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

case "${1-}" in
  '') ;;
  --check) CHECK_MODE=1 ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
[ "$#" -le 1 ] || usage

command -v jq >/dev/null 2>&1 || die "jq is required"
QUOTA_BIN=$(command -v quota-axi 2>/dev/null) || die "quota-axi is required"

PROFILE_LABELS=()
PROFILE_DIRS=()

add_profile() {
  local label=$1 config_dir=$2 existing_index
  case "$label" in
    ''|*[!A-Za-z0-9._-]*) die "invalid Claude account label in $PROFILE_FILE: $label" ;;
  esac
  existing_index=0
  while [ "$existing_index" -lt "${#PROFILE_LABELS[@]}" ]; do
    [ "${PROFILE_LABELS[$existing_index]}" != "$label" ] \
      || die "duplicate Claude account label in $PROFILE_FILE: $label"
    existing_index=$((existing_index + 1))
  done
  case "$config_dir" in
    default) ;;
    /*) ;;
    *) die "Claude account config directory must be 'default' or absolute: $config_dir" ;;
  esac
  PROFILE_LABELS+=("$label")
  PROFILE_DIRS+=("$config_dir")
}

if [ -e "$PROFILE_FILE" ] || [ -L "$PROFILE_FILE" ]; then
  [ -f "$PROFILE_FILE" ] && [ ! -L "$PROFILE_FILE" ] || die "Claude account profile file is not a regular file: $PROFILE_FILE"
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s\n' "$line" | awk '{$1=$1; print}')
    case "$line" in ''|'#'*) continue ;; esac
    IFS=' ' read -r label config_dir extra <<EOF
$line
EOF
    [ -n "${label:-}" ] && [ -n "${config_dir:-}" ] && [ -z "${extra:-}" ] \
      || die "invalid Claude account profile line: $line"
    add_profile "$label" "$config_dir"
  done < "$PROFILE_FILE"
else
  add_profile shiftcare default
  add_profile teohcapital "$HOME/.claude-teohcapital"
fi

[ "${#PROFILE_LABELS[@]}" -eq 2 ] || die "Claude account profile file must define exactly two profiles"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-claude-account-quota.XXXXXX") || die "could not create temporary directory"
MARKER_TMP=
cleanup() {
  rm -rf -- "$TMP_ROOT"
  [ -z "$MARKER_TMP" ] || rm -f -- "$MARKER_TMP"
}
trap cleanup EXIT HUP INT TERM
ACCOUNTS_FILE="$TMP_ROOT/accounts.jsonl"
: > "$ACCOUNTS_FILE" || die "could not initialize account summary"

unreadable_account() {
  local label=$1 config_dir=$2
  jq -cn --arg label "$label" --arg config_dir "$config_dir" '
    {
      account: $label,
      claudeConfigDir: (if $config_dir == "default" then null else $config_dir end),
      authState: "unreadable",
      scopes: [],
      limits: [
        {scope: "session", effectivePercentRemaining: null, limitedBy: "five_hour", resetsAt: null},
        {scope: "weekly", effectivePercentRemaining: null, limitedBy: "seven_day", resetsAt: null}
      ]
    }
  '
}

read_account() {
  local label=$1 config_dir=$2 raw=$3 parsed=$4
  if [ "$config_dir" = default ]; then
    env -u CLAUDE_CONFIG_DIR "$QUOTA_BIN" --provider claude --json --no-credential-refresh > "$raw" 2>/dev/null || return 1
  else
    CLAUDE_CONFIG_DIR="$config_dir" "$QUOTA_BIN" --provider claude --json --no-credential-refresh > "$raw" 2>/dev/null || return 1
  fi
  jq -ce --arg label "$label" --arg config_dir "$config_dir" '
    if .schemaVersion != 5 then error("unsupported schema") else . end |
    ([.providers[]? | select(.provider == "claude")] | if length == 1 then .[0] else error("missing Claude provider") end) as $provider |
    ($provider.windows // []) as $windows |
    def limit($id; $name):
      ([$provider.windows[]? | select(.id == $id and (.percentRemaining | type) == "number")] |
        if length == 1 then .[0] else error("missing quota window") end) as $window |
      {
        scope: $name,
        effectivePercentRemaining: $window.percentRemaining,
        limitedBy: $id,
        resetsAt: ($window.resetsAt // null)
      };
    def quota_scope:
      . as $availability |
      ($availability.limitingWindowIds // []) as $limiting_ids |
      {
        scope: $availability.scope,
        effectivePercentRemaining: $availability.effectivePercentRemaining,
        limitedBy: ($limiting_ids | join("+")),
        resetsAt: ([$limiting_ids[] as $id | $windows[] | select(.id == $id) | .resetsAt?] | first // null)
      };
    {
      account: $label,
      claudeConfigDir: (if $config_dir == "default" then null else $config_dir end),
      authState: "available",
      scopes: [$provider.quotaSemantics.effectiveAvailability[]? |
        select(.status == "known" and (.effectivePercentRemaining | type) == "number") |
        quota_scope],
      limits: [limit("five_hour"; "session"), limit("seven_day"; "weekly")]
    }
  ' "$raw" > "$parsed" 2>/dev/null
}

READABLE=0
index=0
while [ "$index" -lt 2 ]; do
  raw="$TMP_ROOT/profile-$index.raw"
  parsed="$TMP_ROOT/profile-$index.json"
  if read_account "${PROFILE_LABELS[$index]}" "${PROFILE_DIRS[$index]}" "$raw" "$parsed"; then
    cat "$parsed" >> "$ACCOUNTS_FILE"
    READABLE=$((READABLE + 1))
  else
    unreadable_account "${PROFILE_LABELS[$index]}" "${PROFILE_DIRS[$index]}" >> "$ACCOUNTS_FILE"
  fi
  index=$((index + 1))
done

ACCOUNTS_JSON=$(jq -cs '.' "$ACCOUNTS_FILE") || die "could not assemble account summary"
VERDICT_JSON=$(printf '%s\n' "$ACCOUNTS_JSON" | jq -ce --argjson threshold "$THRESHOLD" '
  def low_scopes($account):
    [$account.limits[] |
      select(.effectivePercentRemaining != null and .effectivePercentRemaining <= $threshold) |
      .scope];
  .[0] as $primary |
  .[1] as $fallback |
  low_scopes($primary) as $primary_low |
  low_scopes($fallback) as $fallback_low |
  if $primary.authState == "available" and ($primary_low | length) == 0 then
    {
      recommendedAccount: $primary.account,
      claudeConfigDir: $primary.claudeConfigDir,
      triggeringScope: "none",
      reason: "primary_within_threshold"
    }
  elif $fallback.authState == "available" and ($fallback_low | length) == 0 then
    {
      recommendedAccount: $fallback.account,
      claudeConfigDir: $fallback.claudeConfigDir,
      triggeringScope: (if $primary.authState != "available" then "primary_unreadable" else ($primary_low | join("+")) end),
      reason: (if $primary.authState != "available" then "primary_unreadable" else "primary_threshold_reached" end)
    }
  else
    {
      recommendedAccount: "none",
      claudeConfigDir: "none",
      triggeringScope: (if $primary.authState != "available" then "primary_unreadable" else ($primary_low | join("+")) end),
      reason: (if $fallback.authState != "available" then "fallback_unreadable" else "all_accounts_at_or_below_threshold" end)
    }
  end
') || die "could not compute Claude account verdict"

VERDICT_LINE=$(printf '%s\n' "$VERDICT_JSON" | jq -r '
  "SWITCH VERDICT recommendedAccount=\(.recommendedAccount) CLAUDE_CONFIG_DIR=\(if .claudeConfigDir == null then "unset" else .claudeConfigDir end) triggeringScope=\(.triggeringScope) reason=\(.reason)"
') || die "could not render Claude account verdict"

if [ "$READABLE" -eq 0 ]; then
  if [ "$CHECK_MODE" -eq 0 ]; then
    jq -cn --argjson threshold "$THRESHOLD" --argjson accounts "$ACCOUNTS_JSON" --argjson verdict "$VERDICT_JSON" \
      '{schemaVersion: 1, thresholdPercentRemaining: $threshold, accounts: $accounts, verdict: $verdict}'
    printf '%s\n' "$VERDICT_LINE"
  fi
  exit 1
fi

if [ "$CHECK_MODE" -eq 0 ]; then
  jq -cn --argjson threshold "$THRESHOLD" --argjson accounts "$ACCOUNTS_JSON" --argjson verdict "$VERDICT_JSON" \
    '{schemaVersion: 1, thresholdPercentRemaining: $threshold, accounts: $accounts, verdict: $verdict}'
  printf '%s\n' "$VERDICT_LINE"
  exit 0
fi

[ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is unavailable: $STATE"
MARKER="$STATE/claude-account-quota.verdict"
[ ! -e "$MARKER" ] || { [ -f "$MARKER" ] && [ ! -L "$MARKER" ]; } || die "verdict marker is unavailable: $MARKER"
if [ -f "$MARKER" ] && cmp -s "$MARKER" <(printf '%s\n' "$VERDICT_JSON"); then
  exit 0
fi
umask 077
MARKER_TMP=$(mktemp "$STATE/.claude-account-quota.verdict.XXXXXX") || die "could not create verdict marker"
printf '%s\n' "$VERDICT_JSON" > "$MARKER_TMP" || die "could not write verdict marker"
chmod 0600 "$MARKER_TMP" || die "could not secure verdict marker"
mv -f -- "$MARKER_TMP" "$MARKER" || die "could not replace verdict marker"
MARKER_TMP=
printf '%s\n' "$VERDICT_LINE"
