// Platform super admin APIs (spec §50), under /v1/platform. Every route needs a platform principal:
// an opaque 'platform' token or a JWT from ntf_platform_issuers sent with X-Platform-Admin: true.
// Organization-level pages reuse /v1/admin/* with X-Product-Code + X-Organization-Id.
import { audit, db, q } from './db.ts';
import { Principal } from './auth.ts';
import { ApiError, json, randomToken, requireArray, requireString, sha256Hex, UUID_RE } from './http.ts';
import { validateProviderConfig } from './config.ts';
import { adapterFor } from './adapters/index.ts';
import { Channel } from './adapters/types.ts';

// deno-lint-ignore no-explicit-any
type Body = Record<string, any>;

const CHANNELS = ['IN_APP', 'PUSH', 'SMS', 'WHATSAPP'];
const EXTERNAL = ['PUSH', 'SMS', 'WHATSAPP'];
const PRODUCT_CODE_RE = /^[a-z][a-z0-9_]{1,29}$/;

async function productByCode(code: string) {
  const p = await q(db.from('ntf_products').select('*').eq('code', code).maybeSingle());
  if (!p) throw new ApiError(404, 'not_found', 'Product not found');
  return p;
}

function channelOf(v: unknown, allowed = CHANNELS): string {
  const c = String(v ?? '').toUpperCase();
  if (!allowed.includes(c)) throw new ApiError(422, 'invalid_request', `channel must be one of ${allowed.join(', ')}`);
  return c;
}

export async function platform(p: Principal, req: Request, path: string, b: Body, cid: string): Promise<Response> {
  if (!p.isPlatform) throw new ApiError(403, 'forbidden', 'Platform super admin access required');
  const m = req.method;
  const url = new URL(req.url);
  const seg = path.split('/').slice(3); // after /v1/platform
  const log = (action: string, details: Record<string, unknown>, tenantId: string | null = null, productId: string | null = null) =>
    audit({ tenantId, productId, actor: p.actor, action: `platform.${action}`, details, correlationId: cid });

  // ---------------------------------------------------------------- overview
  if (seg[0] === 'overview' && m === 'GET') {
    const { count: products } = await db.from('ntf_products').select('id', { count: 'exact', head: true });
    const { count: organizations } = await db.from('ntf_tenants').select('id', { count: 'exact', head: true });
    return json({ products: products ?? 0, organizations: organizations ?? 0, queues: await q(db.rpc('ntf_queue_metrics')) }, 200, cid);
  }

  // ---------------------------------------------------------------- products
  if (seg[0] === 'products') {
    if (seg.length === 1 && m === 'GET') {
      const rows = await q(db.from('ntf_products').select('id,code,name,status,defaults:ntf_product_channel_defaults(channel,supported,default_enabled),issuers:ntf_identity_issuers(issuer,active)').order('code'));
      const counts = await q(db.from('ntf_tenants').select('product_id'));
      const n = new Map<string, number>();
      for (const t of counts) n.set(t.product_id, (n.get(t.product_id) ?? 0) + 1);
      return json(rows.map((r: Body) => ({ ...r, organizations: n.get(r.id) ?? 0 })), 200, cid);
    }
    if (seg.length === 1 && m === 'POST') {
      const code = requireString(b.code, 'code', 30).toLowerCase();
      if (!PRODUCT_CODE_RE.test(code)) throw new ApiError(422, 'invalid_request', 'code must be 2-30 lowercase letters, digits or _');
      const saved = await q(db.from('ntf_products').insert({ code, name: requireString(b.name, 'name', 200) }).select().single());
      await q(db.from('ntf_product_channel_defaults').upsert(
        CHANNELS.map((c) => ({ product_id: saved.id, channel: c, supported: c === 'IN_APP', default_enabled: c === 'IN_APP' }))
      ));
      await log('product.create', { code }, null, saved.id);
      return json(saved, 201, cid);
    }
    const product = await productByCode(seg[1]);
    if (seg[2] === 'status' && m === 'POST') {
      if (typeof b.active !== 'boolean') throw new ApiError(422, 'invalid_request', 'active must be boolean');
      await q(db.from('ntf_products').update({ status: b.active ? 'ACTIVE' : 'SUSPENDED' }).eq('id', product.id));
      await log('product.status', { code: product.code, active: b.active }, null, product.id);
      return json({ ok: true }, 200, cid);
    }
    if (seg[2] === 'channels' && m === 'PUT') {
      const items = requireArray(b.items, 'items', 4) as Body[];
      const rows = items.map((it) => {
        const channel = channelOf(it.channel);
        const supported = channel === 'IN_APP' ? true : it.supported === true;
        const defaultEnabled = channel === 'IN_APP' ? true : supported && it.default_enabled === true;
        return { product_id: product.id, channel, supported, default_enabled: defaultEnabled, updated_at: new Date().toISOString() };
      });
      await q(db.from('ntf_product_channel_defaults').upsert(rows));
      await log('product.channels', { code: product.code, items: rows.map(({ channel, supported, default_enabled }) => ({ channel, supported, default_enabled })) }, null, product.id);
      return json(await q(db.from('ntf_product_channel_defaults').select('channel,supported,default_enabled').eq('product_id', product.id)), 200, cid);
    }
    if (seg[2] === 'tokens' && m === 'GET') {
      return json(await q(db.from('ntf_api_tokens').select('id,label,scope,created_at,expires_at,revoked_at')
        .eq('product_id', product.id).eq('scope', 'product').order('created_at', { ascending: false })), 200, cid);
    }
    if (seg[2] === 'tokens' && m === 'POST') {
      const days = Math.min(Math.max(Number(b.ttlDays ?? 90), 1), 365);
      const token = randomToken();
      const expiresAt = new Date(Date.now() + days * 86400000).toISOString();
      const saved = await q(db.from('ntf_api_tokens').insert({
        token_hash: await sha256Hex(token), product_id: product.id, scope: 'product', expires_at: expiresAt,
        label: typeof b.label === 'string' ? b.label.slice(0, 100) : 'console'
      }).select('id,label,expires_at').single());
      await log('token.create', { code: product.code, id: saved.id, label: saved.label }, null, product.id);
      // The token is shown once; only its hash is stored.
      return json({ ...saved, token }, 201, cid);
    }
    if (seg[2] === 'issuers' && m === 'GET') {
      return json(await q(db.from('ntf_identity_issuers').select('*').eq('product_id', product.id)), 200, cid);
    }
    if (seg[2] === 'issuers' && m === 'POST') {
      const issuer = requireString(b.issuer, 'issuer', 500);
      if (!/^https:\/\//.test(issuer)) throw new ApiError(422, 'invalid_request', 'issuer must be an https URL');
      if (b.jwks_url != null && !/^https:\/\//.test(String(b.jwks_url))) throw new ApiError(422, 'invalid_request', 'jwks_url must be an https URL');
      const row = { product_id: product.id, issuer, jwks_url: b.jwks_url ?? null, audience: b.audience ?? 'authenticated',
        user_id_claim: b.user_id_claim ?? 'sub', active: b.active !== false };
      const saved = await q(db.from('ntf_identity_issuers').upsert(row, { onConflict: 'product_id,issuer' }).select().single());
      await log('issuer.save', { code: product.code, issuer, active: row.active }, null, product.id);
      return json(saved, 200, cid);
    }
  }

  if (seg[0] === 'tokens' && seg[1] && m === 'DELETE') {
    if (!UUID_RE.test(seg[1])) throw new ApiError(404, 'not_found', 'Token not found');
    const rows = await q(db.from('ntf_api_tokens').update({ revoked_at: new Date().toISOString() }).eq('id', seg[1]).is('revoked_at', null).select('id,product_id'));
    if (!rows.length) throw new ApiError(404, 'not_found', 'Token not found or already revoked');
    await log('token.revoke', { id: seg[1] }, null, rows[0].product_id);
    return json({ ok: true }, 200, cid);
  }

  // ---------------------------------------------------------------- organizations
  if (seg[0] === 'groups' && m === 'GET') {
    const product = await productByCode(requireString(url.searchParams.get('product'), 'product', 30));
    const rows = await q(db.from('ntf_events').select('module_code,code').eq('product_id', product.id));
    const groups = new Map<string, Set<string>>();
    for (const r of rows) {
      const g = String(r.module_code).toUpperCase();
      if (!groups.has(g)) groups.set(g, new Set());
      groups.get(g)!.add(r.code);
    }
    return json([...groups.entries()].sort().map(([group, events]) => ({ group, events: [...events].sort() })), 200, cid);
  }

  if (seg[0] === 'organizations') {
    if (seg.length === 1 && m === 'GET') {
      const product = await productByCode(requireString(url.searchParams.get('product'), 'product', 30));
      const rows = await q(db.rpc('ntf_platform_org_summary', {
        p_product: product.id, p_search: url.searchParams.get('search') || null,
        p_limit: Number(url.searchParams.get('limit') ?? 100), p_offset: Number(url.searchParams.get('offset') ?? 0)
      }));
      const status = url.searchParams.get('status');
      return json(status ? rows.filter((r: Body) => (status === 'active') === r.active) : rows, 200, cid);
    }
    if (seg.length === 1 && m === 'POST') {
      const code = requireString(b.productCode, 'productCode', 30);
      const org = requireString(b.organizationId, 'organizationId', 36);
      if (!UUID_RE.test(org)) throw new ApiError(422, 'invalid_request', 'organizationId must be a UUID');
      if (b.preferences !== undefined && (typeof b.preferences !== 'object' || Array.isArray(b.preferences))) {
        throw new ApiError(422, 'invalid_request', 'preferences must be an object of group -> channels');
      }
      const r = await q(db.rpc('ntf_provision_org', {
        p_product_code: code, p_org: org, p_org_name: requireString(b.organizationName, 'organizationName', 200),
        p_preferences: b.preferences ?? {}, p_settings: b.settings ?? {}, p_actor: p.actor
      }));
      await log('organization.create', { productCode: code, organizationId: org, groups: Object.keys(b.preferences ?? {}) }, r.tenantId, null);
      return json(r, 201, cid);
    }
    if (seg[1] === 'status' && m === 'POST') {
      const product = await productByCode(requireString(b.productCode, 'productCode', 30));
      if (typeof b.active !== 'boolean') throw new ApiError(422, 'invalid_request', 'active must be boolean');
      if (!b.active && !(typeof b.reason === 'string' && b.reason.trim())) throw new ApiError(422, 'invalid_request', 'A reason is required to suspend an organization');
      const rows = await q(db.from('ntf_tenants').update({ active: b.active }).eq('product_id', product.id).eq('organization_id', b.organizationId).select('id'));
      if (!rows.length) throw new ApiError(404, 'not_found', 'Organization is not provisioned for this product');
      await log('organization.status', { productCode: product.code, organizationId: b.organizationId, active: b.active, reason: b.reason ?? null }, rows[0].id, product.id);
      return json({ ok: true }, 200, cid);
    }
  }

  // ---------------------------------------------------------------- platform channels and providers
  if (seg[0] === 'channels') {
    if (seg.length === 1 && m === 'GET') {
      const rows = await q(db.from('ntf_platform_channels').select('*'));
      const by = new Map(rows.map((r: Body) => [r.channel, r]));
      return json(EXTERNAL.map((c) => {
        const r = by.get(c) as Body | undefined;
        return { channel: c, provider_config: r?.provider_config ?? {}, configured: !!r?.provider_config?.provider,
          hasSecret: !!r?.provider_config?.secret_name, updated_at: r?.updated_at ?? null, updated_by: r?.updated_by ?? null };
      }), 200, cid);
    }
    const channel = channelOf(seg[1], EXTERNAL);
    if (seg.length === 2 && m === 'PUT') {
      const cfg = validateProviderConfig(channel, b.provider_config);
      if (!cfg) throw new ApiError(422, 'invalid_request', 'provider_config is required');
      const cur = await q(db.from('ntf_platform_channels').select('provider_config').eq('channel', channel).maybeSingle());
      // secret_name is managed by the write-only secret endpoint; keep it unless the caller names a shared secret.
      const merged: Body = { ...cfg, secret_name: cfg.secret_name ?? cur?.provider_config?.secret_name };
      if (!merged.secret_name) delete merged.secret_name;
      await q(db.from('ntf_platform_channels').upsert({ channel, provider_config: merged, updated_at: new Date().toISOString(), updated_by: p.actor }));
      await log('channel.save', { channel, provider: merged.provider, secret_name: merged.secret_name ?? null });
      return json({ ok: true, channel, provider_config: merged }, 200, cid);
    }
    if (seg[2] === 'secret' && m === 'PUT') {
      if (!b.value || typeof b.value !== 'object' || Array.isArray(b.value) || JSON.stringify(b.value).length > 8192) {
        throw new ApiError(422, 'invalid_request', 'value must be a JSON object of credentials');
      }
      const name = await q(db.rpc('ntf_set_platform_secret', { p_channel: channel, p_value: b.value, p_actor: p.actor }));
      await log('channel.secret', { channel, secret_name: name, keys: Object.keys(b.value) });
      return json({ ok: true, secret_name: name }, 200, cid);
    }
    if (seg[2] === 'test' && m === 'POST') {
      const since = new Date(Date.now() - 10 * 60000).toISOString();
      const { count } = await db.from('ntf_audit_logs').select('id', { count: 'exact', head: true })
        .eq('action', 'platform.channel.test').gt('created_at', since);
      if ((count ?? 0) >= 10) throw new ApiError(429, 'rate_limited', 'At most 10 test sends per 10 minutes');
      const row = await q(db.from('ntf_platform_channels').select('provider_config').eq('channel', channel).maybeSingle());
      const config = row?.provider_config ?? {};
      if (!config.provider) throw new ApiError(409, 'not_configured', `No platform provider is configured for ${channel}`);
      const recipient = { userId: 'test', displayName: 'Test', phone: null as string | null, email: null, locale: null, deviceTokens: [] as { id: string; token: string }[] };
      if (channel === 'PUSH') {
        recipient.deviceTokens = [{ id: 'test', token: requireString(b.deviceToken, 'deviceToken', 4096) }];
      } else if (typeof b.phone === 'string' && /^\+[1-9]\d{6,14}$/.test(b.phone)) {
        recipient.phone = b.phone;
      } else throw new ApiError(422, 'invalid_request', 'Give an E.164 phone');
      const adapter = adapterFor(channel as Channel, config);
      const secret = adapter.provider === 'mock' ? {} : ((await q(db.rpc('ntf_get_platform_secret', { p_channel: channel }))) ?? {});
      const payload = { title: 'Test notification', body: 'Test message from the notification platform', ...(b.payload && typeof b.payload === 'object' ? b.payload : {}) };
      const r = await adapter.send({ deliveryId: `test-${crypto.randomUUID()}`, tenantId: 'platform', channel: channel as Channel, payload, recipient, config, secret });
      await log('channel.test', { channel, provider: adapter.provider, outcome: r.outcome });
      return json({ provider: adapter.provider, ...r }, 200, cid);
    }
  }

  // ---------------------------------------------------------------- platform templates
  if (seg[0] === 'templates') {
    if (seg.length === 1 && m === 'GET') {
      let s = db.from('ntf_templates').select('id,code,name,description,product_id,versions:ntf_template_versions(version,channel,locale,status,published_at,content,variables)').order('code');
      const pc = url.searchParams.get('product');
      if (pc) {
        const product = await productByCode(pc);
        s = s.or(`product_id.is.null,product_id.eq.${product.id}`);
      }
      const templates = await q(s);
      const pins = await q(db.from('ntf_rule_channels').select('template_id,template_version,tenant_id'));
      const ovs = await q(db.from('ntf_overrides').select('template_id,tenant_id').eq('status', 'PUBLISHED'));
      return json(templates.map((t: Body) => {
        const pinned: Record<string, Set<string>> = {};
        for (const r of pins) if (r.template_id === t.id) (pinned[r.template_version] ??= new Set()).add(r.tenant_id);
        const published = t.versions.filter((v: Body) => v.status === 'PUBLISHED').map((v: Body) => v.version);
        return {
          ...t,
          latestPublished: published.length ? Math.max(...published) : null,
          draftVersion: t.versions.find((v: Body) => v.status === 'DRAFT')?.version ?? null,
          pinnedOrganizations: Object.fromEntries(Object.entries(pinned).map(([v, set]) => [v, set.size])),
          organizationsWithOverrides: new Set(ovs.filter((o: Body) => o.template_id === t.id).map((o: Body) => o.tenant_id)).size
        };
      }), 200, cid);
    }
    if (seg.length === 1 && m === 'POST') {
      const code = requireString(b.code, 'code', 100).toUpperCase();
      if (!/^[A-Z0-9_]{2,100}$/.test(code)) throw new ApiError(422, 'invalid_request', 'code must be upper-case letters, digits or _');
      const productId = b.productCode ? (await productByCode(String(b.productCode))).id : null;
      const saved = await q(db.from('ntf_templates').insert({ code, name: requireString(b.name, 'name', 200), description: b.description ?? null, product_id: productId }).select().single());
      await log('template.create', { id: saved.id, code, product_id: productId });
      return json(saved, 201, cid);
    }
    const id = seg[1];
    if (!UUID_RE.test(id ?? '')) throw new ApiError(404, 'not_found', 'Template not found');
    const tpl = await q(db.from('ntf_templates').select('id,code').eq('id', id).maybeSingle());
    if (!tpl) throw new ApiError(404, 'not_found', 'Template not found');

    // Save a draft channel version. The draft number is the next version unless a draft already exists.
    if (seg[2] === 'versions' && seg.length === 3 && m === 'POST') {
      const channel = channelOf(b.channel), locale = typeof b.locale === 'string' ? b.locale.slice(0, 10) : 'en';
      if (!b.content || typeof b.content !== 'object' || Array.isArray(b.content)) throw new ApiError(422, 'invalid_request', 'content must be an object');
      const all = await q(db.from('ntf_template_versions').select('version,status').eq('template_id', id));
      const draft = all.find((v: Body) => v.status === 'DRAFT');
      const version = draft?.version ?? (all.length ? Math.max(...all.map((v: Body) => v.version)) + 1 : 1);
      const existing = await q(db.from('ntf_template_versions').select('status').eq('template_id', id).eq('version', version).eq('channel', channel).eq('locale', locale).maybeSingle());
      if (existing && existing.status !== 'DRAFT') throw new ApiError(409, 'immutable_version', 'Published versions cannot change; save a new draft');
      const saved = await q(db.from('ntf_template_versions').upsert({
        template_id: id, version, channel, locale, content: b.content, variables: b.variables ?? {}, status: 'DRAFT'
      }).select().single());
      await log('template.draft', { id, code: tpl.code, version, channel, locale });
      return json(saved, 200, cid);
    }
    const version = Number(seg[3]);
    if (seg[2] === 'versions' && Number.isInteger(version) && seg[4] === 'publish' && m === 'POST') {
      const rows = await q(db.from('ntf_template_versions').update({ status: 'PUBLISHED', published_at: new Date().toISOString() })
        .eq('template_id', id).eq('version', version).eq('status', 'DRAFT').select('channel,locale'));
      if (!rows.length) throw new ApiError(409, 'nothing_to_publish', 'This version has no draft to publish');
      await log('template.publish', { id, code: tpl.code, version, channels: rows.map((r: Body) => r.channel) });
      // Existing organizations keep their pinned version; new rule channels default to the latest published version.
      return json({ ok: true, version, channels: rows }, 200, cid);
    }
    if (seg[2] === 'versions' && Number.isInteger(version) && seg[4] === 'retire' && m === 'POST') {
      const { count: pinned } = await db.from('ntf_rule_channels').select('rule_id', { count: 'exact', head: true }).eq('template_id', id).eq('template_version', version);
      const { count: ovs } = await db.from('ntf_overrides').select('id', { count: 'exact', head: true }).eq('template_id', id).eq('base_version', version).eq('status', 'PUBLISHED');
      if ((pinned ?? 0) > 0 || (ovs ?? 0) > 0) {
        throw new ApiError(409, 'version_in_use', `Version ${version} is still used by ${pinned ?? 0} rule channels and ${ovs ?? 0} overrides; upgrade those organizations first`);
      }
      const rows = await q(db.from('ntf_template_versions').update({ status: 'RETIRED' }).eq('template_id', id).eq('version', version).eq('status', 'PUBLISHED').select('channel'));
      if (!rows.length) throw new ApiError(404, 'not_found', 'No published rows for this version');
      await log('template.retire', { id, code: tpl.code, version });
      return json({ ok: true }, 200, cid);
    }
  }

  // ---------------------------------------------------------------- operations
  if (seg[0] === 'ops' && m === 'GET') {
    const [queues, dlq] = await Promise.all([q(db.rpc('ntf_queue_metrics')), q(db.rpc('ntf_dlq_list', { p_limit: 50 }))]);
    return json({ queues, deadLetters: dlq }, 200, cid);
  }
  if (seg[0] === 'deliveries' && seg[2] === 'replay' && m === 'POST') {
    if (!UUID_RE.test(seg[1] ?? '')) throw new ApiError(404, 'not_found', 'Delivery not found');
    const d = await q(db.from('ntf_deliveries').select('id,tenant_id').eq('id', seg[1]).maybeSingle());
    if (!d) throw new ApiError(404, 'not_found', 'Delivery not found');
    const r = await q(db.rpc('ntf_requeue_delivery', { p_delivery: d.id, p_tenant: d.tenant_id }));
    if (!r) throw new ApiError(409, 'not_retryable', 'Only FAILED or DEAD_LETTERED external deliveries can be replayed');
    await log('delivery.replay', { id: d.id }, d.tenant_id);
    return json({ ok: true }, 200, cid);
  }
  if (seg[0] === 'audit' && m === 'GET') {
    let s = db.from('ntf_audit_logs').select('*').order('created_at', { ascending: false }).limit(Math.min(Number(url.searchParams.get('limit') ?? 100), 200));
    if (url.searchParams.get('platformOnly') === 'true') s = s.like('action', 'platform.%');
    return json(await q(s), 200, cid);
  }

  throw new ApiError(404, 'not_found', 'Unknown platform resource');
}
