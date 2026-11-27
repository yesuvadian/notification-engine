-- Template variables are product level (spec: platform gives default variables, products must match them).
-- ntf_variables rows with product_id NULL are the platform defaults; every product holds its own copy, made when
-- the product is created, and adds its own fields. Metadata sync checks every event field against the product's
-- variables: a field with another type is refused, a new field is added to the product as source 'product'.
-- Additive and idempotent: safe to run on existing DEV data and to re-run.
begin;
set local search_path = ntf, public;

create table if not exists ntf.ntf_variables(
  id uuid primary key default gen_random_uuid(),
  product_id uuid references ntf.ntf_products on delete cascade,
  name text not null check (name ~ '^[A-Za-z][A-Za-z0-9_]{0,49}$'),
  type text not null check (type in ('string','number','integer','boolean','object','array')),
  description text,
  example text,
  source text not null default 'platform' check (source in ('platform','product')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (product_id is not null or source = 'platform')
);
create unique index if not exists ntf_variables_product_name
  on ntf.ntf_variables(coalesce(product_id, '00000000-0000-0000-0000-000000000000'::uuid), name);

insert into ntf.ntf_variables(product_id, name, type, description, example) values
  (null, 'subject', 'string', 'Short subject or title line', 'Water tank cleaning tomorrow'),
  (null, 'body', 'string', 'Main message text', 'The water supply will be off from 10 AM to 1 PM.'),
  (null, 'reference', 'string', 'Number or code of the record the message is about', 'INV-1042'),
  (null, 'amount', 'number', 'Money amount', '2500'),
  (null, 'due_date', 'string', 'Due date, already formatted for reading', '30 Nov 2026'),
  (null, 'status', 'string', 'Current status of the record', 'Overdue'),
  (null, 'person_name', 'string', 'Name of the person the message is about (not the recipient)', 'Anita Rao'),
  (null, 'link', 'string', 'Link to open the record', 'https://example.com/r/1042'),
  (null, 'note', 'string', 'Extra remark', 'Please carry your ID card.')
on conflict do nothing;

-- Copies platform defaults a product does not have yet. Never changes a product's own rows.
create or replace function ntf.ntf_copy_variable_defaults(p_product uuid) returns integer
language plpgsql security definer set search_path = ntf, public as $$
declare n integer;
begin
  insert into ntf.ntf_variables(product_id, name, type, description, example, source)
  select p_product, d.name, d.type, d.description, d.example, 'platform'
    from ntf.ntf_variables d
   where d.product_id is null
     and not exists (select 1 from ntf.ntf_variables v where v.product_id = p_product and v.name = d.name)
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function ntf.ntf_products_copy_variables() returns trigger
language plpgsql security definer set search_path = ntf, public as $$
begin
  perform ntf.ntf_copy_variable_defaults(new.id);
  return new;
end $$;

drop trigger if exists ntf_products_copy_variables on ntf.ntf_products;
create trigger ntf_products_copy_variables after insert on ntf.ntf_products
  for each row execute function ntf.ntf_products_copy_variables();

-- Existing products get the defaults now.
select ntf.ntf_copy_variable_defaults(id) from ntf.ntf_products;

-- Existing events' fields become product variables (type taken from the event; a default with another type wins
-- and the event is reported by the check below).
insert into ntf.ntf_variables(product_id, name, type, source)
select distinct on (e.product_id, f.key) e.product_id, f.key, coalesce(f.value->>'type', 'string'), 'product'
  from ntf.ntf_events e
  cross join lateral jsonb_each(coalesce(e.payload_schema->'properties', '{}'::jsonb)) f
 where f.key ~ '^[A-Za-z][A-Za-z0-9_]{0,49}$'
   and coalesce(f.value->>'type', 'string') in ('string','number','integer','boolean','object','array')
 order by e.product_id, f.key, e.version desc
on conflict do nothing;

alter table ntf.ntf_variables enable row level security;
revoke all on ntf.ntf_variables from public, anon, authenticated;
grant all on ntf.ntf_variables to service_role;
revoke all on function ntf.ntf_copy_variable_defaults(uuid) from public, anon, authenticated;
revoke all on function ntf.ntf_products_copy_variables() from public, anon, authenticated;
grant execute on function ntf.ntf_copy_variable_defaults(uuid) to service_role;
commit;
