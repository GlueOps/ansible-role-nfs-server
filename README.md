# ansible-role-nfs-server

Ansible role to configure an NFS v4.2 server on Ubuntu 24.04 LTS.

## What it configures

- Installs `nfs-kernel-server`
- `/etc/nfs.conf` — thread count, NFSv4-only (v2/v3 disabled)
- `/etc/exports` — exports with multiple subnet support
- systemd drop-in overrides — `LimitNOFILE` for `nfs-mountd` and `rpcbind`
- Firewall (ufw) — TCP 2049 from specified subnets, SSH on port 22, port 111 (rpcbind) blocked
- SSH hardening — password auth disabled, root key-only, root password locked
- Extra packages (tmux, curl, htop by default)
- Service restart — nfs-server (stop+start with daemon-reload)

## Quick start

### Pull the container

```bash
docker pull ghcr.io/glueops/ansible-role-nfs-server:latest
```

### Run the container

```bash
docker run --rm -it --cap-add=NET_ADMIN --device=/dev/net/tun \
  ghcr.io/glueops/ansible-role-nfs-server:latest
```

This drops you into a shell with Ansible, Tailscale, and the role ready to go.

### Connect and run

**Option 1: Tailscale SSH**

```bash
# Inside the container:
tailscaled --state=/var/lib/tailscale/tailscaled.state &
sleep 2
tailscale up --hostname="ansible-nfs-runner" --ssh
# Click the login URL, then:
ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook /ansible/playbook.yml -i "100.x.x.x," -u root
```

**Option 2: SSH key**

```bash
# Mount your key when starting the container:
docker run --rm -it \
  -v ~/.ssh/id_rsa:/root/.ssh/id_rsa:ro \
  ghcr.io/glueops/ansible-role-nfs-server:latest

# Inside the container:
ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook /ansible/playbook.yml -i "10.0.50.10," -u root --private-key=/root/.ssh/id_rsa
```

### Tags

Run specific subsets of the role:

```bash
# Everything (NFS + base, but NOT updates)
ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook /ansible/playbook.yml -i "100.x.x.x," -u root

# Only NFS config
ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook /ansible/playbook.yml -i "100.x.x.x," -u root --tags nfs

# Only base setup (firewall, SSH, extra packages)
ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook /ansible/playbook.yml -i "100.x.x.x," -u root --tags base

# Update and upgrade all packages (must be explicitly requested)
ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook /ansible/playbook.yml -i "100.x.x.x," -u root --tags updates
```

| Tag | What it does |
|---|---|
| `nfs` | Install nfs-kernel-server, deploy nfs.conf, exports, systemd overrides, start services |
| `base` | Install extra packages, configure ufw (firewall), SSH hardening, lock root password |
| `updates` | `apt update && apt dist-upgrade`, reports if reboot is needed. Skipped by default. |

### Override variables

Pass extra vars on the command line:

```bash
ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook /ansible/playbook.yml -i "100.x.x.x," -u root \
  -e '{"nfs_exports": [{"path": "/var/nfs/data", "owner": "nobody", "group": "nogroup", "mode": "0755", "options": "rw,sync,no_subtree_check,insecure", "subnets": ["10.0.0.0/8"]}]}'
```

## Variables

| Variable | Default | Description |
|---|---|---|
| `nfs_threads` | `max(vcpus * 2, 8)` | Number of nfsd threads |
| `nfs_exports` | See `defaults/main.yml` | List of exports (see below) |
| `nfs_allowed_subnets` | `["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]` | Subnets allowed through the firewall |
| `nfs_ulimit_nofile` | `524288` | LimitNOFILE for nfs-mountd and rpcbind |
| `nfs_extra_packages` | `[tmux, curl, htop]` | Additional packages to install |

### Export format

```yaml
nfs_exports:
  - path: /var/nfs/general
    owner: nobody
    group: nogroup
    mode: "0755"
    subnets:
      - "10.0.0.0/8"
      - "172.16.0.0/12"
    options: "rw,sync,no_subtree_check,insecure"  # optional, this is the default
```

## Notes

- **Password auth disabled**: After the role runs, only SSH key and Tailscale SSH access work. Ensure your key is on the server before running.
- **idmapd domain**: NFSv4 uses `idmapd` to map UIDs to usernames. If your NFS server and clients have different DNS domains, files may appear owned by `nobody:nogroup` on the client. Fix by setting the same `Domain` in `/etc/idmapd.conf` on both server and clients.
- **Tailscale flags**: `--cap-add=NET_ADMIN --device=/dev/net/tun` are required for Tailscale to create its VPN tunnel inside the container. Not needed if you're only using SSH key or password auth on a reachable network.

## Testing

### Linting

Linting runs automatically during `docker build` (yamllint, ansible-lint, syntax-check). To build and lint locally:

```bash
docker build -f docker/Dockerfile .
```

### Integration test

The integration test spins up two Hetzner VMs on a private network, applies the NFS role, checks idempotency, then sets up a KIND cluster and verifies NFS read/write from Kubernetes.

**Prerequisites:** `docker`, `ssh-keygen`, `curl`, and a `HCLOUD_TOKEN`

```bash
export HCLOUD_TOKEN=your-token
bash tests/test-hetzner.sh

# Test with a specific Kubernetes version
K8S_VERSION=v1.34.3 bash tests/test-hetzner.sh
```

**What it tests:**
1. Applies the NFS role to VM1 (must succeed)
2. Runs the role again (idempotency — must report `changed=0`)
3. Creates a KIND cluster on VM2 (with optional K8s version)
4. Mounts NFS from VM1 via Kubernetes PV/PVC
5. Writes a file from a pod, reads it from another pod
6. Cleans up Hetzner resources on exit

In CI, the test runs as a matrix against K8s v1.35, v1.34, and v1.33 in parallel. Triggered by adding the `run-tests` label to a PR.

### Run against your own server

```bash
bash tests/test-remote.sh --host <IP> --key <path-to-ssh-key> --user root
```

This builds the Docker container, runs the playbook, then runs it again to verify idempotency.

## Monitoring

This role does not install monitoring tools. If you use Prometheus `node_exporter`, the built-in `nfsd` collector exposes thread utilization, RPC stats, and error counts with no extra configuration.

Key things to watch:
- `nfsstat -s` — server operation stats
- `cat /proc/fs/nfsd/threads` — thread utilization
- `ss -tnp | grep 2049` — active connections
- Disk usage on export paths

## Requirements

- Ubuntu 24.04 LTS (target)
- Docker (to pull and run the container)
