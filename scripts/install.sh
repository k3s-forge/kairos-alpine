#!/bin/sh
# ─── Kairos Bare-Metal Takeover ───
# Standalone install script — use when Worker endpoint is unavailable.
# Set env vars before running:
#   export WORKER_URL="https://transform-worker.bengcor.workers.dev"
#   export WORKER_TOKEN="<enrollment-token>"
#   export KAIROS_VERSION="2026.07.11"
# Or pass as arguments:
#   ./install.sh <WORKER_URL> <TOKEN> <VERSION>
#
# Usage:
#   curl -sS https://raw.githubusercontent.com/k3s-forge/kairos-alpine/main/scripts/install.sh | bash
#
# ──────────────────────────────────
set -e

WORKER_URL="${1:-${WORKER_URL:-}}"
WORKER_TOKEN="${2:-${WORKER_TOKEN:-}}"
KAIROS_VERSION="${3:-${KAIROS_VERSION:-}}"

[ -n "$WORKER_URL" ]   || { echo "ERROR: WORKER_URL not set" >&2; exit 1; }
[ -n "$WORKER_TOKEN" ] || { echo "ERROR: WORKER_TOKEN not set" >&2; exit 1; }

log() { echo "[kairos] $(date -Iseconds) $*" >&2; }
die()  { log "FATAL: $*"; exit 1; }

# ─── 1. Detect OS ───
detect_os() {
  if [ -f /etc/alpine-release ]; then echo "alpine"
  elif [ -f /etc/debian_version ]; then echo "debian"
  elif [ -f /etc/redhat-release ] || [ -f /etc/rocky-release ] || [ -f /etc/fedora-release ]; then echo "el"
  else echo "unknown"; fi
}

OS=$(detect_os)
log "Detected OS: $OS"

[ "$(id -u)" = "0" ] || die "Must run as root"

# ─── 2. Install dependencies ───
install_deps() {
  log "Installing podman + dependencies..."
  case "$OS" in
    alpine)
      apk update >&2
      apk add podman curl jq bash >&2
      rc-service cgroups start 2>/dev/null || true
      ;;
    debian)
      apt-get update -qq >&2
      apt-get install -y -qq podman curl jq >&2
      ;;
    el)
      dnf install -y podman curl jq >&2
      systemctl enable --now podman.socket 2>/dev/null || true
      ;;
    *) die "Unsupported OS. Requires Alpine/Debian/EL." ;;
  esac
  log "Dependencies installed."
}

install_deps

# ─── 3. Resolve version if not set ───
if [ -z "$KAIROS_VERSION" ]; then
  log "Resolving latest release..."
  KAIROS_VERSION=$(curl -sS "$WORKER_URL/api/v1/releases/latest" | jq -r .version 2>/dev/null)
  if [ -z "$KAIROS_VERSION" ] || [ "$KAIROS_VERSION" = "null" ]; then
    die "Could not resolve latest release version from Worker"
  fi
  log "Resolved version: $KAIROS_VERSION"
fi

# ─── 4. Login to GHCR ───
log "Configuring container registry..."
if command -v podman >/dev/null 2>&1; then
  # Try to get GHCR token from Worker API
  GHCR_TOKEN=$(curl -sS "$WORKER_URL/api/v1/github/installation-token" \
    -H "Authorization: Bearer $WORKER_TOKEN" 2>/dev/null | jq -r .token 2>/dev/null || echo "")
  if [ -n "$GHCR_TOKEN" ] && [ "$GHCR_TOKEN" != "null" ]; then
    echo "$GHCR_TOKEN" | podman login ghcr.io -u token --password-stdin 2>/dev/null
    log "GHCR authenticated."
  else
    log "WARNING: Could not get GHCR token, attempting unauthenticated pull"
  fi
else
  die "podman not found after installation"
fi

# ─── 5. Pull kairos-alpine image ───
pull_kairos() {
  log "Pulling kairos-alpine:$KAIROS_VERSION..."
  podman pull "ghcr.io/k3s-forge/kairos-alpine:$KAIROS_VERSION" >&2
}

RETRY=0
MAX_RETRIES=3
while [ "$RETRY" -lt "$MAX_RETRIES" ]; do
  if pull_kairos; then break; fi
  RETRY=$((RETRY + 1))
  [ "$RETRY" -lt "$MAX_RETRIES" ] && sleep 5
done
[ "$RETRY" -ge "$MAX_RETRIES" ] && die "Failed to pull image after $MAX_RETRIES attempts"

# ─── 6. Extract binaries ───
log "Extracting binaries..."

CONTAINER_ID=$(podman create "ghcr.io/k3s-forge/kairos-alpine:$KAIROS_VERSION" /bin/true)

mkdir -p /opt/kairos /opt/cni/bin

podman cp "$CONTAINER_ID:/entrypoint.sh" /opt/kairos/entrypoint.sh
podman cp "$CONTAINER_ID:/nebula"       /opt/kairos/nebula
podman cp "$CONTAINER_ID:/nomad"        /opt/kairos/nomad
podman cp "$CONTAINER_ID:/cni-plugins/." /opt/cni/bin/ 2>/dev/null || true

chmod +x /opt/kairos/entrypoint.sh /opt/kairos/nebula /opt/kairos/nomad
podman rm "$CONTAINER_ID" >/dev/null 2>&1

log "Binaries installed:"
ls -lh /opt/kairos/ >&2

# ─── 7. Service setup ───
log "Setting up system service..."

CLUSTER_ID=$(echo "$WORKER_TOKEN" | cut -d- -f1,2)

case "$OS" in
  alpine)
    cat > /etc/init.d/kairos-agent << 'UNITEOF'
#!/sbin/openrc-run
name="kairos-agent"
description="Kairos Node Agent"
command="/opt/kairos/entrypoint.sh"
command_args="AUTO"
command_background=true
pidfile="/run/kairos-agent.pid"
depend() { need net; after firewall; }
UNITEOF
    chmod +x /etc/init.d/kairos-agent
    rc-update add kairos-agent default
    rc-service kairos-agent start
    log "Started (openrc)."
    ;;
  debian|el)
    cat > /etc/systemd/system/kairos-agent.service << UNITEOF
[Unit]
Description=Kairos Node Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/kairos/entrypoint.sh AUTO
Environment=WORKER_URL=$WORKER_URL
Environment=WORKER_TOKEN=$WORKER_TOKEN
Environment=MODE=AUTO
Restart=always
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNITEOF
    systemctl daemon-reload
    systemctl enable --now kairos-agent
    log "Started (systemd). Monitor: journalctl -u kairos-agent -f"
    ;;
esac

log ""
log "=== Takeover Complete ==="
log "Cluster:  $CLUSTER_ID"
log "Worker:   $WORKER_URL"
log "Version:  $KAIROS_VERSION"
log ""
