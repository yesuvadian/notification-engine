// Notification engine Edge Function: single entry point, routes under /v1.
import Ajv from 'npm:ajv@8';
import { merge, render } from './parser.mjs';
import { audit, db, q } from './db.ts';
import { authenticate, isEndUser, isServer, Principal } from './auth.ts';
import {
  ApiError, corsHeaders, decodeCursor, encodeCursor, errorResponse, json, normalizePath, randomToken,
  requireArray, requireString, safeEqual, sha256Hex, toApiError, UUID_RE
} from './http.ts';
import { runWorker } from './worker.ts';
import { platform } from './platform.ts';
import { adapterFor } from './adapters/index.ts';
import { Channel } from './adapters/types.ts';
import { eventVariables, jsonEqual, VARIABLE_NAME_RE, VARIABLE_TYPES, VariableDef, variableIssues } from './logic.ts';

const VERSION = '0.2.0';
const MAX_BODY_BYTES = 256 * 1024;
// deno-lint-ignore no-explicit-any
const ajv = new (Ajv as any)({ strict: false, allErrors: true });

// deno-lint-ignore no-explicit-any
type Body = Record<string, any>;

async function readBody(req: Request): Promise<Body> {
  if (req.method !== 'POST' && req.method !== 'PUT') return {};
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

async function syncMetadata(p: Principal, b: Body, cid: string) {
  if (!isServer(p)) forbid();
  const events = requireArray(b.events, 'events', 200) as Body[];
  const vars = await productVariables(p.productId);
  const declared = await declareVariables(p, b.variables, vars);
  // Every event field must match the product's variables before anything is written.
  const newFields = new Map<string, string>();
  for (const ev of events) {
    const code = String(ev?.code ?? '');
    // A contract the engine already holds is not re-checked, so products syncing it again keep working.
    const same = await q(db.from('ntf_events').select('payload_schema').eq('product_id', p.productId).eq('code', code)
      .eq('version', Number.isInteger(ev?.version) ? ev.version : 1).maybeSingle());
    if (same && jsonEqual(same.payload_schema, ev?.payloadSchema)) continue;
    const { mismatched, invalid, unknown } = variableIssues(ev?.payloadSchema, vars);
    if (invalid.length) throw new ApiError(422, 'invalid_variable', `${code}: ${invalid.join(', ')} cannot be variables (letters, digits and _ only, a JSON type)`);
    if (mismatched.length) {
      throw new ApiError(422, 'variable_mismatch', `${code}: ` + mismatched.map((x) => `data.${x.name} is ${x.type} but the product variable is ${x.expected}`).join('; '));
    }
    for (const u of unknown) {
      const seen = newFields.get(u.name);
      if (seen && seen !== u.type) throw new ApiError(422, 'variable_mismatch', `data.${u.name} is ${seen} in one event and ${u.type} in another`);
      newFields.set(u.name, u.type);
    }
  }
  const TRIGGERS = ['WORKFLOW_TRANSITION', 'STATUS_CHANGE', 'ACTION', 'RECORD_CREATED', 'RECORD_UPDATED', 'ASSIGNMENT', 'SCHEDULED', 'MANUAL', 'SYSTEM_EVENT'];
  let created = 0, unchanged = 0;
  for (const ev of events) {
    const code = requireString(ev.code, 'events[].code', 100);
    const version = ev.version ?? 1;
    if (!Number.isInteger(version) || version < 1) throw new ApiError(422, 'invalid_request', `${code}: version must be a positive integer`);
    if (!TRIGGERS.includes(ev.triggerType)) throw new ApiError(422, 'invalid_request', `${code}: unknown triggerType`);
    if (!ev.payloadSchema || typeof ev.payloadSchema !== 'object') throw new ApiError(422, 'invalid_request', `${code}: payloadSchema required`);
    try {
      ajv.compile(ev.payloadSchema);
    } catch {
      throw new ApiError(422, 'invalid_request', `${code}: payloadSchema is not a valid JSON schema`);
    }
    const row = {
      product_id: p.productId, code, version, module_code: requireString(ev.moduleCode, 'events[].moduleCode', 100),
      trigger_type: ev.triggerType, payload_schema: ev.payloadSchema, metadata: ev.metadata ?? {}
    };
    const existing = await q(db.from('ntf_events').select('*').eq('product_id', p.productId).eq('code', code).eq('version', version).maybeSingle());
    if (existing) {
      const same = existing.module_code === row.module_code && existing.trigger_type === row.trigger_type &&
        jsonEqual(existing.payload_schema, row.payload_schema);
      if (!same) throw new ApiError(409, 'version_conflict', `${code} v${version} already exists with a different contract; publish a new version`);
      if (!jsonEqual(existing.metadata, row.metadata)) {
        await q(db.from('ntf_events').update({ metadata: row.metadata }).eq('product_id', p.productId).eq('code', code).eq('version', version));
      }
      unchanged++;
    } else {
      await q(db.from('ntf_events').insert(row));
      created++;
    }
  }
  if (newFields.size) {
    await q(db.from('ntf_variables').insert([...newFields].map(([name, type]) => ({ product_id: p.productId, name, type, source: 'product' }))));
  }
  const added = [...declared, ...newFields.keys()];
  await audit({ tenantId: p.tenantId, productId: p.productId, actor: p.actor, action: 'metadata.sync', details: { created, unchanged, variablesAdded: added }, correlationId: cid });
  return json({ created, unchanged, variablesAdded: added }, 200, cid);
}

async function productVariables(productId: string): Promise<VariableDef[]> {
  return await q(db.from('ntf_variables').select('name,type,description,example,source').eq('product_id', productId));
}

/** Optional `variables` in a metadata sync: the product declares its own fields. A name it already has keeps its type. */
async function declareVariables(p: Principal, input: unknown, vars: VariableDef[]): Promise<string[]> {
  if (input == null) return [];
  const list = requireArray(input, 'variables', 200) as Body[];
  const added: string[] = [];
  for (const v of list) {
    const name = requireString(v?.name, 'variables[].name', 50);
    const type = String(v?.type ?? 'string');
    if (!VARIABLE_NAME_RE.test(name)) throw new ApiError(422, 'invalid_variable', `${name}: letters, digits and _ only`);
    if (!VARIABLE_TYPES.includes(type)) throw new ApiError(422, 'invalid_variable', `${name}: type must be one of ${VARIABLE_TYPES.join(', ')}`);
    const description = typeof v.description === 'string' ? v.description.slice(0, 500) : null;
    const example = typeof v.example === 'string' ? v.example.slice(0, 200) : null;
    const have = vars.find((x) => x.name === name);
    if (have) {
      if (have.type !== type) throw new ApiError(422, 'variable_mismatch', `${name} is ${have.type} for this product; it cannot become ${type}`);
      if (have.source === 'product' && (description !== (have.description ?? null) || example !== (have.example ?? null))) {
        await q(db.from('ntf_variables').update({ description, example, updated_at: new Date().toISOString() }).eq('product_id', p.productId).eq('name', name));
        Object.assign(have, { description, example });
      }
      continue;
    }
    await q(db.from('ntf_variables').insert({ product_id: p.productId, name, type, description, example, source: 'product' }));
    vars.push({ name, type, description, example, source: 'product' });
    added.push(name);
  }
  return added;
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

// ---------------------------------------------------------------- organization settings (spec §50)

const DEFAULT_ORG_SETTINGS = { inbox_retention_days: null, unread_badge: true, group_by_day: true, push_prompt: 'after_first_notification', push_explanation: null, members_can_change: true };

/** Settings provisioned by the super admin; null for organizations created before §50 (unmanaged). */
async function orgSettings(tenantId: string): Promise<Body | null> {
  return await q(db.from('ntf_org_settings').select('*').eq('tenant_id', tenantId).maybeSingle());
}

function retentionCutoff(s: Body | null): string | null {
  return s?.inbox_retention_days ? new Date(Date.now() - s.inbox_retention_days * 86400000).toISOString() : null;
}

async function memberSettings(p: Principal, cid: string) {
  const s = await orgSettings(p.tenantId);
  const push = await q(db.from('ntf_channels').select('enabled').eq('tenant_id', p.tenantId).eq('channel', 'PUSH').maybeSingle());
  const v = s ?? DEFAULT_ORG_SETTINGS;
  return json({
    managed: !!s, preferencesLocked: !!s && !s.members_can_change,
    inbox: { retentionDays: v.inbox_retention_days, unreadBadge: v.unread_badge, groupByDay: v.group_by_day },
    push: { enabled: push?.enabled === true, prompt: push?.enabled ? v.push_prompt : 'off', explanation: v.push_explanation }
  }, 200, cid);
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
  const cutoff = retentionCutoff(await orgSettings(p.tenantId));
  if (cutoff) s = s.gte('created_at', cutoff);
  const rows = await q(s.order('created_at', { ascending: false }).order('id', { ascending: false }).limit(limit + 1));
  const items = rows.slice(0, limit);
  const last = items[items.length - 1];
  return json({ items, nextCursor: rows.length > limit && last ? encodeCursor(last.created_at, last.id) : null }, 200, cid);
}

async function unreadCount(p: Principal, cid: string) {
  let s = db.from('ntf_notifications')
    .select('id,deliveries:ntf_deliveries!inner(channel)', { count: 'exact', head: true })
    .eq('tenant_id', p.tenantId).eq('user_id', p.userId!).eq('deliveries.channel', 'IN_APP').is('read_at', null);
  const cutoff = retentionCutoff(await orgSettings(p.tenantId));
  if (cutoff) s = s.gte('created_at', cutoff);
  const { count, error } = await s;
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
  const settings = await orgSettings(p.tenantId);
  const locked = !!settings && !settings.members_can_change;
  const channels = await q(db.from('ntf_channels').select('channel,enabled').eq('tenant_id', p.tenantId));
  const prefs = await q(db.from('ntf_preferences').select('channel,enabled,consent_at,locale').eq('tenant_id', p.tenantId).eq('user_id', p.userId!));
  const byChannel = new Map(prefs.map((x: Body) => [x.channel, x]));
  return json({
    items: channels.filter((c: Body) => c.enabled).map((c: Body) => {
      const x = byChannel.get(c.channel) as Body | undefined;
      return {
        channel: c.channel, enabled: locked ? true : (x?.enabled ?? true), consent: c.channel === 'IN_APP' ? true : !!x?.consent_at,
        consentAt: x?.consent_at ?? null, locked: locked || c.channel === 'IN_APP'
      };
    }),
    locked
  }, 200, cid);
}

async function setPreferences(p: Principal, b: Body, cid: string) {
  const items = requireArray(b.items, 'items', 10) as Body[];
  const enabledChannels = new Set((await q(db.from('ntf_channels').select('channel').eq('tenant_id', p.tenantId).eq('enabled', true))).map((c: Body) => c.channel));
  const now = new Date().toISOString();
  const settings = await orgSettings(p.tenantId);
  const locked = !!settings && !settings.members_can_change;
  for (const it of items) {
    const channel = String(it.channel ?? '').toUpperCase();
    if (!CHANNELS.includes(channel)) throw new ApiError(422, 'invalid_request', 'Unknown channel');
    if (!enabledChannels.has(channel)) throw new ApiError(422, 'channel_disabled', `${channel} is not enabled for this organization`);
    // Managed organizations: channels are set by the super admin; members can only give or withdraw consent.
    if (locked && it.enabled === false) throw new ApiError(403, 'preferences_locked', 'Channels are set by your organization');
    const row: Body = { tenant_id: p.tenantId, user_id: p.userId, channel, enabled: locked ? true : it.enabled !== false, updated_at: now };
    if (typeof it.consent === 'boolean') row.consent_at = it.consent ? now : null;
    await q(db.from('ntf_preferences').upsert(row, { onConflict: 'tenant_id,user_id,channel' }));
  }
  await audit({ tenantId: p.tenantId, productId: p.productId, actor: p.actor, action: 'preferences.update', details: { channels: items.map((i) => i.channel) }, correlationId: cid });
  return await getPreferences(p, cid);
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

// deno-lint-ignore no-explicit-any
type AuditFn = (action: string, details: Record<string, unknown>) => Promise<any>;

async function adminItem(p: Principal, req: Request, seg: string[], b: Body, cid: string, auditWrite: AuditFn) {
  const [resource, id, action] = seg;
  const m = req.method;

  // Rules: PUT /rules/{id}, DELETE /rules/{id}
  if (resource === 'rules' && !action && (m === 'PUT' || m === 'DELETE')) {
    const rule = await q(db.from('ntf_rules').select('*').eq('id', id).eq('tenant_id', p.tenantId).maybeSingle());
    if (!rule) throw new ApiError(404, 'not_found', 'Rule not found');
    if (m === 'DELETE') {
      await q(db.from('ntf_rule_channels').delete().eq('rule_id', id).eq('tenant_id', p.tenantId));
      await q(db.from('ntf_rules').delete().eq('id', id).eq('tenant_id', p.tenantId));
      await auditWrite('rule.delete', { id, event_code: rule.event_code });
      return json({ ok: true }, 200, cid);
    }
    const patch: Body = {};
    for (const k of ['active', 'conditions', 'recipient_strategy', 'role_code', 'priority', 'purpose', 'schedule_config']) if (k in b) patch[k] = b[k];
    if ('active' in patch && typeof patch.active !== 'boolean') throw new ApiError(422, 'invalid_request', 'active must be boolean');
    // Moving a rule to a newer event version keeps its channels, pinned templates and overrides.
    if ('event_version' in b) {
      if (!Number.isInteger(b.event_version) || b.event_version < 1) throw new ApiError(422, 'invalid_request', 'event_version must be a positive integer');
      const ev = await q(db.from('ntf_events').select('code').eq('product_id', p.productId).eq('code', rule.event_code).eq('version', b.event_version).maybeSingle());
      if (!ev) throw new ApiError(422, 'invalid_request', `${rule.event_code} v${b.event_version} is not registered`);
      patch.event_version = b.event_version;
    }
    const saved = await q(db.from('ntf_rules').update(patch).eq('id', id).eq('tenant_id', p.tenantId).select().single());
    await auditWrite('rule.update', { id, fields: Object.keys(patch) });
    return json(saved, 200, cid);
  }

  // Rule channels: DELETE /rule-channels/{ruleId}?channel=SMS  (or /rule-channels/{ruleId}/{channel})
  if (resource === 'rule-channels' && m === 'DELETE') {
    const channel = String(action ?? new URL(req.url).searchParams.get('channel') ?? '').toUpperCase();
    const rows = await q(db.from('ntf_rule_channels').delete().eq('rule_id', id).eq('tenant_id', p.tenantId).eq('channel', channel).select('rule_id'));
    if (!rows.length) throw new ApiError(404, 'not_found', 'Rule channel not found');
    await auditWrite('rule_channel.delete', { rule_id: id, channel });
    return json({ ok: true }, 200, cid);
  }

  // Overrides: DELETE /overrides/{id} = reset to master (retired, history kept)
  if (resource === 'overrides' && !action && m === 'DELETE') {
    const rows = await q(db.from('ntf_overrides').update({ status: 'RETIRED' }).eq('id', id).eq('tenant_id', p.tenantId).eq('status', 'PUBLISHED').select('id,template_id,channel'));
    if (!rows.length) throw new ApiError(404, 'not_found', 'No published override with this id');
    await auditWrite('override.reset', { id, template_id: rows[0].template_id, channel: rows[0].channel });
    return json({ ok: true }, 200, cid);
  }

  // Templates: GET /templates/{templateId}/effective?channel=&locale=&version=
  if (resource === 'templates' && action === 'effective' && m === 'GET') {
    await assertTemplateAllowed(p, id);
    const u = new URL(req.url);
    const channel = (u.searchParams.get('channel') ?? 'IN_APP').toUpperCase(), locale = u.searchParams.get('locale') ?? 'en';
    let s = db.from('ntf_template_versions').select('*').eq('template_id', id).eq('channel', channel).eq('locale', locale).eq('status', 'PUBLISHED');
    if (u.searchParams.get('version')) s = s.eq('version', Number(u.searchParams.get('version')));
    const versions = await q(s.order('version', { ascending: false }).limit(1));
    if (!versions.length) throw new ApiError(404, 'not_found', 'No published master version for this channel/locale');
    const master = versions[0];
    const override = await q(db.from('ntf_overrides').select('*').eq('tenant_id', p.tenantId).eq('template_id', id).eq('channel', channel)
      .eq('locale', locale).eq('base_version', master.version).eq('status', 'PUBLISHED').maybeSingle());
    return json({ master, override, effective: merge(master.content, override?.patch), source: override ? 'OVERRIDE' : 'MASTER' }, 200, cid);
  }

  // Templates: POST /templates/{templateId}/upgrade {version?} = move this organization to a newer platform version
  if (resource === 'templates' && action === 'upgrade' && m === 'POST') {
    await assertTemplateAllowed(p, id);
    if (b.version !== undefined && !(Number.isInteger(b.version) && b.version > 0)) throw new ApiError(422, 'invalid_request', 'version must be a positive integer');
    const r = await q(db.rpc('ntf_upgrade_org_template', { p_tenant: p.tenantId, p_template: id, p_to_version: b.version ?? null }));
    await auditWrite('template.upgrade', { template_id: id, ...r });
    return json(r, 200, cid);
  }

  // Events: GET /events/{code}/variables?version=
  if (resource === 'events' && action === 'variables' && m === 'GET') {
    const version = Number(new URL(req.url).searchParams.get('version') ?? 1);
    const ev = await q(db.from('ntf_events').select('payload_schema,metadata').eq('product_id', p.productId).eq('code', id).eq('version', version).maybeSingle());
    if (!ev) throw new ApiError(404, 'not_found', 'Event not found');
    return json({ variables: eventVariables(ev.payload_schema, await productVariables(p.productId)) }, 200, cid);
  }

  // Deliveries: GET /deliveries/{id}/attempts, POST /deliveries/{id}/retry
  if (resource === 'deliveries' && action === 'attempts' && m === 'GET') {
    return json(await q(db.from('ntf_delivery_attempts').select('*').eq('delivery_id', id).eq('tenant_id', p.tenantId).order('attempt')), 200, cid);
  }
  if (resource === 'deliveries' && action === 'retry' && m === 'POST') {
    const r = await q(db.rpc('ntf_requeue_delivery', { p_delivery: id, p_tenant: p.tenantId }));
    if (!r) throw new ApiError(409, 'not_retryable', 'Only FAILED or DEAD_LETTERED external deliveries can be retried');
    await auditWrite('delivery.retry', { id });
    return json({ ok: true }, 200, cid);
  }

  // Channels: POST /channels/{channel}/test  {userId} or {phone}, optional title/body
  if (resource === 'channels' && action === 'test' && m === 'POST') {
    const channel = id.toUpperCase() as Channel;
    if (!['SMS', 'WHATSAPP', 'PUSH'].includes(channel)) throw new ApiError(422, 'invalid_request', 'Test send supports SMS, WHATSAPP and PUSH');
    const since = new Date(Date.now() - 10 * 60000).toISOString();
    const { count } = await db.from('ntf_audit_logs').select('id', { count: 'exact', head: true })
      .eq('tenant_id', p.tenantId).eq('action', 'channel.test').gt('created_at', since);
    if ((count ?? 0) >= 10) throw new ApiError(429, 'rate_limited', 'At most 10 test sends per 10 minutes');
    let recipient = { userId: 'test', displayName: 'Test', phone: null as string | null, email: null, locale: null, deviceTokens: [] as { id: string; token: string }[] };
    if (b.userId) {
      const u = await q(db.from('ntf_users').select('*').eq('tenant_id', p.tenantId).eq('user_id', b.userId).maybeSingle());
      if (!u) throw new ApiError(404, 'not_found', 'User not synced');
      const tokens = channel === 'PUSH' ? await q(db.from('ntf_device_tokens').select('id,token').eq('tenant_id', p.tenantId).eq('user_id', u.user_id).eq('active', true).limit(5)) : [];
      recipient = { userId: u.user_id, displayName: u.display_name, phone: u.phone, email: null, locale: u.locale, deviceTokens: tokens };
    } else if (typeof b.phone === 'string' && /^\+[1-9]\d{6,14}$/.test(b.phone)) {
      recipient.phone = b.phone;
    } else throw new ApiError(422, 'invalid_request', 'Give userId (synced user) or an E.164 phone');
    const config = (await q(db.rpc('ntf_effective_channel_config', { p_tenant: p.tenantId, p_channel: channel }))) ?? {};
    const adapter = adapterFor(channel, config);
    const secret = adapter.provider === 'mock' ? {} : ((await q(db.rpc('ntf_get_provider_secret', { p_tenant: p.tenantId, p_channel: channel }))) ?? {});
    const payload = { title: 'Test notification', body: 'Test message from the notification engine', ...(b.payload && typeof b.payload === 'object' ? b.payload : {}) };
    const r = await adapter.send({ deliveryId: `test-${crypto.randomUUID()}`, tenantId: p.tenantId, channel, payload, recipient, config, secret });
    await auditWrite('channel.test', { channel, provider: adapter.provider, outcome: r.outcome, userId: b.userId ?? null });
    return json({ provider: adapter.provider, configSource: config._source ?? (config.provider ? 'organization' : 'none'), ...r }, 200, cid);
  }

  throw new ApiError(404, 'not_found', 'Unknown admin resource');
}

async function orgAdminWritesAllowed(): Promise<boolean> {
  const s = await q(db.from('ntf_platform_settings').select('value').eq('key', 'org_admin_writes').maybeSingle());
  return s?.value === true;
}

async function admin(p: Principal, req: Request, path: string, b: Body, cid: string) {
  if (!p.isAdmin) forbid('Admin access required');
  if (p.isPlatform && !p.tenantId) throw new ApiError(400, 'organization_required', 'Send X-Product-Code and X-Organization-Id to manage an organization');
  // Phase 1 of §50: the platform super admin manages organizations; organization admins are read-only.
  if (!p.isPlatform && req.method !== 'GET' && path !== '/v1/admin/templates/preview' && !(await orgAdminWritesAllowed())) {
    throw new ApiError(403, 'org_admin_read_only', 'Organization settings are managed by the platform super admin');
  }
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
  // ---- sub-resources: /v1/admin/<resource>/<id>[/<action>]
  const seg = path.split('/').slice(3); // [resource, id, action?]
  if (seg.length >= 2) return await adminItem(p, req, seg, b, cid, auditWrite);
  if (path.split('/').length !== 4) throw new ApiError(404, 'not_found', 'Unknown admin resource');

  if (resource === 'org-preferences') {
    if (req.method === 'POST') {
      const items = requireArray(b.items, 'items', 50);
      const added = await q(db.rpc('ntf_add_org_preferences', { p_tenant: p.tenantId, p_items: items, p_actor: p.actor }));
      await auditWrite('org_preferences.add', { items, added });
    } else if (req.method !== 'GET') throw new ApiError(405, 'method_not_allowed', 'Organization preferences are add-only');
    const rows = await q(db.from('ntf_org_preferences').select('group_code,channel,source,created_at').eq('tenant_id', p.tenantId).order('group_code'));
    const events = await q(db.from('ntf_events').select('module_code').eq('product_id', p.productId));
    const channels = await q(db.from('ntf_channels').select('channel').eq('tenant_id', p.tenantId).eq('enabled', true));
    const groups = [...new Set([...events.map((e: Body) => String(e.module_code).toUpperCase()), ...rows.map((r: Body) => r.group_code)])].sort();
    return json({
      groups: groups.map((g) => ({ group: g, channels: rows.filter((r: Body) => r.group_code === g).map((r: Body) => ({ channel: r.channel, source: r.source, createdAt: r.created_at })) })),
      enabledChannels: channels.map((c: Body) => c.channel).sort()
    }, 200, cid);
  }

  if (resource === 'org-settings') {
    if (req.method === 'PUT') {
      const patch: Body = {};
      for (const k of ['inbox_retention_days', 'unread_badge', 'group_by_day', 'push_prompt', 'push_explanation', 'members_can_change']) if (k in b) patch[k] = b[k];
      const cur = await orgSettings(p.tenantId);
      if (!cur) await q(db.from('ntf_org_settings').insert({ tenant_id: p.tenantId, ...patch }));
      else await q(db.from('ntf_org_settings').update(patch).eq('tenant_id', p.tenantId));
      await auditWrite('org_settings.update', { fields: Object.keys(patch) });
    } else if (req.method !== 'GET') throw new ApiError(405, 'method_not_allowed', 'Method not allowed');
    const s = await orgSettings(p.tenantId);
    return json({ managed: !!s, settings: s ?? DEFAULT_ORG_SETTINGS }, 200, cid);
  }

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
    const qp = new URL(req.url).searchParams;
    if (resource === 'deliveries') {
      s = db.from('ntf_deliveries').select('*,notification:ntf_notifications!inner(user_id,title,event_id,created_at)').eq('tenant_id', p.tenantId).order('created_at', { ascending: false });
      if (qp.get('status')) s = s.eq('status', qp.get('status')!.toUpperCase());
      if (qp.get('channel')) s = s.eq('channel', qp.get('channel')!.toUpperCase());
    }
    return json(await q(s.limit(100)), 200, cid);
  }

  if (req.method !== 'POST') throw new ApiError(405, 'method_not_allowed', 'Method not allowed');

  if (resource === 'channels') {
    const channel = String(b.channel ?? '').toUpperCase();
    if (!['IN_APP', 'PUSH', 'SMS', 'WHATSAPP'].includes(channel)) throw new ApiError(422, 'invalid_request', 'Unknown channel');
    if (b.provider_config !== undefined) {
      throw new ApiError(422, 'provider_platform_level', 'Providers are configured once for the platform (PUT /v1/platform/channels/{channel})');
    }
    if (b.enabled === true) {
      const supported = await q(db.from('ntf_product_channel_defaults').select('supported').eq('product_id', p.productId).eq('channel', channel).maybeSingle());
      if (supported && !supported.supported) throw new ApiError(422, 'channel_not_supported', `${channel} is not supported by this product`);
    }
    const row: Body = { tenant_id: p.tenantId, channel, enabled: b.enabled === true };
    await q(db.from('ntf_channels').upsert(row));
    await auditWrite('channel.save', { channel, enabled: row.enabled });
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
    const channel = String(b.channel ?? '').toUpperCase(), locale = b.locale ?? 'en';
    // Without an explicit version, new bindings start on the latest published platform version.
    const version = b.template_version ?? await q(db.rpc('ntf_latest_template_version', { p_template: b.template_id, p_channel: channel, p_locale: locale }));
    if (!version) throw new ApiError(422, 'no_published_version', `Template has no published ${channel}/${locale} version`);
    const row = {
      rule_id: rule.id, tenant_id: p.tenantId, channel, template_id: b.template_id,
      template_version: version, locale, mappings: b.mappings ?? {}
    };
    const saved = await q(db.from('ntf_rule_channels').upsert(row).select().single());
    await auditWrite('rule_channel.save', { rule_id: rule.id, channel: row.channel, template_id: row.template_id });
    return json(saved, 200, cid);
  }

  if (resource === 'overrides') {
    await assertTemplateAllowed(p, b.template_id);
    const channel = String(b.channel ?? '').toUpperCase(), locale = b.locale ?? 'en';
    if (!b.patch || typeof b.patch !== 'object' || Array.isArray(b.patch)) throw new ApiError(422, 'invalid_request', 'patch must be an object');
    const prev = await q(db.from('ntf_overrides').select('version').eq('tenant_id', p.tenantId).eq('template_id', b.template_id)
      .eq('channel', channel).eq('locale', locale).order('version', { ascending: false }).limit(1));
    // Publishing a new override retires the previously published one (immutable history).
    await q(db.from('ntf_overrides').update({ status: 'RETIRED' }).eq('tenant_id', p.tenantId).eq('template_id', b.template_id)
      .eq('channel', channel).eq('locale', locale).eq('status', 'PUBLISHED'));
    const saved = await q(db.from('ntf_overrides').insert({
      tenant_id: p.tenantId, template_id: b.template_id, base_version: b.base_version, channel,
      locale, version: Number.isInteger(b.version) ? b.version : (prev[0]?.version ?? 0) + 1, patch: b.patch, status: 'PUBLISHED'
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
      if (path === '/v1/metadata/sync') return await syncMetadata(p, b, cid);
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

    if (path === '/v1/settings' && req.method === 'GET') {
      if (!isEndUser(p)) forbid('A user credential is required');
      return await memberSettings(p, cid);
    }

    if (path.startsWith('/v1/admin/')) return await admin(p, req, path, b, cid);
    if (path.startsWith('/v1/platform/')) return await platform(p, req, path, b, cid);

    throw new ApiError(404, 'not_found', 'Route not found');
  } catch (e) {
    const err = toApiError(e);
    if (err.status >= 500) console.error('NTF Request Error:', JSON.stringify({ path, cid, error: String(e) }));
    else console.warn('NTF Request Rejected:', JSON.stringify({ path, cid, status: err.status, code: err.code }));
    return errorResponse(err, cid);
  }
});
