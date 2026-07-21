import type { APIRoute } from 'astro';
import { createEncryptedStateRepository } from '../../../../../data/encrypted-state-repository';
import { requireAdmin } from '../../../../../lib/admin-auth';
import { apiError, text } from '../../../../../lib/http';
import { getKV } from '../../../../../lib/kv';
import { createEncryptedStateService } from '../../../../../services/encrypted-state-service';

/** GET — node-authenticated: retrieve Nebula CA private key */
export const GET: APIRoute = async ({ request, url }) => {
  try {
    const nodeToken = bearerToken(request);
    const kv = await getKV();
    const identity = await createEncryptedStateService(
      createEncryptedStateRepository(kv),
    ).authenticate(nodeToken);

    const clusterId = url.searchParams.get('clusterId') || identity.clusterId;
    const caKey = await kv.get(`cluster/${clusterId}/nebula/ca-key`);
    if (!caKey) return text('CA key not found for this cluster', 404);

    return text(caKey, 200);
  } catch (error) {
    return apiError(error);
  }
};

/** PUT — admin: upload Nebula CA private key */
export const PUT: APIRoute = async ({ request, url }) => {
  try {
    requireAdmin(request);
    const clusterId = url.searchParams.get('clusterId');
    if (!clusterId) return text('missing clusterId', 400);

    const caKey = await request.text();
    if (!caKey?.trim().startsWith('-----BEGIN NEBULA')) {
      return text('invalid CA key — must start with "-----BEGIN NEBULA"', 400);
    }

    const kv = await getKV();
    await kv.put(`cluster/${clusterId}/nebula/ca-key`, caKey.trim());
    return text('ok', 200);
  } catch (error) {
    return apiError(error);
  }
};

const bearerToken = (request: Request): string => {
  const authorization = request.headers.get('Authorization');
  return authorization?.startsWith('Bearer ')
    ? authorization.slice('Bearer '.length)
    : '';
};
