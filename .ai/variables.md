# Variables

All variables are prefixed with `nfs_` and defined in `defaults/main.yml`:

- `nfs_threads` — dynamic: `max(vcpus * 2, 8)`, requires `gather_facts: true`
- `nfs_exports` — list of exports with path, owner, group, mode, options, subnets
- `nfs_allowed_subnets` — firewall allowlist for TCP 2049 (all RFC 1918 by default)
- `nfs_ulimit_nofile` — systemd LimitNOFILE for nfs-mountd and rpcbind
- `nfs_ssh_port` — SSH listen port (default 2222)
- `nfs_extra_packages` — additional apt packages to install
