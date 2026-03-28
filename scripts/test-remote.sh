#!/bin/bash
set -euo pipefail

# Usage: test-remote.sh --host <IP> --key <path> [--port <port>] [--user <user>]
# Runs on the host. Uses Docker only for Ansible execution.

HOST=""
KEY=""
PORT="22"
USER="root"

while [[ $# -gt 0 ]]; do
  case $1 in
    --host) HOST="$2"; shift 2 ;;
    --key) KEY="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --user) USER="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [ -z "$HOST" ] || [ -z "$KEY" ]; then
  echo "Usage: test-remote.sh --host <IP> --key <path> [--port <port>] [--user <user>]"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
KEY="$(cd "$(dirname "$KEY")" && pwd)/$(basename "$KEY")"

# Docker needs to read the key file for volume mount
chmod 644 "$KEY"

echo "=== Test target: $USER@$HOST:$PORT ==="

echo "=== Building Ansible runner container ==="
docker build -t glueops/ansible-role-nfs-server-test "$REPO_DIR" -q

echo "=== Running Ansible (first run) ==="
docker run --rm --network=host \
  -v "${KEY}:/tmp/ssh_key:ro" \
  -e ANSIBLE_SSH_ARGS="-o StrictHostKeyChecking=no" \
  --entrypoint ansible-playbook \
  glueops/ansible-role-nfs-server-test \
  /ansible/playbook.yml \
  -i "${HOST}," \
  -u "${USER}" \
  --become \
  --private-key=/tmp/ssh_key \
  -e "ansible_port=${PORT}"

echo "=== Running Ansible (idempotency check) ==="
docker run --rm --network=host \
  -v "${KEY}:/tmp/ssh_key:ro" \
  -v "${SCRIPT_DIR}/idempotency-check.sh:/tmp/idempotency-check.sh:ro" \
  -e ANSIBLE_SSH_ARGS="-o StrictHostKeyChecking=no" \
  --entrypoint bash \
  glueops/ansible-role-nfs-server-test \
  /tmp/idempotency-check.sh \
  /ansible/playbook.yml \
  -i "${HOST}," \
  -u "${USER}" \
  --become \
  --private-key=/tmp/ssh_key \
  -e "ansible_port=${PORT}" \
  --diff

echo "=== All tests passed ==="
