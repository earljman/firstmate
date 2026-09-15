#!/usr/bin/env bash
# Behavior tests for bin/fm-claude-account-quota.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SUBJECT="$ROOT/bin/fm-claude-account-quota.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-account-quota)

make_case() {
  local name=$1 home fakebin
  home="$TMP_ROOT/$name/home"
  fakebin="$TMP_ROOT/$name/fakebin"
  mkdir -p "$home/config" "$home/state" "$fakebin"
  cat > "$home/config/claude-account-profiles" <<EOF
shiftcare default
teohcapital $home/teoh-profile
EOF
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  profile=teohcapital
else
  profile=shiftcare
fi
fixture="$FM_QUOTA_FIXTURES/$profile.json"
[ -f "$fixture" ] || exit 1
cat "$fixture"
SH
  chmod 0700 "$fakebin/quota-axi"
  printf '%s|%s\n' "$home" "$fakebin"
}

write_quota() {
  local path=$1 session=$2 weekly=$3 session_reset=${4:-2026-09-15T10:00:00Z} weekly_reset=${5:-2026-09-20T00:00:00Z}
  jq -cn \
    --argjson session "$session" \
    --argjson weekly "$weekly" \
    --arg session_reset "$session_reset" \
    --arg weekly_reset "$weekly_reset" '
      {
        schemaVersion: 5,
        providers: [{
          provider: "claude",
          windows: [
            {id: "five_hour", kind: "session", percentRemaining: $session, resetsAt: $session_reset},
            {id: "seven_day", kind: "weekly", percentRemaining: $weekly, resetsAt: $weekly_reset}
          ],
          quotaSemantics: {
            status: "known",
            effectiveAvailability: [{
              scope: "all_models",
              status: "known",
              effectivePercentRemaining: ([$session, $weekly] | min),
              limitingWindowIds: (if $session <= $weekly then ["five_hour"] else ["seven_day"] end)
            }]
          }
        }]
      }
    ' > "$path"
}

run_case() {
  local home=$1 fakebin=$2 fixtures=$3
  shift 3
  HOME="$home" FM_HOME="$home" FM_QUOTA_FIXTURES="$fixtures" PATH="$fakebin:$PATH" "$SUBJECT" "$@"
}

verdict_json() { sed -n '1p' | jq -c '.verdict'; }

test_default_healthy_recommends_primary() {
  local rec home fakebin fixtures out verdict
  rec=$(make_case default-healthy)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  fixtures="$TMP_ROOT/default-healthy/fixtures"
  mkdir -p "$fixtures"
  write_quota "$fixtures/shiftcare.json" 70 80
  write_quota "$fixtures/teohcapital.json" 90 90
  out=$(run_case "$home" "$fakebin" "$fixtures")
  expect_code 0 $? "healthy primary read must succeed: $out"
  verdict=$(printf '%s\n' "$out" | verdict_json)
  assert_contains "$verdict" '"recommendedAccount":"shiftcare"' "healthy primary was not recommended"
  assert_contains "$verdict" '"claudeConfigDir":null' "default profile was not represented as an unset CLAUDE_CONFIG_DIR"
  assert_contains "$out" '"scope":"all_models","effectivePercentRemaining":70,"limitedBy":"five_hour","resetsAt":"2026-09-15T10:00:00Z"' "per-scope effective quota summary is incomplete"
  assert_contains "$out" 'SWITCH VERDICT recommendedAccount=shiftcare CLAUDE_CONFIG_DIR=unset' "human verdict did not identify the default profile"
  pass "fm-claude-account-quota.sh: healthy primary is recommended"
}

test_session_threshold_switches_to_fallback() {
  local rec home fakebin fixtures out verdict
  rec=$(make_case session-trigger)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  fixtures="$TMP_ROOT/session-trigger/fixtures"
  mkdir -p "$fixtures"
  write_quota "$fixtures/shiftcare.json" 20 80
  write_quota "$fixtures/teohcapital.json" 90 90
  out=$(run_case "$home" "$fakebin" "$fixtures")
  expect_code 0 $? "session threshold read must succeed: $out"
  verdict=$(printf '%s\n' "$out" | verdict_json)
  assert_contains "$verdict" '"recommendedAccount":"teohcapital"' "session threshold did not select fallback"
  assert_contains "$verdict" '"triggeringScope":"session"' "session threshold did not name its scope"
  pass "fm-claude-account-quota.sh: session threshold switches to fallback"
}

test_weekly_threshold_switches_to_fallback() {
  local rec home fakebin fixtures out verdict
  rec=$(make_case weekly-trigger)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  fixtures="$TMP_ROOT/weekly-trigger/fixtures"
  mkdir -p "$fixtures"
  write_quota "$fixtures/shiftcare.json" 70 20
  write_quota "$fixtures/teohcapital.json" 90 90
  out=$(run_case "$home" "$fakebin" "$fixtures")
  expect_code 0 $? "weekly threshold read must succeed: $out"
  verdict=$(printf '%s\n' "$out" | verdict_json)
  assert_contains "$verdict" '"recommendedAccount":"teohcapital"' "weekly threshold did not select fallback"
  assert_contains "$verdict" '"triggeringScope":"weekly"' "weekly threshold did not name its scope"
  pass "fm-claude-account-quota.sh: weekly threshold switches to fallback"
}

test_reset_recovery_changes_check_once() {
  local rec home fakebin fixtures first quiet recovered quiet_again
  rec=$(make_case reset-recovery)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  fixtures="$TMP_ROOT/reset-recovery/fixtures"
  mkdir -p "$fixtures"
  write_quota "$fixtures/shiftcare.json" 20 80
  write_quota "$fixtures/teohcapital.json" 90 90
  first=$(run_case "$home" "$fakebin" "$fixtures" --check)
  expect_code 0 $? "initial check must succeed: $first"
  assert_contains "$first" 'recommendedAccount=teohcapital' "initial check did not report fallback"
  quiet=$(run_case "$home" "$fakebin" "$fixtures" --check)
  expect_code 0 $? "unchanged check must succeed: $quiet"
  [ -z "$quiet" ] || fail "unchanged verdict emitted a wake line: $quiet"
  write_quota "$fixtures/shiftcare.json" 100 80
  recovered=$(run_case "$home" "$fakebin" "$fixtures" --check)
  expect_code 0 $? "recovery check must succeed: $recovered"
  assert_contains "$recovered" 'recommendedAccount=shiftcare' "reset recovery did not switch back to primary"
  quiet_again=$(run_case "$home" "$fakebin" "$fixtures" --check)
  [ -z "$quiet_again" ] || fail "recovered verdict emitted more than once: $quiet_again"
  pass "fm-claude-account-quota.sh: reset recovery wakes once and switches back"
}

test_both_accounts_exhausted_recommends_none() {
  local rec home fakebin fixtures out verdict
  rec=$(make_case both-exhausted)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  fixtures="$TMP_ROOT/both-exhausted/fixtures"
  mkdir -p "$fixtures"
  write_quota "$fixtures/shiftcare.json" 10 80
  write_quota "$fixtures/teohcapital.json" 90 10
  out=$(run_case "$home" "$fakebin" "$fixtures")
  expect_code 0 $? "both-exhausted read must still return a verdict: $out"
  verdict=$(printf '%s\n' "$out" | verdict_json)
  assert_contains "$verdict" '"recommendedAccount":"none"' "both exhausted accounts did not suppress Claude recommendation"
  assert_contains "$verdict" '"reason":"all_accounts_at_or_below_threshold"' "both exhausted verdict did not explain the threshold"
  pass "fm-claude-account-quota.sh: both exhausted accounts recommend none"
}

test_one_unreadable_profile_uses_the_healthy_other_profile() {
  local rec home fakebin fixtures out summary verdict
  rec=$(make_case one-unreadable)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  fixtures="$TMP_ROOT/one-unreadable/fixtures"
  mkdir -p "$fixtures"
  write_quota "$fixtures/teohcapital.json" 90 90
  out=$(run_case "$home" "$fakebin" "$fixtures")
  expect_code 0 $? "one readable profile must return a verdict: $out"
  summary=$(printf '%s\n' "$out" | sed -n '1p')
  verdict=$(printf '%s\n' "$summary" | jq -c '.verdict')
  assert_contains "$summary" '"account":"shiftcare","claudeConfigDir":null,"authState":"unreadable"' "failed primary profile was not labeled unreadable"
  assert_contains "$verdict" '"recommendedAccount":"teohcapital"' "healthy fallback was not selected after a primary read failure"
  assert_contains "$verdict" '"triggeringScope":"primary_unreadable"' "unreadable primary did not explain the switch"
  pass "fm-claude-account-quota.sh: one unreadable profile uses the healthy other profile"
}

test_total_failure_is_nonzero_and_check_is_silent() {
  local rec home fakebin fixtures out code
  rec=$(make_case total-failure)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  fixtures="$TMP_ROOT/total-failure/fixtures"
  mkdir -p "$fixtures"
  code=0
  out=$(run_case "$home" "$fakebin" "$fixtures" --check) || code=$?
  expect_code 1 "$code" "total read failure must exit nonzero"
  [ -z "$out" ] || fail "total-failure check emitted a wake line: $out"
  assert_absent "$home/state/claude-account-quota.verdict" "total failure replaced the last reliable verdict"
  pass "fm-claude-account-quota.sh: total failure is nonzero and check mode stays silent"
}

test_installed_custom_check_registers_and_emits_one_line() {
  local rec home fakebin fixtures check out quiet lines
  rec=$(make_case registered-check)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  fixtures="$TMP_ROOT/registered-check/fixtures"
  mkdir -p "$fixtures"
  write_quota "$fixtures/shiftcare.json" 20 80
  write_quota "$fixtures/teohcapital.json" 90 90
  check="$home/state/claude-account-quota.check.sh"
  install -m 0700 "$SUBJECT" "$check"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" claude-account-quota >/dev/null \
    || fail "quota account custom check could not be registered"
  out=$(HOME="$home" FM_HOME="$home" FM_QUOTA_FIXTURES="$fixtures" PATH="$fakebin:$PATH" "$check")
  expect_code 0 $? "registered quota account check must succeed: $out"
  lines=$(printf '%s\n' "$out" | awk 'NF { count += 1 } END { print count + 0 }')
  [ "$lines" -eq 1 ] || fail "registered quota account check emitted $lines lines: $out"
  assert_contains "$out" 'SWITCH VERDICT recommendedAccount=teohcapital' "registered check did not emit the changed verdict"
  quiet=$(HOME="$home" FM_HOME="$home" FM_QUOTA_FIXTURES="$fixtures" PATH="$fakebin:$PATH" "$check")
  [ -z "$quiet" ] || fail "registered quota account check repeated an unchanged verdict: $quiet"
  pass "fm-claude-account-quota.sh: installed custom check registers and emits one line"
}

test_default_healthy_recommends_primary
test_session_threshold_switches_to_fallback
test_weekly_threshold_switches_to_fallback
test_reset_recovery_changes_check_once
test_both_accounts_exhausted_recommends_none
test_one_unreadable_profile_uses_the_healthy_other_profile
test_total_failure_is_nonzero_and_check_is_silent
test_installed_custom_check_registers_and_emits_one_line
