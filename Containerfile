# tinycloud — self-bootstrapping edge node agent
# Single-stage Alpine build using pre-built musl binaries from:
#   - k3s-forge/nomad-musl (Nomad client)
#   - k3s-forge/nomad-driver-podman-musl (Podman task driver)
#   - slackhq/nebula (static binary)
#   - containernetworking/plugins (CNI plugins)

FROM docker.io/library/alpine:3.21

# ── system deps ──
RUN apk add --no-cache \
    bash curl jq iproute2 iptables nftables \
    podman podman-remote conmon crun netavark aardvark-dns \
    bird ca-certificates openssl && \
    mkdir -p /run/podman /opt/cni/bin /opt/cni/config /var/lib/nomad /etc/nomad.d /opt/nomad/plugins /var/lib/nebula /etc/nebula

# ── Nebula (static binary from GitHub) ──
ARG NEBULA_VER=1.10.0
RUN wget -qO /tmp/nebula.tar.gz "https://github.com/slackhq/nebula/releases/download/v${NEBULA_VER}/nebula-linux-amd64.tar.gz" && \
    tar xzf /tmp/nebula.tar.gz -C /usr/local/bin/ nebula nebula-cert && \
    chmod +x /usr/local/bin/nebula /usr/local/bin/nebula-cert && \
    rm /tmp/nebula.tar.gz

# ── Nomad (static musl binary from k3s-forge/nomad-musl) ──
ARG NOMAD_VER=v2.0.4-musl
RUN wget -qO /usr/local/bin/nomad "https://github.com/k3s-forge/nomad-musl/releases/download/${NOMAD_VER}/nomad" && \
    chmod +x /usr/local/bin/nomad && \
    /usr/local/bin/nomad version

# ── Nomad Podman driver (static musl binary) ──
ARG PODMAN_DRIVER_VER=v0.6.5-musl
RUN wget -qO /opt/nomad/plugins/nomad-driver-podman "https://github.com/k3s-forge/nomad-driver-podman-musl/releases/download/${PODMAN_DRIVER_VER}/nomad-driver-podman" && \
    chmod +x /opt/nomad/plugins/nomad-driver-podman

# ── CNI plugins ──
ARG CNI_VER=1.6.2
RUN wget -qO /tmp/cni.tgz "https://github.com/containernetworking/plugins/releases/download/v${CNI_VER}/cni-plugins-linux-amd64-v${CNI_VER}.tgz" && \
    tar xzf /tmp/cni.tgz -C /opt/cni/bin/ && \
    rm /tmp/cni.tgz

# ── Entrypoint ──
COPY entrypoint.sh /usr/local/bin/tinycloud-init
RUN chmod +x /usr/local/bin/tinycloud-init

# ── Nomad system jobs ──
COPY nomad-jobs/ /etc/nomad-jobs/

VOLUME /var/lib/nomad
VOLUME /var/lib/containers

ENTRYPOINT ["/usr/local/bin/tinycloud-init"]
