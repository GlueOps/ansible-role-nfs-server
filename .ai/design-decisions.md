# Design Decisions

- **NFSv4-only**: v2/v3 disabled. No need for rpcbind (kept running but firewalled off on port 111).
- **`insecure` export option**: Required because Kubernetes clients use `noresvport`.
- **`root_squash` is implicit**: Not explicitly set — kernel default applies. Export dirs owned by `nobody:nogroup`.
- **Tags**: `nfs`, `base`, `updates` (never). Tags control what runs. `updates` requires explicit `--tags updates`.
- **Handler pattern**: Uses Ansible `listen` for ordered service restarts (daemon-reload → rpcbind → nfs-mountd → nfs-server).
- **No sysctl tuning**: Removed after expert review — kernel defaults on Ubuntu 24.04 are sufficient for low-usage workloads.
- **SSH port 2222**: Port 22 stays open in firewall for Tailscale. Password auth disabled, root password locked.
- **All dependencies pinned**: Python packages via `requirements.txt`, Ansible collection version in Dockerfile, Tailscale version pinned.
