-- Phase 2: pgmq queues (one message per event, one message per external delivery), dead-letter queue,
-- delivery attempts, and a pg_cron schedule that invokes the worker through pg_net.
-- Safe on existing DEV data: legacy ntf_jobs is kept; pending EVENT jobs are moved onto the event queue.
-- Requires the pgmq, pg_cron and pg_net extensions (Dashboard -> Database -> Extensions if CREATE EXTENSION is refused).
create extension if not exists pgmq;
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

begin;
set local search_path = ntf, public;

do $$ begin
  if not exists (select 1 from pgmq.meta where queue_name = 'ntf_events') then perform pgmq.create('ntf_events'); end if;
  if not exists (select 1 from pgmq.meta where queue_name = 'ntf_deliveries') then perform pgmq.create('ntf_deliveries'); end if;
  if not exists (select 1 from pgmq.meta where queue_name = 'ntf_dlq') then perform pgmq.create('ntf_dlq'); end if;
end $$;

-- Event processing state
alter table ntf.ntf_event_log add column if not exists status text not null default 'ACCEPTED';
alter table ntf.ntf_event_log add column if not exists processed_at timestamptz;
alter table ntf.ntf_event_log add column if not exists last_error text;
alter table ntf.ntf_event_log drop constraint if exists ntf_event_log_status_check;
alter table ntf.ntf_event_log add constraint ntf_event_log_status_check check (status in ('ACCEPTED','PROCESSED','FAILED','DEAD_LETTERED'));
update ntf.ntf_event_log e set status = 'PROCESSED', processed_at = coalesce(processed_at, now())
  where status = 'ACCEPTED' and exists (select 1 from ntf.ntf_jobs j where j.kind = 'EVENT' and j.payload->>'event_id' = e.id::text and j.state = 'DONE');

-- Delivery lifecycle (spec §8, §26). ACCEPTED is kept for legacy mock rows.
alter table ntf.ntf_deliveries drop constraint if exists ntf_deliveries_status_check;
alter table ntf.ntf_deliveries add constraint ntf_deliveries_status_check check (status in
  ('QUEUED','PROCESSING','ACCEPTED','SENT','DELIVERED','FAILED','UNKNOWN','CANCELLED','DEAD_LETTERED','SUPPRESSED','EXPIRED'));
alter table ntf.ntf_deliveries add column if not exists provider text;
alter table ntf.ntf_deliveries add column if not exists enqueued_at timestamptz;
alter table ntf.ntf_deliveries add column if not exists last_error text;
alter table ntf.ntf_deliveries add column if not exists max_attempts integer not null default 5;
alter table ntf.ntf_deliveries add column if not exists created_at timestamptz not null default now();
alter table ntf.ntf_deliveries add column if not exists updated_at timestamptz not null default now();
alter table ntf.ntf_deliveries add column if not exists sent_at timestamptz;
alter table ntf.ntf_deliveries add column if not exists delivered_at timestamptz;
create index if not exists ntf_deliveries_pending on ntf.ntf_deliveries (tenant_id, status) where status in ('QUEUED','PROCESSING');
create index if not exists ntf_deliveries_notification on ntf.ntf_deliveries (notification_id);

create table if not exists ntf.ntf_delivery_attempts (
  id bigint generated always as identity primary key,
  delivery_id uuid not null references ntf.ntf_deliveries on delete cascade,
  tenant_id uuid not null references ntf.ntf_tenants,
  attempt integer not null,
  outcome text not null check (outcome in ('SENT','ACCEPTED','RETRY','FAILED','DEAD_LETTERED','SUPPRESSED')),
  provider text,
  provider_message_id text,
  http_status integer,
  error text,
  response jsonb not null default '{}',
  created_at timestamptz not null default now()
);
create index if not exists ntf_delivery_attempts_delivery on ntf.ntf_delivery_attempts (delivery_id, attempt);
alter table ntf.ntf_delivery_attempts enable row level security;
create or replace view ntf.delivery_attempts with (security_invoker = true) as select * from ntf.ntf_delivery_attempts;

-- Event acceptance now enqueues on pgmq in the same transaction as the event row.
create or replace function ntf.ntf_accept_event_v2(p_tenant uuid, p_product uuid, p_code text, p_version int, p_key text, p_payload jsonb, p_correlation text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare eid uuid; h text := encode(sha256(convert_to(p_payload::text, 'UTF8')), 'hex'); old_hash text;
begin
  insert into ntf.ntf_event_log(tenant_id, product_id, event_code, event_version, idempotency_key, payload, payload_hash, correlation_id)
  values (p_tenant, p_product, p_code, p_version, p_key, p_payload, h, p_correlation)
  on conflict (tenant_id, idempotency_key) do nothing returning id into eid;
  if eid is not null then
    perform pgmq.send('ntf_events', jsonb_build_object('event_id', eid, 'tenant_id', p_tenant));
    return jsonb_build_object('event_id', eid, 'status', 'ACCEPTED');
  end if;
  select id, payload_hash into eid, old_hash from ntf.ntf_event_log where tenant_id = p_tenant and idempotency_key = p_key;
  if old_hash is distinct from h then return jsonb_build_object('event_id', eid, 'status', 'CONFLICT'); end if;
  return jsonb_build_object('event_id', eid, 'status', 'DUPLICATE');
end $$;

-- Legacy RPC keeps working for old callers but also uses the queue.
create or replace function ntf.ntf_accept_event(p_tenant uuid, p_product uuid, p_code text, p_version int, p_key text, p_payload jsonb)
returns uuid language sql security definer set search_path = '' as $$
  select (ntf.ntf_accept_event_v2(p_tenant, p_product, p_code, p_version, p_key, p_payload)->>'event_id')::uuid;
$$;

create or replace function ntf.ntf_check_queue(p_queue text) returns void language plpgsql immutable set search_path = '' as $$
begin
  if p_queue not in ('ntf_events','ntf_deliveries','ntf_dlq') then raise exception 'unknown queue %', p_queue using errcode = '22023'; end if;
end $$;

create or replace function ntf.ntf_queue_read(p_queue text, p_vt integer, p_qty integer)
returns table (msg_id bigint, read_ct integer, enqueued_at timestamptz, message jsonb)
language plpgsql security definer set search_path = '' as $$
begin
  perform ntf.ntf_check_queue(p_queue);
  return query select r.msg_id, r.read_ct, r.enqueued_at, r.message
    from pgmq.read(p_queue, greatest(10, least(p_vt, 900)), greatest(1, least(p_qty, 100))) r;
end $$;

create or replace function ntf.ntf_queue_ack(p_queue text, p_msg_id bigint) returns boolean
language plpgsql security definer set search_path = '' as $$
begin perform ntf.ntf_check_queue(p_queue); return pgmq.archive(p_queue, p_msg_id); end $$;

create or replace function ntf.ntf_queue_retry(p_queue text, p_msg_id bigint, p_delay_seconds integer) returns void
language plpgsql security definer set search_path = '' as $$
begin perform ntf.ntf_check_queue(p_queue); perform pgmq.set_vt(p_queue, p_msg_id, greatest(1, least(p_delay_seconds, 86400))); end $$;

create or replace function ntf.ntf_queue_dead_letter(p_queue text, p_msg_id bigint, p_message jsonb, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform ntf.ntf_check_queue(p_queue);
  perform pgmq.send('ntf_dlq', p_message || jsonb_build_object('source_queue', p_queue, 'reason', left(p_reason, 500), 'dead_lettered_at', now()));
  perform pgmq.archive(p_queue, p_msg_id);
end $$;

-- Enqueue every not-yet-enqueued external delivery of an event exactly once (rows are locked while sending).
create or replace function ntf.ntf_enqueue_deliveries(p_event uuid) returns integer
language plpgsql security definer set search_path = '' as $$
declare d record; n integer := 0;
begin
  for d in
    select x.id, x.notification_id, x.tenant_id, x.channel from ntf.ntf_deliveries x
    join ntf.ntf_notifications nn on nn.id = x.notification_id
    where nn.event_id = p_event and x.status = 'QUEUED' and x.enqueued_at is null and x.channel <> 'IN_APP'
    for update of x skip locked
  loop
    perform pgmq.send('ntf_deliveries', jsonb_build_object('delivery_id', d.id, 'notification_id', d.notification_id, 'tenant_id', d.tenant_id, 'channel', d.channel));
    update ntf.ntf_deliveries set enqueued_at = now(), updated_at = now() where id = d.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- Queue depth / age for monitoring (spec §8).
create or replace function ntf.ntf_queue_metrics() returns table (queue_name text, queue_length bigint, oldest_msg_age_sec integer)
language sql security definer set search_path = '' as $$
  select m.queue_name, m.queue_length, m.oldest_msg_age_sec from pgmq.metrics_all() m where m.queue_name like 'ntf\_%';
$$;

-- Move pending legacy jobs onto the event queue (idempotent: moved jobs become DONE).
do $$ declare j record; begin
  for j in select id, tenant_id, payload from ntf.ntf_jobs where kind = 'EVENT' and state in ('READY','LEASED') for update loop
    perform pgmq.send('ntf_events', jsonb_build_object('event_id', j.payload->>'event_id', 'tenant_id', j.tenant_id));
    update ntf.ntf_jobs set state = 'DONE', lease_token = null, lease_until = null, last_error = 'migrated to pgmq' where id = j.id;
  end loop;
end $$;

-- Worker invocation from pg_cron. URL and token live in Vault (secrets ntf_worker_url, ntf_worker_token).
create or replace function ntf.ntf_invoke_worker() returns bigint
language plpgsql security definer set search_path = '' as $$
declare u text; t text;
begin
  select decrypted_secret into u from vault.decrypted_secrets where name = 'ntf_worker_url';
  select decrypted_secret into t from vault.decrypted_secrets where name = 'ntf_worker_token';
  if u is null or t is null then
    raise notice 'ntf worker not configured: create vault secrets ntf_worker_url and ntf_worker_token';
    return null;
  end if;
  return net.http_post(url := u, body := '{}'::jsonb,
    headers := jsonb_build_object('Authorization', 'Bearer ' || t, 'Content-Type', 'application/json'),
    timeout_milliseconds := 60000);
end $$;

-- Housekeeping: archived queue messages and expired tokens older than 30 days.
create or replace function ntf.ntf_housekeeping() returns void
language plpgsql security definer set search_path = '' as $$
begin
  delete from pgmq.a_ntf_events where archived_at < now() - interval '30 days';
  delete from pgmq.a_ntf_deliveries where archived_at < now() - interval '30 days';
  delete from ntf.ntf_api_tokens where expires_at < now() - interval '30 days';
end $$;

revoke all on all functions in schema ntf from public, anon, authenticated;
grant execute on all functions in schema ntf to service_role;
revoke all on all tables in schema ntf from public, anon, authenticated;
grant all on all tables in schema ntf to service_role;
grant usage, select on all sequences in schema ntf to service_role;
commit;

-- Schedules (cron.schedule upserts by job name).
select cron.schedule('ntf-worker', '* * * * *', 'select ntf.ntf_invoke_worker()');
select cron.schedule('ntf-housekeeping', '17 3 * * *', 'select ntf.ntf_housekeeping()');
