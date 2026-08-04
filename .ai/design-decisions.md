# Design Decisions

- **NFSv4-only**: v2/v3 disabled. No need for rpcbind (kept running but firewalled off on port 111).
- **`insecure` export option**: Required because Kubernetes clients use `noresvport`.
- **`no_root_squash` is the default** (changed; previously the kernel default
  `root_squash` applied implicitly). A client connecting as uid 0 stays uid 0 on
  the server. Export dirs are still created `nobody:nogroup 0755`.

  Rationale: the role's exports are consumed by hosts that need to operate on
  the whole tree as root — principally backup and restore. Under `root_squash`
  those fail in the worst possible way, *partially*: a default umask leaves most
  files world-readable, so a backup appears to succeed while silently skipping
  every mode-0600 file (ssh keys, credentials, tokens), and a restore cannot
  `chown`, so files land owned by `nobody` and the owning uid cannot write them.
  The result is a green backup that restores to an unusable state.

  The trade is explicit: **any client that can mount the export now has root
  over all of its data.** The security boundary is `subnets` plus the firewall,
  not uid mapping. Scope `subnets` and `nfs_allowed_subnets` to the hosts that
  actually need the export rather than leaving them at RFC1918-wide.

  Note this is not much of a boundary shift where clients already run
  privileged workloads — a container that can gain uid 0 and mount the PV was
  never meaningfully constrained by squashing. It *is* a real change for
  clients that cannot.

  Consumers who want the old behaviour set
  `options: "rw,sync,no_subtree_check,insecure"` explicitly. The template
  fallback tracks this default, so it is `no_root_squash` too.
- **Tags**: `nfs`, `base`, `updates` (never). Tags control what runs. `updates` requires explicit `--tags updates`.
- **Config as a drop-in**: NFS settings go to `/etc/nfs.conf.d/10-glueops.conf`, never to `/etc/nfs.conf`. Overwriting the distro file removes its active `pipefs-directory`, and `rpc-pipefs-generator` has no fallback — so `rpc_pipefs.target` is never generated and `nfsdcld`, `nfs-idmapd`, `rpc-gssd` and `nfs-blkmap` all fail to start. The drop-in re-asserts `pipefs-directory` and `manage-gids` so hosts damaged by earlier versions recover. Drop-in values win over `/etc/nfs.conf` for conflicting keys (verified).
- **Handler pattern**: `restart nfs` uses shell to daemon-reload then stop+start nfs-server. This was originally attributed to `systemctl restart` failing on fresh Ubuntu 24.04 "due to rpc_pipefs.target" — that failure was self-inflicted by the `/etc/nfs.conf` clobbering above, now fixed. The workaround is retained only until a plain `systemctl restart nfs-server` is confirmed working on a live host; it can then become `ansible.builtin.systemd_service` with `daemon_reload: true`.
- **Sysctl tuning is back, scoped and durability-neutral**: an earlier version removed sysctl tuning on the grounds that Ubuntu 24.04 defaults are sufficient for low-usage workloads. That still holds for low-usage workloads; it stops holding once many Kubernetes clients share the server. The set in `nfs_sysctl_settings` is restricted to values that cannot affect durability — socket buffers, backlogs, writeback thresholds, cache pressure. Anything that trades a durability guarantee for throughput (`async` exports above all) stays out, and the reasoning is recorded per-value in `defaults/main.yml` so a future reviewer can re-litigate individual values instead of the whole file. Set `nfs_sysctl_settings: {}` to return to stock.
- **`sync` exports are not negotiable**: `async` is the largest available NFS speed-up and loses acknowledged writes on server crash or power loss — the client is told a write completed, never learns otherwise, and never replays it. The writeback sysctls (`vm.dirty_*`) look adjacent but are not: they move when the kernel *starts* flushing, not whether a stable write is flushed before it is acknowledged.
- **`LimitNOFILE` is a ceiling, not a tuning knob, and is set as `1024:<value>`**: a bare `LimitNOFILE=N` sets soft *and* hard. Raising the soft limit is the part with failure modes — fd numbers past `FD_SETSIZE` (1024) become reachable, which is undefined behaviour in `select()` users. Measured on 24.04: systemd's default is already `1024:524288`, so the role's 524288 never raised the hard limit at all; `rpc.mountd` calls `select()` and defends itself by `setrlimit()`-ing its own soft limit back to 1024 at startup (started at 524288, reported 1024, ~15 fds in use); `rpcbind` uses ~9 fds and polls via libtirpc. The override is therefore inert by design and kept only so the ceiling is raiseable. Do not present it as a throughput improvement.
- **`nfs_ulimit_nofile` is asserted against `fs.nr_open`, read from the host**: PAM cannot open a session whose `nofile` exceeds the kernel ceiling, so a too-large value locks SSH out of the host the role just converged. Cheap assert, unrecoverable failure mode. The ceiling is slurped rather than hardcoded — the historical default is 1048576, but systemd raises it to 1073741816 at boot on 24.04, so a hardcoded bound would reject values the host accepts.
- **`nf_conntrack_max` is deliberately not set**: its default already scales with RAM, so a fixed value is a no-op on a small host and a downgrade on a large one. Conntrack exhaustion is a Kubernetes-node problem (many short-lived connections), not an NFS-server one — a client node holds only a handful of long-lived TCP connections here. Considered and rejected; do not re-add without measuring `conntrack -C` first.
- **`rpc.mountd` thread count**: nfs-utils defaults to 1. Not obvious on a v4-only server — mountd looks like v3 legacy — but the kernel still upcalls to it for export authentication, so a single thread serialises first-touch from every client.
- **SSH on port 22**: Password auth disabled, root password locked. Key-only or Tailscale SSH access. Hardening is applied via `/etc/ssh/sshd_config.d/00-hardening.conf`, not by editing `/etc/ssh/sshd_config`: that file's `Include` sits above its own directives and sshd takes the first value it obtains, so edits there lose to cloud-init's `50-cloud-init.conf`. The `00-` prefix is load-bearing. An `sshd -T` assertion verifies the effective config so a future shadowing regression fails loudly.
- **All dependencies pinned**: Python packages via `requirements.txt`, Ansible collection version in Dockerfile, Tailscale version pinned.
