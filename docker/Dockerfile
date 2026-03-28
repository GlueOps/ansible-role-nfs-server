# Stage 1: Lint and validate
FROM python:3.13.12-slim AS lint

COPY docker/requirements.txt /tmp/requirements.txt
COPY docker/requirements-lint.txt /tmp/requirements-lint.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt -r /tmp/requirements-lint.txt

COPY role/collections/requirements.yml /tmp/requirements-collections.yml
RUN ansible-galaxy collection install -r /tmp/requirements-collections.yml

COPY role/ /ansible/roles/ansible-role-nfs-server/
COPY docker/playbook.yml /ansible/playbook.yml
COPY .yamllint /ansible/roles/ansible-role-nfs-server/.yamllint
COPY .ansible-lint /ansible/roles/ansible-role-nfs-server/.ansible-lint
WORKDIR /ansible

RUN yamllint -c roles/ansible-role-nfs-server/.yamllint roles/ansible-role-nfs-server/
RUN ansible-lint -c roles/ansible-role-nfs-server/.ansible-lint roles/ansible-role-nfs-server/
RUN ansible-playbook playbook.yml --syntax-check

RUN touch /lint-passed

# Stage 2: Runtime image
FROM python:3.13.12-slim

COPY --from=lint /lint-passed /tmp/.lint-passed

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
COPY docker/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# Install required Ansible collections
COPY role/collections/requirements.yml /tmp/requirements-collections.yml
RUN ansible-galaxy collection install -r /tmp/requirements-collections.yml

# Copy the role and playbook
COPY role/ /ansible/roles/ansible-role-nfs-server/
COPY docker/playbook.yml /ansible/playbook.yml

WORKDIR /ansible

ENTRYPOINT ["/bin/bash"]
