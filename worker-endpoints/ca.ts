import type { APIRoute } from 'astro';
import { createNebulaCaRepository } from '../../../../../data/cluster-config-repository';
import { requireAdmin } from '../../../../../lib/admin-auth';
import { apiError, text } from '../../../../../lib/http';
import { getKV } from '../../../../../lib/kv';

/** GET — public: retrieve Nebula CA cert for a cluster */
export const GET: APIRoute = async ({ url }) => {
  try {
    const clusterId = url.searchParams.get('clusterId');
    if (!clusterId) return text('missing clusterId', 400);
    const kv = await getKV();
    const cert = await createNebulaCaRepository(kv).get(clusterId);
    if (!cert) return text('not found', 404);
    return text(cert, 200, { 'Content-Type': 'text/plain' });
  } catch (error) {
    return apiError(error);
  }
};

/** PUT — admin: set Nebula CA cert */
export const PUT: APIRoute = async ({ request, url }) => {
  try {
    requireAdmin(request);
    const clusterId = url.searchParams.get('clusterId');
    if (!clusterId) return text('missing clusterId', 400);
    const body = await request.text();
    const kv = await getKV();
    const repo = createNebulaCaRepository(kv);
    await repo.save(clusterId, body);
    return text('ok', 200);
  } catch (error) {
    return apiError(error);
  }
};
