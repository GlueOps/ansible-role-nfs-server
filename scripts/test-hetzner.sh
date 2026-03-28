#!/bin/bash
set -euo pipefail

# Usage: HCLOUD_TOKEN=xxx bash scripts/test-hetzner.sh
# Installs hcloud CLI if missing. Requires: docker, ssh-keygen, curl

echo "=== Checking prerequisites ==="
for cmd in docker ssh-keygen curl; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "ERROR: $cmd not found."
    exit 1
  fi
done

if [ -z "${HCLOUD_TOKEN:-}" ]; then
  echo "ERROR: HCLOUD_TOKEN env var is required"
  exit 1
fi

# Install hcloud CLI if not present
if ! command -v hcloud &> /dev/null; then
  echo "=== Installing hcloud CLI ==="
  curl -fsSL -o /tmp/hcloud.tar.gz https://github.com/hetznercloud/cli/releases/latest/download/hcloud-linux-amd64.tar.gz
  sudo tar -xzf /tmp/hcloud.tar.gz -C /usr/local/bin hcloud
  rm /tmp/hcloud.tar.gz
  echo "hcloud $(hcloud version) installed"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_ID="nfs-test-$(date +%s)"
TEST_TMPDIR="$REPO_DIR/.test-tmp-$RUN_ID"
mkdir -p "$TEST_TMPDIR"
trap 'echo "=== Cleaning up ==="; hcloud server delete "$RUN_ID" 2>/dev/null || true; hcloud ssh-key delete "$RUN_ID" 2>/dev/null || true; rm -rf "$TEST_TMPDIR"' EXIT

echo "=== Generating SSH key ==="
ssh-keygen -t ed25519 -f "$TEST_TMPDIR/key" -N "" -q

echo "=== Uploading SSH key to Hetzner ==="
hcloud ssh-key create --name "$RUN_ID" --public-key-from-file "$TEST_TMPDIR/key.pub"

echo "=== Creating Hetzner server (cpx21, ubuntu-24.04) ==="
hcloud server create \
  --name "$RUN_ID" \
  --type cpx21 \
  --image ubuntu-24.04 \
  --ssh-key "$RUN_ID" \
  --location fsn1

SERVER_IP=$(hcloud server ip "$RUN_ID")
echo "Server IP: $SERVER_IP"

echo "=== Waiting for SSH ==="
for i in $(seq 1 30); do
  if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
    -i "$TEST_TMPDIR/key" root@"$SERVER_IP" true 2>/dev/null; then
    echo "SSH ready after $((i * 10))s"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "ERROR: SSH never became available"
    exit 1
  fi
  sleep 10
done

echo "=== Running integration test ==="
bash "$(dirname "$0")/test-remote.sh" --host "$SERVER_IP" --key "$TEST_TMPDIR/key" --user root
