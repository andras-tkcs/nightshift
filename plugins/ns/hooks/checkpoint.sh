#!/usr/bin/env bash
set -euo pipefail
# Stop hook: commit the run ledger. Does nothing outside a run or in a worker.
if [ -z "${NS_RUN_ID:-}" ] || [ -z "${NS_LEDGER:-}" ] || [ -n "${NS_WORKER:-}" ]; then
  exit 0
fi
if ! command -v ns-ledger >/dev/null 2>&1; then
  echo "ns checkpoint: ns-ledger not on PATH for $NS_RUN_ID" >&2
  exit 0
fi
ns-ledger checkpoint "$NS_LEDGER" --push >/dev/null 2>&1 || echo "ns checkpoint: failed for $NS_RUN_ID" >&2
exit 0
