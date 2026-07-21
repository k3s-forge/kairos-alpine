// Worker endpoint: GET /api/v1/clusters/[clusterId]/takeover/[token]
// Returns a one-line podman command for full-disk takeover installation.
// The command runs in rescue mode and installs kairos-alpine to /dev/sda.

import type { APIRoute } from 'astro';

const WORKER_URL = 'https://transform-worker.bengcor.workers.dev';

export const GET: APIRoute = async ({ params, request }) => {
  try {
    const { clusterId, token } = params;
    const { env } = await import('cloudflare:workers');
    const kv = env.NOMAD_KV;

    // 1. Validate enrollment token
    const enrollmentKey = `transform/enrollments/${token}`;
    const enrollmentRaw = await kv.get(enrollmentKey);
    if (!enrollmentRaw) {
      return new Response('Invalid or expired enrollment token', { status: 403 });
    }
    const enrollment = JSON.parse(enrollmentRaw);

    if (enrollment.clusterId && enrollment.clusterId !== clusterId) {
      return new Response('Token does not match cluster', { status: 403 });
    }

    if (enrollment.expiresAt && new Date(enrollment.expiresAt) < new Date()) {
      return new Response('Enrollment token expired', { status: 403 });
    }

    // Mark token as takeover_used
    enrollment.takeoverUsedAt = new Date().toISOString();
    await kv.put(enrollmentKey, JSON.stringify(enrollment));

    // 2. Get latest release version
    const releaseKey = 'transform/releases/latest';
    const latestRaw = await kv.get(releaseKey);
    const version = latestRaw ? JSON.parse(latestRaw).version : '2026.07.11';
    const imageRef = `ghcr.io/k3s-forge/kairos-alpine:${version}`;

    // 3. Build enrollment seed (base64-encoded JSON)
    const seed = btoa(JSON.stringify({
      workerUrl: WORKER_URL,
      token,
      clusterId,
      version,
      createdAt: new Date().toISOString(),
    }));

    // 4. Return the podman command
    const command = `podman run --privileged -v /dev:/dev --rm \\
  ${imageRef} \\
  /install.sh /dev/sda "${seed}"`;

    return new Response(command + '\n', {
      headers: {
        'Content-Type': 'text/plain; charset=utf-8',
        'Cache-Control': 'no-cache, no-store, must-revalidate',
      },
    });
  } catch (error) {
    console.error('takeover GET error:', error);
    return new Response('Internal server error', { status: 500 });
  }
};
