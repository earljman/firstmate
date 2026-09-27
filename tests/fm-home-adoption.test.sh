#!/usr/bin/env bash
# Preserved adoption through public interfaces, with real transport/job worker
# and the deterministic Herdr backend fixture (never the operator's server).
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/remote-herdr-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"
TMP_ROOT=$(fm_test_tmproot fm-home-adoption)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
TARGET="$TMP_ROOT/target"
PARENT="$TMP_ROOT/parent"
mkdir -p "$TARGET" "$PARENT/data" "$PARENT/state"
cleanup() {
  if [ -f "$TMP_ROOT/jobs/worker.pid" ]; then kill "$(cat "$TMP_ROOT/jobs/worker.pid")" 2>/dev/null || true; fi
  chmod -R u+w "$TMP_ROOT" 2>/dev/null || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT
# Include new worktree files as well as tracked files, without private state.
(cd "$ROOT" && tar --exclude=.git --exclude=.task-evidence --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config --exclude=projects -cf - .) |
  (cd "$TARGET" && tar -xf -)
mkdir -p "$TARGET/data" "$TARGET/state" "$TARGET/config" "$TARGET/projects"
printf 'notes and holds stay here\n' > "$TARGET/data/sentinel"
printf 'pending correlation\n' > "$TARGET/state/sentinel"
printf 'local-only configuration\n' > "$TARGET/config/sentinel"
printf 'off\n' > "$TARGET/config/trace-context"
printf 'Own retained work. Report through state/parent-replies.status.\n' > "$TMP_ROOT/charter"
install_remote_herdr_fixture "$TARGET" "$TMP_ROOT/herdr.json" "$TMP_ROOT/herdr.log" "$TMP_ROOT/send-fail" "$TMP_ROOT/herdr.sock"
git -C "$TARGET" init -q -b main
git -C "$TARGET" config user.name Test
git -C "$TARGET" config user.email test@example.com
git -C "$TARGET" add .
git -C "$TARGET" commit -qm fixture
HEAD_BEFORE=$(git -C "$TARGET" rev-parse HEAD)
printf 'unlanded\n' > "$TARGET/unlanded.txt"
cp "$TARGET/data/sentinel" "$TMP_ROOT/data.before"
cp "$TARGET/state/sentinel" "$TMP_ROOT/state.before"
cp "$TARGET/config/sentinel" "$TMP_ROOT/config.before"
run_target() { PATH="$TARGET/bin:$PATH" FM_HOME="$TARGET" FM_ROOT_OVERRIDE="$TARGET" "$@"; }
refuse() {
  if "$@" > "$TMP_ROOT/refusal" 2>&1; then cat "$TMP_ROOT/refusal"; fail "expected refusal: $*"; fi
}
route() {
  printf -- '- old - retained operations (host: fixture-host; root: %s; home: %s; scope: retained work; projects: ; %sadded 2026-09-27)\n' "$TARGET" "$TARGET" "$1" > "$PARENT/data/secondmates.md"
}
route ''
refuse env FM_HOME="$PARENT" "$ROOT/bin/fm-home-seed.sh" validate
assert_grep 'overlapping remote root and home' "$TMP_ROOT/refusal" 'reproduces original equality refusal'
refuse env FM_HOME="$PARENT" "$ROOT/bin/fm-remote-home-seed.sh" old fixture-host "$TARGET" "$TARGET" --no-projects
OWNER=$(FM_HOME="$PARENT" "$ROOT/bin/fm-home-adopt.sh" identity)
# A forged registry exception cannot authorize the unadopted target entrypoint.
root_b64=$(printf '%s' "$TARGET" | base64 | tr -d '\n')
argv_b64=$(printf '%s\0' fm-adopted-home-control.sh "$OWNER" fm-remote-secondmate-control.sh state old | base64 | tr -d '\n')
refuse "$TARGET/bin/fm-remote-entrypoint.sh" 1 "$root_b64" "$root_b64" "$argv_b64"
assert_grep 'unless explicitly adopted' "$TMP_ROOT/refusal" 'transport requires target-side authorization'

refuse run_target "$ROOT/bin/fm-home-adopt.sh" prepare old "$OWNER" "$TMP_ROOT/charter" not-quiesced
assert_absent "$TARGET/.fm-home-adoption" 'unauthorized prepare must not publish'
run_target "$ROOT/bin/fm-home-adopt.sh" prepare old "$OWNER" "$TMP_ROOT/charter" --quiesced
refuse run_target "$ROOT/bin/fm-lock.sh"
refuse run_target "$ROOT/bin/fm-adopted-home-control.sh" "$OWNER" fm-remote-secondmate-control.sh state old
# A repeated preparation models retry after publication but before activation.
run_target "$ROOT/bin/fm-home-adopt.sh" prepare old "$OWNER" "$TMP_ROOT/charter" --quiesced
# Simulate death after a binding rename but before phase publication.
mkdir -p "$TMP_ROOT/failbin"
REAL_MV=$(command -v mv)
cat > "$TMP_ROOT/failbin/mv" <<'SH'
#!/usr/bin/env bash
"$TEST_REAL_MV" "$@" || exit $?
if [ "${!#}" = "$TEST_FAIL_DEST" ] && [ ! -e "$TEST_FAIL_ONCE" ]; then
  : > "$TEST_FAIL_ONCE"
  exit 77
fi
SH
chmod +x "$TMP_ROOT/failbin/mv"
refuse env PATH="$TMP_ROOT/failbin:$TARGET/bin:$PATH" TEST_REAL_MV="$REAL_MV" \
  TEST_FAIL_DEST="$TARGET/.fm-secondmate-parent" TEST_FAIL_ONCE="$TMP_ROOT/activate-failed" \
  FM_HOME="$TARGET" FM_ROOT_OVERRIDE="$TARGET" "$ROOT/bin/fm-home-adopt.sh" activate old "$OWNER"
refuse run_target "$ROOT/bin/fm-adopted-home-control.sh" "$OWNER" fm-remote-secondmate-control.sh state old
run_target "$ROOT/bin/fm-home-adopt.sh" activate old "$OWNER"
run_target "$ROOT/bin/fm-home-adopt.sh" activate old "$OWNER"
route "adopted-parent: $OWNER; "
FM_HOME="$PARENT" "$ROOT/bin/fm-home-seed.sh" validate > "$TMP_ROOT/validated"
pass 'root=home requires explicit preserved adoption and registry identity'
refuse run_target "$ROOT/bin/fm-adopted-home-control.sh" displaced-parent fm-remote-secondmate-control.sh state old
refuse run_target "$ROOT/bin/fm-remote-secondmate-control.sh" send old stale-parent
refuse run_target "$ROOT/bin/fm-remote-home-provision.sh"
refuse run_target "$ROOT/bin/fm-adopted-home-control.sh" "$OWNER" fm-remote-secondmate-control.sh retire old --force
run_target "$ROOT/bin/fm-adopted-home-control.sh" "$OWNER" fm-remote-secondmate-control.sh sync old
run_target "$ROOT/bin/fm-adopted-home-control.sh" "$OWNER" fm-remote-inherit.sh absent config/backend 0 ignored 1
for dir in data state config; do cmp "$TARGET/$dir/sentinel" "$TMP_ROOT/$dir.before" || fail "changed $dir sentinel"; done
[ "$(git -C "$TARGET" rev-parse HEAD)" = "$HEAD_BEFORE" ] || fail 'moved Git HEAD'
assert_present "$TARGET/unlanded.txt" 'unlanded work preserved'
pass 'displaced parent, reseed and retirement refused; private records and Git preserved'
# Ancestor overlap remains invalid even with an adoption identity.
sed "s@home: $TARGET;@home: $TARGET/child;@" "$PARENT/data/secondmates.md" > "$TMP_ROOT/bad-route"
cp "$TMP_ROOT/bad-route" "$PARENT/data/secondmates.md"
refuse env FM_HOME="$PARENT" "$ROOT/bin/fm-home-seed.sh" validate
# Ordinary disjoint homes sharing one host/root remain valid.
printf -- '- a - one (host: fixture-host; root: %s; home: %s/a; scope: one; projects: ; added 2026-09-27)\n- b - two (host: fixture-host; root: %s; home: %s/b; scope: two; projects: ; added 2026-09-27)\n' "$TARGET" "$TMP_ROOT" "$TARGET" "$TMP_ROOT" > "$PARENT/data/secondmates.md"
FM_HOME="$PARENT" "$ROOT/bin/fm-home-seed.sh" validate > "$TMP_ROOT/validated"
route "adopted-parent: $OWNER; "
# Transport uses the actual entrypoint and detached job worker with a fake SSH
# process that can only address this fixture. The only herdr is the fixture.
cat > "$TMP_ROOT/ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac; done
[ "$1" = fixture-host ] && [ "$2" = fm-remote-entrypoint.sh ] || exit 91
shift 2
exec "$TEST_ENTRY" "$@"
SH
chmod +x "$TMP_ROOT/ssh"
remote() {
  FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$TARGET" FM_SSH_BIN="$TMP_ROOT/ssh" \
    TEST_ENTRY="$TARGET/bin/fm-remote-entrypoint.sh" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
    FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/jobs" "$@"
}
remote "$TARGET/bin/fm-on.sh" old fm-remote-secondmate-control.sh state old > "$TMP_ROOT/state"
assert_grep 'missing' "$TMP_ROOT/state" 'identified transport reaches real controller'
# Drive the actual spawn boundary against the isolated deterministic backend.
remote "$TARGET/bin/fm-on.sh" old fm-remote-secondmate-control.sh launch old codex - - herdr > "$TMP_ROOT/launch"
assert_grep 'backend=herdr' "$TMP_ROOT/launch" 'root-home launch publishes real backend metadata'
remote "$TARGET/bin/fm-on.sh" old fm-remote-secondmate-control.sh state old > "$TMP_ROOT/state"
assert_grep 'alive' "$TMP_ROOT/state" 'adopted root-home agent recovers as alive'
assert_grep 'off' "$TARGET/config/trace-context" 'launch preserves session-scoped config too'
remote "$TARGET/bin/fm-on.sh" old fm-remote-secondmate-control.sh send old 'preserved route test' fire-and-forget > "$TMP_ROOT/send"
assert_present "$TARGET/state/parent-route/old.inbox/001.msg" 'identified send uses durable inbox'
mkdir -p "$TMP_ROOT/displaced/state" "$TMP_ROOT/displaced/data"
cp "$TARGET/state/parent-route/old.meta" "$TMP_ROOT/displaced/state/old.meta"
refuse env PATH="$TARGET/bin:$PATH" FM_HOME="$TMP_ROOT/displaced" FM_ROOT_OVERRIDE="$TARGET" \
  "$TARGET/bin/fm-send.sh" old 'stale metadata retry'
assert_grep 'fenced against this parent' "$TMP_ROOT/refusal" 'metadata-only stale parent is fenced without a registry'

pass 'identified root-home route runs through real transport, worker and backend integration'
# Rollback freezes new authority before restoring only original ownership bytes.
# A live endpoint blocks even an explicit quiescence assertion.
refuse run_target "$ROOT/bin/fm-home-adopt.sh" rollback old "$OWNER" --quiesced
reset_remote_herdr_fixture "$TMP_ROOT/herdr.json"
# Interrupt rollback after the first restored snapshot; the phase stays fenced.
refuse env PATH="$TMP_ROOT/failbin:$TARGET/bin:$PATH" TEST_REAL_MV="$REAL_MV" \
  TEST_FAIL_DEST="$TARGET/.fm-home-adoption/phase" TEST_FAIL_ONCE="$TMP_ROOT/rollback-failed" \
  FM_HOME="$TARGET" FM_ROOT_OVERRIDE="$TARGET" "$ROOT/bin/fm-home-adopt.sh" rollback old "$OWNER" --quiesced
refuse remote "$TARGET/bin/fm-on.sh" old fm-remote-secondmate-control.sh send old late-command
run_target "$ROOT/bin/fm-home-adopt.sh" rollback old "$OWNER" --quiesced
run_target "$ROOT/bin/fm-home-adopt.sh" rollback old "$OWNER" --quiesced
refuse run_target "$ROOT/bin/fm-home-adopt.sh" activate old "$OWNER"
refuse remote "$TARGET/bin/fm-on.sh" old fm-remote-secondmate-control.sh send old late-command
assert_absent "$TARGET/.fm-secondmate-home" 'rollback restores former primary identity'
assert_absent "$TARGET/.fm-secondmate-parent" 'rollback restores absent primary binding'
for dir in data state config; do cmp "$TARGET/$dir/sentinel" "$TMP_ROOT/$dir.before" || fail "rollback changed $dir sentinel"; done
assert_present "$TARGET/unlanded.txt" 'rollback preserves unlanded work'
pass 'rollback and delayed retries cannot reactivate new parent or restore stale operational records'

# Seeded disjoint homes retain the original identity, binding and charter on
# rollback, without copying or restoring any operational records.
LOCAL_TARGET="$TMP_ROOT/local-target"
mkdir -p "$LOCAL_TARGET/bin" "$LOCAL_TARGET/data" "$LOCAL_TARGET/state"
printf 'fixture\n' > "$LOCAL_TARGET/AGENTS.md"
printf 'mate\n' > "$LOCAL_TARGET/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$TMP_ROOT/displaced" > "$LOCAL_TARGET/.fm-secondmate-parent"
printf 'prior charter\n' > "$LOCAL_TARGET/data/charter.md"
cp "$LOCAL_TARGET/.fm-secondmate-parent" "$TMP_ROOT/prior-binding"
FM_HOME="$LOCAL_TARGET" "$ROOT/bin/fm-home-adopt.sh" prepare mate "$OWNER" "$TMP_ROOT/charter" --quiesced
FM_HOME="$LOCAL_TARGET" "$ROOT/bin/fm-home-adopt.sh" activate mate "$OWNER"
printf 'late reply\n' > "$LOCAL_TARGET/state/late-reply"
FM_HOME="$LOCAL_TARGET" "$ROOT/bin/fm-home-adopt.sh" rollback mate "$OWNER" --quiesced
cmp "$TMP_ROOT/prior-binding" "$LOCAL_TARGET/.fm-secondmate-parent" || fail 'local parent binding not restored'
assert_grep 'prior charter' "$LOCAL_TARGET/data/charter.md" 'original charter restored'
assert_grep 'late reply' "$LOCAL_TARGET/state/late-reply" 'rollback preserves late replies'
pass 'disjoint seeded-home handoff restores the exact former local parent'
