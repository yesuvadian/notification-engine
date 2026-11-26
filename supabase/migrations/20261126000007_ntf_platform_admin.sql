-- Platform super admin (spec §50): platform credentials, platform-level providers, organization preferences and
-- member app settings provisioned at organization creation (add-only afterwards), template lifecycle helpers.
-- Additive and idempotent: safe to run on existing DEV data and to re-run.
begin;
set local search_path = ntf, public;

-- ------------------------------------------------------------------ platform credentials
-- Opaque 'platform' tokens (scripts, CI) carry no tenant or product.
alter table ntf.ntf_api_tokens add column if not exists id uuid not null default gen_random_uuid();
create unique index if not exists ntf_api_tokens_id on ntf.ntf_api_tokens (id);
alter table ntf.ntf_api_tokens drop constraint if exists ntf_api_tokens_scope_check;
alter table ntf.ntf_api_tokens add constraint ntf_api_tokens_scope_check
  check (scope in ('service','admin','user','product','platform'));
alter table ntf.ntf_api_tokens drop constraint if exists ntf_api_tokens_binding_check;
alter table ntf.ntf_api_tokens add constraint ntf_api_tokens_binding_check check (
  (scope = 'product' and product_id is not null and tenant_id is null)
  or (scope = 'platform' and product_id is null and tenant_id is null)
  or (scope not in ('product','platform') and tenant_id is not null));

-- Logins trusted for super admins. jwks_url NULL => this Supabase project's Auth verifies the token.
-- A user is a super admin when admin_claim equals admin_value (e.g. usertype = super_admin), or, when
-- admin_claim is NULL, when the user id is listed in ntf_platform_admins.
create table if not exists ntf.ntf_platform_issuers (
  issuer text primary key,
  jwks_url text,
  audience text not null default 'authenticated',
  user_id_claim text not null default 'sub',
  admin_claim text,
  admin_value text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  check ((admin_claim is null) = (admin_value is null))
);
create table if not exists ntf.ntf_platform_admins (
  issuer text not null references ntf.ntf_platform_issuers on delete cascade,
  user_id text not null,
  display_name text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  primary key (issuer, user_id)
);

-- Platform switches. org_admin_writes = false: organization admins can read the admin APIs but not change
-- anything; the super admin manages every organization in this phase.
create table if not exists ntf.ntf_platform_settings (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);
insert into ntf.ntf_platform_settings(key, value) values ('org_admin_writes', 'false') on conflict (key) do nothing;

-- ------------------------------------------------------------------ platform-level providers
create table if not exists ntf.ntf_platform_channels (
  channel text primary key check (channel in ('PUSH','SMS','WHATSAPP')),
  provider_config jsonb not null default '{}',
  updated_at timestamptz not null default now(),
  updated_by text
);
create or replace function ntf.ntf_check_platform_secret() returns trigger language plpgsql set search_path = '' as $$
begin
  if new.provider_config ? 'secret_name' and (new.provider_config->>'secret_name') not like 'ntf\_shared\_%' then
    raise exception 'platform secret_name must start with ntf_shared_' using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists ntf_platform_channels_secret_scope on ntf.ntf_platform_channels;
create trigger ntf_platform_channels_secret_scope before insert or update on ntf.ntf_platform_channels
  for each row execute function ntf.ntf_check_platform_secret();

-- Effective provider: the platform provider when one is configured (no product or organization override in
-- this phase). Without a platform row, the earlier organization/product settings keep working.
create or replace function ntf.ntf_effective_channel_config(p_tenant uuid, p_channel text) returns jsonb
language sql stable set search_path = '' as $$
  select coalesce(
    (select pc.provider_config || jsonb_build_object('_source', 'platform') from ntf.ntf_platform_channels pc
      where pc.channel = p_channel and pc.provider_config ? 'provider'),
    (select c.provider_config from ntf.ntf_channels c where c.tenant_id = p_tenant and c.channel = p_channel and c.provider_config ? 'provider'),
    (select d.provider_config || jsonb_build_object('_source', 'product') from ntf.ntf_product_channel_defaults d
       join ntf.ntf_tenants t on t.product_id = d.product_id
      where t.id = p_tenant and d.channel = p_channel and d.provider_config ? 'provider'),
    '{}'::jsonb);
$$;

-- Platform secret used by test sends before any tenant exists.
create or replace function ntf.ntf_get_platform_secret(p_channel text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare n text; v text;
begin
  select provider_config->>'secret_name' into n from ntf.ntf_platform_channels where channel = p_channel;
  if n is null then return null; end if;
  if n not like 'ntf\_shared\_%' then raise exception 'platform secret % out of scope', n using errcode = '42501'; end if;
  select decrypted_secret into v from vault.decrypted_secrets where name = n;
  if v is null then raise exception 'missing vault secret %', n using errcode = 'P0002'; end if;
  return v::jsonb;
end $$;

-- Write-only credential store: creates or replaces ntf_shared_<channel> in Vault and points the platform channel
-- at it. The value is never returned.
create or replace function ntf.ntf_set_platform_secret(p_channel text, p_value jsonb, p_actor text default null) returns text
language plpgsql security definer set search_path = '' as $$
declare n text := 'ntf_shared_' || lower(p_channel); sid uuid;
begin
  if p_channel not in ('PUSH','SMS','WHATSAPP') then raise exception 'unknown channel %', p_channel using errcode = '22023'; end if;
  if p_value is null or jsonb_typeof(p_value) <> 'object' then raise exception 'secret must be a JSON object' using errcode = '22023'; end if;
  select id into sid from vault.secrets where name = n;
  if sid is null then
    perform vault.create_secret(p_value::text, n, 'notification platform provider credentials');
  else
    perform vault.update_secret(sid, p_value::text, n, 'notification platform provider credentials');
  end if;
  insert into ntf.ntf_platform_channels(channel, provider_config, updated_by)
    values (p_channel, jsonb_build_object('secret_name', n), p_actor)
    on conflict (channel) do update set provider_config = ntf.ntf_platform_channels.provider_config || jsonb_build_object('secret_name', n),
      updated_at = now(), updated_by = p_actor;
  return n;
end $$;

-- ------------------------------------------------------------------ organization preferences (add-only)
-- Which channels each notification group (event module_code) goes out on for an organization. Chosen when the
-- super admin creates the organization (PROVISIONED); later the super admin can only add (ADDED).
create table if not exists ntf.ntf_org_preferences (
  tenant_id uuid not null references ntf.ntf_tenants,
  group_code text not null,
  channel text not null check (channel in ('IN_APP','PUSH','SMS','WHATSAPP')),
  source text not null check (source in ('PROVISIONED','ADDED')),
  created_at timestamptz not null default now(),
  created_by text,
  primary key (tenant_id, group_code, channel)
);
create or replace function ntf.ntf_org_preferences_add_only() returns trigger language plpgsql set search_path = '' as $$
begin
  if coalesce(current_setting('ntf.allow_preference_removal', true), '') = 'on' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  raise exception 'organization preferences are add-only' using errcode = '42501';
end $$;
drop trigger if exists ntf_org_preferences_add_only on ntf.ntf_org_preferences;
create trigger ntf_org_preferences_add_only before update or delete on ntf.ntf_org_preferences
  for each row execute function ntf.ntf_org_preferences_add_only();

-- Member app settings (C1 preferences page, C2 inbox, C3 push permission), also add-only.
create table if not exists ntf.ntf_org_settings (
  tenant_id uuid primary key references ntf.ntf_tenants,
  inbox_retention_days integer not null default 90 check (inbox_retention_days between 7 and 3650),
  unread_badge boolean not null default true,
  group_by_day boolean not null default true,
  push_prompt text not null default 'off' check (push_prompt in ('off','after_first_notification','first_login')),
  push_explanation text check (char_length(push_explanation) <= 200),
  members_can_change boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create or replace function ntf.ntf_org_settings_add_only() returns trigger language plpgsql set search_path = '' as $$
begin
  if coalesce(current_setting('ntf.allow_preference_removal', true), '') = 'on' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  if tg_op = 'DELETE'
     or new.inbox_retention_days < old.inbox_retention_days
     or (old.unread_badge and not new.unread_badge)
     or (old.group_by_day and not new.group_by_day)
     or (old.push_prompt <> 'off' and new.push_prompt = 'off')
     or (old.members_can_change and not new.members_can_change) then
    raise exception 'organization settings are add-only: provisioned values cannot be reduced' using errcode = '42501';
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists ntf_org_settings_add_only on ntf.ntf_org_settings;
create trigger ntf_org_settings_add_only before update or delete on ntf.ntf_org_settings
  for each row execute function ntf.ntf_org_settings_add_only();

-- Managed organizations (those with settings) cannot have a channel switched off.
create or replace function ntf.ntf_channels_add_only() returns trigger language plpgsql set search_path = '' as $$
begin
  if coalesce(current_setting('ntf.allow_preference_removal', true), '') = 'on' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  if exists (select 1 from ntf.ntf_org_settings s where s.tenant_id = old.tenant_id)
     and old.enabled and (tg_op = 'DELETE' or not new.enabled) then
    raise exception 'channel % was provisioned for this organization and cannot be turned off', old.channel using errcode = '42501';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;
drop trigger if exists ntf_channels_add_only on ntf.ntf_channels;
create trigger ntf_channels_add_only before update or delete on ntf.ntf_channels
  for each row execute function ntf.ntf_channels_add_only();

-- Create an organization with its preferences and member app settings in one step.
--   p_preferences: {"COLLECTIONS": ["IN_APP","SMS"], "VISITORS": ["IN_APP","PUSH"]}
--   p_settings:    {"inbox_retention_days": 90, "push_prompt": "after_first_notification", ...}
-- Every channel named in the preferences is turned on (it must be supported by the product). IN_APP is always on.
create or replace function ntf.ntf_provision_org(p_product_code text, p_org uuid, p_org_name text,
  p_preferences jsonb default '{}', p_settings jsonb default '{}', p_actor text default null)
returns jsonb language plpgsql set search_path = '' as $$
declare r jsonb; tid uuid; g text; chans jsonb; c text; channels jsonb := '{"IN_APP": true}'::jsonb; s jsonb := coalesce(p_settings, '{}');
begin
  if jsonb_typeof(coalesce(p_preferences, '{}')) <> 'object' then raise exception 'preferences must be an object' using errcode = '22023'; end if;
  if exists (select 1 from ntf.ntf_org_settings os join ntf.ntf_tenants t on t.id = os.tenant_id
             join ntf.ntf_products p on p.id = t.product_id where p.code = p_product_code and t.organization_id = p_org) then
    raise exception 'organization is already provisioned; add channels instead' using errcode = '23505';
  end if;
  for g, chans in select * from jsonb_each(coalesce(p_preferences, '{}')) loop
    if g !~ '^[A-Za-z0-9_.-]{1,100}$' then raise exception 'invalid group %', g using errcode = '22023'; end if;
    if jsonb_typeof(chans) <> 'array' then raise exception 'preferences.% must be a channel array', g using errcode = '22023'; end if;
    for c in select upper(x) from jsonb_array_elements_text(chans) x loop
      channels := channels || jsonb_build_object(c, true);
    end loop;
  end loop;
  r := ntf.ntf_assign_org(p_product_code, p_org, p_org_name, channels);
  tid := (r->>'tenantId')::uuid;
  for g, chans in select * from jsonb_each(coalesce(p_preferences, '{}')) loop
    insert into ntf.ntf_org_preferences(tenant_id, group_code, channel, source, created_by)
      select tid, upper(g), upper(x), 'PROVISIONED', p_actor from jsonb_array_elements_text(chans) x
      on conflict do nothing;
  end loop;
  insert into ntf.ntf_org_settings(tenant_id, inbox_retention_days, unread_badge, group_by_day, push_prompt, push_explanation, members_can_change)
  values (tid, coalesce((s->>'inbox_retention_days')::int, 90), coalesce((s->>'unread_badge')::boolean, true),
          coalesce((s->>'group_by_day')::boolean, true), coalesce(s->>'push_prompt', case when channels ? 'PUSH' then 'after_first_notification' else 'off' end),
          s->>'push_explanation', coalesce((s->>'members_can_change')::boolean, false));
  return r;
end $$;

-- Add channels to groups of an existing organization. The channel must already be on for the organization.
create or replace function ntf.ntf_add_org_preferences(p_tenant uuid, p_items jsonb, p_actor text default null) returns integer
language plpgsql set search_path = '' as $$
declare it jsonb; n integer := 0; g text; c text;
begin
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]')) loop
    g := upper(it->>'group'); c := upper(it->>'channel');
    if g is null or g !~ '^[A-Z0-9_.-]{1,100}$' then raise exception 'invalid group' using errcode = '22023'; end if;
    if not exists (select 1 from ntf.ntf_channels where tenant_id = p_tenant and channel = c and enabled) then
      raise exception 'channel % is not on for this organization; add the channel first', c using errcode = '22023';
    end if;
    insert into ntf.ntf_org_preferences(tenant_id, group_code, channel, source, created_by)
      values (p_tenant, g, c, 'ADDED', p_actor) on conflict do nothing;
    if found then n := n + 1; end if;
  end loop;
  return n;
end $$;

-- ------------------------------------------------------------------ template lifecycle
alter table ntf.ntf_template_versions add column if not exists created_at timestamptz not null default now();
alter table ntf.ntf_template_versions add column if not exists published_at timestamptz;
alter table ntf.ntf_templates add column if not exists description text;

-- Latest published version of a template for a channel/locale (what new organizations start on).
create or replace function ntf.ntf_latest_template_version(p_template uuid, p_channel text, p_locale text) returns integer
language sql stable set search_path = '' as $$
  select max(version) from ntf.ntf_template_versions
   where template_id = p_template and channel = p_channel and locale = p_locale and status = 'PUBLISHED';
$$;

-- Move one organization to the latest (or a given) published version of a template. Overrides are carried over
-- to the new base version; rule channels without that version for their channel/locale are left as they are.
create or replace function ntf.ntf_upgrade_org_template(p_tenant uuid, p_template uuid, p_to_version integer default null)
returns jsonb language plpgsql set search_path = '' as $$
declare rc record; target integer; moved integer := 0; skipped integer := 0; ov record; carried integer := 0;
begin
  for rc in select * from ntf.ntf_rule_channels where tenant_id = p_tenant and template_id = p_template for update loop
    target := coalesce(p_to_version, ntf.ntf_latest_template_version(p_template, rc.channel, rc.locale));
    if target is null or target <= rc.template_version or not exists (
      select 1 from ntf.ntf_template_versions where template_id = p_template and version = target
        and channel = rc.channel and locale = rc.locale and status = 'PUBLISHED') then
      skipped := skipped + 1; continue;
    end if;
    select * into ov from ntf.ntf_overrides where tenant_id = p_tenant and template_id = p_template and channel = rc.channel
      and locale = rc.locale and base_version = rc.template_version and status = 'PUBLISHED';
    if found and not exists (select 1 from ntf.ntf_overrides where tenant_id = p_tenant and template_id = p_template
        and channel = rc.channel and locale = rc.locale and base_version = target and status = 'PUBLISHED') then
      update ntf.ntf_overrides set status = 'RETIRED' where id = ov.id;
      insert into ntf.ntf_overrides(tenant_id, template_id, base_version, channel, locale, version, patch, status)
        values (p_tenant, p_template, target, rc.channel, rc.locale,
          (select coalesce(max(version), 0) + 1 from ntf.ntf_overrides where tenant_id = p_tenant and template_id = p_template
             and channel = rc.channel and locale = rc.locale), ov.patch, 'PUBLISHED');
      carried := carried + 1;
    end if;
    update ntf.ntf_rule_channels set template_version = target where rule_id = rc.rule_id and channel = rc.channel;
    moved := moved + 1;
  end loop;
  return jsonb_build_object('upgraded', moved, 'skipped', skipped, 'overridesCarried', carried);
end $$;

-- Organization list for the super admin console (one query instead of one per organization).
create or replace function ntf.ntf_platform_org_summary(p_product uuid, p_search text default null, p_limit integer default 100, p_offset integer default 0)
returns table (tenant_id uuid, organization_id uuid, name text, active boolean, managed boolean, channels text[], users bigint, sent_7d bigint)
language sql stable set search_path = '' as $$
  select t.id, t.organization_id, o.name, t.active,
    exists (select 1 from ntf.ntf_org_settings s where s.tenant_id = t.id),
    coalesce((select array_agg(c.channel order by c.channel) from ntf.ntf_channels c where c.tenant_id = t.id and c.enabled), '{}'),
    (select count(*) from ntf.ntf_users u where u.tenant_id = t.id and u.active),
    (select count(*) from ntf.ntf_deliveries d where d.tenant_id = t.id and d.created_at > now() - interval '7 days')
  from ntf.ntf_tenants t join ntf.ntf_organizations o on o.id = t.organization_id
  where t.product_id = p_product and (p_search is null or o.name ilike '%' || p_search || '%' or t.organization_id::text = p_search)
  order by o.name limit least(greatest(p_limit, 1), 500) offset greatest(p_offset, 0);
$$;

-- ------------------------------------------------------------------ operations
create or replace function ntf.ntf_dlq_list(p_limit integer default 50)
returns table (msg_id bigint, enqueued_at timestamptz, message jsonb)
language sql security definer set search_path = '' as $$
  select q.msg_id, q.enqueued_at, q.message from pgmq.q_ntf_dlq q order by q.msg_id desc limit least(greatest(p_limit, 1), 200);
$$;

-- Views with spec names
create or replace view ntf.org_preferences with (security_invoker = true) as select * from ntf.ntf_org_preferences;
create or replace view ntf.org_settings with (security_invoker = true) as select * from ntf.ntf_org_settings;
create or replace view ntf.platform_channels with (security_invoker = true) as select * from ntf.ntf_platform_channels;

alter table ntf.ntf_platform_issuers enable row level security;
alter table ntf.ntf_platform_admins enable row level security;
alter table ntf.ntf_platform_settings enable row level security;
alter table ntf.ntf_platform_channels enable row level security;
alter table ntf.ntf_org_preferences enable row level security;
alter table ntf.ntf_org_settings enable row level security;

revoke all on all tables in schema ntf from public, anon, authenticated;
grant all on all tables in schema ntf to service_role;
revoke all on all functions in schema ntf from public, anon, authenticated;
grant execute on all functions in schema ntf to service_role;
commit;
