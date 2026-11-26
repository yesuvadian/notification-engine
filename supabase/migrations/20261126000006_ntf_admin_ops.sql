-- Admin operations: manual retry of failed / dead-lettered deliveries. Additive and idempotent.
begin;
set local search_path = ntf, public;

-- Re-queues one external delivery of a tenant. Returns false when the delivery is not retryable.
create or replace function ntf.ntf_requeue_delivery(p_delivery uuid, p_tenant uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
declare d record;
begin
  select id, notification_id, tenant_id, channel into d from ntf.ntf_deliveries
   where id = p_delivery and tenant_id = p_tenant and channel <> 'IN_APP' and status in ('FAILED','DEAD_LETTERED')
   for update;
  if not found then return false; end if;
  update ntf.ntf_deliveries set status = 'QUEUED', last_error = null, enqueued_at = now(), updated_at = now(),
         max_attempts = greatest(max_attempts, attempts + 3)
   where id = d.id;
  perform pgmq.send('ntf_deliveries', jsonb_build_object('delivery_id', d.id, 'notification_id', d.notification_id, 'tenant_id', d.tenant_id, 'channel', d.channel, 'manual_retry', true));
  return true;
end $$;

revoke all on all functions in schema ntf from public, anon, authenticated;
grant execute on all functions in schema ntf to service_role;
commit;
