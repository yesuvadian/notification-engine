-- "Everyone with a role" can name several roles.
-- ntf_rules.role_codes holds every role of an ALL_USERS_IN_ROLE rule; role_code stays as the first of them (it
-- keeps its foreign key and older clients keep working). Existing rules get role_codes = {role_code}.
-- The API checks each code is a role of the organization; the worker notifies members of any of them, once.
-- Additive and idempotent.
begin;
set local search_path = ntf, public;

alter table ntf.ntf_rules add column if not exists role_codes text[] not null default '{}';
alter table ntf.ntf_rules drop constraint if exists ntf_rules_role_codes_size;
alter table ntf.ntf_rules add constraint ntf_rules_role_codes_size check (cardinality(role_codes) <= 20);

update ntf.ntf_rules set role_codes = array[role_code]
where role_code is not null and role_codes = '{}';

commit;
