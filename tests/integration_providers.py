"""Provider integration tests (LOCAL ONLY). Covers every provider option end to end through the worker.

Needs: local stack seeded with supabase/seed.sql, migrations up to date, and
  deno run -A tests/fake_provider.ts                     (fake providers on :9100)
  function env: NTF_HTTP_PROVIDER_TEST_MODE=true NTF_TWILIO_BASE_URL=http://127.0.0.1:9100
                NTF_MSG91_BASE_URL=http://127.0.0.1:9100 NTF_META_BASE_URL=http://127.0.0.1:9100
                NTF_GOOGLE_TOKEN_URL=http://127.0.0.1:9100/token NTF_FCM_BASE_URL=http://127.0.0.1:9100
  NTF_TEST_DB_URL=postgres://postgres:postgres@127.0.0.1:54322/postgres
Run: python tests/integration_providers.py
"""
import json, os, subprocess, sys, urllib.request, urllib.error, uuid
B = os.getenv('NOTIFICATION_BASE_URL', 'http://127.0.0.1:54321/functions/v1/notification/v1').rstrip('/')
DB = os.getenv('NTF_TEST_DB_URL', 'postgres://postgres:postgres@127.0.0.1:54322/postgres')
ORG = '20000000-0000-0000-0000-000000000001'; TEN = '30000000-0000-0000-0000-000000000001'; PROD = '10000000-0000-0000-0000-000000000001'
TPL = '40000000-0000-0000-0000-000000000001'; RULE = '50000000-0000-0000-0000-000000000001'
S, A, W = 'local-service-only', 'local-admin-only', 'local-worker-only'
FAILED = []

def sql(q):
    return subprocess.run(['psql', DB, '-v', 'ON_ERROR_STOP=1', '-qAtc', q], check=True, capture_output=True, text=True).stdout.strip()

def call(m, path, tok, body=None, org=None):
    h = {'Content-Type': 'application/json', 'Authorization': 'Bearer ' + tok}
    if org: h['X-Organization-Id'] = org
    r = urllib.request.Request(B + path, method=m, data=None if body is None else json.dumps(body).encode(), headers=h)
    try:
        with urllib.request.urlopen(r) as x: return x.status, json.loads(x.read() or 'null')
    except urllib.error.HTTPError as e: return e.code, json.loads(e.read() or 'null')

def check(name, cond, extra=''):
    print(('PASS ' if cond else 'FAIL ') + name, '' if cond else extra)
    if not cond: FAILED.append(name)

def fake_calls():
    with urllib.request.urlopen('http://127.0.0.1:9100/calls') as r: return json.load(r)

def publish_and_run(ref):
    s, b = call('POST', '/events/publish', S, {'eventCode': 'APPROVED', 'triggerType': 'WORKFLOW_TRANSITION', 'idempotencyKey': str(uuid.uuid4()), 'data': {'reference': ref}})
    assert s == 202, (s, b)
    call('POST', '/worker', W, {})
    rows = sql(f"select d.channel||'|'||n.user_id||'|'||d.status||'|'||coalesce(d.provider,'')||'|'||coalesce(d.provider_message_id,'')||'|'||d.id from ntf.ntf_deliveries d join ntf.ntf_notifications n on n.id=d.notification_id join ntf.ntf_event_log e on e.id=n.event_id where e.payload->'data'->>'reference'='{ref}' and d.channel<>'IN_APP' order by 1")
    return [dict(zip(['channel', 'user', 'status', 'provider', 'msg', 'id'], r.split('|'))) for r in rows.splitlines() if r]

# ---- setup: templates, bindings, secrets, users with phones and consent
sql(f"""
insert into ntf.ntf_template_versions values('{TPL}',1,'SMS','en','{{"body":"PR {{{{data.reference}}}} approved","msg91_template_id":"tpl1","params":{{"VAR1":"{{{{data.reference}}}}"}}}}','{{}}','PUBLISHED'),
 ('{TPL}',1,'WHATSAPP','en','{{"template_name":"purchase_update","params":["{{{{recipient.name}}}}","{{{{data.reference}}}}"]}}','{{}}','PUBLISHED'),
 ('{TPL}',1,'PUSH','en','{{"title":"Purchase","body":"{{{{data.reference}}}} updated","data":{{"ref":"{{{{data.reference}}}}"}}}}','{{}}','PUBLISHED') on conflict (template_id,version,channel,locale) do update set content=excluded.content;
insert into ntf.ntf_channels(tenant_id,channel,enabled) values('{TEN}','SMS',true),('{TEN}','WHATSAPP',true),('{TEN}','PUSH',true) on conflict (tenant_id,channel) do update set enabled=true, provider_config='{{}}';
insert into ntf.ntf_rule_channels(rule_id,tenant_id,channel,template_id,template_version) select '{RULE}','{TEN}',c,'{TPL}',1 from unnest(array['SMS','WHATSAPP','PUSH']) c on conflict do nothing;
insert into ntf.ntf_product_channel_defaults(product_id,channel,supported,default_enabled) values('{PROD}','SMS',true,false),('{PROD}','WHATSAPP',true,false),('{PROD}','PUSH',true,false) on conflict do nothing;
update ntf.ntf_product_channel_defaults set provider_config='{{}}' where product_id='{PROD}';
""")
for name, val in [('ntf_p_product_a_gen', '{"api_key":"gk-123"}'), ('ntf_t_30000000000000000000000000000001_twilio', '{"account_sid":"AC1","auth_token":"tok"}'),
                  ('ntf_p_product_a_msg91', '{"authkey":"k91"}'), ('ntf_p_product_a_meta', '{"access_token":"wa"}')]:
    sql(f"select vault.create_secret('{val}','{name}') where not exists (select 1 from vault.secrets where name='{name}')")
s, b = call('POST', '/users/sync', S, {'users': [{'userId': 'u1', 'displayName': 'Demo User', 'phone': '+919999999999', 'roles': ['manager'], 'consents': {'SMS': True, 'WHATSAPP': True}}]})
check('sync phone + consents', s == 200, (s, b))
s, b = call('POST', '/users/sync', S, {'users': [{'userId': 'u1', 'phone': '99999'}]}); check('sync rejects non-E.164', s == 422, (s, b))
sql(f"delete from ntf.ntf_user_roles where tenant_id='{TEN}' and role_code='manager' and user_id<>'u1'")
fake_calls()

# 1. no provider configured -> mock (ACCEPTED)
r = publish_and_run('INT-MOCK-' + uuid.uuid4().hex[:6])
check('mock provider ACCEPTED', any(d['channel'] == 'SMS' and d['status'] == 'ACCEPTED' and d['provider'] == 'mock' for d in r), r)

# 2. product default: generic http
sql(f"""update ntf.ntf_product_channel_defaults set provider_config='{{"provider":"http","url":"http://127.0.0.1:9100/generic/send","headers":{{"Authorization":"Bearer {{{{secret.api_key}}}}"}},"body":{{"to":"{{{{to}}}}","text":"{{{{body}}}}"}},"message_id_path":"data.id","success_path":"ok","success_values":["yes"],"secret_name":"ntf_p_product_a_gen"}}' where product_id='{PROD}' and channel='SMS'""")
r = publish_and_run('INT-HTTP-' + uuid.uuid4().hex[:6]); calls = fake_calls()
check('http provider (product default) SENT', any(d['channel'] == 'SMS' and d['status'] == 'SENT' and d['provider'] == 'http' and d['msg'].startswith('gen-') for d in r), r)
check('http provider used secret header', any(c['path'] == '/generic/send' and c.get('auth', '').startswith('Bearer gk-') for c in calls), calls)

# 3. http business reject -> FAILED, then manual retry re-queues
sql(f"""update ntf.ntf_product_channel_defaults set provider_config=jsonb_set(provider_config,'{{url}}','"http://127.0.0.1:9100/generic/reject"') where product_id='{PROD}' and channel='SMS'""")
r = publish_and_run('INT-REJ-' + uuid.uuid4().hex[:6]); sms = [d for d in r if d['channel'] == 'SMS']
check('http reject FAILED', sms and sms[0]['status'] == 'FAILED', r)
sql(f"""update ntf.ntf_product_channel_defaults set provider_config=jsonb_set(provider_config,'{{url}}','"http://127.0.0.1:9100/generic/send"') where product_id='{PROD}' and channel='SMS'""")
if sms:
    s, b = call('POST', f"/admin/deliveries/{sms[0]['id']}/retry", A, {}, org=ORG); check('manual retry accepted', s == 200, (s, b))
    call('POST', '/worker', W, {})
    check('retried delivery SENT', sql(f"select status from ntf.ntf_deliveries where id='{sms[0]['id']}'") == 'SENT')
    s, b = call('GET', f"/admin/deliveries/{sms[0]['id']}/attempts", A, org=ORG); check('attempt history has FAILED then SENT', s == 200 and [a['outcome'] for a in b][-2:] == ['FAILED', 'SENT'], (s, b))

# 4. organization override beats product default: msg91
s, b = call('POST', '/admin/channels', A, {'channel': 'SMS', 'enabled': True, 'provider_config': {'provider': 'msg91', 'secret_name': 'ntf_p_product_a_msg91'}}, org=ORG); check('org override saved', s == 200, (s, b))
r = publish_and_run('INT-M91-' + uuid.uuid4().hex[:6]); calls = fake_calls()
check('msg91 (org override) SENT', any(d['channel'] == 'SMS' and d['status'] == 'SENT' and d['provider'] == 'msg91' for d in r), r)
check('msg91 called with authkey + DLT template', any(c['path'] == '/api/v5/flow' and c.get('authkey') == 'k91' and '"tpl1"' in c['body'] for c in calls), calls)

# 5. twilio: success, then 503 -> retry -> dead letter
s, b = call('POST', '/admin/channels', A, {'channel': 'SMS', 'enabled': True, 'provider_config': {'provider': 'twilio', 'from': '+15550001111', 'secret_name': 'ntf_t_30000000000000000000000000000001_twilio'}}, org=ORG)
r = publish_and_run('INT-TW-' + uuid.uuid4().hex[:6])
check('twilio SENT', any(d['channel'] == 'SMS' and d['status'] == 'SENT' and d['provider'] == 'twilio' and d['msg'] == 'SM123' for d in r), r)
sql(f"update ntf.ntf_users set phone='+910000000500' where tenant_id='{TEN}' and user_id='u1'")
r = publish_and_run('INT-TW5-' + uuid.uuid4().hex[:6]); sms = [d for d in r if d['channel'] == 'SMS']
check('twilio 503 -> QUEUED for retry', sms and sms[0]['status'] == 'QUEUED', r)
if sms:
    sql(f"update ntf.ntf_deliveries set max_attempts=2 where id='{sms[0]['id']}'; select pgmq.set_vt('ntf_deliveries', msg_id, 0) from pgmq.q_ntf_deliveries where message->>'delivery_id'='{sms[0]['id']}'")
    call('POST', '/worker', W, {})
    check('twilio exhausted -> DEAD_LETTERED', sql(f"select status from ntf.ntf_deliveries where id='{sms[0]['id']}'") == 'DEAD_LETTERED')
    check('dead letter queue has the message', sql(f"select count(*) from pgmq.q_ntf_dlq where message->>'delivery_id'='{sms[0]['id']}'") == '1')
sql(f"update ntf.ntf_users set phone='+919999999999' where tenant_id='{TEN}' and user_id='u1'")

# 6. whatsapp meta + push fcm (with an invalid token deactivated)
key = subprocess.run(['openssl', 'genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:2048'], check=True, capture_output=True, text=True).stdout
sa = json.dumps({'project_id': 'p', 'client_email': 'sa@p.iam.gserviceaccount.com', 'private_key': key}).replace("'", "''")
sql(f"select vault.create_secret('{sa}','ntf_shared_fcm_int') where not exists (select 1 from vault.secrets where name='ntf_shared_fcm_int')")
call('POST', '/admin/channels', A, {'channel': 'WHATSAPP', 'enabled': True, 'provider_config': {'provider': 'meta', 'phone_number_id': '123', 'secret_name': 'ntf_p_product_a_meta'}}, org=ORG)
call('POST', '/admin/channels', A, {'channel': 'PUSH', 'enabled': True, 'provider_config': {'provider': 'fcm', 'secret_name': 'ntf_shared_fcm_int'}}, org=ORG)
U = 'local-user-only'
call('POST', '/devices/register', U, {'token': 'good-token', 'installationId': 'int-1', 'platform': 'android'}, org=ORG)
call('POST', '/devices/register', U, {'token': 'dead-token', 'installationId': 'int-2', 'platform': 'ios'}, org=ORG)
r = publish_and_run('INT-WA-' + uuid.uuid4().hex[:6])
check('whatsapp meta SENT', any(d['channel'] == 'WHATSAPP' and d['status'] == 'SENT' and d['msg'] == 'wamid.1' for d in r), r)
check('push fcm SENT', any(d['channel'] == 'PUSH' and d['status'] == 'SENT' and d['provider'] == 'fcm' for d in r), r)
check('invalid push token deactivated', sql(f"select active from ntf.ntf_device_tokens where tenant_id='{TEN}' and installation_id='int-2'") == 'f')

# 7. consent withdrawn -> no delivery created; test send works with configured provider
call('POST', '/users/sync', S, {'users': [{'userId': 'u1', 'consents': {'WHATSAPP': False}}]})
r = publish_and_run('INT-NOC-' + uuid.uuid4().hex[:6])
check('no consent -> no WhatsApp delivery', not any(d['channel'] == 'WHATSAPP' for d in r), r)
s, b = call('POST', '/admin/channels/SMS/test', A, {'userId': 'u1'}, org=ORG); check('test send via twilio', s == 200 and b['provider'] == 'twilio' and b['outcome'] == 'SENT', (s, b))
s, b = call('POST', '/admin/channels', A, {'channel': 'SMS', 'enabled': True, 'provider_config': {'provider': 'twilio', 'secret_name': 'ntf_t_0000000000000000000000000000000f_x'}}, org=ORG); check('out-of-scope secret rejected', s == 403, (s, b))

# cleanup: back to mock so other suites are unaffected
sql(f"update ntf.ntf_channels set provider_config='{{}}' where tenant_id='{TEN}'; update ntf.ntf_product_channel_defaults set provider_config='{{}}' where product_id='{PROD}'")
call('POST', '/users/sync', S, {'users': [{'userId': 'u1', 'consents': {'WHATSAPP': True}}]})
if FAILED: sys.exit('%d checks failed' % len(FAILED))
print('All provider integration checks passed')
