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
| Admin | Scoped JSON admin APIs: templates, events, roles, rules, rule-channels, channels (with provider config), overrides, deliveries, attempts, and audit. Every write is audited. |
| Errors | `{error, message, correlationId}` with 400/401/403/404/409/413/422/500. `x-correlation-id` is echoed. |

Not implemented yet: provider delivery webhooks (so SENT is the last state for external channels), realtime inbox (the SDK polls), quiet hours, per-tenant rate limits and quotas, scheduled sends and condition endpoints, and a visual template designer.

Spec table names map to the physical tables like this: tables keep their `ntf.ntf_*` names, and read-only views give the spec names (`ntf.product_tenants`, `ntf.in_app_notifications`, `ntf.notification_deliveries`, `ntf.delivery_attempts`, `ntf.platform_templates`, `ntf.audit_logs`, and so on).

## Upgrade the shared DEV project (owefydcgkvpwvllsbhcx)

Migrations `20260101000001`–`03` are already applied. The new files are additive and safe to re-run. Don't reset the database.

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

## Channel providers

Store the credentials JSON as a Vault secret with a scoped name: `ntf_t_<tenant uuid without dashes>_*`, `ntf_p_<product code>_*` or `ntf_shared_*`. Then save the channel through `POST /v1/admin/channels`:

| Channel | provider_config | Vault secret JSON | Template content |
|---|---|---|---|
| SMS | `{"provider":"twilio","from":"+1…" or "messaging_service_sid":"MG…","secret_name":"…"}` | `{"account_sid","auth_token"}` | `body` (or `sms_body`) |
| SMS | `{"provider":"msg91","template_id":"…","secret_name":"…"}` | `{"authkey"}` | `msg91_template_id`, `params: {"VAR1":"{{data.x}}"}` |
| WHATSAPP | `{"provider":"meta","phone_number_id":"…","secret_name":"…"}` | `{"access_token"}` | `template_name`, `language`, `params: ["{{data.x}}"]` |
| PUSH | `{"provider":"fcm","secret_name":"…"}` | Firebase service-account JSON | `title`, `body`, `data` |

External channels need the user's consent (`POST /v1/preferences`, or device registration for push) and an E.164 phone number from user sync.

## Local development

```sh
supabase start && supabase db reset          # applies all migrations + supabase/seed.sql (LOCAL ONLY tokens)
cp .env.example .env.local
supabase functions serve notification --env-file .env.local --no-verify-jwt
python tests/smoke.py                         # end to end (calls the worker directly)
python tests/api_contract.py                  # 30 API contract checks
node --test tests/parser.test.mjs && deno test -A tests/logic.test.ts
cd flutter_sdk && flutter pub get && flutter analyze && flutter test
```

CI (`.github/workflows/ci.yml`) runs the Flutter SDK checks, a demo web build against the in-repo SDK, the parser and Deno tests, and a migration apply plus re-apply on a disposable Supabase Postgres.

## SDK releases

Tag tested commits with immutable tags (`v0.1.0` is the original baseline, `v0.2.0` is this release once verified), push them with `git push origin --tags`, and pin products to a tag or commit SHA (spec §47.2).
