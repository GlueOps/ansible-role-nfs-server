FROM python:3.14.3-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      openssh-client \
      curl \
      iptables \
      ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Install Tailscale (with checksum verification)
RUN set -eux; \
    curl -fsSL -o /tmp/tailscale.tgz https://pkgs.tailscale.com/stable/tailscale_1.96.4_amd64.tgz; \
    echo "a1cba18826b1f91cb25ef7f5b8259b5258339b42db7867af9269e21829ea78cc  /tmp/tailscale.tgz" | sha256sum -c -; \
    tar -xz -C /usr/local/bin --strip-components=1 -f /tmp/tailscale.tgz; \
    rm /tmp/tailscale.tgz

# Install Ansible and Python dependencies
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# Install required Ansible collections
RUN ansible-galaxy collection install community.general:==12.5.0

# Copy the role and playbook
COPY . /ansible/roles/ansible-role-nfs-server
COPY playbook.yml /ansible/playbook.yml

WORKDIR /ansible

ENTRYPOINT ["/bin/bash"]
