// Phase 1 worker: legacy ntf_jobs queue (one job per event). Replaced by pgmq in phase 2.
import { db, q } from './db.ts';
import { path, merge, render } from './parser.mjs';

// Notification processing
export async function processEventJob(job: any) {

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

