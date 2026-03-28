# Contributing / Making Changes

- **Adding a new task**: Put it in the appropriate file (`nfs.yml`, `base.yml`, or `updates.yml`). Tags are inherited from `main.yml` imports.
- **Adding a new variable**: Add to `defaults/main.yml` with the `nfs_` prefix. Update README.md variables table.
- **Changing handlers**: NFS handlers use `listen: restart nfs` for ordered restarts. The `restart sshd` handler is standalone, triggered by SSH config changes. Add new handlers to `handlers/main.yml`.
- **Updating dependencies**: Rebuild the Docker image without pins, run `pip freeze`, update `requirements.txt`. Check Tailscale and community.general versions too.
- **Testing**: Linting runs during `docker build` (yamllint, ansible-lint, syntax-check). For full integration testing, run the playbook against a disposable Ubuntu 24.04 VM.
