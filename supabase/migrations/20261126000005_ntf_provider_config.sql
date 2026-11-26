-- Provider-agnostic channel configuration. Additive and idempotent.
--  * Product-level provider defaults (ntf_product_channel_defaults.provider_config), used by every organization
--    of the product unless the organization's ntf_channels.provider_config names its own provider.
--  * Consent can be recorded by the product backend through /v1/users/sync ("consents": {"SMS": true}).
begin;
set local search_path = ntf, public;

alter table ntf.ntf_product_channel_defaults add column if not exists provider_config jsonb not null default '{}';

-- Product-level secrets must be product- or platform-scoped.
create or replace function ntf.ntf_check_product_secret() returns trigger language plpgsql set search_path = '' as $$
declare code text;
begin
  if new.provider_config ? 'secret_name' then
    select p.code into code from ntf.ntf_products p where p.id = new.product_id;
    if not ((new.provider_config->>'secret_name') like 'ntf\_shared\_%' or (new.provider_config->>'secret_name') like 'ntf\_p\_' || code || '\_%') then
      raise exception 'product secret_name must start with ntf_p_%_ or ntf_shared_', code using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists ntf_product_defaults_secret_scope on ntf.ntf_product_channel_defaults;
create trigger ntf_product_defaults_secret_scope before insert or update on ntf.ntf_product_channel_defaults
  for each row execute function ntf.ntf_check_product_secret();

-- Effective provider config: organization override when it names a provider, otherwise the product default.
create or replace function ntf.ntf_effective_channel_config(p_tenant uuid, p_channel text) returns jsonb
language sql stable set search_path = '' as $$
  select coalesce(
    (select c.provider_config from ntf.ntf_channels c where c.tenant_id = p_tenant and c.channel = p_channel and c.provider_config ? 'provider'),
    (select d.provider_config || jsonb_build_object('_source', 'product') from ntf.ntf_product_channel_defaults d
       join ntf.ntf_tenants t on t.product_id = d.product_id
      where t.id = p_tenant and d.channel = p_channel and d.provider_config ? 'provider'),
    '{}'::jsonb);
$$;

create or replace function ntf.ntf_get_provider_secret(p_tenant uuid, p_channel text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare n text; v text;
begin
  n := ntf.ntf_effective_channel_config(p_tenant, p_channel)->>'secret_name';
  if n is null then return null; end if;
  if not ntf.ntf_secret_allowed(p_tenant, n) then
    raise exception 'secret % is not in scope for tenant %', n, p_tenant using errcode = '42501';
  end if;
  select decrypted_secret into v from vault.decrypted_secrets where name = n;
  if v is null then raise exception 'missing vault secret %', n using errcode = 'P0002'; end if;
  return v::jsonb;
end $$;

-- User sync with optional consents: {"userId":"u1","phone":"+91...","consents":{"SMS":true,"WHATSAPP":false}}
-- Consent rows are written only for channels the organization has configured.
create or replace function ntf.ntf_sync_users(p_tenant uuid, p_users jsonb) returns jsonb language plpgsql set search_path = '' as $$
declare u jsonb; n int := 0; bad text; c text; v jsonb;
begin
  if jsonb_typeof(p_users) <> 'array' then raise exception 'users must be an array' using errcode = '22023'; end if;
  for u in select * from jsonb_array_elements(p_users) loop
    if coalesce(u->>'userId', '') = '' then raise exception 'userId required' using errcode = '22023'; end if;
    if u ? 'phone' and u->>'phone' is not null and (u->>'phone') !~ '^\+[1-9][0-9]{6,14}$' then
      raise exception 'phone for % must be E.164, e.g. +919876543210', u->>'userId' using errcode = '22023';
    end if;
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
    if jsonb_typeof(u->'consents') = 'object' then
      for c, v in select * from jsonb_each(u->'consents') loop
        c := upper(c);
        if c not in ('PUSH','SMS','WHATSAPP') then raise exception 'unknown consent channel %', c using errcode = '22023'; end if;
        if exists (select 1 from ntf.ntf_channels where tenant_id = p_tenant and channel = c) then
          insert into ntf.ntf_preferences(tenant_id, user_id, channel, enabled, consent_at, updated_at)
          values (p_tenant, u->>'userId', c, true, case when v = 'true'::jsonb then now() end, now())
          on conflict (tenant_id, user_id, channel) do update set
            consent_at = case when v = 'true'::jsonb then coalesce(ntf.ntf_preferences.consent_at, now()) else null end,
            updated_at = now();
        end if;
      end loop;
    end if;
    n := n + 1;
  end loop;
  return jsonb_build_object('synced', n);
end $$;

revoke all on all tables in schema ntf from public, anon, authenticated;
grant all on all tables in schema ntf to service_role;
revoke all on all functions in schema ntf from public, anon, authenticated;
grant execute on all functions in schema ntf to service_role;
commit;
