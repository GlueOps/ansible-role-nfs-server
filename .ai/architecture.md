# Architecture

## Project Overview

This is an Ansible role that configures an NFSv4.2 server on Ubuntu 24.04 LTS. It is packaged as a Docker container published to `ghcr.io/glueops/ansible-role-nfs-server:latest`.

## Repository Structure

```
role/                              # The Ansible role (clean, portable)
  defaults/main.yml                # All configurable variables with defaults
  tasks/
    main.yml                       # Entry point — imports task files with tags
    nfs.yml                        # NFS server: packages, nfs.conf, exports, systemd overrides, services
    base.yml                       # Base system: extra packages, ufw firewall, SSH hardening
    updates.yml                    # OS updates: apt update/upgrade, reboot check
  handlers/main.yml                # Service restart handlers
  templates/
    nfs.conf.j2                    # NFS daemon config (v4-only, thread count)
    exports.j2                     # NFS exports (multi-subnet support)
  meta/main.yml                    # Ansible Galaxy metadata
  collections/requirements.yml     # Ansible collection dependencies

docker/                            # Container packaging
  Dockerfile                       # Python 3.13 + Ansible + Tailscale + role (multi-stage with lint)
  playbook.yml                     # Simple playbook that applies the role to all hosts
  requirements.txt                 # Pinned Python dependencies (from pip freeze)
  requirements-lint.txt            # Lint tool versions (yamllint, ansible-lint)

tests/                             # Integration tests
  test-hetzner.sh                  # Full test: 2 Hetzner VMs, NFS role + KIND NFS read/write (supports K8S_VERSION env var)
  test-remote.sh                   # Reusable: run role via Docker against a remote host
  idempotency-check.sh             # Wrapper: runs playbook, asserts changed=0
  hetzner-nuke-config.yml          # Config for cleaning up Hetzner resources

.github/workflows/                 # CI/CD
  container_image.yml              # Builds and pushes to ghcr.io on git tags (v*)
  test-hetzner.yml                 # Runs integration test on PRs
```
