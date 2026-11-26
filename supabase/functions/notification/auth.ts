// Authentication adapters (spec §11, §40):
//  * opaque scoped tokens (ntf_api_tokens: service | product | admin | user), including tokens minted by /v1/auth/exchange
//  * JWTs from trusted issuers registered per product in ntf_identity_issuers
//    - jwks_url NULL  => same Supabase project; verified by Supabase Auth (works for HS256 and asymmetric keys)
//    - jwks_url set   => external OIDC/FastAPI issuer; verified against its JWKS (issuer + audience + expiry)
import { createRemoteJWKSet, decodeJwt, jwtVerify } from 'npm:jose@5';
import { db, q } from './db.ts';
import { ApiError, UUID_RE, sha256Hex } from './http.ts';

export type Scope = 'service' | 'product' | 'admin' | 'user';

export interface Principal {
  via: 'token' | 'jwt';
  scope: Scope;
  tenantId: string;
  productId: string;
  organizationId: string;
  userId: string | null;
  /** True for admin tokens and for JWT users holding a role with notification_admin = true. */
  isAdmin: boolean;
  /** Audit actor string, never contains secrets. */
  actor: string;
}

const jwksCache = new Map<string, ReturnType<typeof createRemoteJWKSet>>();

export function looksLikeJwt(token: string): boolean {
  const parts = token.split('.');
  if (parts.length !== 3) return false;
  try {
    const h = JSON.parse(atob(parts[0].replace(/-/g, '+').replace(/_/g, '/')));
    return typeof h?.alg === 'string';
  } catch {
    return false;
  }
}

async function activeTenant(productId: string, organizationId: string) {
  const t = await q(
    db.from('ntf_tenants').select('id,product_id,organization_id,active')
      .eq('product_id', productId).eq('organization_id', organizationId).maybeSingle()
  );
  if (!t) throw new ApiError(403, 'tenant_not_found', 'Organization is not provisioned for this product');
  if (!t.active) throw new ApiError(403, 'tenant_inactive', 'Tenant is suspended');
  return t;
}

async function activeProduct(productId: string) {
  const p = await q(db.from('ntf_products').select('id,code,status').eq('id', productId).maybeSingle());
  if (!p || p.status !== 'ACTIVE') throw new ApiError(403, 'product_inactive', 'Product is not active');
  return p;
}

function orgHeader(req: Request, required: boolean): string | null {
  const org = req.headers.get('x-organization-id')?.trim() || null;
  if (!org && required) throw new ApiError(400, 'organization_required', 'X-Organization-Id header is required');
  if (org && !UUID_RE.test(org)) throw new ApiError(400, 'invalid_organization', 'X-Organization-Id must be a UUID');
  return org;
}

async function isNotificationAdmin(tenantId: string, userId: string): Promise<boolean> {
  const rows = await q(
    db.from('ntf_user_roles').select('role_code,role:ntf_roles!inner(notification_admin,active)')
      .eq('tenant_id', tenantId).eq('user_id', userId)
      .eq('role.notification_admin', true).eq('role.active', true).limit(1)
  );
  return rows.length > 0;
}

async function activeUser(tenantId: string, userId: string) {
  const u = await q(
    db.from('ntf_users').select('user_id,active').eq('tenant_id', tenantId).eq('user_id', userId).maybeSingle()
  );
  if (!u) throw new ApiError(403, 'user_not_synced', 'User is not a member of this tenant');
  if (!u.active) throw new ApiError(403, 'user_inactive', 'User is inactive');
}

async function fromJwt(req: Request, token: string): Promise<Principal> {
  const productCode = req.headers.get('x-product-code')?.trim();
  if (!productCode) throw new ApiError(400, 'product_required', 'X-Product-Code header is required with a JWT');
  const product = await q(db.from('ntf_products').select('id,code,status').eq('code', productCode).maybeSingle());
  if (!product || product.status !== 'ACTIVE') throw new ApiError(401, 'unauthorized', 'Unknown product');

  let iss: string | undefined;
  try {
    iss = decodeJwt(token).iss;
  } catch {
    throw new ApiError(401, 'unauthorized', 'Malformed token');
  }
  if (!iss) throw new ApiError(401, 'unauthorized', 'Token has no issuer');
  const issuer = await q(
    db.from('ntf_identity_issuers').select('*').eq('product_id', product.id).eq('issuer', iss).eq('active', true).maybeSingle()
  );
  if (!issuer) throw new ApiError(401, 'unauthorized', 'Issuer is not trusted for this product');

  let claims: Record<string, unknown>;
  if (!issuer.jwks_url) {
    // Same Supabase project: Supabase Auth validates signature, expiry and session.
    const { data, error } = await db.auth.getUser(token);
    if (error || !data?.user) throw new ApiError(401, 'unauthorized', 'Invalid or expired token');
    claims = decodeJwt(token) as Record<string, unknown>;
    const aud = claims.aud;
    const audOk = Array.isArray(aud) ? aud.includes(issuer.audience) : aud === issuer.audience;
    if (!audOk) throw new ApiError(401, 'unauthorized', 'Invalid audience');
    claims.sub = data.user.id;
  } else {
    let jwks = jwksCache.get(issuer.jwks_url);
    if (!jwks) {
      jwks = createRemoteJWKSet(new URL(issuer.jwks_url));
      jwksCache.set(issuer.jwks_url, jwks);
    }
    try {
      claims = (await jwtVerify(token, jwks, { issuer: issuer.issuer, audience: issuer.audience })).payload as Record<string, unknown>;
    } catch {
      throw new ApiError(401, 'unauthorized', 'Invalid or expired token');
    }
  }
  const userId = claims[issuer.user_id_claim];
  if (typeof userId !== 'string' || !userId) throw new ApiError(401, 'unauthorized', 'Token has no user id claim');

  const org = orgHeader(req, true)!;
  const t = await activeTenant(product.id, org);
  await activeUser(t.id, userId);
  return {
    via: 'jwt', scope: 'user', tenantId: t.id, productId: product.id, organizationId: org, userId,
    isAdmin: await isNotificationAdmin(t.id, userId), actor: `jwt:${product.code}:${userId}`
  };
}

async function fromOpaque(req: Request, token: string): Promise<Principal> {
  const a = await q(
    db.from('ntf_api_tokens').select('*').eq('token_hash', await sha256Hex(token))
      .gt('expires_at', new Date().toISOString()).is('revoked_at', null).maybeSingle()
  );
  if (!a) throw new ApiError(401, 'unauthorized', 'Invalid or expired token');
  const label = `token:${a.scope}:${(a.token_hash as string).slice(0, 8)}`;

  if (a.scope === 'product') {
    await activeProduct(a.product_id);
    const org = orgHeader(req, true)!;
    const t = await activeTenant(a.product_id, org);
    return { via: 'token', scope: 'product', tenantId: t.id, productId: a.product_id, organizationId: org, userId: null, isAdmin: false, actor: label };
  }

  const t = await q(db.from('ntf_tenants').select('*').eq('id', a.tenant_id).maybeSingle());
  if (!t) throw new ApiError(401, 'unauthorized', 'Invalid token');
  if (!t.active) throw new ApiError(403, 'tenant_inactive', 'Tenant is suspended');
  await activeProduct(t.product_id);
  // Browser-facing scopes must name the organization they act on; server tokens may omit it.
  const org = orgHeader(req, a.scope === 'user' || a.scope === 'admin');
  if (org && org !== t.organization_id) throw new ApiError(403, 'scope', 'Organization does not match the credential');
  if (a.scope === 'user') await activeUser(t.id, a.user_id);
  return {
    via: 'token', scope: a.scope, tenantId: t.id, productId: t.product_id, organizationId: t.organization_id,
    userId: a.user_id ?? null, isAdmin: a.scope === 'admin', actor: a.user_id ? `${label}:${a.user_id}` : label
  };
}

export async function authenticate(req: Request): Promise<Principal> {
  const token = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '').trim();
  if (!token) throw new ApiError(401, 'unauthorized', 'Missing bearer token');
  return looksLikeJwt(token) ? await fromJwt(req, token) : await fromOpaque(req, token);
}

/** Server-side credentials allowed to publish events and sync identities. */
export function isServer(p: Principal) {
  return p.scope === 'service' || p.scope === 'product';
}

/** End users: opaque user tokens and JWT users. */
export function isEndUser(p: Principal) {
  return p.scope === 'user' && !!p.userId;
}
