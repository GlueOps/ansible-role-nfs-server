#!/bin/bash
set -euo pipefail

# Spins up two Hetzner VMs on a private network:
#   VM1: NFS server (role applied)
#   VM2: KIND cluster (mounts NFS, runs read/write test)
# Requires: HCLOUD_TOKEN env var, docker, ssh-keygen, curl

TEST_START=$(date +%s)
STEP_TIMES=()

step_start() {
  STEP_NAME="$1"
  STEP_START=$(date +%s)
  echo ""
  echo "=========================================="
  echo "=== $STEP_NAME"
  echo "=========================================="
}

step_end() {
  local elapsed=$(( $(date +%s) - STEP_START ))
  STEP_TIMES+=("${elapsed}s  ${STEP_NAME}")
  echo "--- ${STEP_NAME}: ${elapsed}s ---"
}

print_summary() {
  local total=$(( $(date +%s) - TEST_START ))
  echo ""
  echo "=========================================="
  echo "=== TEST SUMMARY"
  echo "=========================================="
  for entry in "${STEP_TIMES[@]}"; do
    printf "  %-6s %s\n" "${entry%%  *}" "${entry#*  }"
  done
  echo "  ------ --------------------------------"
  printf "  %-6s %s\n" "${total}s" "TOTAL"
  echo "=========================================="
}

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

step_start "Nuke existing resources"
docker run --rm -e HCLOUD_TOKEN="$HCLOUD_TOKEN" \
  -v "$(cd "$(dirname "$0")" && pwd)/hetzner-nuke-config.yml:/config.yaml:ro" \
  ghcr.io/cgroschupp/hetzner-nuke:v0.6.2 run --config /config.yaml --no-dry-run --no-prompt || true

step_end

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
  docker run --rm -e HCLOUD_TOKEN="$HCLOUD_TOKEN" \
  -v "$(cd "$(dirname "$0")" && pwd)/hetzner-nuke-config.yml:/config.yaml:ro" \
  ghcr.io/cgroschupp/hetzner-nuke:v0.6.2 run --config /config.yaml --no-dry-run --no-prompt || true
  rm -rf "$TEST_TMPDIR"
}
trap cleanup EXIT INT TERM

step_start "Create infrastructure"
ssh-keygen -t ed25519 -f "$TEST_TMPDIR/key" -N "" -q

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

step_end

step_start "Wait for SSH"
for VM_IP in "$NFS_PUBLIC_IP" "$K8S_PUBLIC_IP"; do
  echo "Waiting for SSH on $VM_IP..."
  for i in $(seq 1 60); do
    SSH_OUT=$(ssh -v -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 \
      -i "$TEST_TMPDIR/key" root@"$VM_IP" true 2>&1) && {
      echo "  SSH ready on $VM_IP after ${i}s"
      break
    }
    if [ "$((i % 10))" -eq 0 ]; then
      echo "  Still waiting after ${i}s... last SSH output:"
      echo "$SSH_OUT" | tail -3 | sed 's/^/    /'
    fi
    if [ "$i" -eq 60 ]; then
      echo "ERROR: SSH never became available on $VM_IP"
      echo "Last SSH output:"
      echo "$SSH_OUT"
      exit 1
    fi
    sleep 1
  done
done

step_end

step_start "Apply NFS role"
bash "$SCRIPT_DIR/test-remote.sh" --host "$NFS_PUBLIC_IP" --key "$TEST_TMPDIR/key" --user root

step_end

step_start "Setup KIND cluster"
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

step_end

step_start "NFS read/write test"

# Generate K8s manifests with the actual NFS server IP
cat > "$TEST_TMPDIR/nfs-test.yaml" <<EOF
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
    - timeo=600
    - retrans=2
    - rsize=1048576
    - wsize=1048576
    - noresvport
    - hard
  nfs:
    server: ${NFS_PRIVATE_IP}
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
---
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
EOF

# Copy manifests to K8s VM and apply
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i "$TEST_TMPDIR/key" "$TEST_TMPDIR/nfs-test.yaml" root@"$K8S_PUBLIC_IP":/tmp/nfs-test.yaml

ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i "$TEST_TMPDIR/key" root@"$K8S_PUBLIC_IP" bash <<'TESTEOF'
set -euo pipefail

echo "=== Applying NFS test manifests ==="
kubectl apply -f /tmp/nfs-test.yaml

echo "=== Cluster state after apply ==="
echo "--- Nodes ---"
kubectl get nodes -o wide
echo "--- PVs ---"
kubectl get pv -o wide
echo "--- PVCs ---"
kubectl get pvc -o wide
echo "--- Pods ---"
kubectl get pods -o wide

echo "=== Waiting for writer pod ==="
kubectl wait --for=condition=Ready pod/nfs-writer --timeout=120s || true
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/nfs-writer --timeout=120s || true

echo "--- Writer pod status ---"
kubectl get pod nfs-writer -o wide
echo "--- Writer pod logs ---"
kubectl logs nfs-writer
echo "--- Writer pod describe ---"
kubectl describe pod nfs-writer

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

echo "=== Waiting for reader pod ==="
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/nfs-reader --timeout=120s || true

echo "--- Reader pod status ---"
kubectl get pod nfs-reader -o wide
echo "--- Reader pod logs ---"
RESULT=$(kubectl logs nfs-reader)
echo "Read result: $RESULT"
echo "--- Reader pod describe ---"
kubectl describe pod nfs-reader

echo "=== Final cluster state ==="
echo "--- All pods ---"
kubectl get pods -A -o wide
echo "--- All PVs ---"
kubectl get pv -o wide
echo "--- All PVCs ---"
kubectl get pvc -o wide
echo "--- Events ---"
kubectl get events --sort-by='.lastTimestamp' | tail -20

if [ "$RESULT" = "nfs-test-ok" ]; then
  echo "NFS READ/WRITE TEST PASSED"
else
  echo "NFS READ/WRITE TEST FAILED — expected 'nfs-test-ok', got '$RESULT'"
  exit 1
fi
TESTEOF
echo ""

step_end

print_summary
echo ""
echo "=== ALL TESTS PASSED ==="
