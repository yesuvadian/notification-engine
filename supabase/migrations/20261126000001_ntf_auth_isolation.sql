-- Phase 1: authentication adapters, identity sync, product isolation, idempotency conflicts, audit.
-- Additive and safe on existing DEV data: no table or column is dropped or renamed.
begin;
set local search_path = ntf, public;

-- Product / organization status (spec §5)
alter table ntf.ntf_products add column if not exists status text not null default 'ACTIVE';
alter table ntf.ntf_products drop constraint if exists ntf_products_status_check;
alter table ntf.ntf_products add constraint ntf_products_status_check check (status in ('ACTIVE','SUSPENDED','RETIRED'));
alter table ntf.ntf_organizations add column if not exists organization_code text;
alter table ntf.ntf_organizations add column if not exists status text not null default 'ACTIVE';
alter table ntf.ntf_tenants add column if not exists created_at timestamptz not null default now();

-- Template product scope (spec §21). product_id NULL = shared platform master visible to every product.
alter table ntf.ntf_templates add column if not exists product_id uuid references ntf.ntf_products;
alter table ntf.ntf_templates add column if not exists name text;
alter table ntf.ntf_templates drop constraint if exists ntf_templates_code_key;
create unique index if not exists ntf_templates_scope_code on ntf.ntf_templates (coalesce(product_id, '00000000-0000-0000-0000-000000000000'::uuid), code);

-- A tenant may only bind or override templates that are shared or belong to its own product.
create or replace function ntf.ntf_check_template_scope() returns trigger language plpgsql set search_path = '' as $$
declare tp uuid; tpl uuid;
begin
  select product_id into tp from ntf.ntf_tenants where id = new.tenant_id;
  select product_id into tpl from ntf.ntf_templates where id = new.template_id;
  if tpl is not null and tpl is distinct from tp then
    raise exception 'template % is not available to tenant %', new.template_id, new.tenant_id using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists ntf_rule_channels_template_scope on ntf.ntf_rule_channels;
create trigger ntf_rule_channels_template_scope before insert or update on ntf.ntf_rule_channels for each row execute function ntf.ntf_check_template_scope();
drop trigger if exists ntf_overrides_template_scope on ntf.ntf_overrides;
create trigger ntf_overrides_template_scope before insert or update on ntf.ntf_overrides for each row execute function ntf.ntf_check_template_scope();

-- Identity projections (spec §40, §42): synced by products through the API, never written by products directly.
alter table ntf.ntf_users add column if not exists locale text;
alter table ntf.ntf_users add column if not exists updated_at timestamptz not null default now();
alter table ntf.ntf_roles add column if not exists active boolean not null default true;
alter table ntf.ntf_roles add column if not exists notification_admin boolean not null default false;
alter table ntf.ntf_roles add column if not exists updated_at timestamptz not null default now();

-- Trusted JWT issuers per product (spec §11, §40). jwks_url NULL + the engine's own Supabase issuer
-- means "same Supabase project": the token is verified with Supabase Auth.
create table if not exists ntf.ntf_identity_issuers (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references ntf.ntf_products,
  issuer text not null,
  audience text not null default 'authenticated',
  jwks_url text,
  user_id_claim text not null default 'sub',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (product_id, issuer)
);

-- Product-level service credentials (one token per product, tenant chosen by X-Organization-Id).
alter table ntf.ntf_api_tokens add column if not exists product_id uuid references ntf.ntf_products;
alter table ntf.ntf_api_tokens add column if not exists label text;
alter table ntf.ntf_api_tokens add column if not exists created_at timestamptz not null default now();
alter table ntf.ntf_api_tokens add column if not exists revoked_at timestamptz;
update ntf.ntf_api_tokens k set product_id = t.product_id from ntf.ntf_tenants t where k.tenant_id = t.id and k.product_id is null;
alter table ntf.ntf_api_tokens alter column tenant_id drop not null;
alter table ntf.ntf_api_tokens drop constraint if exists ntf_api_tokens_scope_check;
alter table ntf.ntf_api_tokens add constraint ntf_api_tokens_scope_check check (scope in ('service','admin','user','product'));
alter table ntf.ntf_api_tokens drop constraint if exists ntf_api_tokens_binding_check;
alter table ntf.ntf_api_tokens add constraint ntf_api_tokens_binding_check check (
  (scope = 'product' and product_id is not null and tenant_id is null) or (scope <> 'product' and tenant_id is not null));
create index if not exists ntf_api_tokens_expiry on ntf.ntf_api_tokens (expires_at);

-- Idempotency conflict detection (spec §5, §40: reused key + different payload => 409)
alter table ntf.ntf_event_log add column if not exists payload_hash text;
update ntf.ntf_event_log set payload_hash = encode(sha256(convert_to(payload::text, 'UTF8')), 'hex') where payload_hash is null;
alter table ntf.ntf_event_log add column if not exists correlation_id text;

-- Returns {event_id, status}: status = ACCEPTED | DUPLICATE | CONFLICT
create or replace function ntf.ntf_accept_event_v2(p_tenant uuid, p_product uuid, p_code text, p_version int, p_key text, p_payload jsonb, p_correlation text default null)
returns jsonb language plpgsql set search_path = '' as $$
declare eid uuid; h text := encode(sha256(convert_to(p_payload::text, 'UTF8')), 'hex'); old_hash text;
begin
  insert into ntf.ntf_event_log(tenant_id, product_id, event_code, event_version, idempotency_key, payload, payload_hash, correlation_id)
  values (p_tenant, p_product, p_code, p_version, p_key, p_payload, h, p_correlation)
  on conflict (tenant_id, idempotency_key) do nothing returning id into eid;
  if eid is not null then
    insert into ntf.ntf_jobs(tenant_id, kind, payload) values (p_tenant, 'EVENT', jsonb_build_object('event_id', eid));
    return jsonb_build_object('event_id', eid, 'status', 'ACCEPTED');
  end if;
  select id, payload_hash into eid, old_hash from ntf.ntf_event_log where tenant_id = p_tenant and idempotency_key = p_key;
  if old_hash is distinct from h then
    return jsonb_build_object('event_id', eid, 'status', 'CONFLICT');
  end if;
  return jsonb_build_object('event_id', eid, 'status', 'DUPLICATE');
end $$;

-- Atomic identity sync for one tenant. p_users: [{userId, displayName, email, phone, locale, active, roles?}]
-- When "roles" is present it replaces that user's memberships (unknown role codes are rejected).
create or replace function ntf.ntf_sync_users(p_tenant uuid, p_users jsonb) returns jsonb language plpgsql set search_path = '' as $$
declare u jsonb; n int := 0; bad text;
begin
  if jsonb_typeof(p_users) <> 'array' then raise exception 'users must be an array' using errcode = '22023'; end if;
  for u in select * from jsonb_array_elements(p_users) loop
    if coalesce(u->>'userId', '') = '' then raise exception 'userId required' using errcode = '22023'; end if;
    insert into ntf.ntf_users(tenant_id, user_id, display_name, email, phone, locale, active, updated_at)
    values (p_tenant, u->>'userId', u->>'displayName', u->>'email', u->>'phone', u->>'locale', coalesce((u->>'active')::boolean, true), now())
    on conflict (tenant_id, user_id) do update set
      display_name = coalesce(excluded.display_name, ntf.ntf_users.display_name),
      email = case when u ? 'email' then excluded.email else ntf.ntf_users.email end,
      phone = case when u ? 'phone' then excluded.phone else ntf.ntf_users.phone end,
      locale = case when u ? 'locale' then excluded.locale else ntf.ntf_users.locale end,
      active = excluded.active, updated_at = now();
    if u ? 'roles' then
      select string_agg(r, ',') into bad from jsonb_array_elements_text(u->'roles') r
        where not exists (select 1 from ntf.ntf_roles x where x.tenant_id = p_tenant and x.code = r and x.active);
      if bad is not null then raise exception 'unknown or inactive roles: %', bad using errcode = '22023'; end if;
      delete from ntf.ntf_user_roles where tenant_id = p_tenant and user_id = u->>'userId'
        and role_code not in (select jsonb_array_elements_text(u->'roles'));
      insert into ntf.ntf_user_roles(tenant_id, user_id, role_code)
        select p_tenant, u->>'userId', r from jsonb_array_elements_text(u->'roles') r on conflict do nothing;
    end if;
    n := n + 1;
  end loop;
  return jsonb_build_object('synced', n);
end $$;

-- p_roles: [{code, name, active?, notificationAdmin?}]. Roles are deactivated, never deleted (rules reference them).
create or replace function ntf.ntf_sync_roles(p_tenant uuid, p_roles jsonb) returns jsonb language plpgsql set search_path = '' as $$
declare r jsonb; n int := 0;
begin
  if jsonb_typeof(p_roles) <> 'array' then raise exception 'roles must be an array' using errcode = '22023'; end if;
  for r in select * from jsonb_array_elements(p_roles) loop
    if coalesce(r->>'code', '') = '' then raise exception 'role code required' using errcode = '22023'; end if;
    insert into ntf.ntf_roles(tenant_id, code, name, active, notification_admin, updated_at)
    values (p_tenant, r->>'code', coalesce(r->>'name', r->>'code'), coalesce((r->>'active')::boolean, true), coalesce((r->>'notificationAdmin')::boolean, false), now())
    on conflict (tenant_id, code) do update set name = excluded.name, active = excluded.active,
      notification_admin = case when r ? 'notificationAdmin' then excluded.notification_admin else ntf.ntf_roles.notification_admin end,
      updated_at = now();
    if not coalesce((r->>'active')::boolean, true) then
      delete from ntf.ntf_user_roles where tenant_id = p_tenant and role_code = r->>'code';
    end if;
    n := n + 1;
  end loop;
  return jsonb_build_object('synced', n);
end $$;

-- Idempotent tenant provisioning for product-level credentials (spec §6, §40).
create or replace function ntf.ntf_provision_tenant(p_product uuid, p_org uuid, p_org_name text, p_channels jsonb) returns jsonb language plpgsql set search_path = '' as $$
declare tid uuid; c text; v jsonb;
begin
  insert into ntf.ntf_organizations(id, name) values (p_org, coalesce(p_org_name, p_org::text)) on conflict (id) do nothing;
  insert into ntf.ntf_tenants(product_id, organization_id) values (p_product, p_org) on conflict (product_id, organization_id) do nothing;
  select id into tid from ntf.ntf_tenants where product_id = p_product and organization_id = p_org;
  insert into ntf.ntf_channels(tenant_id, channel, enabled) values (tid, 'IN_APP', true) on conflict do nothing;
  for c, v in select * from jsonb_each(coalesce(p_channels, '{}'::jsonb)) loop
    if upper(c) not in ('IN_APP','PUSH','SMS','WHATSAPP') then raise exception 'unknown channel %', c using errcode = '22023'; end if;
    insert into ntf.ntf_channels(tenant_id, channel, enabled) values (tid, upper(c), v = 'true'::jsonb)
      on conflict (tenant_id, channel) do update set enabled = excluded.enabled;
  end loop;
  return jsonb_build_object('tenantId', tid, 'status', (select case when active then 'ACTIVE' else 'SUSPENDED' end from ntf.ntf_tenants where id = tid));
end $$;

-- Audit (spec §11, §40)
alter table ntf.ntf_audit_logs add column if not exists product_id uuid;
alter table ntf.ntf_audit_logs add column if not exists correlation_id text;
create index if not exists ntf_audit_tenant_time on ntf.ntf_audit_logs (tenant_id, created_at desc);

-- Inbox pagination
create index if not exists ntf_inbox_cursor_idx on ntf.ntf_notifications (tenant_id, user_id, created_at desc, id desc);

-- Spec-named, read-only compatibility views (spec §5 names; physical tables keep ntf_* names).
create or replace view ntf.products with (security_invoker = true) as
  select id, code as product_code, name as display_name, status from ntf.ntf_products;
create or replace view ntf.product_tenants with (security_invoker = true) as
  select id, product_id, organization_id, case when active then 'ACTIVE' else 'SUSPENDED' end as status, created_at from ntf.ntf_tenants;
create or replace view ntf.in_app_notifications with (security_invoker = true) as
  select n.id, n.tenant_id, n.user_id as external_user_id, n.id as notification_id, n.title, n.body, n.action, n.read_at, n.created_at
  from ntf.ntf_notifications n where exists (select 1 from ntf.ntf_deliveries d where d.notification_id = n.id and d.channel = 'IN_APP');
create or replace view ntf.notification_events with (security_invoker = true) as
  select product_id, code as event_code, version, module_code, trigger_type, metadata, payload_schema from ntf.ntf_events;
create or replace view ntf.platform_templates with (security_invoker = true) as
  select t.id, t.product_id, t.code as template_code, v.version, v.channel, v.locale, v.content, v.variables, v.status
  from ntf.ntf_templates t join ntf.ntf_template_versions v on v.template_id = t.id;
create or replace view ntf.tenant_template_overrides with (security_invoker = true) as select * from ntf.ntf_overrides;
create or replace view ntf.tenant_notification_channels with (security_invoker = true) as select tenant_id, channel, enabled from ntf.ntf_channels;
create or replace view ntf.notification_rules with (security_invoker = true) as select * from ntf.ntf_rules;
create or replace view ntf.notification_deliveries with (security_invoker = true) as select * from ntf.ntf_deliveries;
create or replace view ntf.audit_logs with (security_invoker = true) as select * from ntf.ntf_audit_logs;

-- Keep the API-only boundary for everything new.
alter table ntf.ntf_identity_issuers enable row level security;
revoke all on all tables in schema ntf from public, anon, authenticated;
grant all on all tables in schema ntf to service_role;
grant usage, select on all sequences in schema ntf to service_role;
revoke all on all functions in schema ntf from public, anon, authenticated;
grant execute on all functions in schema ntf to service_role;
commit;
