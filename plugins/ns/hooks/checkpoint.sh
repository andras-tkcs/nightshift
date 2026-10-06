#!/usr/bin/env bash
set -euo pipefail
# Stop hook: commit the run ledger, then check the budget: a session that ends over its
# wall-clock budget is escalated at gate 1.5 (R-BUD-1). Does nothing outside a run or in a worker.
if [ -z "${NS_RUN_ID:-}" ] || [ -z "${NS_LEDGER:-}" ] || [ -n "${NS_WORKER:-}" ]; then
  exit 0
fi
if ! command -v ns-ledger >/dev/null 2>&1; then
  echo "ns checkpoint: ns-ledger not on PATH for $NS_RUN_ID" >&2
  exit 0
fi
ns-ledger checkpoint "$NS_LEDGER" --push >/dev/null 2>&1 || echo "ns checkpoint: failed for $NS_RUN_ID" >&2
rc=0
ns-conductor budget-check "$NS_RUN_ID" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 4 ]; then
  echo "ns checkpoint: $NS_RUN_ID used its budget (gate 1.5)" >&2
elif [ "$rc" -ne 0 ]; then
  echo "ns checkpoint: budget check failed for $NS_RUN_ID" >&2
fi
exit 0
