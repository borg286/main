# Dockerfile - tool image with kubectl, helm, flux, git, jq, openssl, curl
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    git \
    jq \
    openssl \
    ca-certificates \
    tar \
    gzip \
    gzip \
    unzip \
    procps \
    iproute2 \
    expect \
    openssh-client \
 && rm -rf /var/lib/apt/lists/*

# kubectl (latest stable)
RUN KUBECTL_VER=$(curl -fsSL https://dl.k8s.io/release/stable.txt) \
 && curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VER}/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl \
 && chmod +x /usr/local/bin/kubectl

# helm (get_helm.sh)
RUN curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# small helper: ensure /workdir exists
RUN mkdir -p /workdir
WORKDIR /workdir

# PATH sanity
ENV PATH="/usr/local/bin:${PATH}"

# Entrypoint is bash so the Job can run commands
ENTRYPOINT ["/bin/bash", "-c"]
