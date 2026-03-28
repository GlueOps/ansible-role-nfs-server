# Design Decisions

- **NFSv4-only**: v2/v3 disabled. No need for rpcbind (kept running but firewalled off on port 111).
- **`insecure` export option**: Required because Kubernetes clients use `noresvport`.
- **`root_squash` is implicit**: Not explicitly set — kernel default applies. Export dirs owned by `nobody:nogroup`.
- **Tags**: `nfs`, `base`, `updates` (never). Tags control what runs. `updates` requires explicit `--tags updates`.
- **Handler pattern**: `restart nfs` uses shell to daemon-reload then stop+start nfs-server (systemctl restart fails on fresh Ubuntu 24.04 due to rpc_pipefs.target).
- **No sysctl tuning**: Removed after expert review — kernel defaults on Ubuntu 24.04 are sufficient for low-usage workloads.
- **SSH on port 22**: Password auth disabled, root password locked. Key-only or Tailscale SSH access.
- **All dependencies pinned**: Python packages via `requirements.txt`, Ansible collection version in Dockerfile, Tailscale version pinned.
