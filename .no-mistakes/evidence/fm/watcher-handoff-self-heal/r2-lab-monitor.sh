#!/usr/bin/env bash
# usage: r2-lab-monitor.sh <lab> <owner-out> <seconds> <interval>
LAB=$1 OUTF=$2 SECS=$3 INT=$4; t=0
while [ "$t" -le "$SECS" ]; do
  echo "=== t+${t}s $(date -u +%H:%M:%S)"
  echo "--- pane tail"; TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -p -t primary | grep -v '^\s*$' | tail -9
  echo "--- owner out"; cat "$OUTF"
  echo "--- delivery: $(cat "$LAB/state/.watch-handoff-delivery" 2>/dev/null)"
  echo "--- escalation: $(cat "$LAB/state/.watch-handoff-escalation" 2>/dev/null)"
  echo "--- queue:"; cat "$LAB/state/.wake-queue" 2>/dev/null
  echo "--- main-eligible: $(tr '\n' ' ' < "$LAB/state/.main-eligible-rows" 2>/dev/null)"
  echo "--- inbox: $(ls "$LAB/state/operational-inbox" 2>/dev/null | tr '\n' ' ')"
  sleep "$INT"; t=$((t+INT))
done
