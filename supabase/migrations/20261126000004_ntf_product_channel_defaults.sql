-- Product channel defaults (spec §4 "Product defaults and effective channels", §5 product_channel_defaults)
-- and a helper to assign an organization to a product. Additive and idempotent.
begin;
set local search_path = ntf, public;

create table if not exists ntf.ntf_product_channel_defaults (
  product_id uuid not null references ntf.ntf_products,
  channel text not null check (channel in ('IN_APP','PUSH','SMS','WHATSAPP')),
  supported boolean not null default true,
  default_enabled boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key (product_id, channel),
  check (supported or not default_enabled)
);
alter table ntf.ntf_product_channel_defaults enable row level security;
create or replace view ntf.product_channel_defaults with (security_invoker = true) as select * from ntf.ntf_product_channel_defaults;

-- Tenant provisioning now starts from the product defaults; p_channels ({"sms": true}) overrides them.
-- Enabling a channel the product does not support is rejected. Existing tenant channel rows are only
-- changed when p_channels names them, so re-provisioning never resets an admin's choices.
create or replace function ntf.ntf_provision_tenant(p_product uuid, p_org uuid, p_org_name text, p_channels jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare tid uuid; c text; v jsonb; has_defaults boolean;
begin
  insert into ntf.ntf_organizations(id, name) values (p_org, coalesce(p_org_name, p_org::text)) on conflict (id) do nothing;
  insert into ntf.ntf_tenants(product_id, organization_id) values (p_product, p_org) on conflict (product_id, organization_id) do nothing;
  select id into tid from ntf.ntf_tenants where product_id = p_product and organization_id = p_org;
  select exists (select 1 from ntf.ntf_product_channel_defaults where product_id = p_product) into has_defaults;

  insert into ntf.ntf_channels(tenant_id, channel, enabled)
    select tid, d.channel, d.default_enabled from ntf.ntf_product_channel_defaults d
    where d.product_id = p_product and d.supported
    on conflict do nothing;
  if not has_defaults then
    insert into ntf.ntf_channels(tenant_id, channel, enabled) values (tid, 'IN_APP', true) on conflict do nothing;
  end if;

  for c, v in select * from jsonb_each(coalesce(p_channels, '{}'::jsonb)) loop
    c := upper(c);
    if c not in ('IN_APP','PUSH','SMS','WHATSAPP') then raise exception 'unknown channel %', c using errcode = '22023'; end if;
    if v = 'true'::jsonb and has_defaults and not exists (
      select 1 from ntf.ntf_product_channel_defaults where product_id = p_product and channel = c and supported) then
      raise exception 'channel % is not supported by this product', c using errcode = '22023';
    end if;
    insert into ntf.ntf_channels(tenant_id, channel, enabled) values (tid, c, v = 'true'::jsonb)
      on conflict (tenant_id, channel) do update set enabled = excluded.enabled;
  end loop;
  return jsonb_build_object('tenantId', tid, 'status', (select case when active then 'ACTIVE' else 'SUSPENDED' end from ntf.ntf_tenants where id = tid));
end $$;

-- SQL helper for operators: select ntf.ntf_assign_org('ast', '<org uuid>', 'Org name');
create or replace function ntf.ntf_assign_org(p_product_code text, p_org uuid, p_org_name text default null, p_channels jsonb default '{}')
returns jsonb language plpgsql set search_path = '' as $$
declare pid uuid;
begin
  select id into pid from ntf.ntf_products where code = p_product_code;
  if pid is null then raise exception 'unknown product %', p_product_code using errcode = '22023'; end if;
  return ntf.ntf_provision_tenant(pid, p_org, p_org_name, p_channels) || jsonb_build_object('productCode', p_product_code, 'organizationId', p_org);
end $$;

revoke all on all tables in schema ntf from public, anon, authenticated;
grant all on all tables in schema ntf to service_role;
revoke all on all functions in schema ntf from public, anon, authenticated;
grant execute on all functions in schema ntf to service_role;
commit;
