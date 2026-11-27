-- Rules can also notify people linked to the record and phone numbers an admin lists.
--
-- attribute_codes: record people the product sends with each event in payload.recipientContext.<code>
--   (for CMM: flat_owner, flat_residents, pass_creator, record_creator, task_starter). The product lists the
--   attributes each event offers in ntf_events.metadata.recipientAttributes ([{code, label}]).
-- custom_phones: E.164 numbers an organization admin adds to a rule (a vendor, a security agency). The API
--   keeps a user "phone:<number>" for each; adding the number is the admin's consent record, so SMS / WhatsApp
--   go to it whenever the channel is on for the organization.
-- Both add to whatever recipient_strategy gives. Additive and idempotent.
begin;
set local search_path = ntf, public;

alter table ntf.ntf_rules add column if not exists attribute_codes text[] not null default '{}';
alter table ntf.ntf_rules add column if not exists custom_phones text[] not null default '{}';
alter table ntf.ntf_rules drop constraint if exists ntf_rules_attribute_codes_size;
alter table ntf.ntf_rules add constraint ntf_rules_attribute_codes_size check (cardinality(attribute_codes) <= 20);
alter table ntf.ntf_rules drop constraint if exists ntf_rules_custom_phones_size;
alter table ntf.ntf_rules add constraint ntf_rules_custom_phones_size check (cardinality(custom_phones) <= 20);

commit;
