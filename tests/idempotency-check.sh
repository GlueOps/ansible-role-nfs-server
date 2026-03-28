#!/bin/bash
set -uo pipefail

LOGFILE=$(mktemp)
trap "rm -f $LOGFILE" EXIT

# Run ansible-playbook, stream output live and capture it
set +e
ansible-playbook "$@" 2>&1 | tee "$LOGFILE"
ANSIBLE_STATUS=${PIPESTATUS[0]}
set -e

# If ansible-playbook itself failed, exit with its status
if [ "$ANSIBLE_STATUS" -ne 0 ]; then
  echo ""
  echo "ANSIBLE PLAYBOOK FAILED (exit code $ANSIBLE_STATUS)"
  exit "$ANSIBLE_STATUS"
fi

# Check for changed=0 in the play recap
if grep -P 'changed=(?!0\b)\d+' "$LOGFILE" > /dev/null; then
  echo ""
  echo "IDEMPOTENCY CHECK FAILED — second run had changes"
  exit 1
fi

echo ""
echo "IDEMPOTENCY CHECK PASSED — no changes on second run"
