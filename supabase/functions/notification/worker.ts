// pgmq worker (spec §8, §26). Invoked by pg_cron every minute through POST /v1/worker.
//  1. ntf_events queue: one message per accepted event -> expand rules into notifications + one delivery per channel.
//     IN_APP is delivered by persisting it; external deliveries are enqueued (one message per delivery).
//  2. ntf_deliveries queue: one message per external delivery -> recheck eligibility -> provider adapter.
// Messages are acknowledged (archived) only after outcomes are persisted. Failures retry with backoff + jitter via
// the visibility timeout; exhausted messages move to ntf_dlq.
import { merge } from './parser.mjs';
import { audit, db, q } from './db.ts';
import { adapterFor } from './adapters/index.ts';
import { Channel, SendResult } from './adapters/types.ts';
import { applyMappings, backoffSeconds, contextRecipients, eligible, matchesConditions, Preference, renderContent } from './logic.ts';

const EVENT_VT = 120;
const DELIVERY_VT = 90;
const MAX_EVENT_ATTEMPTS = 5;
const DELIVERY_CONCURRENCY = 10;

// deno-lint-ignore no-explicit-any
type Row = Record<string, any>;
interface QueueMsg { msg_id: number; read_ct: number; message: Row }

export interface WorkerStats {
  events: { processed: number; retried: number; deadLettered: number; enqueuedDeliveries: number };
  deliveries: { sent: number; retried: number; failed: number; suppressed: number; deadLettered: number };
}

// ------------------------------------------------------------------ event expansion

async function expandEvent(eventId: string, tenantId: string): Promise<{ enqueued: number; renderErrors: number }> {
  const e = await q(db.from('ntf_event_log').select('*').eq('id', eventId).eq('tenant_id', tenantId).maybeSingle());
  if (!e) return { enqueued: 0, renderErrors: 0 };
  const t = await q(db.from('ntf_tenants').select('id,active').eq('id', tenantId).single());
  if (!t.active) {
    await q(db.from('ntf_event_log').update({ status: 'PROCESSED', processed_at: new Date().toISOString(), last_error: 'tenant suspended' }).eq('id', e.id));
    return { enqueued: 0, renderErrors: 0 };
  }

  const rules: Row[] = await q(db.from('ntf_rules').select('*').eq('tenant_id', t.id).eq('event_code', e.event_code)
    .eq('event_version', e.event_version).eq('active', true).order('priority', { ascending: false }));
  const channelRows: Row[] = await q(db.from('ntf_channels').select('channel,enabled').eq('tenant_id', t.id));
  const channelEnabled = new Map(channelRows.map((c) => [c.channel, c.enabled === true]));

  // Resolve recipients per rule (batched).
  const perRule: { rule: Row; ids: string[] }[] = [];
  const allIds = new Set<string>();
  for (const r of rules) {
    if (!matchesConditions(r.conditions, e.payload)) continue;
    let ids: string[];
    if (r.recipient_strategy === 'ALL_USERS_IN_ROLE') {
      ids = (await q(db.from('ntf_user_roles').select('user_id').eq('tenant_id', t.id).eq('role_code', r.role_code))).map((x: Row) => x.user_id);
    } else if (r.recipient_strategy === 'ALL_ORG_USERS') {
      ids = (await q(db.from('ntf_users').select('user_id').eq('tenant_id', t.id).eq('active', true).limit(10000))).map((x: Row) => x.user_id);
    } else {
      ids = contextRecipients(r.recipient_strategy, e.payload);
    }
    ids = [...new Set(ids)];
    ids.forEach((i) => allIds.add(i));
    perRule.push({ rule: r, ids });
  }
  if (!allIds.size) {
    await q(db.from('ntf_event_log').update({ status: 'PROCESSED', processed_at: new Date().toISOString() }).eq('id', e.id));
    return { enqueued: 0, renderErrors: 0 };
  }

  // Only active, synced members are eligible; supplied references are validated against membership (spec §42).
  const users = new Map<string, Row>();
  const prefs = new Map<string, Preference>();
  const idList = [...allIds];
  for (let i = 0; i < idList.length; i += 500) {
    const chunk = idList.slice(i, i + 500);
    for (const u of await q(db.from('ntf_users').select('*').eq('tenant_id', t.id).eq('active', true).in('user_id', chunk))) users.set(u.user_id, u);
    for (const p of await q(db.from('ntf_preferences').select('user_id,channel,enabled,consent_at').eq('tenant_id', t.id).in('user_id', chunk))) {
      prefs.set(`${p.user_id}|${p.channel}`, p);
    }
  }

  const templateCache = new Map<string, { content: Row; snapshot: Row }>();
  async function resolveTemplate(ch: Row) {
    const key = `${ch.template_id}|${ch.template_version}|${ch.channel}|${ch.locale}`;
    if (!templateCache.has(key)) {
      const tv = await q(db.from('ntf_template_versions').select('*').eq('template_id', ch.template_id).eq('version', ch.template_version)
        .eq('channel', ch.channel).eq('locale', ch.locale).eq('status', 'PUBLISHED').single());
      const ov = await q(db.from('ntf_overrides').select('*').eq('tenant_id', t.id).eq('template_id', ch.template_id)
        .eq('base_version', ch.template_version).eq('channel', ch.channel).eq('locale', ch.locale).eq('status', 'PUBLISHED').maybeSingle());
      templateCache.set(key, { content: merge(tv.content, ov?.patch), snapshot: { template_id: ch.template_id, version: tv.version, override: ov?.id ?? null, override_version: ov?.version ?? null } });
    }
    return templateCache.get(key)!;
  }

  const notifications: Row[] = [];
  const pendingDeliveries: { key: string; channel: Channel; rendered: Row; snapshot: Row }[] = [];
  let renderErrors = 0;

  for (const { rule, ids } of perRule) {
    const channels: Row[] = (await q(db.from('ntf_rule_channels').select('*').eq('rule_id', rule.id).eq('tenant_id', t.id)))
      .sort((a: Row, b: Row) => Number(b.channel === 'IN_APP') - Number(a.channel === 'IN_APP'));
    for (const id of ids) {
      const u = users.get(id);
      if (!u) continue;
      const nKey = `${id}|${rule.purpose}`;
      for (const ch of channels) {
        if (!eligible(ch.channel, channelEnabled.get(ch.channel) ?? false, prefs.get(`${id}|${ch.channel}`))) continue;
        const tpl = await resolveTemplate(ch);
        const ctx: Row = { ...e.payload, recipient: { name: u.display_name, id: u.user_id, locale: u.locale } };
        let rendered: Row;
        try {
          ctx.vars = applyMappings(ctx, ch.mappings);
          rendered = renderContent(tpl.content, ctx) as Row;
        } catch (err) {
          renderErrors++;
          console.warn('NTF Render Error:', JSON.stringify({ event: e.id, rule: rule.id, channel: ch.channel, error: String((err as Error).message) }));
          continue;
        }
        if (!notifications.some((n) => n._key === nKey)) {
          notifications.push({
            _key: nKey, tenant_id: t.id, event_id: e.id, user_id: id, purpose: rule.purpose,
            title: String(rendered.title ?? ''), body: String(rendered.body ?? ''), design: rendered.design ?? {}, action: rendered.action ?? null
          });
        }
        pendingDeliveries.push({ key: nKey, channel: ch.channel, rendered, snapshot: tpl.snapshot });
      }
    }
  }

  if (notifications.length) {
    for (let i = 0; i < notifications.length; i += 500) {
      await q(db.from('ntf_notifications').upsert(
        notifications.slice(i, i + 500).map(({ _key, ...n }) => n),
        { onConflict: 'event_id,user_id,purpose', ignoreDuplicates: true }
      ));
    }
    const ids = new Map<string, string>();
    for (const n of await q(db.from('ntf_notifications').select('id,user_id,purpose').eq('tenant_id', t.id).eq('event_id', e.id))) {
      ids.set(`${n.user_id}|${n.purpose}`, n.id);
    }
    const now = new Date().toISOString();
    const rows = pendingDeliveries.filter((d) => ids.has(d.key)).map((d) => ({
      notification_id: ids.get(d.key), tenant_id: t.id, channel: d.channel,
      status: d.channel === 'IN_APP' ? 'DELIVERED' : 'QUEUED',
      delivered_at: d.channel === 'IN_APP' ? now : null,
      rendered_payload: d.rendered, template_snapshot: d.snapshot
    }));
    for (let i = 0; i < rows.length; i += 500) {
      await q(db.from('ntf_deliveries').upsert(rows.slice(i, i + 500), { onConflict: 'notification_id,channel', ignoreDuplicates: true }));
    }
  }

  // Atomic: sends one queue message per not-yet-enqueued external delivery and stamps enqueued_at.
  const enqueued = await q(db.rpc('ntf_enqueue_deliveries', { p_event: e.id }));
  await q(db.from('ntf_event_log').update({
    status: 'PROCESSED', processed_at: new Date().toISOString(),
    last_error: renderErrors ? `${renderErrors} recipient/channel render errors` : null
  }).eq('id', e.id));
  if (renderErrors) {
    await audit({ tenantId: t.id, actor: 'worker', action: 'event.render_errors', details: { eventId: e.id, count: renderErrors } });
  }
  return { enqueued, renderErrors };
}

// ------------------------------------------------------------------ delivery

async function loadSecret(tenantId: string, channel: string): Promise<Row> {
  const s = await q(db.rpc('ntf_get_provider_secret', { p_tenant: tenantId, p_channel: channel }));
  return (s ?? {}) as Row;
}

async function deliver(msg: QueueMsg, stats: WorkerStats) {
  const m = msg.message;
  const d = await q(db.from('ntf_deliveries').select('*,notification:ntf_notifications!inner(id,user_id,expires_at)')
    .eq('id', m.delivery_id).eq('tenant_id', m.tenant_id).maybeSingle());
  if (!d || !['QUEUED', 'PROCESSING'].includes(d.status)) {
    await q(db.rpc('ntf_queue_ack', { p_queue: 'ntf_deliveries', p_msg_id: msg.msg_id }));
    return;
  }
  const attempt = (d.attempts ?? 0) + 1;
  const finish = async (status: string, outcome: string, r: Partial<SendResult> & { provider?: string }, extra: Row = {}) => {
    const now = new Date().toISOString();
    await q(db.from('ntf_deliveries').update({
      status, attempts: attempt, updated_at: now, last_error: r.error ?? null,
      provider: r.provider ?? d.provider, provider_message_id: r.providerMessageId ?? d.provider_message_id, ...extra
    }).eq('id', d.id));
    await q(db.from('ntf_delivery_attempts').insert({
      delivery_id: d.id, tenant_id: d.tenant_id, attempt, outcome, provider: r.provider ?? null,
      provider_message_id: r.providerMessageId ?? null, http_status: r.httpStatus ?? null, error: r.error ?? null, response: r.response ?? {}
    }));
  };

  // Recheck tenant state, channel enablement, membership, consent and expiry right before sending (spec §8).
  const [t, ch, u, pref] = await Promise.all([
    q(db.from('ntf_tenants').select('active').eq('id', d.tenant_id).single()),
    q(db.from('ntf_channels').select('enabled,provider_config').eq('tenant_id', d.tenant_id).eq('channel', d.channel).maybeSingle()),
    q(db.from('ntf_users').select('*').eq('tenant_id', d.tenant_id).eq('user_id', d.notification.user_id).maybeSingle()),
    q(db.from('ntf_preferences').select('enabled,consent_at').eq('tenant_id', d.tenant_id).eq('user_id', d.notification.user_id).eq('channel', d.channel).maybeSingle())
  ]);
  const expired = d.notification.expires_at && Date.parse(d.notification.expires_at) < Date.now();
  if (!t?.active || !u?.active || expired || !eligible(d.channel, ch?.enabled === true, pref ?? undefined)) {
    const reason = !t?.active ? 'tenant suspended' : !u?.active ? 'user inactive' : expired ? 'expired' : 'channel disabled or no consent';
    await finish(expired ? 'EXPIRED' : 'SUPPRESSED', 'SUPPRESSED', { error: reason });
    await q(db.rpc('ntf_queue_ack', { p_queue: 'ntf_deliveries', p_msg_id: msg.msg_id }));
    stats.deliveries.suppressed++;
    return;
  }

  await q(db.from('ntf_deliveries').update({ status: 'PROCESSING', updated_at: new Date().toISOString() }).eq('id', d.id));
  const config = (ch?.provider_config ?? {}) as Row;
  let result: SendResult;
  let provider = String(config.provider ?? 'mock');
  try {
    const adapter = adapterFor(d.channel, config);
    provider = adapter.provider;
    const deviceTokens = d.channel === 'PUSH'
      ? await q(db.from('ntf_device_tokens').select('id,token').eq('tenant_id', d.tenant_id).eq('user_id', u.user_id).eq('active', true).limit(20))
      : [];
    result = await adapter.send({
      deliveryId: d.id, tenantId: d.tenant_id, channel: d.channel, payload: d.rendered_payload ?? {},
      recipient: { userId: u.user_id, displayName: u.display_name, phone: u.phone, email: u.email, locale: u.locale, deviceTokens },
      config, secret: provider === 'mock' ? {} : await loadSecret(d.tenant_id, d.channel)
    });
  } catch (err) {
    const message = String((err as Error).message ?? err).slice(0, 300);
    result = message.startsWith('unsupported provider') || message.startsWith('missing')
      ? { outcome: 'FAILED', error: message }
      : { outcome: 'RETRY', error: message };
  }

  if (result.invalidTokenIds?.length) {
    await q(db.from('ntf_device_tokens').update({ active: false, updated_at: new Date().toISOString() }).in('id', result.invalidTokenIds));
  }

  const r = { ...result, provider };
  if (result.outcome === 'SENT' || result.outcome === 'ACCEPTED') {
    await finish(result.outcome, result.outcome, r, { sent_at: new Date().toISOString() });
    await q(db.rpc('ntf_queue_ack', { p_queue: 'ntf_deliveries', p_msg_id: msg.msg_id }));
    stats.deliveries.sent++;
  } else if (result.outcome === 'RETRY' && attempt < (d.max_attempts ?? 5)) {
    await finish('QUEUED', 'RETRY', r);
    await q(db.rpc('ntf_queue_retry', { p_queue: 'ntf_deliveries', p_msg_id: msg.msg_id, p_delay_seconds: backoffSeconds(attempt, result.retryAfter) }));
    stats.deliveries.retried++;
  } else if (result.outcome === 'RETRY') {
    await finish('DEAD_LETTERED', 'DEAD_LETTERED', r);
    await q(db.rpc('ntf_queue_dead_letter', { p_queue: 'ntf_deliveries', p_msg_id: msg.msg_id, p_message: m, p_reason: result.error ?? 'retries exhausted' }));
    stats.deliveries.deadLettered++;
  } else {
    await finish('FAILED', 'FAILED', r);
    await q(db.rpc('ntf_queue_ack', { p_queue: 'ntf_deliveries', p_msg_id: msg.msg_id }));
    stats.deliveries.failed++;
  }
}

// ------------------------------------------------------------------ loop

export async function runWorker(budgetMs = 45000): Promise<WorkerStats> {
  const started = Date.now();
  const left = () => budgetMs - (Date.now() - started);
  const stats: WorkerStats = {
    events: { processed: 0, retried: 0, deadLettered: 0, enqueuedDeliveries: 0 },
    deliveries: { sent: 0, retried: 0, failed: 0, suppressed: 0, deadLettered: 0 }
  };

  // Events first so new deliveries can go out in the same run.
  while (left() > 15000) {
    const msgs: QueueMsg[] = await q(db.rpc('ntf_queue_read', { p_queue: 'ntf_events', p_vt: EVENT_VT, p_qty: 10 }));
    if (!msgs.length) break;
    for (const msg of msgs) {
      try {
        const r = await expandEvent(msg.message.event_id, msg.message.tenant_id);
        await q(db.rpc('ntf_queue_ack', { p_queue: 'ntf_events', p_msg_id: msg.msg_id }));
        stats.events.processed++;
        stats.events.enqueuedDeliveries += r.enqueued;
      } catch (err) {
        const error = String((err as Error).message ?? err).slice(0, 300);
        console.error('NTF Event Error:', JSON.stringify({ event: msg.message.event_id, read_ct: msg.read_ct, error }));
        if (msg.read_ct >= MAX_EVENT_ATTEMPTS) {
          await q(db.from('ntf_event_log').update({ status: 'DEAD_LETTERED', last_error: error }).eq('id', msg.message.event_id));
          await q(db.rpc('ntf_queue_dead_letter', { p_queue: 'ntf_events', p_msg_id: msg.msg_id, p_message: msg.message, p_reason: error }));
          stats.events.deadLettered++;
        } else {
          await q(db.from('ntf_event_log').update({ last_error: error }).eq('id', msg.message.event_id));
          await q(db.rpc('ntf_queue_retry', { p_queue: 'ntf_events', p_msg_id: msg.msg_id, p_delay_seconds: backoffSeconds(msg.read_ct) }));
          stats.events.retried++;
        }
      }
    }
  }

  while (left() > 20000) {
    const msgs: QueueMsg[] = await q(db.rpc('ntf_queue_read', { p_queue: 'ntf_deliveries', p_vt: DELIVERY_VT, p_qty: 50 }));
    if (!msgs.length) break;
    for (let i = 0; i < msgs.length; i += DELIVERY_CONCURRENCY) {
      await Promise.all(msgs.slice(i, i + DELIVERY_CONCURRENCY).map(async (msg) => {
        try {
          await deliver(msg, stats);
        } catch (err) {
          // Unexpected (database) failure: leave the message; it reappears after the visibility timeout.
          console.error('NTF Delivery Error:', JSON.stringify({ delivery: msg.message.delivery_id, error: String(err) }));
          if (msg.read_ct >= 10) {
            await q(db.rpc('ntf_queue_dead_letter', { p_queue: 'ntf_deliveries', p_msg_id: msg.msg_id, p_message: msg.message, p_reason: 'worker error' }));
            stats.deliveries.deadLettered++;
          }
        }
      }));
    }
  }
  return stats;
}
