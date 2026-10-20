#!/usr/bin/env bash
# Lab driver: launch the production handoff owner against the real lab Claude pane.
# usage: lab-driver.sh <lab> <worktree> <gen> <reason> <grace> <retries> <outfile>
set -u
LAB=$1 WT=$2 GEN=$3 REASON=$4 GRACE=$5 RETRIES=$6 OUTF=$7
export FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux"
SESSION=$(TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab display -p -t primary '#{pane_pid}')
printf '%s\n' "$SESSION" > "$LAB/state/.lock"
printf 'epoch=%s owner_pid=%s outcome=rewake updated_at=%s\n' "$GEN" "$SESSION" "$(date +%s)" > "$LAB/state/.claude-autoarm-epoch"
IDENT=$(bash -c '. "$1/bin/fm-wake-lib.sh"; fm_pid_identity "$2"' bash "$WT" "$SESSION")
bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_append stale lab-task "$2"' bash "$WT" "$REASON"
echo "session=$SESSION ident=$IDENT queue:"; cat "$LAB/state/.wake-queue"
# tmux(1) inside the backend must address the lab server: the pane's own $TMUX names it.
TMUXV=$(tr "\0" "\n" < /proc/"$SESSION"/environ | sed -n "s/^TMUX=//p")
env -u NO_MISTAKES_GATE TMUX="$TMUXV" TMUX_PANE=%0 \
  FM_WATCH_HANDOFF_GEN="$GEN" FM_WATCH_HANDOFF_SESSION="$SESSION" FM_WATCH_HANDOFF_IDENTITY="$IDENT" \
  FM_WATCH_HANDOFF_REASON="$REASON" FM_WATCH_HANDOFF_GRACE="$GRACE" FM_WATCH_HANDOFF_RETRIES="$RETRIES" \
  FM_SUPERVISOR_TARGET=%0 FM_SUPERVISOR_BACKEND=tmux \
  nohup "$WT/bin/fm-watch-handoff.sh" > "$OUTF" 2>&1 < /dev/null &
echo "owner_pid=$!"
