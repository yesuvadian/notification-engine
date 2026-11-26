import { createClient } from 'npm:@supabase/supabase-js@2';
import Ajv from 'npm:ajv@8';
import { path, merge, render } from './parser.mjs';

const db = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  {
    db: {
      schema: 'ntf'
    }
  }
);

const ajv = new Ajv({ strict: false });

const headers = {
  'Content-Type': 'application/json',
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization,content-type,x-organization-id,apikey,x-client-info',
  'Access-Control-Allow-Methods': 'GET,POST,OPTIONS'
};

const reply = (x: unknown, status = 200) =>
  new Response(JSON.stringify(x), {
    status,
    headers
  });

// Database query helper
async function q(p: any) {
  const { data, error } = await p;

  if (error) {
    console.error('NTF Database Error:', JSON.stringify({
      code: error.code,
      message: error.message
    }));

    throw Error(error.message);
  }

  return data;
}

// SHA-256 token hashing
async function hash(s: string) {
  return Array.from(
    new Uint8Array(
      await crypto.subtle.digest(
        'SHA-256',
        new TextEncoder().encode(s)
      )
    )
  )
    .map(x => x.toString(16).padStart(2, '0'))
    .join('');
}

// Normalize Edge Function request path
function normalizePath(url: string): string {
  const rawPath = new URL(url).pathname;

  const normalizedPath = rawPath
    .replace(
      /^(?:\/functions\/v1)?\/notification(?=\/|$)/,
      ''
    )
    .replace(/\/+$/, '');

  return normalizedPath || '/';
}

// Notification processing
async function process(job: any) {

  const e = await q(
    db.from('ntf_event_log')
      .select('*')
      .eq('id', job.payload.event_id)
      .eq('tenant_id', job.tenant_id)
      .single()
  );

  const t = await q(
    db.from('ntf_tenants')
      .select('*')
      .eq('id', e.tenant_id)
      .single()
  );

  if (!t.active) return;

  const rules = await q(
    db.from('ntf_rules')
      .select('*')
      .eq('tenant_id', t.id)
      .eq('event_code', e.event_code)
      .eq('event_version', e.event_version)
      .eq('active', true)
      .order('priority', { ascending: false })
  );

  for (const r of rules) {

    if (
      !Object.entries(r.conditions ?? {}).every(
        ([k, v]) =>
          JSON.stringify(path(e.payload, k)) ===
          JSON.stringify(v)
      )
    ) {
      continue;
    }

    let ids: string[] = [];

    if (r.recipient_strategy === 'ALL_USERS_IN_ROLE') {

      ids = (
        await q(
          db.from('ntf_user_roles')
            .select('user_id')
            .eq('tenant_id', t.id)
            .eq('role_code', r.role_code)
        )
      ).map((x: any) => x.user_id);

    } else if (
      r.recipient_strategy === 'ALL_ORG_USERS'
    ) {

      ids = (
        await q(
          db.from('ntf_users')
            .select('user_id')
            .eq('tenant_id', t.id)
            .eq('active', true)
        )
      ).map((x: any) => x.user_id);

    } else {

      const v =
        e.payload.recipientContext?.[
          r.recipient_strategy.toLowerCase()
        ];

      ids = Array.isArray(v) ? v : [];
    }

    const channels = await q(
      db.from('ntf_rule_channels')
        .select('*')
        .eq('rule_id', r.id)
        .eq('tenant_id', t.id)
    );

    for (const id of new Set(ids)) {

      const u = await q(
        db.from('ntf_users')
          .select('*')
          .eq('tenant_id', t.id)
          .eq('user_id', id)
          .eq('active', true)
          .maybeSingle()
      );

      if (!u) continue;

      for (
        const ch of channels.sort(
          (a: any, b: any) =>
            Number(b.channel === 'IN_APP') -
            Number(a.channel === 'IN_APP')
        )
      ) {

        const enabled = await q(
          db.from('ntf_channels')
            .select('enabled')
            .eq('tenant_id', t.id)
            .eq('channel', ch.channel)
            .maybeSingle()
        );

        if (!enabled?.enabled) continue;

        const pref = await q(
          db.from('ntf_preferences')
            .select('*')
            .eq('tenant_id', t.id)
            .eq('user_id', id)
            .eq('channel', ch.channel)
            .maybeSingle()
        );

        if (
          pref?.enabled === false ||
          (ch.channel !== 'IN_APP' && !pref?.consent_at)
        ) {
          continue;
        }

        const tv = await q(
          db.from('ntf_template_versions')
            .select('*')
            .eq('template_id', ch.template_id)
            .eq('version', ch.template_version)
            .eq('channel', ch.channel)
            .eq('locale', ch.locale)
            .eq('status', 'PUBLISHED')
            .single()
        );

        const ov = await q(
          db.from('ntf_overrides')
            .select('*')
            .eq('tenant_id', t.id)
            .eq('template_id', ch.template_id)
            .eq('base_version', ch.template_version)
            .eq('channel', ch.channel)
            .eq('locale', ch.locale)
            .eq('status', 'PUBLISHED')
            .maybeSingle()
        );

        const content = merge(tv.content, ov?.patch);

        const ctx = {
          ...e.payload,
          recipient: {
            name: u.display_name
          },
          vars: {} as Record<string, unknown>
        };

        for (
          const [k, m] of Object.entries(
            ch.mappings ?? {}
          ) as any
        ) {
          ctx.vars[k] =
            m.type === 'STATIC'
              ? m.value
              : path(ctx, m.path);
        }

        const title = render(content.title ?? '', ctx);
        const body = render(content.body ?? '', ctx);

        await q(
          db.from('ntf_notifications').upsert(
            {
              tenant_id: t.id,
              event_id: e.id,
              user_id: id,
              purpose: r.purpose,
              title,
              body,
              design: content.design ?? {},
              action: content.action ?? null
            },
            {
              onConflict: 'event_id,user_id,purpose',
              ignoreDuplicates: true
            }
          )
        );

        const n = await q(
          db.from('ntf_notifications')
            .select('id')
            .eq('tenant_id', t.id)
            .eq('event_id', e.id)
            .eq('user_id', id)
            .eq('purpose', r.purpose)
            .single()
        );

        await q(
          db.from('ntf_deliveries').upsert(
            {
              notification_id: n.id,
              tenant_id: t.id,
              channel: ch.channel,
              status:
                ch.channel === 'IN_APP'
                  ? 'DELIVERED'
                  : 'ACCEPTED',
              rendered_payload: {
                title,
                body,
                mock: ch.channel !== 'IN_APP'
              },
              template_snapshot: {
                version: tv.version,
                override: ov?.id ?? null
              }
            },
            {
              onConflict: 'notification_id,channel',
              ignoreDuplicates: true
            }
          )
        );
      }
    }
  }
}

// Main Edge Function
Deno.serve(async req => {

  // CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers });
  }

  try {

    const rawPath = new URL(req.url).pathname;
    const p = normalizePath(req.url);

    console.log('NTF Routing:', JSON.stringify({
      rawPath,
      normalizedPath: p,
      method: req.method
    }));

    // Authentication
    const token = (
      req.headers.get('authorization') ?? ''
    )
      .replace(/^Bearer\s+/i, '')
      .trim();

    if (!token) {
      console.warn('NTF Authentication: Missing token');

      return reply({
        error: 'unauthorized'
      }, 401);
    }

    const a = await q(
      db.from('ntf_api_tokens')
        .select('*')
        .eq('token_hash', await hash(token))
        .gt('expires_at', new Date().toISOString())
        .maybeSingle()
    );

    if (!a) {
      console.warn(
        'NTF Authentication: Invalid or expired token'
      );

      return reply({
        error: 'unauthorized'
      }, 401);
    }

    console.log('NTF Authentication:', JSON.stringify({
      scope: a.scope,
      tenantId: a.tenant_id
    }));

    // Tenant validation
    const t = await q(
      db.from('ntf_tenants')
        .select('*')
        .eq('id', a.tenant_id)
        .eq('active', true)
        .maybeSingle()
    );

    if (!t) {
      return reply({
        error: 'inactive tenant'
      }, 403);
    }

    // Organization validation
    const org = req.headers.get('x-organization-id');

    if (org && org !== t.organization_id) {

      console.warn('NTF Organization mismatch');

      return reply({
        error: 'scope'
      }, 403);
    }

    // User validation
    if (a.scope === 'user') {

      const user = await q(
        db.from('ntf_users')
          .select('active')
          .eq('tenant_id', t.id)
          .eq('user_id', a.user_id)
          .maybeSingle()
      );

      if (!user?.active) {
        return reply({
          error: 'inactive'
        }, 403);
      }
    }

    const b =
      req.method === 'POST'
        ? await req.json().catch(() => ({}))
        : {};

    // ========================================
    // EVENT PUBLISHING API
    // ========================================

    if (
      p === '/v1/events/publish' &&
      req.method === 'POST' &&
      a.scope === 'service'
    ) {

      const ev = await q(
        db.from('ntf_events')
          .select('*')
          .eq('product_id', t.product_id)
          .eq('code', b.eventCode)
          .eq('version', b.schemaVersion ?? 1)
          .single()
      );

      if (
        !b.idempotencyKey ||
        b.triggerType !== ev.trigger_type ||
        !ajv.validate(ev.payload_schema, b.data ?? {})
      ) {
        return reply({
          error: 'invalid event'
        }, 400);
      }

      const id = await q(
        db.rpc('ntf_accept_event', {
          p_tenant: t.id,
          p_product: t.product_id,
          p_code: ev.code,
          p_version: ev.version,
          p_key: b.idempotencyKey,
          p_payload: b
        })
      );

      return reply({ id }, 202);
    }

    // ========================================
    // WORKER API
    // ========================================

    if (
      p === '/v1/worker' &&
      req.method === 'POST' &&
      a.scope === 'service'
    ) {

      if (token !== Deno.env.get('WORKER_TOKEN')) {
        return reply({
          error: 'forbidden'
        }, 403);
      }

      await q(db.rpc('ntf_reap_jobs'));

      const jobs = await q(
        db.rpc('ntf_claim_jobs', {
          p_limit: 10
        })
      );

      for (const j of jobs) {

        try {

          await process(j);

          await q(
            db.rpc('ntf_finish_job', {
              p_id: j.id,
              p_token: j.lease_token,
              p_success: true
            })
          );

        } catch (e) {

          console.error('NTF Worker Error:', String(e));

          await q(
            db.rpc('ntf_finish_job', {
              p_id: j.id,
              p_token: j.lease_token,
              p_success: false,
              p_error: 'processing failed'
            })
          );
        }
      }

      return reply({
        processed: jobs.length
      });
    }

    // ========================================
    // USER NOTIFICATION APIs
    // ========================================

    if (a.scope === 'user') {

      const base = () =>
        db.from('ntf_notifications')
          .select(
            '*,deliveries:ntf_deliveries!inner(channel)'
          )
          .eq('tenant_id', t.id)
          .eq('user_id', a.user_id)
          .eq('deliveries.channel', 'IN_APP');

      // Notification inbox
      if (
        p === '/v1/notifications' &&
        req.method === 'GET'
      ) {

        const items = await q(
          base()
            .order('created_at', { ascending: false })
            .limit(100)
        );

        return reply({ items });
      }

      // Unread count
      if (
        p === '/v1/notifications/unread-count' &&
        req.method === 'GET'
      ) {

        const { count, error } = await db
          .from('ntf_notifications')
          .select(
            'id,deliveries:ntf_deliveries!inner(channel)',
            {
              count: 'exact',
              head: true
            }
          )
          .eq('tenant_id', t.id)
          .eq('user_id', a.user_id)
          .eq('deliveries.channel', 'IN_APP')
          .is('read_at', null);

        if (error) {
          throw Error(error.message);
        }

        console.log('NTF Unread Count:', count ?? 0);

        return reply({
          count: count ?? 0
        });
      }

      // Mark notification as read
      const m = p.match(
        /^\/v1\/notifications\/([\w-]+)\/read$/
      );

      if (m && req.method === 'POST') {

        await q(
          db.from('ntf_notifications')
            .update({
              read_at: new Date().toISOString()
            })
            .eq('tenant_id', t.id)
            .eq('user_id', a.user_id)
            .eq('id', m[1])
        );

        return reply({
          ok: true
        });
      }
    }

    // ========================================
    // SUPER ADMIN APIs
    // ========================================

    if (
      a.scope === 'admin' &&
      p.startsWith('/v1/admin/')
    ) {

      const resource = p.split('/')[3];

      // Template preview
      if (
        p.endsWith('/preview') &&
        req.method === 'POST'
      ) {

        return reply({
          title: render(
            b.title ?? '',
            b.context ?? {}
          ),
          body: render(
            b.body ?? '',
            b.context ?? {}
          )
        });
      }

      const table = ({
        templates: 'template_versions',
        events: 'events',
        roles: 'roles',
        rules: 'rules',
        channels: 'channels',
        overrides: 'overrides',
        deliveries: 'deliveries',
        audit: 'audit_logs'
      } as Record<string, string>)[resource];

      if (!table) {
        return reply({
          error: 'not found'
        }, 404);
      }

      // Read configuration
      if (req.method === 'GET') {

        let s = db.from('ntf_' + table).select('*');

        if (resource === 'events') {
          s = s.eq('product_id', t.product_id);

        } else if (resource !== 'templates') {
          s = s.eq('tenant_id', t.id);
        }

        return reply(
          await q(s.limit(100))
        );
      }

      // Save channel configuration
      if (
        req.method === 'POST' &&
        resource === 'channels'
      ) {

        await q(
          db.from('ntf_channels').upsert({
            tenant_id: t.id,
            channel: b.channel,
            enabled: b.enabled === true
          })
        );

        return reply({
          ok: true
        });
      }

      // Save notification rule
      if (
        req.method === 'POST' &&
        resource === 'rules'
      ) {

        const row = {
          tenant_id: t.id,
          product_id: t.product_id,
          event_code: b.event_code,
          event_version: b.event_version ?? 1,
          active: b.active === true,
          conditions: b.conditions ?? {},
          recipient_strategy: b.recipient_strategy,
          role_code: b.role_code,
          purpose: b.purpose
        };

        return reply(
          await q(
            db.from('ntf_rules')
              .insert(row)
              .select()
              .single()
          )
        );
      }

      // Save template override
      if (
        req.method === 'POST' &&
        resource === 'overrides'
      ) {

        return reply(
          await q(
            db.from('ntf_overrides')
              .insert({
                tenant_id: t.id,
                template_id: b.template_id,
                base_version: b.base_version,
                channel: b.channel,
                locale: b.locale ?? 'en',
                version: b.version,
                patch: b.patch,
                status: 'PUBLISHED'
              })
              .select()
              .single()
          )
        );
      }
    }

    // ========================================
    // UNMATCHED ROUTE
    // ========================================

    console.warn(
      'NTF Route Not Matched:',
      JSON.stringify({
        rawPath,
        normalizedPath: p,
        method: req.method,
        scope: a.scope
      })
    );

    return reply({
      error: 'not found or forbidden'
    }, 404);

  } catch (e) {

    console.error('NTF Request Error:', String(e));

    return reply({
      error: 'request failed'
    }, 400);
  }
});