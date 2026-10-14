#!/usr/bin/env bash
# fm-daily-summary.sh - write the daily agent summary from this home's records.
# Usage: fm-daily-summary.sh generate|sample|observe [arguments...]
# This tracked shell entrypoint runs the sibling stdlib-only Python generator,
# whose header and --help own the subcommands, inputs, output files, and exit
# codes; docs/agent-daily-summary.md owns the file contract and the timers.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm-daily-summary.py" "$@"
