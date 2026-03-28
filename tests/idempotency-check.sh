#!/bin/bash
set -uo pipefail

# Run ansible-playbook and capture output + exit code
set +e
OUTPUT=$(ansible-playbook "$@" 2>&1)
ANSIBLE_STATUS=$?
set -e

echo "$OUTPUT"

# If ansible-playbook itself failed, exit with its status
if [ "$ANSIBLE_STATUS" -ne 0 ]; then
  echo ""
  echo "ANSIBLE PLAYBOOK FAILED (exit code $ANSIBLE_STATUS)"
  exit "$ANSIBLE_STATUS"
fi

# Check for changed=0 in the play recap
if echo "$OUTPUT" | grep -P 'changed=(?!0\b)\d+' > /dev/null; then
  echo ""
  echo "IDEMPOTENCY CHECK FAILED — second run had changes"
  exit 1
fi

echo ""
echo "IDEMPOTENCY CHECK PASSED — no changes on second run"
