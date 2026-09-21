#!/usr/bin/env bash
# Export local agent chat logs using the sibling stdlib-only Python exporter.
# Usage: fm-chat-export.sh [fm-chat-export.py arguments...]
# This tracked shell entrypoint also supports fm-on.sh remote execution.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm-chat-export.py" "$@"
