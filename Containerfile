# tinycloud — self-bootstrapping edge node agent
# Bootstrap: Nebula + Podman + CNI + Nomad client
# Steady-state: hands off to Nomad system jobs (BIRD BGP, workloads)

FROM docker.io/library/alpine:3.21

# ── system deps ──
RUN apk add --no-cache \
    bash curl jq iproute2 iptables nftables \
    podman podman-remote conmon crun netavark aardvark-dns \
    bird ca-certificates openssl gcompat unzip && \
    mkdir -p /run/podman /opt/cni/bin /opt/cni/config /var/lib/nomad /etc/nomad.d /opt/nomad/plugins /var/lib/nebula /etc/nebula

# ── Nebula (static binary from GitHub) ──
ARG NEBULA_VER=1.10.0
RUN wget -qO /tmp/nebula.tar.gz "https://github.com/slackhq/nebula/releases/download/v${NEBULA_VER}/nebula-linux-amd64.tar.gz" && \
    tar xzf /tmp/nebula.tar.gz -C /usr/local/bin/ nebula nebula-cert && \
    chmod +x /usr/local/bin/nebula /usr/local/bin/nebula-cert && \
    rm /tmp/nebula.tar.gz

# ── Nomad (glibc binary, gcompat provides runtime compat on musl) ──
ARG NOMAD_VER=2.0.3+ent
RUN wget -qO /tmp/nomad.zip "https://releases.hashicorp.com/nomad/${NOMAD_VER}/nomad_${NOMAD_VER}_linux_amd64.zip" && \
    unzip -o /tmp/nomad.zip nomad -d /usr/local/bin/ && \
    chmod +x /usr/local/bin/nomad && \
    rm /tmp/nomad.zip && \
    /usr/local/bin/nomad version

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
