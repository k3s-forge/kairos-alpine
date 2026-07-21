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
    mod_b64=$(printf "$(echo "$mod_hex" | sed 's/\(..\)/\\x\1/g')" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
    if [ -z "$mod_b64" ]; then
        die "failed to encode modulus"
    fi

    printf '{"kty":"RSA","alg":"RSA-OAEP-256","n":"%s","e":"AQAB","ext":true,"key_ops":["encrypt"]}' "$mod_b64"
}

# ─── Worker API ───
# Usage: worker_get <path> [auth_token] [max_retries=3]
# Returns body on 200/201, logs retries to stderr, returns non-zero on failure.
worker_get() {
    local path="$1" auth="${2:-}" max_retries="${3:-3}"
    local code curl_rc respfile="/tmp/worker-resp-$$.txt"
    local curl_opts=(-sS --connect-timeout 10 --max-time 30 -w '%{http_code}' -o "$respfile")

    if [ -n "$auth" ]; then
        curl_opts+=(-H "Authorization: Bearer $auth")
    fi

    for i in $(seq 1 "$max_retries"); do
        code=$(curl "${curl_opts[@]}" "$WORKER_URL$path" 2>/dev/null) || true
        # Strip trailing newline from -w output, keep only numeric code
        code="${code//[!0-9]/}"
        if [ "$code" = "200" ] || [ "$code" = "201" ]; then
            cat "$respfile"
            rm -f "$respfile"
            return 0
        fi
        log "worker GET $path → HTTP $code, retry $i/$max_retries" >&2
        sleep 2
    done
    rm -f "$respfile"
    return 1
}

worker_post() {
    local path="$1" body="$2" auth="${3:-}" max_retries="${4:-3}"
    local code respfile="/tmp/worker-resp-$$.txt"
    local curl_opts=(-sS --connect-timeout 10 --max-time 30
        -w '%{http_code}' -o "$respfile"
        -H "Content-Type: application/json" -d "$body")

    if [ -n "$auth" ]; then
        curl_opts+=(-H "Authorization: Bearer $auth")
    fi

    for i in $(seq 1 "$max_retries"); do
        code=$(curl "${curl_opts[@]}" "$WORKER_URL$path" 2>/dev/null) || true
        code="${code//[!0-9]/}"
        if [ "$code" = "200" ] || [ "$code" = "201" ]; then
            cat "$respfile"
            rm -f "$respfile"
            return 0
        fi
        log "worker POST $path → HTTP $code, retry $i/$max_retries" >&2
        sleep 2
    done
    rm -f "$respfile"
    return 1
}

# ─── step 1: identity ───
resolve_identity() {
    log "resolving identity"

    if [[ -n "${WORKER_URL:-}" && -n "${WORKER_TOKEN:-}" ]]; then
        # ═══ AUTO mode ═══
        log "AUTO mode: pulling identity from $WORKER_URL"

        # 1a. Generate RSA-4096 key pair
        if [[ ! -f /var/lib/nebula/node.key ]]; then
            log "generating RSA-4096 key pair"
            mkdir -p /var/lib/nebula
            openssl genrsa -out /var/lib/nebula/node.key 4096 2>/dev/null
        fi

        # 1b. Public key → JWK
        local jwk
        jwk=$(rsa_pubkey_to_jwk /var/lib/nebula/node.key)
        log "public key JWK ready"

        # 1c. Bootstrap — one-shot enrollment token
        log "calling /api/v1/bootstrap"
        local bootstrap
        bootstrap=$(worker_post "/api/v1/bootstrap" "{\"publicKey\":$jwk}" "$WORKER_TOKEN") || {
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

            # Static host map: {"IP":"addr"|["addr"],...} → "IP=addr,IP=addr"
            local shm
            shm=$(echo "$cluster" \
                | jq -r '[.nebula.static_host_map // {} | to_entries[] | "\(.key)=\(.value | if type == "array" then .[0] else . end)"] | join(",")')
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
        hostCert=$(worker_get "/api/v1/clusters/nebula/host-cert?clusterId=$CLUSTER_ID" "$NODE_TOKEN") || true

        if [ -n "$hostCert" ] && [ "$hostCert" != "null" ]; then
            echo "$hostCert" | jq -r '.cert // empty' > /var/lib/nebula/host.crt
            echo "$hostCert" | jq -r '.key // empty' > /var/lib/nebula/host.key
            chmod 600 /var/lib/nebula/host.key
        fi

        # Fallback: generate host cert locally using CA key from Worker
        if [ ! -s /var/lib/nebula/host.crt ] || [ ! -s /var/lib/nebula/host.key ]; then
            log "host cert not pre-provisioned, generating locally"

            local caKey
            caKey=$(worker_get "/api/v1/clusters/nebula/ca-key?clusterId=$CLUSTER_ID" "$NODE_TOKEN") || {
                die "failed to pull CA key for local cert generation"
            }
            echo "$caKey" > /var/lib/nebula/ca.key
            chmod 600 /var/lib/nebula/ca.key

            # Determine Nebula IP: env var X, or derive from nodeId (1-254)
            local nebulaIP="${NEBULA_IP:-}"
            if [ -z "$nebulaIP" ]; then
                local octet
                octet=$(echo "$NODE_ID" | cksum | awk '{print ($1 % 254) + 1}')
                nebulaIP="192.168.200.$octet"
            fi
            log "using Nebula IP: $nebulaIP"

            nebula-cert sign \
                -name "$NODE_ID" \
                -ip "$nebulaIP/24" \
                -out-crt /var/lib/nebula/host.crt \
                -out-key /var/lib/nebula/host.key \
                -ca-crt /var/lib/nebula/ca.crt \
                -ca-key /var/lib/nebula/ca.key || {
                die "nebula-cert sign failed"
            }
            rm -f /var/lib/nebula/ca.key
            log "host cert generated locally"
        fi

        # Store node identity for later use
        echo "$bootstrap" | jq '.identity' > /var/lib/nebula/identity.json
        echo "$NODE_TOKEN" > /var/lib/nebula/node-token
        chmod 600 /var/lib/nebula/node-token

        return 0
    fi

    # ═══ LOCAL mode ═══
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

    mkdir -p /etc/nebula
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

    killall nebula 2>/dev/null || true
    sleep 1

    nebula -config /etc/nebula/config.yml &
    local pid=$!
    sleep 3

    if ! kill -0 "$pid" 2>/dev/null; then
        die "Nebula failed to start"
    fi

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
    mkdir -p /var/lib/nomad/data /etc/nomad.d

    cat > /etc/nomad.d/client.hcl <<HCL
data_dir = "/var/lib/nomad/data"

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

if [ "$MODE" = "bootstrap" ] || [ "$MODE" = "AUTO" ] || [ "$MODE" = "LOCAL" ]; then
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
