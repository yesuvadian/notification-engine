begin;
create table ntf.ntf_api_tokens(token_hash text primary key, tenant_id uuid not null references ntf.ntf_tenants, user_id text, scope text not null check(scope in ('service','admin','user')), expires_at timestamptz not null, foreign key(tenant_id,user_id) references ntf.ntf_users);
alter table ntf.ntf_api_tokens enable row level security;
grant all on ntf.ntf_api_tokens to service_role;
create function ntf.ntf_accept_event(p_tenant uuid,p_product uuid,p_code text,p_version int,p_key text,p_payload jsonb) returns uuid language plpgsql set search_path='' as $$
declare eid uuid; begin
insert into ntf.ntf_event_log(tenant_id,product_id,event_code,event_version,idempotency_key,payload) values(p_tenant,p_product,p_code,p_version,p_key,p_payload) on conflict(tenant_id,idempotency_key) do nothing returning id into eid;
if eid is null then select id into eid from ntf.ntf_event_log where tenant_id=p_tenant and idempotency_key=p_key; else insert into ntf.ntf_jobs(tenant_id,kind,payload) values(p_tenant,'EVENT',jsonb_build_object('event_id',eid)); end if; return eid; end $$;
revoke all on function ntf.ntf_accept_event(uuid,uuid,text,int,text,jsonb) from public,anon,authenticated;
grant execute on function ntf.ntf_accept_event(uuid,uuid,text,int,text,jsonb) to service_role;

revoke all on ntf.ntf_api_tokens from public, anon, authenticated;
commit;
