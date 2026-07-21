#!/bin/bash
set -euo pipefail

# ─── tinycloud — self-bootstrapping edge node agent ───
# Supports two modes:
#   AUTO:  WORKER_URL + WORKER_TOKEN set → pulls identity, Nebula certs, config
#   LOCAL: certs pre-mounted at /var/lib/nebula/
#
# Bootstrap: Nebula + Podman socket + CNI + Nomad client
# Steady-state: submits BIRD system job → Nomad manages everything

: "${HOSTNAME:=$(hostname)}"
MODE="${1:-bootstrap}"

log() { echo "[tinycloud] $(date -Iseconds) $*"; }
die()  { log "FATAL: $*"; exit 1; }

# AUTO mode: WORKER_URL + WORKER_TOKEN → bootstrap from Worker API
if [ -n "${WORKER_URL:-}" ] && [ -n "${WORKER_TOKEN:-}" ]; then
    MODE=AUTO
    log "AUTO mode: bootstrapping from $WORKER_URL"
else
    : "${NOMAD_SERVER:?NOMAD_SERVER required (or provide WORKER_URL+WORKER_TOKEN)}"
    : "${NEBULA_LIGHTHOUSE:?NEBULA_LIGHTHOUSE required (or provide WORKER_URL+WORKER_TOKEN)}"
    MODE=LOCAL
fi

# ─── RSA JWK extraction (pure shell, no Python/Node) ───
# Extracts the public key from an RSA PEM and outputs a JWK object.
# Usage: rsa_pubkey_to_jwk </path/to/key.pem>
rsa_pubkey_to_jwk() {
    local privkey="$1"
    local pubpem="/tmp/rsa-pub-$$.pem"

    openssl rsa -in "$privkey" -pubout -out "$pubpem" 2>/dev/null || {
        die "failed to extract public key"
    }

    local mod_hex
    mod_hex=$(openssl rsa -pubin -in "$pubpem" -modulus -noout 2>/dev/null | sed 's/Modulus=//')
    rm -f "$pubpem"

    if [ -z "$mod_hex" ]; then
        die "failed to read RSA modulus"
    fi

    local mod_b64
    # hex → binary (printf+sed, no xxd needed) → base64url
    mod_b64=$(printf "$(echo "$mod_hex" | sed 's/\(..\)/\\x\1/g')" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
    if [ -z "$mod_b64" ]; then
        die "failed to encode modulus"
    fi

    printf '{"kty":"RSA","alg":"RSA-OAEP-256","n":"%s","e":"AQAB","ext":true,"key_ops":["encrypt"]}' "$mod_b64"
}

# ─── Worker API call with retry ───
worker_get() {
    local path="$1" auth="${2:-}" max_retries="${3:-3}"
    local code
    for i in $(seq 1 "$max_retries"); do
        if [ -n "$auth" ]; then
            code=$(curl -sfS --connect-timeout 10 --max-time 30 \
                -w '%{http_code}' -o /tmp/worker-resp-$$.txt \
                -H "Authorization: Bearer $auth" \
                "$WORKER_URL$path" 2>/dev/null || echo "000")
        else
            code=$(curl -sfS --connect-timeout 10 --max-time 30 \
                -w '%{http_code}' -o /tmp/worker-resp-$$.txt \
                "$WORKER_URL$path" 2>/dev/null || echo "000")
        fi
        if [ "$code" = "200" ] || [ "$code" = "201" ]; then
            cat /tmp/worker-resp-$$.txt
            rm -f /tmp/worker-resp-$$.txt
            return 0
        fi
        log "worker GET $path → HTTP $code, retry $i/$max_retries"
        sleep 2
    done
    rm -f /tmp/worker-resp-$$.txt
    return 1
}

worker_post() {
    local path="$1" body="$2" auth="${3:-}" max_retries="${4:-3}"
    local code
    for i in $(seq 1 "$max_retries"); do
        if [ -n "$auth" ]; then
            code=$(curl -sfS --connect-timeout 10 --max-time 30 \
                -w '%{http_code}' -o /tmp/worker-resp-$$.txt \
                -H "Authorization: Bearer $auth" \
                -H "Content-Type: application/json" \
                -d "$body" \
                "$WORKER_URL$path" 2>/dev/null || echo "000")
        else
            code=$(curl -sfS --connect-timeout 10 --max-time 30 \
                -w '%{http_code}' -o /tmp/worker-resp-$$.txt \
                -H "Content-Type: application/json" \
                -d "$body" \
                "$WORKER_URL$path" 2>/dev/null || echo "000")
        fi
        if [ "$code" = "200" ] || [ "$code" = "201" ]; then
            cat /tmp/worker-resp-$$.txt
            rm -f /tmp/worker-resp-$$.txt
            return 0
        fi
        log "worker POST $path → HTTP $code, retry $i/$max_retries"
        sleep 2
    done
    rm -f /tmp/worker-resp-$$.txt
    return 1
}

# ─── step 1: identity ───
resolve_identity() {
    log "resolving identity"

    # ── AUTO mode: pull everything from Worker ──
    if [[ -n "${WORKER_URL:-}" && -n "${WORKER_TOKEN:-}" ]]; then
        log "AUTO mode: pulling identity from $WORKER_URL"

        # 1a. Generate RSA-4096 key pair for Worker encryption
        if [[ ! -f /var/lib/nebula/node.key ]]; then
            log "generating RSA-4096 key pair"
            mkdir -p /var/lib/nebula
            openssl genrsa -out /var/lib/nebula/node.key 4096 2>/dev/null
        fi

        # 1b. Extract public key as JWK
        local jwk
        jwk=$(rsa_pubkey_to_jwk /var/lib/nebula/node.key)
        log "public key JWK: ${jwk:0:80}..."

        # 1c. Bootstrap — one-shot enrollment token
        log "calling /api/v1/bootstrap"
        local bootstrap
        bootstrap=$(worker_post "/api/v1/bootstrap" "$jwk" "$WORKER_TOKEN") || {
            die "bootstrap failed — enrollment token may be expired or already consumed"
        }

        NODE_TOKEN=$(echo "$bootstrap" | jq -r '.nodeToken // empty')
        NODE_ID=$(echo "$bootstrap" | jq -r '.identity.nodeId // empty')
        CLUSTER_ID=$(echo "$bootstrap" | jq -r '.identity.clusterId // empty')

        if [ -z "$NODE_TOKEN" ] || [ -z "$NODE_ID" ]; then
            die "bootstrap response missing nodeToken or identity"
        fi
        log "identity: node=$NODE_ID cluster=$CLUSTER_ID"

        # 1d. Cluster config from bootstrap response
        local cluster
        cluster=$(echo "$bootstrap" | jq -r '.cluster // empty')
        if [ -n "$cluster" ] && [ "$cluster" != "null" ]; then
            export NOMAD_SERVER="${NOMAD_SERVER:-$(echo "$cluster" | jq -r '.nomad_server // empty')}"
            export NEBULA_LIGHTHOUSE="${NEBULA_LIGHTHOUSE:-$(echo "$cluster" | jq -r '.nebula.lighthouse // empty')}"
            export NEBULA_MTU="${NEBULA_MTU:-$(echo "$cluster" | jq -r '.nebula.mtu // empty')}"
            export NEBULA_PORT="${NEBULA_PORT:-$(echo "$cluster" | jq -r '.nebula.port // empty')}"
            export CNI_SUBNET="${CNI_SUBNET:-$(echo "$cluster" | jq -r '.bgp.cni_subnet // empty')}"

            # Static host map: { "IP": ["host:port"], ... } → "IP=host:port,IP=host:port"
            local shm
            shm=$(echo "$cluster" | jq -r '
                .nebula.static_host_map // {} |
                to_entries |
                map("\(.key)=\(.value[0])") |
                join(",")
            ' 2>/dev/null)
            export STATIC_HOST_MAP="${STATIC_HOST_MAP:-$shm}"
        fi

        # 1e. Nebula CA cert
        log "pulling Nebula CA cert"
        worker_get "/api/v1/clusters/nebula/ca?clusterId=$CLUSTER_ID" > /var/lib/nebula/ca.crt || {
            die "failed to pull CA cert"
        }
        log "CA cert saved ($(wc -c < /var/lib/nebula/ca.crt) bytes)"

        # 1f. Nebula host cert + key (authenticated with nodeToken)
        log "pulling Nebula host cert"
        local hostCert
        hostCert=$(worker_get "/api/v1/clusters/nebula/host-cert?clusterId=$CLUSTER_ID" "$NODE_TOKEN") || {
            die "failed to pull host cert"
        }

        echo "$hostCert" | jq -r '.cert // empty' > /var/lib/nebula/host.crt
        echo "$hostCert" | jq -r '.key // empty' > /var/lib/nebula/host.key
        chmod 600 /var/lib/nebula/host.key

        if [ ! -s /var/lib/nebula/host.crt ] || [ ! -s /var/lib/nebula/host.key ]; then
            die "host cert or key empty"
        fi
        log "host cert saved"

        # Store node identity for later use
        echo "$bootstrap" | jq '.identity' > /var/lib/nebula/identity.json
        echo "$NODE_TOKEN" > /var/lib/nebula/node-token
        chmod 600 /var/lib/nebula/node-token

        return 0
    fi

    # ── LOCAL mode: certs are pre-mounted ──
    if [ -f /var/lib/nebula/host.crt ] && [ -f /var/lib/nebula/host.key ] && [ -f /var/lib/nebula/ca.crt ]; then
        log "LOCAL mode: using pre-mounted certs"
        return 0
    fi

    die "no WORKER_URL/WORKER_TOKEN and no pre-mounted certs — cannot resolve identity"
}

# ─── step 2: Nebula config ───
generate_nebula_config() {
    log "generating Nebula config"
    local config="/etc/nebula/config.yml"

    local mtu="${NEBULA_MTU:-1300}"
    local port="${NEBULA_PORT:-4242}"

    # Static host map as YAML
    local shm_yaml=""
    if [ -n "${STATIC_HOST_MAP:-}" ]; then
        IFS=',' read -ra SHM_ENTRIES <<< "$STATIC_HOST_MAP"
        for entry in "${SHM_ENTRIES[@]}"; do
            local ip="${entry%%=*}"
            local addr="${entry#*=}"
            shm_yaml="$shm_yaml"$'\n'"  \"$ip\": [\"$addr\"]"
        done
    fi

    cat > "$config" <<YAML
pki:
  ca: /var/lib/nebula/ca.crt
  cert: /var/lib/nebula/host.crt
  key: /var/lib/nebula/host.key

lighthouse:
  am_lighthouse: false
  interval: 60
  hosts:
    - "$NEBULA_LIGHTHOUSE"
  local_allow_list:
    interfaces:
      lo: false
    "10.77.0.0/16": false

listen:
  host: 0.0.0.0
  port: $port

tun:
  dev: nebula1
  mtu: $mtu
  tx_queue: 500
  drop_local_broadcast: false
  drop_multicast: false
  use_system_route_table: true
  use_system_route_table_buffer_size: 1048576

firewall:
  outbound:
    - port: any
      proto: any
      host: any
    - port: any
      proto: any
      host: any
      local_cidr: 10.77.0.0/16
  inbound:
    - port: any
      proto: any
      host: any
    - port: any
      proto: any
      host: any
      local_cidr: 10.77.0.0/16

punchy:
  punch: false

preferred_ranges:
  - 192.168.100.0/24

static_host_map:$shm_yaml
YAML

    log "Nebula config written ($(wc -c < "$config") bytes)"
}

# ─── step 3: start Nebula ───
start_nebula() {
    log "starting Nebula"

    # Kill any existing Nebula
    killall nebula 2>/dev/null || true
    sleep 1

    nebula -config /etc/nebula/config.yml &
    local pid=$!
    sleep 3

    if ! kill -0 "$pid" 2>/dev/null; then
        die "Nebula failed to start"
    fi

    # Wait for TUN device
    for i in $(seq 1 30); do
        if ip link show nebula1 >/dev/null 2>&1; then
            log "Nebula TUN (nebula1) ready"
            return 0
        fi
        sleep 1
    done
    die "Nebula TUN device not created after 30s"
}

# ─── step 4: start Podman ───
start_podman() {
    log "starting Podman socket"
    podman system service --time=0 tcp:0.0.0.0:8080 &
    sleep 2
}

# ─── step 5: start Nomad ───
start_nomad() {
    log "starting Nomad client"
    cat > /etc/nomad.d/client.hcl <<HCL
client {
  enabled = true
  server_join {
    retry_join = ["$NOMAD_SERVER"]
  }
  network_interface = "nebula1"
}
plugin "podman" {
  config {
    socket_path = "tcp://127.0.0.1:8080"
  }
}
HCL

    nomad agent -config=/etc/nomad.d &
    sleep 3
}

# ─── main ───
echo "=== tinycloud v0.5.0 ==="

resolve_identity
generate_nebula_config

if [ "$MODE" = "bootstrap" ]; then
    if ! ip link show nebula1 >/dev/null 2>&1; then
        start_nebula
    fi
    start_podman
    start_nomad
    log "bootstrap complete — handing off to Nomad"
elif [ "$MODE" = "certs-only" ]; then
    log "certs-only mode — identity resolved, services not started"
else
    log "unknown mode: $MODE"
fi

log "done"
exec sleep infinity
