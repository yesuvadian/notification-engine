# Notification platform — local integration baseline

This archive contains the architecture specification, Supabase migrations, seeded demo, Edge Function, Flutter package, lightweight Python and TypeScript clients and tests. It is not a complete production implementation.

## Run locally
Install Docker, Supabase CLI, Flutter, Python 3 and Node 22. From this directory:

```sh
supabase start
supabase db reset
cp .env.example .env.local
supabase functions serve notification --env-file .env.local
```

In another terminal run `python tests/smoke.py`. It publishes an event twice, invokes the worker, checks the inbox and marks the notification read. Run `node --test tests/parser.test.mjs` for parser tests. The worker is invoked manually; no cron is installed. Demo tokens are intentionally public and must never be deployed. Seed only locally. Supabase may require adjusting local Postgres major version to match your CLI.

## Flutter
In `flutter_sdk`, run `flutter pub get`, `flutter analyze`, `flutter test`. Integrate the package via a path dependency in your existing Flutter app. Construct NotificationApi with baseUrl `Uri.parse('http://127.0.0.1:54321/functions/v1/notification/')` (trailing slash required), organizationId `20000000-0000-0000-0000-000000000001`, accessToken callback returning `local-user-only` for inbox or `local-admin-only` for admin. See package README for widgets. Android emulator uses 10.0.2.2 and may require debug cleartext configuration. Never put service or worker tokens in Flutter.

## Scope and limitations
Implemented paths: seeded tenant authentication with hashed opaque tokens, event schema validation, transactional event enqueue, leased jobs, role/context recipient routing, pinned master versions and matching overrides, basic template parsing, inbox/read API, basic admin JSON UI, mock external delivery records. External channels are simulated only; ACCEPTED does not mean delivered. Admin rule-channel associations and metadata provisioning currently require SQL. No real FCM/SMS/WhatsApp, token exchange, realtime, automatic scheduling, full template designer, advanced parser loops, production auditing, rate limiting, provider callbacks or full lifecycle synchronization. Worker processing is not atomic across all recipients and channels; retries use unique constraints but partial results are possible. No production deployment. The architecture MD describes the target, not the implemented scope. Database and Flutter runtime tests require your local environment. Do not expose this demo publicly.

## Shared DEV database naming (authoritative)
All 21 engine tables use `ntf.ntf_*`; all four engine RPCs and explicit indexes use `ntf_`. Product tables are not referenced or altered. Keep the dedicated `ntf` schema; expose it in Supabase Data API settings alongside existing schemas, not instead of them. Only service_role has schema access; browser clients use the Edge Function.
For a fresh installation, run the three migrations in order in SQL Editor. Do not reset the shared database. The existing `notification` schema is left untouched. This is a fresh installation into `ntf`, not a data migration. If `ntf` already exists, inspect it before running migrations. Do not drop the old schema or product tables.
For cloud DEV use `supabase/seed_cloud_dev.sql` optionally, once, instead of `seed.sql`. It returns random short-lived demo tokens; save them securely. Set WORKER_TOKEN in Edge Function secrets to the returned worker token. Deploy notification function with JWT gateway verification disabled (the function validates its own opaque tokens); never expose service role key. Use NOTIFICATION_BASE_URL (ending /v1), NOTIFICATION_SERVICE_TOKEN, NOTIFICATION_WORKER_TOKEN and NOTIFICATION_USER_TOKEN for smoke.py. Keep this demo restricted to DEV. Existing production limitations still apply.
