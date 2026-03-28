# Contributing / Making Changes

- **Adding a new task**: Put it in the appropriate file (`nfs.yml`, `base.yml`, or `updates.yml`). Tags are inherited from `main.yml` imports.
- **Adding a new variable**: Add to `defaults/main.yml` with the `nfs_` prefix. Update README.md variables table.
- **Changing handlers**: NFS handler (`restart nfs`) uses shell to stop+start nfs-server with daemon-reload. `restart sshd` and `reload exports` are standalone handlers. Add new handlers to `handlers/main.yml`.
- **Updating dependencies**: Rebuild the Docker image without pins, run `pip freeze`, update `requirements.txt`. Check Tailscale and community.general versions too.
- **Testing**: Linting runs during `docker build` (yamllint, ansible-lint, syntax-check). For full integration testing, run `bash tests/test-hetzner.sh` (requires `HCLOUD_TOKEN`). Set `K8S_VERSION` env var to test a specific Kubernetes version. CI runs a matrix against the last 3 K8s versions.
