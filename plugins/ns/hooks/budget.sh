#!/usr/bin/env bash
set -euo pipefail
# PreToolUse hook: stop a conductor session that works past its wall-clock budget (R-BUD-1).
# Does nothing outside a run or in a worker.
if [ -z "${NS_RUN_ID:-}" ] || [ -z "${NS_LEDGER:-}" ] || [ -n "${NS_WORKER:-}" ]; then
  exit 0
fi
exec python3 "$(dirname "$0")/lib/budget.py"
