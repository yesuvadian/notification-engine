# Notification engine

A shared notification engine: the Supabase `ntf` schema, one Edge Function (`notification`), a Flutter SDK (`flutter_sdk`), and Python and TypeScript server clients. The target architecture is in `notification_engine.md`. This README describes what is implemented.

## What's implemented

| Area | Status |
|---|---|
| Auth | Opaque scoped tokens (`service`, `product`, `admin`, `user`). Supabase JWTs from the same project, and JWKS-verified external issuers (`ntf_identity_issuers`). `POST /v1/auth/exchange` mints short-lived user/admin tokens. |
| Identity | `POST /v1/users/sync`, `/v1/roles/sync`, `/v1/tenants/provision` and `/v1/metadata/sync`, so products never write ntf tables. |
| Isolation | Each tenant is one product-organization pair. `X-Organization-Id` is required for user and admin credentials. Templates are shared (`product_id` NULL) or product-scoped, enforced by the API and by DB triggers. Provider secrets are tenant/product scoped. |
| Ingestion | Schema-validated events, durable acceptance (202), idempotent retries. A reused key with a different payload returns 409. |
| Worker | pgmq queues `ntf_events`, `ntf_deliveries` and `ntf_dlq`, with one message per external delivery. Visibility timeouts, exponential backoff with jitter, dead-lettering, and `ntf_delivery_attempts`. pg_cron invokes it every minute through pg_net, with the URL and token in Vault. |
| Channels | IN_APP; SMS (Twilio, MSG91); WhatsApp (Meta Cloud API, approved templates); push (FCM HTTP v1). Credentials are in Vault. A channel with no provider uses the DEV mock (`ACCEPTED` is not proof of delivery). |
| User APIs | Paginated inbox, unread count, mark read (one, many or all), device register/unregister, and per-channel preferences and consent. |
| Admin | Scoped JSON admin APIs: templates, events, roles, rules, rule-channels, channels (with provider config), overrides, deliveries, attempts, and audit. Every write is audited. Also: rule update/delete (`PUT`/`DELETE /v1/admin/rules/{id}`), unbind (`DELETE /v1/admin/rule-channels/{ruleId}/{channel}`), override reset (`DELETE /v1/admin/overrides/{id}`), effective template (`GET /v1/admin/templates/{id}/effective`), event variables (`GET /v1/admin/events/{code}/variables`), delivery attempts and retry, and channel test send (`POST /v1/admin/channels/{channel}/test`). |
| Errors | `{error, message, correlationId}` with 400/401/403/404/409/413/422/500. `x-correlation-id` is echoed. |

Not implemented yet: provider delivery webhooks (so SENT is the last state for external channels), realtime inbox (the SDK polls), quiet hours, per-tenant rate limits and quotas, scheduled sends and condition endpoints, and a visual template designer.

Spec table names map to the physical tables like this: tables keep their `ntf.ntf_*` names, and read-only views give the spec names (`ntf.product_tenants`, `ntf.in_app_notifications`, `ntf.notification_deliveries`, `ntf.delivery_attempts`, `ntf.platform_templates`, `ntf.audit_logs`, and so on).

## Upgrade the shared DEV project (owefydcgkvpwvllsbhcx)

Migrations `20260101000001`–`03` are already applied. Apply `20261126000001`–`06` in order. The new files are additive and safe to re-run. Don't reset the database.

1. **Enable extensions** under Dashboard → Database → Extensions: `pgmq`, `pg_cron` and `pg_net` (Vault is on by default). Migration 2 also tries to create them.
2. **Apply the migrations in order.** Either paste each file into the SQL Editor, or run:
   ```powershell
   $db = Read-Host 'DB connection string (Session pooler URI)' -MaskInput
   psql $db -v ON_ERROR_STOP=1 -f supabase/migrations/20261126000001_ntf_auth_isolation.sql
   psql $db -v ON_ERROR_STOP=1 -f supabase/migrations/20261126000002_ntf_pgmq_worker.sql
   psql $db -v ON_ERROR_STOP=1 -f supabase/migrations/20261126000003_ntf_channel_providers.sql
   ```
   If you'd rather use `supabase db push`, first mark the old files as applied with `supabase migration repair --status applied 20260101000001 20260101000002 20260101000003`.
3. **Store the worker URL and token in Vault** (SQL Editor). Use the same value as the function's `WORKER_TOKEN` secret:
   ```sql
   select vault.create_secret('https://owefydcgkvpwvllsbhcx.supabase.co/functions/v1/notification/v1/worker', 'ntf_worker_url');
   select vault.create_secret('<WORKER_TOKEN value>', 'ntf_worker_token');
   ```
4. **Deploy the function:** `supabase functions deploy notification --project-ref owefydcgkvpwvllsbhcx --no-verify-jwt`
5. **Verify:** `GET .../notification/v1/health` returns `{"status":"ok","version":"0.2.0"}`. Then run the §48 flow. You no longer need to call the worker by hand, because cron does it within a minute. Check with:
   ```sql
   select * from ntf.ntf_queue_metrics();
   select status, return_message, start_time from cron.job_run_details order by start_time desc limit 5;
   ```
   `python tests/smoke.py` needs `NOTIFICATION_BASE_URL`, `NOTIFICATION_SERVICE_TOKEN`, `NOTIFICATION_WORKER_TOKEN`, `NOTIFICATION_USER_TOKEN` and `NOTIFICATION_ORG_ID`.

## Onboard a product in the same Supabase project (e.g. CMM)

For the Astute products (cmm, ast, ass, afd), run migration `20261126000004_ntf_product_channel_defaults.sql` and then `supabase/scripts/onboard_astute_products.sql`. That registers the products, their channel defaults and the CMM issuer, and prints one product token each. `select ntf.ntf_assign_org('<code>', '<org uuid>', '<name>')` assigns an organization to a product. The manual steps for any other product are below.

```sql
insert into ntf.ntf_products(code, name) values ('cmm', 'CMM') on conflict (code) do nothing;
-- Trust this project's Supabase Auth JWTs for the product (jwks_url NULL = verify with Supabase Auth)
insert into ntf.ntf_identity_issuers(product_id, issuer)
  select id, 'https://owefydcgkvpwvllsbhcx.supabase.co/auth/v1' from ntf.ntf_products where code = 'cmm' on conflict do nothing;
-- Product-level backend credential (shown once; store it as a backend secret, never in Flutter)
with t as (select 'ntfp_' || encode(extensions.gen_random_bytes(32), 'hex') as tok)
insert into ntf.ntf_api_tokens(token_hash, product_id, scope, expires_at, label)
select encode(extensions.digest(tok, 'sha256'), 'hex'), (select id from ntf.ntf_products where code = 'cmm'),
       'product', now() + interval '90 days', 'cmm backend' from t
returning (select tok from t) as product_token;
```

Then, from the product backend (an Edge Function or server, using the product token):

1. `POST /v1/tenants/provision` with `{organizationId, organizationName, notificationChannels}` once per organization.
2. `POST /v1/metadata/sync` with the event contracts.
3. `POST /v1/roles/sync` and `POST /v1/users/sync` (with `X-Organization-Id`). Use `userId` = the Supabase auth user id, and mark admin roles with `notificationAdmin: true`.
4. `POST /v1/events/publish` from the product's outbox worker.

Templates and rules are configured through the admin APIs.

In Flutter, create `NotificationApi(productCode: 'cmm', accessToken: () => supabase session JWT, organizationId: ...)`. See `flutter_sdk/README.md`.

## Channel providers (SMS, WhatsApp, push)

The provider is pure configuration, so each client can use its own. The worker uses the organization's `ntf_channels.provider_config` when it names a `provider`. Otherwise it falls back to the product default in `ntf_product_channel_defaults.provider_config`. Credentials always live in a Vault secret referenced by `secret_name`, which must be scoped `ntf_p_<product code>_*` (product), `ntf_t_<tenant uuid without dashes>_*` (one organization) or `ntf_shared_*`.

| provider | Channels | provider_config | Vault secret JSON | Template content |
|---|---|---|---|---|
| `http` (any provider) | SMS, WHATSAPP | `url` (https), `method`, `content_type` (json/form), `headers`, `body`, `message_id_path`, `success_path` + `success_values`, `secret_name` | any keys, used as `{{secret.key}}` | anything the body template uses |
| `twilio` | SMS | `from` or `messaging_service_sid`, `secret_name` | `{"account_sid","auth_token"}` | `body` (or `sms_body`) |
| `msg91` | SMS | `template_id`, `secret_name` | `{"authkey"}` | `msg91_template_id`, `params: {"VAR1":"{{data.x}}"}` |
| `meta` | WHATSAPP | `phone_number_id`, `secret_name` | `{"access_token"}` | `template_name`, `language`, `params: ["{{data.x}}"]` |
| `fcm` | PUSH | `secret_name` | Firebase service-account JSON | `title`, `body`, `data` |

Variables in the `http` url, headers and body: `{{to}}` (E.164), `{{to_digits}}`, `{{body}}`, `{{title}}`, `{{template_name}}`, `{{language}}`, `{{params.x}}` / `{{params[0]}}`, `{{delivery_id}}`, `{{user_id}}` and `{{secret.<key>}}`. Event data reaches the provider through the channel template (for example `params`). The URL must be https and public. Set `NTF_HTTP_PROVIDER_ALLOWED_HOSTS` on the function to restrict hosts further.

**Example: one SMS provider for every CMM organization**
```sql
select vault.create_secret('{"api_key":"<key from the provider>"}', 'ntf_p_cmm_sms');
update ntf.ntf_product_channel_defaults set provider_config = '{
  "provider": "http",
  "url": "https://api.your-sms-provider.com/v1/send",
  "headers": {"Authorization": "Bearer {{secret.api_key}}"},
  "body": {"to": "{{to_digits}}", "message": "{{body}}", "sender": "ASTUTE"},
  "message_id_path": "data.id",
  "secret_name": "ntf_p_cmm_sms"
}'::jsonb
where channel = 'SMS' and product_id = (select id from ntf.ntf_products where code = 'cmm');
```
An organization with its own provider sends `POST /v1/admin/channels` with its own `provider_config` and an `ntf_t_<tenant>_*` secret.

**Everything needed before an SMS or WhatsApp message goes out**
1. A provider account with a sender ID or number and API credentials. India SMS needs DLT-registered templates and a header. WhatsApp needs a verified business number and approved templates.
2. A Vault secret with the credentials (above).
3. Provider config: the product default, or an organization override.
4. The channel enabled for the organization (`POST /v1/admin/channels {"channel":"SMS","enabled":true}`, or `ntf_assign_org(..., '{"sms": true}')`). Channels are off by default.
5. A published template version for the channel, and a rule binding (`POST /v1/admin/rule-channels`). WhatsApp template names and parameter counts must match the approved template.
6. Users synced with E.164 `phone`.
7. Consent per user and channel: `"consents": {"SMS": true}` in `/v1/users/sync` from the backend, or `POST /v1/preferences` from the app. Without consent, deliveries are not created.
8. Check results in `/v1/admin/deliveries` and `/v1/admin/attempts`. `SENT` means the provider accepted the message. Delivery receipts (webhooks) are not implemented yet.

## Local development

```sh
supabase start && supabase db reset          # applies all migrations + supabase/seed.sql (LOCAL ONLY tokens)
cp .env.example .env.local
supabase functions serve notification --env-file .env.local --no-verify-jwt
python tests/smoke.py                         # end to end (calls the worker directly)
python tests/api_contract.py                  # 60 API contract checks
python tests/integration_providers.py         # every provider option end to end (needs tests/fake_provider.ts, see file header)
node --test tests/parser.test.mjs && deno test -A tests/logic.test.ts
cd flutter_sdk && flutter pub get && flutter analyze && flutter test
```

CI (`.github/workflows/ci.yml`) runs the Flutter SDK checks, a demo web build against the in-repo SDK, the parser and Deno tests, and a migration apply plus re-apply on a disposable Supabase Postgres.

## SDK releases

Tag tested commits with immutable tags (`v0.1.0` is the original baseline, `v0.2.0` is this release once verified), push them with `git push origin --tags`, and pin products to a tag or commit SHA (spec §47.2).
