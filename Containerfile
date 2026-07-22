# tinycloud — self-bootstrapping edge node agent
# Runtime:    Bootstrap Nebula + Podman + CNI + Nomad client
# Installer:  Full-disk takeover (rescue → /dev/sda → reboot → auto-enroll)
# Steady-state: hands off to Nomad system jobs (BIRD BGP, workloads)

FROM docker.io/library/alpine:3.21

# ── system deps ──
RUN apk add --no-cache \
    bash curl jq iproute2 iptables nftables \
    podman podman-remote conmon crun netavark aardvark-dns \
    bird ca-certificates openssl && \
    # podman socket directory
    mkdir -p /run/podman && \
    # CNI plugin dir (Nomad expects /opt/cni/bin)
    mkdir -p /opt/cni/bin /opt/cni/config && \
    # Nomad + Nebula dirs
    mkdir -p /var/lib/nomad /etc/nomad.d /opt/nomad/plugins /var/lib/nebula /etc/nebula

# ── Takeover installer deps ──
# Full-disk takeover: partition, format, copy rootfs, install bootloader
RUN apk add --no-cache \
    # Partitioning & filesystems
    gptfdisk sgdisk parted dosfstools e2fsprogs \
    # Rootfs copy
    rsync \
    # Bootloader
    grub-efi efibootmgr \
    # Init system (for installed OS)
    openrc \
    # Kernel (baked into the image for target)
    linux-virt linux-firmware-none

# ── Nebula v1.10.0 (static binary from GitHub) ──
COPY build/nebula /usr/local/bin/nebula
COPY build/nebula-cert /usr/local/bin/nebula-cert

# ── Nomad v2.0.3+ent.musl (static musl binary) ──
COPY build/nomad /usr/local/bin/nomad

# ── CNI plugins ──
COPY build/cni-plugins/ /opt/cni/bin/

# ── Entrypoint ──
COPY entrypoint.sh /usr/local/bin/tinycloud-init
RUN chmod +x /usr/local/bin/tinycloud-init /usr/local/bin/nebula /usr/local/bin/nomad

# ── Installer (full-disk takeover) ──
COPY install.sh /install.sh
RUN chmod +x /install.sh

# ── Nomad system jobs (submitted after join) ──
COPY nomad-jobs/ /etc/nomad-jobs/

VOLUME /var/lib/nomad
VOLUME /var/lib/containers

ENTRYPOINT ["/usr/local/bin/tinycloud-init"]
