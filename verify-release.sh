#!/bin/sh
# verify-release.sh
# Verifies Ed25519-signed release metadata from the Worker.
# Embedded in the Kairos CronJob for upgrade auto-detection.
#
# Input: JSON from GET /api/v1/releases/latest
#   { "payload": {...}, "signature": "<base64>", "timestamp": "..." }
#
# Exit 0 if verified & upgrade needed (writes NodeOpUpgrade YAML to stdout).
# Exit 1 on verification failure.
# Exit 2 if already at latest version.

set -e

PUBKEY="${TRANSFORM_PUBKEY:-/etc/transform/release-key.pub}"
WORKER_URL="${TRANSFORM_WORKER_URL:-https://worker.example.com}"
API_TOKEN="${TRANSFORM_API_TOKEN:-}"

if [ -z "$API_TOKEN" ]; then
  echo "FATAL: TRANSFORM_API_TOKEN not set" >&2
  exit 3
fi

# 1. Fetch signed release
RESP=$(curl -sfSL -H "Authorization: Bearer ${API_TOKEN}" "${WORKER_URL}/api/v1/releases/latest")
if [ $? -ne 0 ]; then
  echo "FATAL: failed to fetch release from Worker" >&2
  exit 3
fi

SIGNATURE=$(echo "$RESP" | jq -r '.signature // empty')
PAYLOAD=$(echo "$RESP" | jq -Sc '.payload // empty')
TIMESTAMP=$(echo "$RESP" | jq -r '.timestamp // empty')

if [ -z "$SIGNATURE" ] || [ -z "$PAYLOAD" ] || [ -z "$TIMESTAMP" ]; then
  echo "FATAL: invalid response format" >&2
  echo "$RESP" >&2
  exit 3
fi

# 2. Verify Ed25519 signature
# The signature covers: canonicalJson(payload) + "\n" + timestamp
printf '%s\n%s' "$PAYLOAD" "$TIMESTAMP" > /tmp/release-msg.bin
# Decode base64url (no padding, URL-safe chars) to binary
# Alpine/busybox base64 -d needs padding and standard chars
SIG_STANDARD=$(echo "$SIGNATURE" | tr '_-' '/+')
# Add padding: base64 needs length divisible by 4
PAD=$(( (4 - ${#SIG_STANDARD} % 4) % 4 ))
PADDED=$(printf '%s%*s' "$SIG_STANDARD" "$PAD" | tr ' ' '=')
echo "$PADDED" | base64 -d > /tmp/release-sig.bin 2>/dev/null

openssl pkeyutl -verify -pubin -inkey "$PUBKEY" \
  -rawin -in /tmp/release-msg.bin -sigfile /tmp/release-sig.bin

if [ $? -ne 0 ]; then
  echo "FATAL: signature verification failed" >&2
  exit 1
fi

echo "Signature verified OK" >&2

# 3. Check if we're already at this version
# /etc/kairos-release contains: KAIROS_VERSION="2026.07.2"
# The payload.version is the release version string.
LATEST_VERSION=$(echo "$PAYLOAD" | jq -r '.version // empty')
if [ -z "$LATEST_VERSION" ]; then
  echo "FATAL: no version in payload" >&2
  exit 3
fi

CURRENT_VERSION=$(grep KAIROS_VERSION /etc/kairos-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "")
if [ "$LATEST_VERSION" = "$CURRENT_VERSION" ]; then
  echo "Already at ${CURRENT_VERSION}, nothing to upgrade" >&2
  exit 2
fi

# 4. Extract image reference (use digest if available)
IMAGE=$(echo "$PAYLOAD" | jq -r '.image.oci // empty')
DIGEST=$(echo "$PAYLOAD" | jq -r '.image.digest // empty')
if [ -n "$DIGEST" ] && [ "$DIGEST" != "null" ]; then
  # Derive digest reference from OCI path: ghcr.io/org/repo:tag → ghcr.io/org/repo@sha256:xxx
  IMAGE_REPO=$(echo "$IMAGE" | cut -d: -f1)
  IMAGE="${IMAGE_REPO}@${DIGEST}"
fi

echo "Upgrading from ${CURRENT_VERSION} to ${LATEST_VERSION} (image: ${IMAGE})" >&2

# 5. Output NodeOpUpgrade manifest
cat <<EOF
apiVersion: operator.kairos.io/v1alpha1
kind: NodeOpUpgrade
metadata:
  generateName: auto-upgrade-
  namespace: default
spec:
  image: ${IMAGE}
  concurrency: 1
  stopOnFailure: true
  upgradeActive: true
  nodeSelector:
    matchLabels:
      kairos.io/managed: "true"
EOF

exit 0
