# ansible-role-nfs-server

Ansible role to configure an NFS v4.2 server on Ubuntu 24.04 LTS.

## What it configures

- Installs `nfs-kernel-server`
- `/etc/nfs.conf.d/10-glueops.conf` — thread count, NFSv4-only (v3 disabled). Shipped as a drop-in so the distro-managed `/etc/nfs.conf` stays intact
- `/etc/exports` — exports with multiple subnet support
- systemd drop-in overrides — `LimitNOFILE` for `nfs-mountd` and `rpcbind`
- `/etc/sysctl.d/60-glueops-nfs.conf` — network, writeback and cache tuning (see [Performance tuning](#performance-tuning))
- `/etc/security/limits.d/60-glueops-nfs.conf` — `nofile` limit for login sessions
- Firewall (ufw) — TCP 2049 from specified subnets, SSH on port 22, port 111 (rpcbind) blocked
- SSH hardening — password auth disabled, root key-only, root password locked. Applied via `/etc/ssh/sshd_config.d/00-hardening.conf`; the `00-` prefix is required so it wins over cloud-init's `50-cloud-init.conf` (sshd takes the first value it obtains)
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
| `nfs` | Install nfs-kernel-server, deploy the nfs.conf drop-in, exports, systemd overrides, kernel tuning, start services |
| `tuning` | Kernel sysctls and nofile limits only (a subset of `nfs`) |
| `base` | Install extra packages, configure ufw (firewall), SSH hardening, lock root password |
| `updates` | `apt update && apt dist-upgrade`, reports if reboot is needed. Skipped by default. |

### Override variables

Pass extra vars on the command line:

```bash
ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook /ansible/playbook.yml -i "100.x.x.x," -u root \
  -e '{"nfs_exports": [{"path": "/var/nfs/data", "owner": "nobody", "group": "nogroup", "mode": "0755", "options": "rw,sync,no_subtree_check,insecure,no_root_squash", "subnets": ["10.0.0.0/8"]}]}'
```

## Variables

| Variable | Default | Description |
|---|---|---|
| `nfs_threads` | `min(max(vcpus * 4, 16), 256)` | Number of nfsd threads |
| `nfs_mountd_threads` | `8` | Number of `rpc.mountd` threads (nfs-utils default is 1) |
| `nfs_exports` | See `defaults/main.yml` | List of exports (see below) |
| `nfs_allowed_subnets` | `["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]` | Subnets allowed through the firewall |
| `nfs_ulimit_nofile` | `524288` | `LimitNOFILE` for nfs-mountd and rpcbind, and the `nofile` limit for login sessions |
| `nfs_sysctl_settings` | See `defaults/main.yml` | Kernel tuning written to `/etc/sysctl.d/60-glueops-nfs.conf`. Set to `{}` to disable |
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
    options: "rw,sync,no_subtree_check,insecure,no_root_squash"  # optional; see role/defaults/main.yml
```

## Performance tuning

Applied by the `tuning` tag (included in `nfs`). Every value here is chosen to
be durability-neutral.

**What is *not* touched, deliberately:** exports stay `sync`. That is the
setting that decides whether the server may acknowledge a write before it is on
stable storage. `async` is the single largest NFS "speed-up" available and also
the one that loses acknowledged data on a server crash or power loss, because
the client believes a write completed that never reached disk and will not
replay it. The writeback sysctls below change *when* the kernel starts flushing,
not *whether* a stable write is flushed before it is acknowledged.

| Area | Setting | Why |
|---|---|---|
| nfsd | `nfs_threads` → `4 × vCPU`, min 16 | nfsd threads block on disk I/O, so the useful count tracks I/O concurrency, not CPU count. The stock 8 serialises under concurrent clients |
| mountd | `nfs_mountd_threads: 8` | nfs-utils defaults to **1**. Even v4-only, mountd answers the kernel's export-authentication upcalls, so one thread serialises first-touch from every client |
| Network | 16 MiB socket buffer ceiling, larger TCP autotune range | NFSv4.2 negotiates 1 MiB rsize/wsize, but the stock ~208 KiB cap stalls the sender waiting for ACKs above a sub-millisecond RTT |
| Network | `tcp_slow_start_after_idle=0` | NFS mounts are long-lived and bursty; by default the congestion window collapses to slow-start after every idle gap |
| Network | `tcp_mtu_probing=1` | Overlay networks (Tailscale, CNI encapsulation) can black-hole PMTU discovery, which hangs large writes |
| Network | `netdev_max_backlog` 1000 → 16384, `somaxconn` 4096 → 8192 | A dropped SYN costs the client a one-second retransmit; a dropped segment costs an RTO. Both surface as "NFS froze" |
| Writeback | `dirty_background_ratio=5`, `dirty_ratio=15` | NFSv4 clients send UNSTABLE writes then COMMIT, so dirty pages accumulate between the two. Flushing earlier means COMMIT drains a small backlog rather than a multi-gigabyte one |
| Cache | `swappiness=10`, `vfs_cache_pressure=50` | Metadata ops (LOOKUP, GETATTR, ACCESS) dominate most NFS workloads and are either a dentry-cache hit or a disk seek |

Rationale for each individual value is in `role/defaults/main.yml`, next to the
value. Override `nfs_sysctl_settings` to change them, or set it to `{}` to skip
sysctl tuning entirely — that removes `/etc/sysctl.d/60-glueops-nfs.conf`, but
note that values already applied to the running kernel persist until reboot.
Setting `{}` stops them being reapplied; it does not roll back the live values.

**Deliberately not set: `net.netfilter.nf_conntrack_max`.** The default (262144)
already scales with RAM, so pinning a fixed value is a no-op on a small host and
a *downgrade* on a large one. Conntrack exhaustion is a Kubernetes-node problem
— many short-lived connections — not an NFS-server one; a client node holds only
a handful of long-lived TCP connections to this host. If you do suspect it,
measure first: `conntrack -C` against `sysctl net.netfilter.nf_conntrack_max`.

### On `ulimit` — it is not a throughput knob

This is the tuning most people reach for first, and on an NFS server it does
essentially nothing. Worth stating plainly, because the role ships a
`LimitNOFILE` override that looks like it is doing more than it is:

- **nfsd has no fd limit at all.** It is kernel threads. `ulimit` is irrelevant
  to the data path; no value makes NFS itself faster.
- **`rpc.mountd` refuses a raised soft limit.** It calls `select()`, so it reads
  its own `RLIMIT_NOFILE` at startup and calls `setrlimit()` to force its soft
  limit back down to `FD_SETSIZE` (1024) — because glibc's sunrpc code has
  undefined behaviour past that. Verified: started with a soft limit of 524288,
  it reports 1024 and uses ~15 fds.
- **`rpcbind` uses about 9 fds**, and polls via libtirpc.
- **systemd's default is already `1024:524288`** (soft:hard). The role's default
  `nfs_ulimit_nofile: 524288` therefore matches the hard limit the units already
  had.

So `nfs_ulimit_nofile` is a **ceiling, not a target**. It is applied as
`LimitNOFILE=1024:<value>` and as a `hard` limit in
`/etc/security/limits.d/60-glueops-nfs.conf` — deliberately raising only the
hard limit, never the soft one. A bare `LimitNOFILE=N` sets *both*, and an
inflated soft limit is the part with real failure modes: it makes fd numbers
≥ 1024 reachable by programs still using `select()`. Raise it per-shell with
`ulimit -n` when a job genuinely needs it; that is what a hard limit is for.

The value is asserted against the host's actual `fs.nr_open`, read at runtime
(the historical default is 1048576, but systemd raises it to 1073741816 at boot
on 24.04). Above that ceiling PAM cannot open a session at all, which would
cost you SSH access to the host.

### The client side matters more

The largest NFS wins are mount options, and a server role cannot set them. On
your Kubernetes nodes / PV definitions:

- `nconnect=8` — multiple TCP connections per mount. Usually the single biggest
  throughput improvement, and it is client-only.
- `rsize=1048576,wsize=1048576` — modern clients negotiate this already, but
  worth asserting if an older PV pins it lower.
- `hard` (the default) — keep it. `soft` returns I/O errors on timeout instead
  of retrying, which turns a transient server hiccup into application-visible
  data loss. Do not trade this for responsiveness.

## Notes

- **`no_root_squash` is the default.** A client connecting as uid 0 stays uid 0
  on the server, rather than being mapped to `nobody`. See
  [design decisions](.ai/design-decisions.md) for why.

  **This means any client that can mount the export has root over all of its
  data.** The boundary is `subnets` (and the firewall), not uid mapping — so
  scope those to the hosts that genuinely need the export:

  ```yaml
  nfs_exports:
    - path: /var/nfs/general
      subnets: ["10.0.50.0/24"]   # the clients that need it, not all of RFC1918
  ```

  To restore the previous squashing behaviour, drop the option:

  ```yaml
  nfs_exports:
    - path: /var/nfs/general
      options: "rw,sync,no_subtree_check,insecure"
  ```

  Be aware of what squashing costs you: a process running as root on a client
  cannot read files that are not world-readable, and cannot `chown`. Backup and
  restore tooling needs both — under squashing a backup silently skips
  unreadable files while still reporting success, and a restore cannot
  reproduce ownership.

- **`nfs_allowed_subnets` changes are additive at the firewall.** The role adds
  a ufw rule per subnet and never removes rules for subnets you have taken out
  of the list. After narrowing the list, delete the stale rules by hand
  (`ufw status numbered`, then `ufw delete allow from <old-cidr> to any port
  2049 proto tcp`) or the firewall stays as open as it was. The `/etc/exports`
  narrowing is declarative and does take effect on its own.

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
