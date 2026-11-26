begin;
create function ntf.ntf_claim_jobs(p_limit integer default 20) returns setof ntf.ntf_jobs language sql set search_path='' as $$
with candidates as (select id from ntf.ntf_jobs where ((state='READY' and available_at<=now()) or (state='LEASED' and lease_until<=now())) and attempts<max_attempts order by available_at for update skip locked limit greatest(0,least(p_limit,100)))
update ntf.ntf_jobs j set state='LEASED', attempts=attempts+1, lease_until=now()+interval '2 minutes',lease_token=gen_random_uuid() from candidates c where j.id=c.id returning j.*;
$$;
create function ntf.ntf_finish_job(p_id uuid,p_token uuid,p_success boolean,p_error text default null) returns boolean language sql set search_path='' as $$
with changed as (update ntf.ntf_jobs set state=case when p_success then 'DONE' when attempts>=max_attempts then 'DEAD' else 'READY' end, available_at=now()+make_interval(secs=>least(3600,30*power(2,least(attempts,7)))::integer),lease_until=null,lease_token=null,last_error=p_error where id=p_id and state='LEASED' and lease_token=p_token and lease_until>now() returning id) select exists(select 1 from changed);
$$;
create function ntf.ntf_reap_jobs() returns void language sql set search_path='' as $$ update ntf.ntf_jobs set state='DEAD',lease_token=null,lease_until=null where state='LEASED' and lease_until<=now() and attempts>=max_attempts; $$;
revoke all on all functions in schema ntf from public,anon,authenticated;
grant execute on all functions in schema ntf to service_role;
commit;
