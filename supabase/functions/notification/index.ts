// Notification engine Edge Function: single entry point, routes under /v1.
import Ajv from 'npm:ajv@8';
import { render } from './parser.mjs';
import { audit, db, q } from './db.ts';
import { authenticate, isEndUser, isServer, Principal } from './auth.ts';
import {
  ApiError, corsHeaders, decodeCursor, encodeCursor, errorResponse, json, normalizePath, randomToken,
  requireArray, requireString, safeEqual, sha256Hex, toApiError, UUID_RE
} from './http.ts';
import { runWorker } from './worker.ts';
import { PROVIDERS } from './adapters/index.ts';

const VERSION = '0.2.0';
const MAX_BODY_BYTES = 256 * 1024;
// deno-lint-ignore no-explicit-any
const ajv = new (Ajv as any)({ strict: false, allErrors: true });

// deno-lint-ignore no-explicit-any
type Body = Record<string, any>;

async function readBody(req: Request): Promise<Body> {
  if (req.method !== 'POST') return {};
  const len = Number(req.headers.get('content-length') ?? 0);
  if (len > MAX_BODY_BYTES) throw new ApiError(413, 'payload_too_large', 'Request body too large');
  const text = await req.text();
  if (text.length > MAX_BODY_BYTES) throw new ApiError(413, 'payload_too_large', 'Request body too large');
  if (!text.trim()) return {};
  try {
    const b = JSON.parse(text);
    if (!b || typeof b !== 'object' || Array.isArray(b)) throw Error();
    return b;
  } catch {
    throw new ApiError(400, 'invalid_json', 'Body must be a JSON object');
  }
}

function forbid(message = 'This credential cannot call this endpoint'): never {
  throw new ApiError(403, 'forbidden', message);
}

// ---------------------------------------------------------------- server APIs

async function publishEvent(p: Principal, b: Body, cid: string) {
  if (!isServer(p)) forbid();
  const eventCode = requireString(b.eventCode, 'eventCode', 100);
  const key = requireString(b.idempotencyKey, 'idempotencyKey', 200);
  const version = b.schemaVersion ?? 1;
  if (!Number.isInteger(version) || version < 1) throw new ApiError(422, 'invalid_request', 'schemaVersion must be a positive integer');
  const ev = await q(
    db.from('ntf_events').select('*').eq('product_id', p.productId).eq('code', eventCode).eq('version', version).maybeSingle()
  );
  if (!ev) throw new ApiError(422, 'unknown_event', `Event ${eventCode} v${version} is not registered for this product`);
  if (b.triggerType !== ev.trigger_type) {
    throw new ApiError(422, 'invalid_trigger_type', `triggerType must be ${ev.trigger_type}`);
  }
  if (!ajv.validate(ev.payload_schema, b.data ?? {})) {
    throw new ApiError(422, 'invalid_payload', 'data does not match the event schema',
      (ajv.errors ?? []).slice(0, 10).map((e: { instancePath: string; message?: string }) => ({ path: e.instancePath, message: e.message })));
  }
  if (b.recipientContext !== undefined && (typeof b.recipientContext !== 'object' || Array.isArray(b.recipientContext))) {
    throw new ApiError(422, 'invalid_request', 'recipientContext must be an object of user id arrays');
  }
  const r = await q(db.rpc('ntf_accept_event_v2', {
    p_tenant: p.tenantId, p_product: p.productId, p_code: ev.code, p_version: ev.version,
    p_key: key, p_payload: b, p_correlation: cid
  }));
  if (r.status === 'CONFLICT') {
    throw new ApiError(409, 'idempotency_conflict', 'idempotencyKey was already used with a different payload', { id: r.event_id });
  }
  // Identical retries return the original acceptance reference (same body, same status).
  return json({ id: r.event_id, status: 'ACCEPTED' }, 202, cid,
    r.status === 'DUPLICATE' ? { 'Idempotent-Replayed': 'true' } : {});
}

async function exchangeToken(p: Principal, b: Body, cid: string) {
  if (!isServer(p)) forbid();
  const userId = requireString(b.userId, 'userId', 200);
  const scope = b.scope ?? 'user';
  if (scope !== 'user' && scope !== 'admin') throw new ApiError(422, 'invalid_request', 'scope must be user or admin');
  const ttl = Math.min(Math.max(Number(b.ttlSeconds ?? 3600), 60), 24 * 3600);
  const u = await q(db.from('ntf_users').select('active').eq('tenant_id', p.tenantId).eq('user_id', userId).maybeSingle());
  if (!u?.active) throw new ApiError(403, 'user_not_synced', 'User is not an active member of this tenant');
  if (scope === 'admin') {
    const rows = await q(
      db.from('ntf_user_roles').select('role_code,role:ntf_roles!inner(notification_admin,active)')
        .eq('tenant_id', p.tenantId).eq('user_id', userId).eq('role.notification_admin', true).eq('role.active', true).limit(1)
    );
    if (!rows.length) throw new ApiError(403, 'forbidden', 'User has no notification admin role');
  }
  const token = randomToken();
  const expiresAt = new Date(Date.now() + ttl * 1000).toISOString();
  await q(db.from('ntf_api_tokens').insert({
    token_hash: await sha256Hex(token), tenant_id: p.tenantId, product_id: p.productId,
    user_id: userId, scope, expires_at: expiresAt, label: 'exchange'
  }));
  await audit({ tenantId: p.tenantId, productId: p.productId, actor: p.actor, action: 'auth.exchange', details: { userId, scope, ttl }, correlationId: cid });
  return json({ accessToken: token, tokenType: 'Bearer', scope, expiresAt }, 200, cid);
}

async function syncUsers(p: Principal, b: Body, cid: string) {
  if (!isServer(p)) forbid();
  const users = requireArray(b.users, 'users', 1000);
  const r = await q(db.rpc('ntf_sync_users', { p_tenant: p.tenantId, p_users: users }));
  await audit({ tenantId: p.tenantId, productId: p.productId, actor: p.actor, action: 'users.sync', details: { count: users.length }, correlationId: cid });
  return json(r, 200, cid);
}

async function syncRoles(p: Principal, b: Body, cid: string) {
  if (!isServer(p)) forbid();
  const roles = requireArray(b.roles, 'roles', 500);
  const r = await q(db.rpc('ntf_sync_roles', { p_tenant: p.tenantId, p_roles: roles }));
  await audit({ tenantId: p.tenantId, productId: p.productId, actor: p.actor, action: 'roles.sync', details: { count: roles.length }, correlationId: cid });
  return json(r, 200, cid);
}

async function provisionTenant(req: Request, b: Body, cid: string) {
  // Needs a product-level credential; the organization comes from the body (it may not exist yet).
  const token = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '').trim();
  if (!token) throw new ApiError(401, 'unauthorized', 'Missing bearer token');
  const a = await q(db.from('ntf_api_tokens').select('*').eq('token_hash', await sha256Hex(token))
    .gt('expires_at', new Date().toISOString()).is('revoked_at', null).maybeSingle());
  if (!a) throw new ApiError(401, 'unauthorized', 'Invalid or expired token');
  if (a.scope !== 'product') forbid('Tenant provisioning requires a product credential');
  const org = requireString(b.organizationId, 'organizationId', 36);
  if (!UUID_RE.test(org)) throw new ApiError(422, 'invalid_request', 'organizationId must be a UUID');
  const r = await q(db.rpc('ntf_provision_tenant', {
    p_product: a.product_id, p_org: org, p_org_name: b.organizationName ?? null, p_channels: b.notificationChannels ?? b.channels ?? {}
  }));
  await audit({ tenantId: r.tenantId, productId: a.product_id, actor: `token:product:${a.token_hash.slice(0, 8)}`, action: 'tenant.provision', details: { organizationId: org }, correlationId: cid });
  return json({ ...r, organizationId: org }, 200, cid);
}

// ---------------------------------------------------------------- end-user APIs

async function inbox(p: Principal, url: URL, cid: string) {
  const limit = Math.min(Math.max(Number(url.searchParams.get('limit') ?? 50), 1), 100);
  let s = db.from('ntf_notifications')
    .select('*,deliveries:ntf_deliveries!inner(channel)')
    .eq('tenant_id', p.tenantId).eq('user_id', p.userId!).eq('deliveries.channel', 'IN_APP');
  const before = url.searchParams.get('before');
  if (before) {
    const c = decodeCursor(before);
    s = s.or(`created_at.lt.${c.createdAt},and(created_at.eq.${c.createdAt},id.lt.${c.id})`);
  }
  if (url.searchParams.get('unread') === 'true') s = s.is('read_at', null);
  const rows = await q(s.order('created_at', { ascending: false }).order('id', { ascending: false }).limit(limit + 1));
  const items = rows.slice(0, limit);
  const last = items[items.length - 1];
  return json({ items, nextCursor: rows.length > limit && last ? encodeCursor(last.created_at, last.id) : null }, 200, cid);
}

async function unreadCount(p: Principal, cid: string) {
  const { count, error } = await db.from('ntf_notifications')
    .select('id,deliveries:ntf_deliveries!inner(channel)', { count: 'exact', head: true })
    .eq('tenant_id', p.tenantId).eq('user_id', p.userId!).eq('deliveries.channel', 'IN_APP').is('read_at', null);
  if (error) throw new ApiError(500, 'internal_error', 'Request failed');
  return json({ count: count ?? 0 }, 200, cid);
}

async function markRead(p: Principal, ids: string[] | null, cid: string) {
  let s = db.from('ntf_notifications').update({ read_at: new Date().toISOString() })
    .eq('tenant_id', p.tenantId).eq('user_id', p.userId!).is('read_at', null);
  if (ids) {
    if (!ids.every((x) => typeof x === 'string' && UUID_RE.test(x))) throw new ApiError(422, 'invalid_request', 'ids must be UUIDs');
    s = s.in('id', ids);
  }
  const rows = await q(s.select('id'));
  return json({ ok: true, updated: rows.length }, 200, cid);
}

// ---------------------------------------------------------------- devices and preferences

const CHANNELS = ['IN_APP', 'PUSH', 'SMS', 'WHATSAPP'];

async function registerDevice(p: Principal, b: Body, cid: string) {
  const token = requireString(b.token, 'token', 4096);
  const installationId = requireString(b.installationId, 'installationId', 200);
  const platform = b.platform ?? null;
  if (platform !== null && !['android', 'ios', 'web'].includes(platform)) throw new ApiError(422, 'invalid_request', 'platform must be android, ios or web');
  const now = new Date().toISOString();
  // A token moves with its installation; one installation belongs to one user per tenant.
  await q(db.from('ntf_device_tokens').update({ active: false, updated_at: now }).eq('tenant_id', p.tenantId).eq('token', token).neq('installation_id', installationId));
  await q(db.from('ntf_device_tokens').upsert({
    tenant_id: p.tenantId, user_id: p.userId, token, installation_id: installationId, platform,
    app_version: typeof b.appVersion === 'string' ? b.appVersion.slice(0, 50) : null, active: true, updated_at: now
  }, { onConflict: 'tenant_id,installation_id' }));
  // OS permission granted on the device counts as push consent, if the tenant has the PUSH channel.
  const ch = await q(db.from('ntf_channels').select('channel').eq('tenant_id', p.tenantId).eq('channel', 'PUSH').maybeSingle());
  if (ch) {
    await q(db.from('ntf_preferences').upsert({ tenant_id: p.tenantId, user_id: p.userId, channel: 'PUSH', enabled: true, consent_at: now, updated_at: now },
      { onConflict: 'tenant_id,user_id,channel' }));
  }
  return json({ ok: true }, 200, cid);
}

async function unregisterDevice(p: Principal, b: Body, cid: string) {
  const installationId = requireString(b.installationId, 'installationId', 200);
  const rows = await q(db.from('ntf_device_tokens').update({ active: false, updated_at: new Date().toISOString() })
    .eq('tenant_id', p.tenantId).eq('user_id', p.userId!).eq('installation_id', installationId).select('id'));
  return json({ ok: true, updated: rows.length }, 200, cid);
}

async function getPreferences(p: Principal, cid: string) {
  const channels = await q(db.from('ntf_channels').select('channel,enabled').eq('tenant_id', p.tenantId));
  const prefs = await q(db.from('ntf_preferences').select('channel,enabled,consent_at,locale').eq('tenant_id', p.tenantId).eq('user_id', p.userId!));
  const byChannel = new Map(prefs.map((x: Body) => [x.channel, x]));
  return json({
    items: channels.filter((c: Body) => c.enabled).map((c: Body) => {
      const x = byChannel.get(c.channel) as Body | undefined;
      return { channel: c.channel, enabled: x?.enabled ?? true, consent: c.channel === 'IN_APP' ? true : !!x?.consent_at, consentAt: x?.consent_at ?? null };
    })
  }, 200, cid);
}

async function setPreferences(p: Principal, b: Body, cid: string) {
  const items = requireArray(b.items, 'items', 10) as Body[];
  const enabledChannels = new Set((await q(db.from('ntf_channels').select('channel').eq('tenant_id', p.tenantId).eq('enabled', true))).map((c: Body) => c.channel));
  const now = new Date().toISOString();
  for (const it of items) {
    const channel = String(it.channel ?? '').toUpperCase();
    if (!CHANNELS.includes(channel)) throw new ApiError(422, 'invalid_request', 'Unknown channel');
    if (!enabledChannels.has(channel)) throw new ApiError(422, 'channel_disabled', `${channel} is not enabled for this organization`);
    const row: Body = { tenant_id: p.tenantId, user_id: p.userId, channel, enabled: it.enabled !== false, updated_at: now };
    if (typeof it.consent === 'boolean') row.consent_at = it.consent ? now : null;
    await q(db.from('ntf_preferences').upsert(row, { onConflict: 'tenant_id,user_id,channel' }));
  }
  await audit({ tenantId: p.tenantId, productId: p.productId, actor: p.actor, action: 'preferences.update', details: { channels: items.map((i) => i.channel) }, correlationId: cid });
  return await getPreferences(p, cid);
}

const SECRETISH = /token|secret|password|private|key|auth/i;

function validateProviderConfig(channel: string, cfg: unknown): Body | undefined {
  if (cfg === undefined) return undefined;
  if (!cfg || typeof cfg !== 'object' || Array.isArray(cfg) || JSON.stringify(cfg).length > 4096) {
    throw new ApiError(422, 'invalid_request', 'provider_config must be a small JSON object');
  }
  const c = cfg as Body;
  const provider = String(c.provider ?? 'mock').toLowerCase();
  if (!PROVIDERS[channel as keyof typeof PROVIDERS]?.includes(provider)) throw new ApiError(422, 'invalid_request', `Unsupported provider ${provider} for ${channel}`);
  for (const k of Object.keys(c)) {
    if (k !== 'secret_name' && SECRETISH.test(k)) throw new ApiError(422, 'invalid_request', `Put credentials in Vault and reference them with secret_name, not ${k}`);
  }
  return { ...c, provider };
}

// ---------------------------------------------------------------- admin APIs

const ADMIN_TABLES: Record<string, string> = {
  events: 'ntf_events', roles: 'ntf_roles', rules: 'ntf_rules', channels: 'ntf_channels',
  overrides: 'ntf_overrides', deliveries: 'ntf_deliveries', audit: 'ntf_audit_logs',
  'rule-channels': 'ntf_rule_channels', attempts: 'ntf_delivery_attempts'
};

async function allowedTemplateIds(p: Principal): Promise<string[]> {
  const rows = await q(db.from('ntf_templates').select('id').or(`product_id.is.null,product_id.eq.${p.productId}`));
  return rows.map((r: { id: string }) => r.id);
}

async function assertTemplateAllowed(p: Principal, templateId: unknown) {
  if (typeof templateId !== 'string' || !UUID_RE.test(templateId)) throw new ApiError(422, 'invalid_request', 'template_id must be a UUID');
  if (!(await allowedTemplateIds(p)).includes(templateId)) throw new ApiError(404, 'not_found', 'Template not found');
}

async function admin(p: Principal, req: Request, path: string, b: Body, cid: string) {
  if (!p.isAdmin) forbid('Admin access required');
  const resource = path.split('/')[3];
  const auditWrite = (action: string, details: Record<string, unknown>) =>
    audit({ tenantId: p.tenantId, productId: p.productId, actor: p.actor, action, details, correlationId: cid });

  if (path === '/v1/admin/templates/preview' && req.method === 'POST') {
    try {
      return json({ title: render(b.title ?? '', b.context ?? {}), body: render(b.body ?? '', b.context ?? {}) }, 200, cid);
    } catch (e) {
      throw new ApiError(422, 'template_error', String((e as Error).message));
    }
  }
  if (path.split('/').length !== 4) throw new ApiError(404, 'not_found', 'Unknown admin resource');

  if (req.method === 'GET') {
    if (resource === 'templates') {
      const ids = await allowedTemplateIds(p);
      const rows = ids.length ? await q(
        db.from('ntf_template_versions').select('*,template:ntf_templates(code,name,product_id)').in('template_id', ids).limit(200)
      ) : [];
      return json(rows, 200, cid);
    }
    const table = ADMIN_TABLES[resource];
    if (!table) throw new ApiError(404, 'not_found', 'Unknown admin resource');
    let s = db.from(table).select('*');
    s = resource === 'events' ? s.eq('product_id', p.productId) : s.eq('tenant_id', p.tenantId);
    if (['audit', 'attempts', 'deliveries'].includes(resource)) s = s.order('created_at', { ascending: false });
    return json(await q(s.limit(100)), 200, cid);
  }

  if (req.method !== 'POST') throw new ApiError(405, 'method_not_allowed', 'Method not allowed');

  if (resource === 'channels') {
    const channel = String(b.channel ?? '').toUpperCase();
    if (!['IN_APP', 'PUSH', 'SMS', 'WHATSAPP'].includes(channel)) throw new ApiError(422, 'invalid_request', 'Unknown channel');
    const row: Body = { tenant_id: p.tenantId, channel, enabled: b.enabled === true };
    const cfg = validateProviderConfig(channel, b.provider_config);
    if (cfg) row.provider_config = cfg;
    await q(db.from('ntf_channels').upsert(row));
    await auditWrite('channel.save', { channel, enabled: row.enabled, provider: cfg?.provider, secret_name: cfg?.secret_name });
    return json({ ok: true }, 200, cid);
  }

  if (resource === 'rules') {
    const row = {
      tenant_id: p.tenantId, product_id: p.productId, event_code: requireString(b.event_code, 'event_code', 100),
      event_version: b.event_version ?? 1, active: b.active === true, conditions: b.conditions ?? {},
      recipient_strategy: requireString(b.recipient_strategy, 'recipient_strategy', 100), role_code: b.role_code ?? null,
      priority: Number.isInteger(b.priority) ? b.priority : 0, purpose: requireString(b.purpose, 'purpose', 100)
    };
    const saved = await q(db.from('ntf_rules').insert(row).select().single());
    await auditWrite('rule.create', { id: saved.id, event_code: row.event_code, active: row.active });
    return json(saved, 201, cid);
  }

  if (resource === 'rule-channels') {
    await assertTemplateAllowed(p, b.template_id);
    const rule = await q(db.from('ntf_rules').select('id').eq('id', b.rule_id).eq('tenant_id', p.tenantId).maybeSingle());
    if (!rule) throw new ApiError(404, 'not_found', 'Rule not found');
    const row = {
      rule_id: rule.id, tenant_id: p.tenantId, channel: String(b.channel ?? '').toUpperCase(), template_id: b.template_id,
      template_version: b.template_version, locale: b.locale ?? 'en', mappings: b.mappings ?? {}
    };
    const saved = await q(db.from('ntf_rule_channels').upsert(row).select().single());
    await auditWrite('rule_channel.save', { rule_id: rule.id, channel: row.channel, template_id: row.template_id });
    return json(saved, 200, cid);
  }

  if (resource === 'overrides') {
    await assertTemplateAllowed(p, b.template_id);
    const saved = await q(db.from('ntf_overrides').insert({
      tenant_id: p.tenantId, template_id: b.template_id, base_version: b.base_version, channel: b.channel,
      locale: b.locale ?? 'en', version: b.version, patch: b.patch, status: 'PUBLISHED'
    }).select().single());
    await auditWrite('override.publish', { id: saved.id, template_id: b.template_id, channel: b.channel });
    return json(saved, 201, cid);
  }

  throw new ApiError(405, 'method_not_allowed', 'This resource is read-only');
}

// ---------------------------------------------------------------- router

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders });
  const cid = req.headers.get('x-correlation-id')?.slice(0, 100) || crypto.randomUUID();
  const url = new URL(req.url);
  const path = normalizePath(req.url);
  try {
    if (path === '/v1/health' && req.method === 'GET') return json({ status: 'ok', version: VERSION }, 200, cid);

    const b = await readBody(req);

    if (path === '/v1/worker') {
      if (req.method !== 'POST') throw new ApiError(405, 'method_not_allowed', 'Method not allowed');
      const token = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '').trim();
      const expected = Deno.env.get('WORKER_TOKEN');
      if (!token) throw new ApiError(401, 'unauthorized', 'Missing bearer token');
      if (!expected || !safeEqual(token, expected)) throw new ApiError(403, 'forbidden', 'Worker credential required');
      const stats = await runWorker(Number(Deno.env.get('WORKER_BUDGET_MS') ?? 45000));
      // `processed` kept for 0.1.x callers (number of events expanded in this run).
      return json({ processed: stats.events.processed, ...stats }, 200, cid);
    }
    if (path === '/v1/tenants/provision' && req.method === 'POST') return await provisionTenant(req, b, cid);

    const p = await authenticate(req);
    console.log('NTF Request:', JSON.stringify({ path, method: req.method, scope: p.scope, via: p.via, tenantId: p.tenantId, cid }));

    if (req.method === 'POST') {
      if (path === '/v1/events/publish') return await publishEvent(p, b, cid);
      if (path === '/v1/auth/exchange') return await exchangeToken(p, b, cid);
      if (path === '/v1/users/sync') return await syncUsers(p, b, cid);
      if (path === '/v1/roles/sync') return await syncRoles(p, b, cid);
    }

    if (path.startsWith('/v1/notifications')) {
      if (!isEndUser(p)) forbid('A user credential is required');
      if (path === '/v1/notifications' && req.method === 'GET') return await inbox(p, url, cid);
      if (path === '/v1/notifications/unread-count' && req.method === 'GET') return await unreadCount(p, cid);
      if (path === '/v1/notifications/mark-read' && req.method === 'POST') {
        return await markRead(p, b.all === true ? null : (requireArray(b.ids, 'ids', 500) as string[]), cid);
      }
      const m = path.match(/^\/v1\/notifications\/([\w-]+)\/read$/);
      if (m && req.method === 'POST') {
        if (!UUID_RE.test(m[1])) throw new ApiError(404, 'not_found', 'Notification not found');
        const n = await q(db.from('ntf_notifications').select('id').eq('tenant_id', p.tenantId).eq('user_id', p.userId!).eq('id', m[1]).maybeSingle());
        if (!n) throw new ApiError(404, 'not_found', 'Notification not found');
        await markRead(p, [m[1]], cid);
        return json({ ok: true }, 200, cid);
      }
    }

    if (path.startsWith('/v1/devices/') || path === '/v1/preferences') {
      if (!isEndUser(p)) forbid('A user credential is required');
      if (path === '/v1/devices/register' && req.method === 'POST') return await registerDevice(p, b, cid);
      if (path === '/v1/devices/unregister' && req.method === 'POST') return await unregisterDevice(p, b, cid);
      if (path === '/v1/preferences' && req.method === 'GET') return await getPreferences(p, cid);
      if (path === '/v1/preferences' && req.method === 'POST') return await setPreferences(p, b, cid);
    }

    if (path.startsWith('/v1/admin/')) return await admin(p, req, path, b, cid);

    throw new ApiError(404, 'not_found', 'Route not found');
  } catch (e) {
    const err = toApiError(e);
    if (err.status >= 500) console.error('NTF Request Error:', JSON.stringify({ path, cid, error: String(e) }));
    else console.warn('NTF Request Rejected:', JSON.stringify({ path, cid, status: err.status, code: err.code }));
    return errorResponse(err, cid);
  }
});
