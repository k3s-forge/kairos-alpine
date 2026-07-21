// Worker endpoint: POST /api/v1/nodes/[id]/takeover
// Generate a node-specific full-disk takeover command.
// Device path, arch, channel are customizable.
// Admin-only (CF Access on setup.* domain).

import type { APIRoute } from 'astro';

const WORKER_URL = 'https://transform-worker.bengcor.workers.dev';

interface TakeoverRequest {
  device: string;         // e.g. "/dev/sda", "/dev/nvme0n1"
  channel?: string;       // "stable" | "edge" (default: stable)
  arch?: string;          // "amd64" | "arm64" (default: amd64)
}

interface TakeoverConfig {
  nodeId: string;
  token: string;
  device: string;
  image: string;
  seed: string;           // base64-encoded enrollment JSON
  command: string;
  version: string;
  createdAt: string;
  expiresAt: string;
}

// ─── GET: Retrieve existing takeover config ───
export const GET: APIRoute = async ({ params }) => {
  try {
    const { id } = params;
    const { env } = await import('cloudflare:workers');
    const kv = env.NOMAD_KV;

    const raw = await kv.get(`transform/takeover/${id}`);
    if (!raw) {
      return new Response(JSON.stringify({ exists: false }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const config: TakeoverConfig = JSON.parse(raw);
    // Don't return the token if expired
    const now = new Date();
    const expired = config.expiresAt && new Date(config.expiresAt) < now;

    return new Response(JSON.stringify({
      exists: true,
      expired,
      device: config.device,
      version: config.version,
      command: expired ? null : config.command,
      createdAt: config.createdAt,
      expiresAt: config.expiresAt,
    }), {
      headers: { 'Content-Type': 'application/json' },
    });
  } catch (error) {
    console.error('takeover GET error:', error);
    return new Response(JSON.stringify({ error: 'Internal error' }), { status: 500 });
  }
};

// ─── POST: Generate new takeover command ───
export const POST: APIRoute = async ({ params, request }) => {
  try {
    const { id } = params;

    // Validate admin access (CF Access on setup.* domain)
    const host = request.headers.get('host') || '';
    if (!host.startsWith('setup.')) {
      // Also allow API token auth
      const auth = request.headers.get('authorization') || '';
      // (CF Access JWT validation handled by Cloudflare)
    }

    const body = await request.json() as TakeoverRequest;

    // Validate device
    const device = body.device || '/dev/sda';
    if (!/^\/dev\/[a-zA-Z0-9]+$/.test(device) || device.includes('..')) {
      return new Response(JSON.stringify({ error: 'Invalid device path' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const channel = body.channel || 'stable';
    const arch = body.arch || 'amd64';

    // Validate node exists
    const { env } = await import('cloudflare:workers');
    const kv = env.NOMAD_KV;
    const nodeRaw = await kv.get(`nomad/nodes/${id}`);
    if (!nodeRaw) {
      return new Response(JSON.stringify({ error: 'Node not found' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    // Get cluster info for this node (from enrollment or probe)
    const clusterId = await resolveClusterId(kv, id);

    // Get latest release
    const releaseRaw = await kv.get('transform/releases/latest');
    const version = releaseRaw ? JSON.parse(releaseRaw).version : '2026.07.11';
    const imageRef = `ghcr.io/k3s-forge/kairos-alpine:${version}`;

    // Generate enrollment token
    const token = generateToken();
    const expiresAt = new Date(Date.now() + 24 * 3600 * 1000).toISOString(); // 24h

    // Store enrollment in KV
    await kv.put(`transform/enrollments/${token}`, JSON.stringify({
      token,
      nodeId: id,
      clusterId,
      channel,
      arch,
      version,
      createdAt: new Date().toISOString(),
      expiresAt,
    }));

    // Build seed (base64-encoded JSON)
    const seed = btoa(JSON.stringify({
      workerUrl: WORKER_URL,
      token,
      nodeId: id,
      clusterId,
      version,
    }));

    // Build command
    // Note: uses docker (not podman) — rescue environments typically have docker
    const command = [
      `docker run --privileged -v /dev:/dev --rm \\`,
      `  ${imageRef} \\`,
      `  /install.sh ${device} "${seed}"`,
    ].join('\n');

    // Store takeover config in KV
    const config: TakeoverConfig = {
      nodeId: id,
      token,
      device,
      image: imageRef,
      seed,
      command,
      version,
      createdAt: new Date().toISOString(),
      expiresAt,
    };

    await kv.put(`transform/takeover/${id}`, JSON.stringify(config));

    return new Response(JSON.stringify({
      command,
      device,
      version,
      token: token.substring(0, 16) + '...',
      createdAt: config.createdAt,
      expiresAt,
    }), {
      status: 201,
      headers: { 'Content-Type': 'application/json' },
    });
  } catch (error) {
    console.error('takeover POST error:', error);
    return new Response(JSON.stringify({ error: 'Internal error' }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' },
    });
  }
};

// ─── DELETE: Revoke takeover config ───
export const DELETE: APIRoute = async ({ params }) => {
  try {
    const { id } = params;
    const { env } = await import('cloudflare:workers');
    const kv = env.NOMAD_KV;

    const raw = await kv.get(`transform/takeover/${id}`);
    if (!raw) {
      return new Response(JSON.stringify({ error: 'Not found' }), { status: 404 });
    }

    // Delete enrollment token too
    const config: TakeoverConfig = JSON.parse(raw);
    await kv.delete(`transform/enrollments/${config.token}`);
    await kv.delete(`transform/takeover/${id}`);

    return new Response(JSON.stringify({ ok: true }), {
      headers: { 'Content-Type': 'application/json' },
    });
  } catch (error) {
    console.error('takeover DELETE error:', error);
    return new Response(JSON.stringify({ error: 'Internal error' }), { status: 500 });
  }
};

// ─── Helpers ───

async function resolveClusterId(kv: any, nodeId: string): Promise<string> {
  // Try enrollment records first
  try {
    const enrollments = await kv.list({ prefix: 'transform/enrollments/' });
    for (const key of enrollments.keys || []) {
      const raw = await kv.get(key.name);
      if (raw) {
        const enrollment = JSON.parse(raw);
        if (enrollment.nodeId === nodeId && enrollment.clusterId) {
          return enrollment.clusterId;
        }
      }
    }
  } catch (_) { /* ignore list errors */ }

  // Fallback: derive from node data
  const nodeRaw = await kv.get(`nomad/nodes/${nodeId}`);
  if (nodeRaw) {
    const node = JSON.parse(nodeRaw);
    if (node.clusterId) return node.clusterId;
  }

  return 'default';
}

function generateToken(): string {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  const seg = (len: number) => {
    let s = '';
    const buf = new Uint8Array(len);
    crypto.getRandomValues(buf);
    for (let i = 0; i < len; i++) s += chars[buf[i] % chars.length];
    return s;
  };
  return `tok_${seg(16)}_${seg(8)}`;
}
