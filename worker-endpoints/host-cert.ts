import type { APIRoute } from 'astro';
import { createNebulaHostCertRepository } from '../../../../../data/cluster-config-repository';
import { createEncryptedStateRepository } from '../../../../../data/encrypted-state-repository';
import { requireAdmin } from '../../../../../lib/admin-auth';
import { apiError, json, text } from '../../../../../lib/http';
import { getKV } from '../../../../../lib/kv';
import { createEncryptedStateService } from '../../../../../services/encrypted-state-service';
import type { NebulaHostCert } from '../../../../../data/cluster-config-repository';

/** GET — node-authenticated: retrieve host cert + key */
export const GET: APIRoute = async ({ request, url }) => {
  try {
    const nodeToken = bearerToken(request);
    const kv = await getKV();
    const identity = await createEncryptedStateService(
      createEncryptedStateRepository(kv),
    ).authenticate(nodeToken);

    const clusterId = url.searchParams.get('clusterId') || identity.clusterId;
    const hostCert = await createNebulaHostCertRepository(kv).get(clusterId, identity.nodeId);
    if (!hostCert) return text('host cert not found for this node', 404);

    return json(hostCert, 200);
  } catch (error) {
    return apiError(error);
  }
};

/** PUT — admin: upload host cert + key for a node */
export const PUT: APIRoute = async ({ request, url }) => {
  try {
    requireAdmin(request);
    const clusterId = url.searchParams.get('clusterId');
    if (!clusterId) return text('missing clusterId', 400);
    const nodeId = url.searchParams.get('nodeId');
    if (!nodeId) return text('missing nodeId', 400);

    const body = object(await request.json());
    const hostCert: NebulaHostCert = {
      cert: stringVal(body.cert, 'cert'),
      key: stringVal(body.key, 'key'),
    };

    const kv = await getKV();
    await createNebulaHostCertRepository(kv).save(clusterId, nodeId, hostCert);
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

const object = (value: unknown): Record<string, unknown> => {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new Error('body must be an object');
  }
  return value as Record<string, unknown>;
};

const stringVal = (value: unknown, path: string): string => {
  if (typeof value !== 'string' || !value.trim()) throw new Error(`${path} must be a string`);
  return value.trim();
};
