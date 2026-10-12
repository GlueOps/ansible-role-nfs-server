# Variables

All variables are prefixed with `nfs_` and defined in `defaults/main.yml`:

- `nfs_threads` — dynamic: `min(max(vcpus * 4, 16), 256)` when facts are available; falls back to `16` otherwise
- `nfs_mountd_threads` — `rpc.mountd` threads (default `8`; nfs-utils itself defaults to 1)
- `nfs_exports` — list of exports with path, owner, group, mode, options, subnets
- `nfs_allowed_subnets` — firewall allowlist for TCP 2049 (all RFC 1918 by default)
- `nfs_ulimit_nofile` — nofile **hard** ceiling for nfs-mountd/rpcbind (`LimitNOFILE=1024:<value>`) and for PAM login sessions. Not a performance knob — see design-decisions. Asserted ≤ the host's `fs.nr_open`
- `nfs_sysctl_settings` — dict rendered to `/etc/sysctl.d/60-glueops-nfs.conf`. Per-value rationale lives inline in `defaults/main.yml`. A key prefixed `-` is applied best-effort — systemd-sysctl skips it silently at boot instead of logging a warning when the key is absent. Neither applier treats a missing key as fatal. `{}` disables sysctl tuning and removes the file
- `nfs_unattended_upgrades` — `false` (default) writes `/etc/apt/apt.conf.d/99-glueops-unattended-upgrades` setting `APT::Periodic::Unattended-Upgrade "0"` and asserts the effective value via `apt-config`; `true` removes the override and leaves the distro default. Package-list refresh is untouched either way
- `nfs_extra_packages` — additional apt packages to install
