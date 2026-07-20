# tinycloud — self-bootstrapping edge node agent
# Stage 1: Build Nomad from source (CGO_ENABLED=0 → pure Go static, no glibc)
# Stage 2: Alpine runtime with Nebula + Podman + CNI + Nomad

# ── Stage 1: Build Nomad ──
FROM docker.io/library/golang:1.24-alpine AS nomad-builder
ARG NOMAD_VER=v2.0.3
RUN apk add --no-cache git make bash
RUN git clone --depth 1 --branch "${NOMAD_VER}" https://github.com/hashicorp/nomad.git /src/nomad
WORKDIR /src/nomad
RUN CGO_ENABLED=0 go build -o /usr/local/bin/nomad \
    -ldflags="-s -w -X github.com/hashicorp/nomad/version.Version=${NOMAD_VER#v}" .

# ── Stage 2: Runtime ──
FROM docker.io/library/alpine:3.21

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

# ── Nomad (CGO_ENABLED=0 static from Stage 1) ──
COPY --from=nomad-builder /usr/local/bin/nomad /usr/local/bin/nomad

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
