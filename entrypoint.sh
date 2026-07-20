#!/bin/bash
set -euo pipefail

# ─── tinycloud — self-bootstrapping edge node agent ───
# Bootstrap: Nebula + Podman socket + CNI + Nomad client
# Steady-state: submits BIRD system job → Nomad manages everything

: "${NOMAD_SERVER:?NOMAD_SERVER required}"
: "${NEBULA_LIGHTHOUSE:?NEBULA_LIGHTHOUSE required}"
HOSTNAME="${HOSTNAME:-$(hostname)}"
MODE="${1:-bootstrap}"

log() { echo "[tinycloud] $(date -Iseconds) $*"; }

# ─── step 1: identity ───
resolve_identity() {
    log "resolving identity"

    # Worker mode: pull certs + config from transform API
    if [[ -n "${WORKER_URL:-}" && -n "${WORKER_TOKEN:-}" ]]; then
        log "pulling identity from $WORKER_URL"

        # 1. Bootstrap — get encrypted identity + cluster config
        local pubkey=""
        if [[ -f /var/lib/nebula/node.pub ]]; then
            pubkey=$(cat /var/lib/nebula/node.pub)
        fi

        local bootstrap
        bootstrap=$(curl -sfS --connect-timeout 10 --max-time 30 \
            -H "Authorization: Bearer $WORKER_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{\"publicKey\":$pubkey}" \
            "$WORKER_URL/api/v1/bootstrap" 2>&1) || {
            log "WARN: bootstrap failed: $(echo "$bootstrap" | head -1)"
            log "  falling back to local certs"
        }

        if [[ -n "$bootstrap" ]]; then
            NODE_TOKEN=$(echo "$bootstrap" | jq -r '.nodeToken // empty' 2>/dev/null)
            CLUSTER_ID=$(echo "$bootstrap" | jq -r '.identity.clusterId // empty' 2>/dev/null)

            # 2. Cluster config
            if [[ -n "$CLUSTER_ID" ]]; then
                local cc
                cc=$(curl -sfS --connect-timeout 5 --max-time 10 \
                    "$WORKER_URL/api/v1/clusters/config?clusterId=$CLUSTER_ID" 2>&1) || true

                if [[ -n "$cc" ]]; then
                    export NOMAD_SERVER="${NOMAD_SERVER:-$(echo "$cc" | jq -r '.nomad_server // empty')}"
                    export NEBULA_LIGHTHOUSE="${NEBULA_LIGHTHOUSE:-$(echo "$cc" | jq -r '.nebula.lighthouse // empty')}"
                    export NEBULA_MTU="${NEBULA_MTU:-$(echo "$cc" | jq -r '.nebula.mtu // empty')}"
                    export NEBULA_PORT="${NEBULA_PORT:-$(echo "$cc" | jq -r '.nebula.port // empty')}"
                    export CNI_SUBNET="${CNI_SUBNET:-$(echo "$cc" | jq -r '.bgp.cni_subnet // empty')}"

                    # Static host map
                    local shm
                    shm=$(echo "$cc" | jq -r '.nebula.static_host_map // {} | to_entries | map("\(.key)=\(.value)") | join(",")' 2>/dev/null)
                    export STATIC_HOST_MAP="${STATIC_HOST_MAP:-$shm}"
                fi
            fi

            # 3. Nebula CA cert
            if [[ -n "$CLUSTER_ID" ]]; then
                curl -sfS --connect-timeout 5 --max-time 10 \
                    "$WORKER_URL/api/v1/clusters/nebula/ca?clusterId=$CLUSTER_ID" \
                    -o /var/lib/nebula/ca.crt 2>/dev/null || true
            fi

            # 4. Host cert + key (authenticated with node token)
            if [[ -n "$CLUSTER_ID" && -n "$NODE_TOKEN" ]]; then
                local hc
                hc=$(curl -sfS --connect-timeout 5 --max-time 10 \
                    -H "Authorization: Bearer $NODE_TOKEN" \
                    "$WORKER_URL/api/v1/clusters/nebula/host-cert?clusterId=$CLUSTER_ID" 2>&1) || true

                if [[ -n "$hc" ]]; then
                    echo "$hc" | jq -r '.cert' > /var/lib/nebula/host.crt 2>/dev/null
                    echo "$hc" | jq -r '.key' > /var/lib/nebula/host.key 2>/dev/null
                    chmod 600 /var/lib/nebula/host.key
                    log "host cert pulled from Worker"
                fi
            fi
        fi
    fi

    # Skip Nebula if lighthouse is set to "skip"
    if [[ "${NEBULA_LIGHTHOUSE:-}" == "skip" ]]; then
        log "Nebula disabled (NEBULA_LIGHTHOUSE=skip)"
        return 0
    fi

    # File mode: certs must be mounted at /etc/nebula/
    if [[ ! -f /etc/nebula/host.crt ]] && [[ ! -f /var/lib/nebula/host.crt ]]; then
        log "FATAL: no host cert at /etc/nebula/host.crt or /var/lib/nebula/host.crt"
        log "  mount certs or set WORKER_URL/WORKER_TOKEN"
        exit 1
    fi
}

# ─── step 2: nebula ───
start_nebula() {
    if [[ "${NEBULA_LIGHTHOUSE:-}" == "skip" ]]; then
        log "Nebula skipped (NEBULA_LIGHTHOUSE=skip)"
        return 0
    fi

    log "starting Nebula (lighthouse=$NEBULA_LIGHTHOUSE)"

    # Config goes to writable dir; certs are read from /etc/nebula
    local config_dir="${NEBULA_CONFIG_DIR:-/var/lib/nebula}"
    mkdir -p "$config_dir"

    if [[ ! -f "$config_dir/config.yml" ]]; then
        # static_host_map: maps Nebula IPs to real addresses
        #   format: STATIC_HOST_MAP="NEB_IP=REAL_ADDR,NEB_IP2=REAL_ADDR2,..."
        local map_block=""
        if [[ -n "${STATIC_HOST_MAP:-}" ]]; then
            map_block="static_host_map:"
            IFS=',' read -ra PAIRS <<< "$STATIC_HOST_MAP"
            for pair in "${PAIRS[@]}"; do
                IFS='=' read -r neb_ip real_addr <<< "$pair"
                map_block+=$'\n'"  \"$neb_ip\": [\"$real_addr\"]"
            done
        fi

        cat > "$config_dir/config.yml" <<YAML
pki:
  ca: /etc/nebula/ca.crt
  cert: /etc/nebula/host.crt
  key: /etc/nebula/host.key

$map_block

lighthouse:
  am_lighthouse: ${AM_LIGHTHOUSE:-false}
  interval: 60
  hosts: ["$NEBULA_LIGHTHOUSE"]

listen:
  host: 0.0.0.0
  port: ${NEBULA_PORT:-4242}

punchy:
  punch: ${PUNCH_ENABLE:-false}

tun:
  dev: nebula1
  mtu: ${NEBULA_MTU:-1300}
  tx_queue: 500
  drop_local_broadcast: true
  drop_multicast: true
  use_system_route_table: true

firewall:
  outbound:
    - port: any
      proto: any
      host: any
  inbound:
    - port: any
      proto: any
      host: any
YAML
    fi

    nebula -config "$config_dir/config.yml" &
    NEBULA_PID=$!

    # Wait for TUN
    for i in $(seq 1 30); do
        ip addr show nebula1 >/dev/null 2>&1 && break
        sleep 0.5
    done
    ip addr show nebula1 >/dev/null 2>&1 || {
        log "FATAL: Nebula TUN did not come up"
        exit 1
    }
    NEBULA_IP=$(ip -4 addr show nebula1 | awk '/inet /{print $2}' | cut -d/ -f1)
    log "Nebula up: PID=$NEBULA_PID IP=$NEBULA_IP"
}

# ─── step 3: podman socket ───
start_podman_socket() {
    log "starting Podman socket"
    mkdir -p /run/podman

    # Kill stale socket
    rm -f /run/podman/podman.sock

    podman system service --time=0 unix:///run/podman/podman.sock &
    PODMAN_PID=$!

    # Wait for socket
    for i in $(seq 1 20); do
        [[ -S /run/podman/podman.sock ]] && break
        sleep 0.3
    done
    [[ -S /run/podman/podman.sock ]] || {
        log "FATAL: Podman socket did not appear"
        exit 1
    }
    log "Podman socket ready: PID=$PODMAN_PID"
}

# ─── step 4: CNI config ───
deploy_cni() {
    local cni_name="${CNI_NAME:-nomad-ptp}"
    local cni_subnet="${CNI_SUBNET:-10.77.200.0/24}"
    local cni_dir="${CNI_CONFIG_DIR:-/opt/cni/config}"

    log "deploying CNI: $cni_name ($cni_subnet)"

    mkdir -p "$cni_dir"
    cat > "$cni_dir/${cni_name}.conflist" <<JSON
{
  "cniVersion": "1.0.0",
  "name": "$cni_name",
  "plugins": [
    {
      "type": "ptp",
      "ipam": {
        "type": "host-local",
        "subnet": "$cni_subnet",
        "routes": [{"dst": "0.0.0.0/0"}]
      }
    },
    {"type": "firewall"}
  ]
}
JSON
    log "CNI deployed: $cni_dir/${cni_name}.conflist"
}

# ─── step 5: Nomad client ───
start_nomad() {
    log "starting Nomad client → $NOMAD_SERVER"
    mkdir -p /var/lib/nomad

    cat > /etc/nomad.d/client.hcl <<HCL
data_dir  = "/var/lib/nomad"
log_level = "INFO"
name      = "$HOSTNAME"

client {
  enabled           = true
  servers           = ["$NOMAD_SERVER"]
  network_interface = "${NOMAD_IFACE:-eth0}"
  cni_path          = "${CNI_BIN_DIR:-/opt/cni/bin}"
  cni_config_dir    = "${CNI_CONFIG_DIR:-/opt/cni/config}"
}

plugin_dir = "/opt/nomad/plugins"

plugin "raw_exec" {
  config { enabled = true }
}

plugin "nomad-driver-podman" {
  config {
    volumes {
      enabled = false
    }
  }
}
HCL

    nomad agent -config=/etc/nomad.d/client.hcl &
    NOMAD_PID=$!

    # Expose env vars for nomad commands
    export NOMAD_ADDR="http://${NOMAD_SERVER}:4646"

    # Wait for client to register
    local node_id=""
    for i in $(seq 1 60); do
        node_id=$(nomad node status -self -json 2>/dev/null | jq -r '.ID // empty' 2>/dev/null || true)
        [[ -n "$node_id" ]] && break
        sleep 1
    done

    if [[ -z "$node_id" ]]; then
        log "WARN: Nomad client registration timeout (continuing)"
    else
        log "Nomad client ready: PID=$NOMAD_PID node=$node_id"
    fi
}

# ─── step 6: submit Nomad system jobs ───
submit_jobs() {
    export NOMAD_ADDR="${NOMAD_ADDR:-http://${NOMAD_SERVER}:4646}"

    local jobs_dir="${1:-/etc/nomad-jobs}"

    if [[ ! -d "$jobs_dir" ]]; then
        log "no nomad-jobs dir at $jobs_dir, skipping job submission"
        return 0
    fi

    for jobfile in "$jobs_dir"/*.nomad; do
        [[ -f "$jobfile" ]] || continue
        local jobname
        jobname=$(basename "$jobfile" .nomad)

        if nomad job status "$jobname" >/dev/null 2>&1; then
            log "job $jobname already running"
            continue
        fi

        log "submitting $jobname"
        nomad job run -detach "$jobfile" 2>&1 || {
            log "WARN: failed to submit $jobname"
            continue
        }
        log "$jobname submitted"
    done
}

# ─── main ───
case "$MODE" in
    bootstrap)
        log "=== tinycloud bootstrap: $HOSTNAME ==="
        resolve_identity
        start_nebula
        start_podman_socket
        deploy_cni
        start_nomad
        submit_jobs
        log "=== bootstrap complete: $HOSTNAME ==="
        ;;
    submit-only)
        log "=== tinycloud submit-only ==="
        submit_jobs
        ;;
    daemon)
        log "=== tinycloud daemon mode ==="
        resolve_identity
        start_nebula
        start_podman_socket
        deploy_cni
        start_nomad
        submit_jobs
        log "=== daemon ready, blocking ==="
        # Block on background processes
        wait
        ;;
    *)
        log "usage: tinycloud-init {bootstrap|daemon|submit-only}"
        exit 1
        ;;
esac
