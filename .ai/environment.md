# Target Environment

- **OS**: Ubuntu 24.04 LTS (Noble)
- **Use case**: Single NFS server, low usage, no HA
- **Clients**: Kubernetes nodes mounting via NFSv4.2 (tested against K8s v1.33–v1.35)
- **Network**: Private subnets, publicly accessible SSH
- **Access**: SSH key or Tailscale SSH only (no passwords)
