-- LOCAL ONLY: known demo tokens; never run on hosted/shared databases.
begin;
create extension if not exists pgcrypto with schema extensions;
insert into ntf.ntf_products(id,code,name) values('10000000-0000-0000-0000-000000000001','product_a','Product A');
insert into ntf.ntf_organizations(id,name) values('20000000-0000-0000-0000-000000000001','Org A');
insert into ntf.ntf_tenants(id,product_id,organization_id) values('30000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001');
insert into ntf.ntf_users(tenant_id,user_id,display_name) values('30000000-0000-0000-0000-000000000001','u1','Demo User');
insert into ntf.ntf_roles values('30000000-0000-0000-0000-000000000001','manager','Manager');
insert into ntf.ntf_user_roles values('30000000-0000-0000-0000-000000000001','u1','manager');
insert into ntf.ntf_events(product_id,code,version,module_code,trigger_type,payload_schema) values('10000000-0000-0000-0000-000000000001','APPROVED',1,'PURCHASE','WORKFLOW_TRANSITION','{"type":"object","required":["reference"],"properties":{"reference":{"type":"string"}}}'),('10000000-0000-0000-0000-000000000001','REMINDER',1,'PURCHASE','ACTION','{"type":"object","required":["reference"]}');
insert into ntf.ntf_templates values('40000000-0000-0000-0000-000000000001','GENERAL');
insert into ntf.ntf_template_versions(template_id,version,channel,locale,content,status) values('40000000-0000-0000-0000-000000000001',1,'IN_APP','en','{"title":"Purchase update","body":"Hello {{recipient.name}}, record {{data.reference}} was updated."}','PUBLISHED');
insert into ntf.ntf_channels(tenant_id,channel,enabled) values('30000000-0000-0000-0000-000000000001','IN_APP',true);
insert into ntf.ntf_rules(id,tenant_id,product_id,event_code,event_version,active,recipient_strategy,role_code,purpose) values('50000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','APPROVED',1,true,'ALL_USERS_IN_ROLE','manager','approval'),('50000000-0000-0000-0000-000000000002','30000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','REMINDER',1,true,'ALL_USERS_IN_ROLE','manager','reminder');
insert into ntf.ntf_rule_channels(rule_id,tenant_id,channel,template_id,template_version) select id,tenant_id,'IN_APP','40000000-0000-0000-0000-000000000001',1 from ntf.ntf_rules;
insert into ntf.ntf_api_tokens select encode(extensions.digest(token,'sha256'),'hex'),'30000000-0000-0000-0000-000000000001',uid,scope,now()+interval '30 days' from (values('local-service-only',null,'service'),('local-worker-only',null,'service'),('local-admin-only',null,'admin'),('local-user-only','u1','user')) as v(token,uid,scope);
insert into ntf.ntf_api_tokens(token_hash,scope,expires_at,label) values(encode(extensions.digest('local-platform-only','sha256'),'hex'),'platform',now()+interval '30 days','local');

commit;
