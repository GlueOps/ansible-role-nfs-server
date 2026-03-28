#!/bin/bash
set -euo pipefail

# Spins up two Hetzner VMs on a private network:
#   VM1: NFS server (role applied)
#   VM2: KIND cluster (mounts NFS, runs read/write test)
# Requires: HCLOUD_TOKEN env var, docker, ssh-keygen, curl

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

NFS_SERVER="${RUN_ID}-nfs"
K8S_NODE="${RUN_ID}-k8s"
NETWORK="${RUN_ID}-net"
NFS_PRIVATE_IP=""
K8S_PRIVATE_IP=""
LOCATION="hel1"
SERVER_TYPE="cpx32"

cleanup() {
  echo "=== Cleaning up ==="
  hcloud server delete "$NFS_SERVER" 2>/dev/null || true
  hcloud server delete "$K8S_NODE" 2>/dev/null || true
  # Wait for servers to be deleted before removing network
  sleep 5
  hcloud network delete "$NETWORK" 2>/dev/null || true
  hcloud ssh-key delete "$RUN_ID" 2>/dev/null || true
  rm -rf "$TEST_TMPDIR"
}
trap cleanup EXIT

echo "=== Generating SSH key ==="
ssh-keygen -t ed25519 -f "$TEST_TMPDIR/key" -N "" -q
chmod 644 "$TEST_TMPDIR/key"

echo "=== Uploading SSH key to Hetzner ==="
hcloud ssh-key create --name "$RUN_ID" --public-key-from-file "$TEST_TMPDIR/key.pub"

echo "=== Creating private network ==="
hcloud network create --name "$NETWORK" --ip-range 10.0.0.0/16
hcloud network add-subnet "$NETWORK" --type server --network-zone eu-central --ip-range 10.0.1.0/24

echo "=== Creating NFS server VM ==="
hcloud server create \
  --name "$NFS_SERVER" \
  --type "$SERVER_TYPE" \
  --image ubuntu-24.04 \
  --ssh-key "$RUN_ID" \
  --location "$LOCATION" \
  --network "$NETWORK"

NFS_PUBLIC_IP=$(hcloud server ip "$NFS_SERVER")
NFS_PRIVATE_IP=$(hcloud server describe "$NFS_SERVER" -o json | python3 -c "import sys,json; print(json.load(sys.stdin)['private_net'][0]['ip'])")
echo "NFS server public IP: $NFS_PUBLIC_IP"
echo "NFS server private IP: $NFS_PRIVATE_IP"

echo "=== Creating Kubernetes VM ==="
hcloud server create \
  --name "$K8S_NODE" \
  --type "$SERVER_TYPE" \
  --image ubuntu-24.04 \
  --ssh-key "$RUN_ID" \
  --location "$LOCATION" \
  --network "$NETWORK"

K8S_PUBLIC_IP=$(hcloud server ip "$K8S_NODE")
K8S_PRIVATE_IP=$(hcloud server describe "$K8S_NODE" -o json | python3 -c "import sys,json; print(json.load(sys.stdin)['private_net'][0]['ip'])")
echo "K8s node public IP: $K8S_PUBLIC_IP"
echo "K8s node private IP: $K8S_PRIVATE_IP"

echo "=== Waiting for SSH on both VMs ==="
for VM_IP in "$NFS_PUBLIC_IP" "$K8S_PUBLIC_IP"; do
  echo "Waiting for SSH on $VM_IP..."
  for i in $(seq 1 30); do
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
      -i "$TEST_TMPDIR/key" root@"$VM_IP" true 2>/dev/null; then
      echo "  SSH ready on $VM_IP after $((i * 10))s"
      break
    fi
    echo "  Attempt $i/30 — waiting..."
    if [ "$i" -eq 30 ]; then
      echo "ERROR: SSH never became available on $VM_IP"
      exit 1
    fi
    sleep 10
  done
done

echo "=== Applying NFS role to server ==="
bash "$SCRIPT_DIR/test-remote.sh" --host "$NFS_PUBLIC_IP" --key "$TEST_TMPDIR/key" --user root

echo "=== Setting up KIND on Kubernetes VM ==="
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i "$TEST_TMPDIR/key" root@"$K8S_PUBLIC_IP" bash <<'SETUP_EOF'
set -euo pipefail

# Install Docker
curl -fsSL https://get.docker.com | sh

# Install kubectl
curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl

# Install KIND
curl -fsSL -o /usr/local/bin/kind "https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64"
chmod +x /usr/local/bin/kind

# Install NFS client
apt-get update -qq && apt-get install -y -qq nfs-common

# Create KIND cluster
kind create cluster --wait 120s

echo "KIND cluster ready"
kubectl get nodes
SETUP_EOF

echo "=== Running NFS read/write test from Kubernetes ==="
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i "$TEST_TMPDIR/key" root@"$K8S_PUBLIC_IP" bash <<TESTEOF
set -euo pipefail

NFS_SERVER_IP="$NFS_PRIVATE_IP"

# Create PV and PVC
cat <<'K8S' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: nfs-test-pv
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteMany
  mountOptions:
    - nfsvers=4.2
    - hard
    - noresvport
  nfs:
    server: NFS_SERVER_PLACEHOLDER
    path: /var/nfs/general
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nfs-test-pvc
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Gi
  volumeName: nfs-test-pv
  storageClassName: ""
K8S

# Replace placeholder with actual IP
kubectl get pv nfs-test-pv -o yaml | sed "s/NFS_SERVER_PLACEHOLDER/\$NFS_SERVER_IP/" | kubectl apply -f -

# Create write pod
cat <<'K8S' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: nfs-writer
spec:
  containers:
    - name: writer
      image: busybox
      command: ['sh', '-c', 'echo "nfs-test-ok" > /mnt/nfs/testfile && echo "WRITE OK" && sleep 10']
      volumeMounts:
        - name: nfs-vol
          mountPath: /mnt/nfs
  volumes:
    - name: nfs-vol
      persistentVolumeClaim:
        claimName: nfs-test-pvc
  restartPolicy: Never
K8S

echo "Waiting for writer pod..."
kubectl wait --for=condition=Ready pod/nfs-writer --timeout=120s || true
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/nfs-writer --timeout=120s || true
kubectl logs nfs-writer

# Create read pod
cat <<'K8S' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: nfs-reader
spec:
  containers:
    - name: reader
      image: busybox
      command: ['sh', '-c', 'cat /mnt/nfs/testfile']
      volumeMounts:
        - name: nfs-vol
          mountPath: /mnt/nfs
  volumes:
    - name: nfs-vol
      persistentVolumeClaim:
        claimName: nfs-test-pvc
  restartPolicy: Never
K8S

echo "Waiting for reader pod..."
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/nfs-reader --timeout=120s || true
RESULT=\$(kubectl logs nfs-reader)
echo "Read result: \$RESULT"

if [ "\$RESULT" = "nfs-test-ok" ]; then
  echo "NFS READ/WRITE TEST PASSED"
else
  echo "NFS READ/WRITE TEST FAILED — expected 'nfs-test-ok', got '\$RESULT'"
  kubectl describe pod nfs-writer
  kubectl describe pod nfs-reader
  exit 1
fi
TESTEOF

echo "=== All tests passed ==="
