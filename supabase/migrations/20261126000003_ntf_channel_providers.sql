-- Phase 3: provider secrets in Vault, device registration and preference metadata. Additive only.
--
-- Provider secrets are Vault secrets whose JSON value holds the credentials. Their names must be scoped:
--   ntf_t_<tenant uuid without dashes>_<anything>   one tenant
--   ntf_p_<product code>_<anything>                 every tenant of one product
--   ntf_shared_<anything>                           platform-wide sender
-- ntf_channels.provider_config holds only non-secret settings plus "secret_name".
begin;
set local search_path = ntf, public;

create or replace function ntf.ntf_secret_allowed(p_tenant uuid, p_name text) returns boolean
language sql stable set search_path = '' as $$
  select p_name is not null and (
    p_name like 'ntf\_shared\_%'
    or p_name like 'ntf\_t\_' || replace(p_tenant::text, '-', '') || '\_%'
    or exists (select 1 from ntf.ntf_tenants t join ntf.ntf_products p on p.id = t.product_id
               where t.id = p_tenant and p_name like 'ntf\_p\_' || p.code || '\_%'));
$$;

-- Returns the decrypted secret JSON for a tenant channel, or NULL. Callable by service_role only.
create or replace function ntf.ntf_get_provider_secret(p_tenant uuid, p_channel text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare n text; v text;
begin
  select provider_config->>'secret_name' into n from ntf.ntf_channels where tenant_id = p_tenant and channel = p_channel;
  if n is null then return null; end if;
  if not ntf.ntf_secret_allowed(p_tenant, n) then
    raise exception 'secret % is not in scope for tenant %', n, p_tenant using errcode = '42501';
  end if;
  select decrypted_secret into v from vault.decrypted_secrets where name = n;
  if v is null then raise exception 'missing vault secret %', n using errcode = 'P0002'; end if;
  return v::jsonb;
end $$;

-- Reject out-of-scope secret names at write time too.
create or replace function ntf.ntf_check_channel_secret() returns trigger language plpgsql set search_path = '' as $$
begin
  if new.provider_config ? 'secret_name' and not ntf.ntf_secret_allowed(new.tenant_id, new.provider_config->>'secret_name') then
    raise exception 'secret_name is not in scope for this tenant' using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists ntf_channels_secret_scope on ntf.ntf_channels;
create trigger ntf_channels_secret_scope before insert or update on ntf.ntf_channels for each row execute function ntf.ntf_check_channel_secret();

-- Devices (spec §24, §34)
alter table ntf.ntf_device_tokens add column if not exists platform text;
alter table ntf.ntf_device_tokens add column if not exists app_version text;
alter table ntf.ntf_device_tokens add column if not exists created_at timestamptz not null default now();
alter table ntf.ntf_device_tokens drop constraint if exists ntf_device_tokens_platform_check;
alter table ntf.ntf_device_tokens add constraint ntf_device_tokens_platform_check check (platform is null or platform in ('android','ios','web'));
create index if not exists ntf_device_tokens_user on ntf.ntf_device_tokens (tenant_id, user_id) where active;
create or replace view ntf.device_tokens with (security_invoker = true) as select * from ntf.ntf_device_tokens;

-- Preferences metadata
alter table ntf.ntf_preferences add column if not exists updated_at timestamptz not null default now();
create or replace view ntf.user_notification_preferences with (security_invoker = true) as select * from ntf.ntf_preferences;

revoke all on all functions in schema ntf from public, anon, authenticated;
grant execute on all functions in schema ntf to service_role;
revoke all on all tables in schema ntf from public, anon, authenticated;
grant all on all tables in schema ntf to service_role;
commit;
