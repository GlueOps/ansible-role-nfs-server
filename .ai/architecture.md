# Architecture

## Project Overview

This is an Ansible role that configures an NFSv4.2 server on Ubuntu 24.04 LTS. It is packaged as a Docker container published to `ghcr.io/glueops/ansible-role-nfs-server:latest`.

## Ansible Role Structure

```
defaults/main.yml          # All configurable variables with defaults
tasks/
  main.yml                 # Entry point — imports task files with tags
  nfs.yml                  # NFS server: packages, nfs.conf, exports, systemd overrides, services
  base.yml                 # Base system: extra packages, ufw firewall, SSH hardening
  updates.yml              # OS updates: apt update/upgrade, reboot check
handlers/main.yml          # Service restart handlers (listen pattern for ordered restarts)
templates/
  nfs.conf.j2              # NFS daemon config (v4-only, thread count)
  exports.j2               # NFS exports (multi-subnet support)
meta/main.yml              # Ansible Galaxy metadata
```

## Container

```
Dockerfile                 # Python 3.14 + Ansible + Tailscale + role
requirements.txt           # Pinned Python dependencies (from pip freeze)
playbook.yml               # Simple playbook that applies the role to all hosts
```

## CI/CD

```
.github/workflows/container_image.yml   # Builds and pushes to ghcr.io on git tags (v*)
```
