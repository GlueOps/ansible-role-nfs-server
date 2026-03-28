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

# Docker needs to read the key file for volume mount — relax perms on host,
# then fix inside the container before SSH uses it
chmod 644 "$KEY"

echo "=== Test target: $USER@$HOST:$PORT ==="

echo "=== Building Ansible runner container ==="
docker build -t glueops/ansible-role-nfs-server-test "$REPO_DIR" -q

ANSIBLE_ARGS="-i ${HOST}, -u ${USER} --become --private-key=/tmp/ssh_key -e ansible_port=${PORT} -e ansible_ssh_common_args='-o StrictHostKeyChecking=no'"

echo "=== Running Ansible (first run) ==="
docker run --rm \
  -e ANSIBLE_FORKS=1 \
  -v "${KEY}:/tmp/ssh_key_orig:ro" \
  glueops/ansible-role-nfs-server-test \
  -c "cp /tmp/ssh_key_orig /tmp/ssh_key && chmod 600 /tmp/ssh_key && ansible-playbook /ansible/playbook.yml $ANSIBLE_ARGS"

echo "=== Running Ansible (idempotency check) ==="
docker run --rm \
  -e ANSIBLE_FORKS=1 \
  -v "${KEY}:/tmp/ssh_key_orig:ro" \
  -v "${SCRIPT_DIR}/idempotency-check.sh:/tmp/idempotency-check.sh:ro" \
  glueops/ansible-role-nfs-server-test \
  -c "cp /tmp/ssh_key_orig /tmp/ssh_key && chmod 600 /tmp/ssh_key && bash /tmp/idempotency-check.sh /ansible/playbook.yml $ANSIBLE_ARGS --diff"

echo "=== All tests passed ==="
