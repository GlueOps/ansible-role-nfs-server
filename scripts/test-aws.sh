#!/bin/bash
set -euo pipefail

# Usage: bash scripts/test-aws.sh
# Installs AWS CLI if missing. Requires: docker, ssh-keygen, curl, AWS credentials configured

echo "=== Checking prerequisites ==="
for cmd in docker ssh-keygen curl; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "ERROR: $cmd not found."
    exit 1
  fi
done

# Install AWS CLI if not present
if ! command -v aws &> /dev/null; then
  echo "=== Installing AWS CLI ==="
  curl -fsSL -o /tmp/awscliv2.zip "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
  unzip -q /tmp/awscliv2.zip -d /tmp
  sudo /tmp/aws/install
  rm -rf /tmp/awscliv2.zip /tmp/aws
  echo "$(aws --version) installed"
fi

aws sts get-caller-identity > /dev/null || { echo "ERROR: AWS credentials not configured"; exit 1; }

REGION="${AWS_REGION:-us-east-1}"
RUN_ID="nfs-test-$(date +%s)"
TEST_TMPDIR=$(mktemp -d)
INSTANCE_ID=""
SG_ID=""

cleanup() {
  echo "=== Cleaning up ==="
  if [ -n "$INSTANCE_ID" ]; then
    aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION" 2>/dev/null || true
    echo "Waiting for termination..."
    aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" --region "$REGION" 2>/dev/null || true
  fi
  aws ec2 delete-key-pair --key-name "$RUN_ID" --region "$REGION" 2>/dev/null || true
  if [ -n "$SG_ID" ]; then
    sleep 5
    aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION" 2>/dev/null || true
  fi
  rm -rf "$TEST_TMPDIR"
}
trap cleanup EXIT

echo "=== Generating SSH key ==="
ssh-keygen -t ed25519 -f "$TEST_TMPDIR/key" -N "" -q

echo "=== Importing SSH key to AWS ==="
aws ec2 import-key-pair \
  --key-name "$RUN_ID" \
  --public-key-material fileb://"$TEST_TMPDIR/key.pub" \
  --region "$REGION"

echo "=== Getting runner IP ==="
RUNNER_IP=$(curl -fsSL https://checkip.amazonaws.com)
echo "Runner IP: $RUNNER_IP"

echo "=== Creating security group ==="
VPC_ID=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text --region "$REGION")
SG_ID=$(aws ec2 create-security-group \
  --group-name "$RUN_ID" \
  --description "Temp SG for NFS role test" \
  --vpc-id "$VPC_ID" \
  --query 'GroupId' --output text \
  --region "$REGION")
echo "Security group: $SG_ID"

aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp --port 22 \
  --cidr "$RUNNER_IP/32" \
  --region "$REGION"

echo "=== Finding Ubuntu 24.04 AMI ==="
AMI_ID=$(aws ec2 describe-images \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
            "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
  --output text \
  --region "$REGION")
echo "AMI: $AMI_ID"

echo "=== Launching EC2 instance (t3a.large) ==="
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3a.large \
  --key-name "$RUN_ID" \
  --security-group-ids "$SG_ID" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$RUN_ID}]" \
  --query 'Instances[0].InstanceId' --output text \
  --region "$REGION")
echo "Instance: $INSTANCE_ID"

echo "Waiting for instance to be running..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"

SERVER_IP=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text \
  --region "$REGION")
echo "Server IP: $SERVER_IP"

echo "=== Waiting for SSH ==="
for i in $(seq 1 30); do
  if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
    -i "$TEST_TMPDIR/key" ubuntu@"$SERVER_IP" true 2>/dev/null; then
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
bash "$(dirname "$0")/test-remote.sh" --host "$SERVER_IP" --key "$TEST_TMPDIR/key" --user ubuntu
