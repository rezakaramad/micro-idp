FROM debian:bookworm-slim

ARG KEYCLOAK_VERSION=24.0.5
ARG VAULT_VERSION=1.16.2

ENV KCADM_HOME=/opt/keycloak
ENV PATH="$PATH:/opt/keycloak/bin"

RUN apt-get update && apt-get install -y \
    ca-certificates \
    curl \
    jq \
    unzip \
    openssl \
    bash \
    coreutils \
    iproute2 \
    procps \
    openjdk-17-jre-headless \
    libnss3-tools \
    && rm -rf /var/lib/apt/lists/*

# ---- Vault CLI ----
RUN curl -L https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_amd64.zip \
    -o /tmp/vault.zip \
 && unzip /tmp/vault.zip -d /usr/local/bin \
 && chmod +x /usr/local/bin/vault \
 && rm /tmp/vault.zip

# ---- Keycloak admin CLI (kcadm.sh) ----
RUN curl -L https://github.com/keycloak/keycloak/releases/download/${KEYCLOAK_VERSION}/keycloak-${KEYCLOAK_VERSION}.zip \
    -o /tmp/keycloak.zip \
 && unzip /tmp/keycloak.zip -d /opt \
 && mv /opt/keycloak-${KEYCLOAK_VERSION} /opt/keycloak \
 && rm /tmp/keycloak.zip

WORKDIR /workspace
ENTRYPOINT ["/bin/bash"]