-- Onboard the Astute products into the notification engine (requires migrations up to 20261126000004).
-- Idempotent: safe to run again. Run in the SQL Editor of project owefydcgkvpwvllsbhcx.
--
-- The LAST result grid lists product tokens created by THIS run. Each token is shown once: store it as a
-- backend secret of that product (never in Flutter / config.json). A product that already has an active
-- onboarding token gets no new one; to rotate, set revoked_at on the old row and run again.
--
-- Channel defaults (adjust below before running, or later with UPDATE ntf.ntf_product_channel_defaults):
--   IN_APP    supported, enabled by default
--   SMS       supported, off by default
--   WHATSAPP  supported, off by default
--   PUSH      supported, off by default
-- Defaults apply to organizations provisioned afterwards; existing tenants keep their channel rows.

-- 1. Products
insert into ntf.ntf_products(code, name) values
  ('cmm', 'Astute Community Management Module'),
  ('ast', 'Astute Trade'),
  ('ass', 'Astute Stay'),
  ('afd', 'Astute Field Desk')
on conflict (code) do update set name = excluded.name;

-- 2. Channel defaults (existing rows are kept, so later adjustments survive re-runs)
insert into ntf.ntf_product_channel_defaults(product_id, channel, supported, default_enabled)
select p.id, d.channel, d.supported, d.default_enabled
from ntf.ntf_products p
cross join (values ('IN_APP', true, true), ('SMS', true, false), ('WHATSAPP', true, false), ('PUSH', true, false))
  as d(channel, supported, default_enabled)
where p.code in ('cmm', 'ast', 'ass', 'afd')
on conflict (product_id, channel) do nothing;

-- 3. Trusted JWT issuer: products whose Flutter app signs in with THIS Supabase project's Auth.
--    CMM does. Add 'ast', 'ass', 'afd' to the list only if they use this same project for login;
--    products on other backends use POST /v1/auth/exchange instead.
insert into ntf.ntf_identity_issuers(product_id, issuer, audience)
select id, 'https://owefydcgkvpwvllsbhcx.supabase.co/auth/v1', 'authenticated'
from ntf.ntf_products where code in ('cmm')
on conflict (product_id, issuer) do nothing;

-- 4. Product-level backend tokens (90 days), only for products without an active one
drop table if exists pg_temp.ntf_new_tokens;
create temp table ntf_new_tokens as
select p.id as product_id, p.code as product_code, 'ntfp_' || encode(extensions.gen_random_bytes(32), 'hex') as product_token
from ntf.ntf_products p
where p.code in ('cmm', 'ast', 'ass', 'afd')
  and not exists (
    select 1 from ntf.ntf_api_tokens k
    where k.product_id = p.id and k.scope = 'product' and k.label = 'onboarding'
      and k.revoked_at is null and k.expires_at > now());

insert into ntf.ntf_api_tokens(token_hash, product_id, scope, expires_at, label)
select encode(extensions.digest(product_token, 'sha256'), 'hex'), product_id, 'product', now() + interval '90 days', 'onboarding'
from ntf_new_tokens;

-- 5. Assign organizations (optional; products normally call POST /v1/tenants/provision themselves).
--    CMM societies are provisioned by the CMM integration. Examples:
-- select ntf.ntf_assign_org('ast', '00000000-0000-0000-0000-000000000000', 'Example trader');
-- select ntf.ntf_assign_org('afd', '00000000-0000-0000-0000-000000000000', 'Example org', '{"sms": true}');

-- Result: new tokens (copy now; they are not stored in readable form)
select product_code, product_token from ntf_new_tokens order by product_code;
