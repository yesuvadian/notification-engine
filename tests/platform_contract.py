"""Platform super admin contract + integration tests (spec §50). LOCAL ONLY.

Covers every option of the super admin console: platform login (token, JWT claim, JWT allow-list), products,
channel defaults, product tokens and issuers, organizations with provisioned preferences and member app settings,
the add-only rules, the organization workspace, platform templates (draft, publish, retire, upgrade with override
carry-over), the worker's organization preference filter, member settings, inbox retention, the org admin
read-only switch, operations and audit.

Needs the same local stack as tests/integration_providers.py:
  NOTIFICATION_BASE_URL=http://127.0.0.1:8000/v1  NTF_TEST_DB_URL=postgres://postgres:postgres@127.0.0.1:54322/postgres
  The Supabase Auth endpoint must verify HS256 tokens signed with NTF_TEST_JWT_SECRET (local default below).
Run: python tests/platform_contract.py
"""
import base64, hashlib, hmac, json, os, subprocess, sys, time, urllib.error, urllib.request, uuid

B = os.getenv('NOTIFICATION_BASE_URL', 'http://127.0.0.1:54321/functions/v1/notification/v1').rstrip('/')
DB = os.getenv('NTF_TEST_DB_URL', 'postgres://postgres:postgres@127.0.0.1:54322/postgres')
JWT_SECRET = os.getenv('NTF_TEST_JWT_SECRET', 'super-secret-jwt-token-with-at-least-32-characters-long').encode()
ORG_A = '20000000-0000-0000-0000-000000000001'
S, A, W, P = 'local-service-only', 'local-admin-only', 'local-worker-only', 'local-platform-only'
U = 'local-user-only'
FAILED = []
RUN = uuid.uuid4().hex[:6]


def sql(q):
    return subprocess.run(['psql', DB, '-v', 'ON_ERROR_STOP=1', '-qAtc', q], check=True, capture_output=True, text=True).stdout.strip()


def sql_fails(q):
    return subprocess.run(['psql', DB, '-v', 'ON_ERROR_STOP=1', '-qAtc', q], capture_output=True, text=True).returncode != 0


def call(m, path, tok, body=None, org=None, product=None, hdr=None):
    h = {'Content-Type': 'application/json'}
    if tok: h['Authorization'] = 'Bearer ' + tok
    if org: h['X-Organization-Id'] = org
    if product: h['X-Product-Code'] = product
    h.update(hdr or {})
    r = urllib.request.Request(B + path, method=m, data=None if body is None else json.dumps(body).encode(), headers=h)
    try:
        with urllib.request.urlopen(r) as x: return x.status, json.loads(x.read() or 'null')
    except urllib.error.HTTPError as e: return e.code, json.loads(e.read() or 'null')


def check(name, cond, extra=''):
    print(('PASS ' if cond else 'FAIL ') + name, '' if cond else extra)
    if not cond: FAILED.append(name)


def b64(d):
    return base64.urlsafe_b64encode(d).rstrip(b'=').decode()


def jwt(claims, secret=JWT_SECRET):
    h = b64(json.dumps({'alg': 'HS256', 'typ': 'JWT'}).encode())
    p = b64(json.dumps({'aud': 'authenticated', 'exp': int(time.time()) + 3600, **claims}).encode())
    return f'{h}.{p}.' + b64(hmac.new(secret, f'{h}.{p}'.encode(), hashlib.sha256).digest())


PA = {'X-Platform-Admin': 'true'}

# ------------------------------------------------------------------ setup
sql(f"insert into ntf.ntf_api_tokens(token_hash,scope,expires_at,label) values(encode(extensions.digest('{P}','sha256'),'hex'),'platform',now()+interval '30 days','local') on conflict do nothing")
sql("""insert into ntf.ntf_platform_issuers(issuer,admin_claim,admin_value) values('https://claim.test/auth/v1','app_metadata.platform_role','super_admin') on conflict (issuer) do nothing;
insert into ntf.ntf_platform_issuers(issuer) values('https://allow.test/auth/v1') on conflict (issuer) do nothing;
insert into ntf.ntf_platform_admins(issuer,user_id) values('https://allow.test/auth/v1','sa-2') on conflict do nothing;
update ntf.ntf_platform_settings set value='false' where key='org_admin_writes';""")

# ------------------------------------------------------------------ 1. platform login
s, b = call('GET', '/platform/overview', P); check('platform token overview', s == 200 and b['products'] >= 1 and isinstance(b['queues'], list), (s, b))
ok_jwt = jwt({'iss': 'https://claim.test/auth/v1', 'sub': 'sa-1', 'app_metadata': {'platform_role': 'super_admin'}})
s, b = call('GET', '/platform/overview', ok_jwt, hdr=PA); check('JWT with super_admin claim', s == 200, (s, b))
s, b = call('GET', '/platform/overview', jwt({'iss': 'https://claim.test/auth/v1', 'sub': 'x', 'app_metadata': {'platform_role': 'viewer'}}), hdr=PA)
check('JWT without the claim 403', s == 403, (s, b))
s, b = call('GET', '/platform/overview', jwt({'iss': 'https://allow.test/auth/v1', 'sub': 'sa-2'}), hdr=PA); check('JWT on allow-list', s == 200, (s, b))
s, b = call('GET', '/platform/overview', jwt({'iss': 'https://allow.test/auth/v1', 'sub': 'sa-3'}), hdr=PA); check('JWT not on allow-list 403', s == 403, (s, b))
s, b = call('GET', '/platform/overview', jwt({'iss': 'https://evil.test', 'sub': 'sa-1'}), hdr=PA); check('untrusted issuer 401', s == 401, (s, b))
s, b = call('GET', '/platform/overview', jwt({'iss': 'https://claim.test/auth/v1', 'sub': 'sa-1', 'app_metadata': {'platform_role': 'super_admin'}}, b'wrong-secret-wrong-secret-wrong-secret!'), hdr=PA)
check('bad signature 401', s == 401, (s, b))
s, b = call('GET', '/platform/overview', ok_jwt); check('JWT without X-Platform-Admin uses product login (400)', s == 400 and b['error'] == 'product_required', (s, b))
s, b = call('GET', '/platform/overview', A, org=ORG_A); check('org admin cannot use platform API 403', s == 403, (s, b))
s, b = call('GET', '/platform/overview', S); check('service token cannot use platform API 403', s == 403, (s, b))
s, b = call('GET', '/admin/rules', P); check('platform admin needs an organization for /admin 400', s == 400 and b['error'] == 'organization_required', (s, b))
s, b = call('GET', '/admin/rules', P, org=ORG_A); check('X-Organization-Id needs X-Product-Code 400', s == 400 and b['error'] == 'product_required', (s, b))
s, b = call('GET', '/admin/rules', P, org=str(uuid.uuid4()), product='product_a'); check('unknown organization 404', s == 404, (s, b))
s, b = call('POST', '/events/publish', P, {'eventCode': 'APPROVED'}); check('platform admin cannot publish events 403', s == 403, (s, b))
s, b = call('GET', '/notifications', P, org=ORG_A, product='product_a'); check('platform admin has no inbox 403', s == 403, (s, b))
s, b = call('GET', '/platform/nope', P); check('unknown platform resource 404', s == 404, (s, b))

# ------------------------------------------------------------------ 2. products, channel defaults, tokens, issuers
code = 'tst_' + RUN
s, b = call('POST', '/platform/products', P, {'code': code, 'name': 'Test product'}); check('create product 201', s == 201 and b['code'] == code, (s, b))
s, b = call('POST', '/platform/products', P, {'code': code, 'name': 'Again'}); check('duplicate product 409', s == 409, (s, b))
s, b = call('POST', '/platform/products', P, {'code': 'Bad Code', 'name': 'x'}); check('bad product code 422', s == 422, (s, b))
s, b = call('PUT', f'/platform/products/{code}/channels', P, {'items': [{'channel': 'SMS', 'supported': True, 'default_enabled': False},
    {'channel': 'PUSH', 'supported': True, 'default_enabled': True}, {'channel': 'WHATSAPP', 'supported': False, 'default_enabled': True},
    {'channel': 'IN_APP', 'supported': False}]})
d = {r['channel']: r for r in b} if s == 200 else {}
check('channel defaults saved', s == 200 and d['PUSH']['default_enabled'] and d['SMS']['supported'] and not d['SMS']['default_enabled'], (s, b))
check('unsupported channel cannot be on for new orgs', s == 200 and not d['WHATSAPP']['supported'] and not d['WHATSAPP']['default_enabled'], b)
check('IN_APP always supported and on', s == 200 and d['IN_APP']['supported'] and d['IN_APP']['default_enabled'], b)
s, b = call('PUT', f'/platform/products/{code}/channels', P, {'items': [{'channel': 'FAX'}]}); check('unknown channel 422', s == 422, (s, b))
s, b = call('GET', '/platform/products', P); row = [p for p in b if p['code'] == code][0] if s == 200 else {}
check('product list with defaults and org count', s == 200 and row.get('organizations') == 0 and len(row.get('defaults', [])) == 4, (s, row))
s, b = call('POST', f'/platform/products/{code}/status', P, {'active': False}); check('suspend product', s == 200, (s, b))
check('product suspended', sql(f"select status from ntf.ntf_products where code='{code}'") == 'SUSPENDED')
s, b = call('POST', f'/platform/products/{code}/status', P, {'active': True}); check('reactivate product', s == 200, (s, b))
s, b = call('POST', f'/platform/products/{code}/status', P, {'active': 'no'}); check('product status needs boolean 422', s == 422, (s, b))
s, tok = call('POST', '/platform/products/product_a/tokens', P, {'label': 'contract', 'ttlDays': 1}); check('create product token (shown once)', s == 201 and tok['token'].startswith('ntf_'), (s, tok))
s, b = call('GET', '/platform/products/product_a/tokens', P); check('token list has no token values', s == 200 and any(t['id'] == tok['id'] for t in b) and all('token' not in t and 'token_hash' not in t for t in b), (s, b))
PT = tok['token']
s, b = call('POST', '/platform/products/nope/tokens', P, {}); check('token for unknown product 404', s == 404, (s, b))
s, b = call('POST', '/platform/products/product_a/issuers', P, {'issuer': 'https://idp.test/' + RUN, 'jwks_url': 'https://idp.test/jwks.json', 'audience': 'api'}); check('save issuer', s == 200 and b['audience'] == 'api', (s, b))
s, b = call('POST', '/platform/products/product_a/issuers', P, {'issuer': 'http://insecure.test'}); check('non-https issuer 422', s == 422, (s, b))
s, b = call('GET', '/platform/products/product_a/issuers', P); check('list issuers', s == 200 and any(i['issuer'].endswith(RUN) for i in b), (s, b))

# ------------------------------------------------------------------ 3. groups and organizations
s, b = call('GET', '/platform/groups?product=product_a', P); check('notification groups from event modules', s == 200 and any(g['group'] == 'PURCHASE' and 'APPROVED' in g['events'] for g in b), (s, b))
sql("insert into ntf.ntf_product_channel_defaults(product_id,channel,supported,default_enabled) select '10000000-0000-0000-0000-000000000001',c,true,c='IN_APP' from unnest(array['IN_APP','SMS','PUSH','WHATSAPP']) c on conflict (product_id,channel) do update set supported=true")
ORG_X = str(uuid.uuid4())
s, b = call('POST', '/platform/organizations', P, {'productCode': code, 'organizationId': str(uuid.uuid4()), 'organizationName': 'Unsupported',
    'preferences': {'PURCHASE': ['IN_APP', 'WHATSAPP']}}); check('preferences with unsupported channel 422', s == 422, (s, b))
s, b = call('POST', '/platform/organizations', P, {'productCode': 'product_a', 'organizationId': ORG_X, 'organizationName': 'Contract Org ' + RUN, 'preferences': ['x']})
check('preferences must be an object 422', s == 422, (s, b))
s, b = call('POST', '/platform/organizations', P, {'productCode': 'product_a', 'organizationId': 'not-a-uuid', 'organizationName': 'x'}); check('organization id must be a UUID 422', s == 422, (s, b))
s, b = call('POST', '/platform/organizations', P, {'productCode': 'product_a', 'organizationId': ORG_X, 'organizationName': 'Contract Org ' + RUN,
    'preferences': {'PURCHASE': ['IN_APP', 'SMS']}, 'settings': {'inbox_retention_days': 30, 'push_prompt': 'off', 'push_explanation': 'Alerts for approvals'}})
check('create organization with preferences + settings 201', s == 201 and b.get('tenantId'), (s, b))
TX = b.get('tenantId')
s, b = call('POST', '/platform/organizations', P, {'productCode': 'product_a', 'organizationId': ORG_X, 'organizationName': 'again', 'preferences': {}}); check('organization created twice 409', s == 409, (s, b))
s, b = call('GET', f'/platform/organizations?product=product_a&search=Contract Org {RUN}'.replace(' ', '%20'), P)
x = b[0] if s == 200 and b else {}
check('organization list (managed, channels, users)', s == 200 and len(b) == 1 and x['managed'] and x['channels'] == ['IN_APP', 'SMS'] and x['users'] == 0, (s, b))
s, b = call('GET', '/platform/organizations?product=product_a&status=active', P); check('status filter', s == 200 and all(o['active'] for o in b), (s, b))
s, b = call('POST', '/platform/organizations/status', P, {'productCode': 'product_a', 'organizationId': ORG_X, 'active': False}); check('suspend needs a reason 422', s == 422, (s, b))
s, b = call('POST', '/platform/organizations/status', P, {'productCode': 'product_a', 'organizationId': ORG_X, 'active': False, 'reason': 'contract test'}); check('suspend organization', s == 200, (s, b))
s, b = call('GET', f'/admin/rules', P, org=ORG_X, product='product_a'); check('super admin can open a suspended organization', s == 200, (s, b))
s, b = call('POST', '/platform/organizations/status', P, {'productCode': 'product_a', 'organizationId': ORG_X, 'active': True}); check('reactivate organization', s == 200, (s, b))
s, b = call('POST', '/platform/organizations/status', P, {'productCode': 'product_a', 'organizationId': str(uuid.uuid4()), 'active': True}); check('status for unknown organization 404', s == 404, (s, b))

# ------------------------------------------------------------------ 4. platform templates
tcode = 'TST_' + RUN.upper()
s, t = call('POST', '/platform/templates', P, {'code': tcode, 'name': 'Contract template', 'productCode': 'product_a'}); check('create template 201', s == 201, (s, t))
TID = t['id']
s, b = call('POST', '/platform/templates', P, {'code': 'bad code', 'name': 'x'}); check('bad template code 422', s == 422, (s, b))
content = {'IN_APP': {'title': 'Approved {{data.reference}}', 'body': 'v1 body'}, 'SMS': {'body': 'v1 sms {{data.reference}}'}, 'PUSH': {'title': 'v1', 'body': 'v1 push'}}
for ch, c in content.items():
    s, b = call('POST', f'/platform/templates/{TID}/versions', P, {'channel': ch, 'content': c}); check(f'draft v1 {ch}', s == 200 and b['version'] == 1 and b['status'] == 'DRAFT', (s, b))
s, b = call('POST', f'/platform/templates/{TID}/versions', P, {'channel': 'IN_APP', 'content': 'x'}); check('draft content must be an object 422', s == 422, (s, b))
s, b = call('POST', f'/platform/templates/{TID}/versions/1/publish', P, {}); check('publish v1', s == 200 and len(b['channels']) == 3, (s, b))
s, b = call('POST', f'/platform/templates/{TID}/versions/1/publish', P, {}); check('publish again 409', s == 409, (s, b))
s, b = call('POST', f'/platform/templates/{uuid.uuid4()}/versions/1/publish', P, {}); check('unknown template 404', s == 404, (s, b))

# ------------------------------------------------------------------ 5. organization workspace (super admin acting on ORG_X)
def X(m, path, body=None): return call(m, path, P, body, org=ORG_X, product='product_a')
s, b = X('GET', '/admin/org-preferences')
grp = {g['group']: g for g in b['groups']} if s == 200 else {}
check('org preferences provisioned', s == 200 and sorted((c['channel'], c['source']) for c in grp['PURCHASE']['channels']) == [('IN_APP', 'PROVISIONED'), ('SMS', 'PROVISIONED')], (s, b))
s, b = X('POST', '/admin/org-preferences', {'items': [{'group': 'PURCHASE', 'channel': 'PUSH'}]}); check('add channel that is not on 422', s == 422, (s, b))
s, b = X('POST', '/admin/channels', {'channel': 'PUSH', 'enabled': True}); check('add PUSH channel to organization', s == 200, (s, b))
s, b = X('POST', '/admin/channels', {'channel': 'SMS', 'enabled': False}); check('provisioned channel cannot be turned off 403', s == 403, (s, b))
s, b = X('POST', '/admin/channels', {'channel': 'PUSH', 'enabled': True, 'provider_config': {'provider': 'fcm'}}); check('no provider override per organization 422', s == 422 and b['error'] == 'provider_platform_level', (s, b))
s, b = call('POST', '/admin/channels', P, {'channel': 'WHATSAPP', 'enabled': True}, org=ORG_A, product='product_a'); check('channel the product supports can be added', s == 200, (s, b))
sql("update ntf.ntf_product_channel_defaults set supported=false where product_id='10000000-0000-0000-0000-000000000001' and channel='WHATSAPP'")
s, b = X('POST', '/admin/channels', {'channel': 'WHATSAPP', 'enabled': True}); check('channel the product does not support 422', s == 422 and b['error'] == 'channel_not_supported', (s, b))
sql("update ntf.ntf_product_channel_defaults set supported=true where product_id='10000000-0000-0000-0000-000000000001' and channel='WHATSAPP'")
s, b = X('POST', '/admin/org-preferences', {'items': [{'group': 'VISITORS', 'channel': 'PUSH'}]}); check('add PUSH to another group', s == 200, (s, b))
s, b = X('DELETE', '/admin/org-preferences'); check('preferences cannot be removed via API 405', s == 405, (s, b))
check('preferences cannot be removed in the database', sql_fails(f"delete from ntf.ntf_org_preferences where tenant_id='{TX}'"))
check('preferences cannot be changed in the database', sql_fails(f"update ntf.ntf_org_preferences set channel='PUSH' where tenant_id='{TX}' and channel='SMS'"))
s, b = X('GET', '/admin/org-settings'); check('org settings provisioned', s == 200 and b['managed'] and b['settings']['inbox_retention_days'] == 30 and b['settings']['push_prompt'] == 'off', (s, b))
s, b = X('PUT', '/admin/org-settings', {'inbox_retention_days': 60}); check('retention can grow', s == 200 and b['settings']['inbox_retention_days'] == 60, (s, b))
s, b = X('PUT', '/admin/org-settings', {'inbox_retention_days': 20}); check('retention cannot shrink 403', s == 403, (s, b))
s, b = X('PUT', '/admin/org-settings', {'unread_badge': False}); check('unread badge cannot be switched off 403', s == 403, (s, b))
s, b = X('PUT', '/admin/org-settings', {'group_by_day': False}); check('day grouping cannot be switched off 403', s == 403, (s, b))
s, b = X('PUT', '/admin/org-settings', {'push_prompt': 'first_login'}); check('push prompt can be turned on', s == 200 and b['settings']['push_prompt'] == 'first_login', (s, b))
s, b = X('PUT', '/admin/org-settings', {'push_prompt': 'after_first_notification'}); check('push prompt timing can change', s == 200, (s, b))
s, b = X('PUT', '/admin/org-settings', {'push_prompt': 'off'}); check('push prompt cannot be turned off 403', s == 403, (s, b))
s, b = X('PUT', '/admin/org-settings', {'push_prompt': 'sometimes'}); check('unknown push prompt 422', s == 422, (s, b))
s, b = X('PUT', '/admin/org-settings', {'push_explanation': 'Get approval alerts'}); check('push explanation editable', s == 200 and b['settings']['push_explanation'] == 'Get approval alerts', (s, b))

# rules + bindings default to the latest published platform version
s, b = X('POST', '/admin/rules', {'event_code': 'APPROVED', 'recipient_strategy': 'ALL_ORG_USERS', 'purpose': 'approval', 'active': True}); check('super admin creates rule', s == 201, (s, b))
RID = b['id']
for ch in ['IN_APP', 'SMS', 'PUSH']:
    s, b = X('POST', '/admin/rule-channels', {'rule_id': RID, 'channel': ch, 'template_id': TID}); check(f'bind {ch} defaults to latest version', s == 200 and b['template_version'] == 1, (s, b))
s, b = X('POST', '/admin/rule-channels', {'rule_id': RID, 'channel': 'WHATSAPP', 'template_id': TID}); check('bind without a published version 422', s == 422, (s, b))

# ------------------------------------------------------------------ 6. worker applies organization preferences per group
s, b = call('POST', '/users/sync', PT, {'users': [{'userId': 'mx1', 'displayName': 'Member X', 'phone': '+919811111111', 'consents': {'SMS': True}}]}, org=ORG_X)
check('product token syncs members of the new org', s == 200, (s, b))
s, b = call('POST', '/auth/exchange', PT, {'userId': 'mx1'}, org=ORG_X); check('exchange user token', s == 200, (s, b))
UX = b['accessToken']
s, b = call('POST', '/devices/register', UX, {'token': 'mx1-token', 'installationId': 'mx1-1', 'platform': 'android'}, org=ORG_X); check('member registers device', s == 200, (s, b))


def publish_x(ref):
    s, b = call('POST', '/events/publish', PT, {'eventCode': 'APPROVED', 'triggerType': 'WORKFLOW_TRANSITION', 'idempotencyKey': str(uuid.uuid4()), 'data': {'reference': ref}}, org=ORG_X)
    assert s == 202, (s, b)
    call('POST', '/worker', W, {})
    return sorted(sql(f"select d.channel from ntf.ntf_deliveries d join ntf.ntf_notifications n on n.id=d.notification_id join ntf.ntf_event_log e on e.id=n.event_id where e.payload->'data'->>'reference'='{ref}'").split())


chans = publish_x('PX-1-' + RUN); check('PUSH not in PURCHASE preferences is not sent', chans == ['IN_APP', 'SMS'], chans)
s, b = X('POST', '/admin/org-preferences', {'items': [{'group': 'PURCHASE', 'channel': 'PUSH'}]}); check('add PUSH to PURCHASE', s == 200, (s, b))
s, b = X('GET', '/admin/org-preferences'); check('added channel marked ADDED', s == 200 and any(c['channel'] == 'PUSH' and c['source'] == 'ADDED' for g in b['groups'] if g['group'] == 'PURCHASE' for c in g['channels']), (s, b))
chans = publish_x('PX-2-' + RUN); check('PUSH sent after it is added', chans == ['IN_APP', 'PUSH', 'SMS'], chans)
chans = sorted(sql("select d.channel from ntf.ntf_deliveries d join ntf.ntf_notifications n on n.id=d.notification_id join ntf.ntf_event_log e on e.id=n.event_id where e.tenant_id='30000000-0000-0000-0000-000000000001' order by e.created_at desc limit 1").split())
check('unmanaged organization is not filtered', len(chans) >= 1, chans)

# ------------------------------------------------------------------ 7. template versions: existing orgs stay pinned, upgrade carries overrides
s, b = X('POST', '/admin/overrides', {'template_id': TID, 'base_version': 1, 'channel': 'IN_APP', 'patch': {'body': 'org override body'}}); check('override for the organization', s == 201, (s, b))
s, b = call('POST', f'/platform/templates/{TID}/versions', P, {'channel': 'IN_APP', 'content': {'title': 'Approved {{data.reference}}', 'body': 'v2 body'}}); check('draft v2', s == 200 and b['version'] == 2, (s, b))
s, b = call('POST', f'/platform/templates/{TID}/versions/2/publish', P, {}); check('publish v2', s == 200, (s, b))
s, b = call('POST', f'/platform/templates/{TID}/versions', P, {'channel': 'IN_APP', 'content': {'title': 't', 'body': 'v3'}}); check('editing after publish starts v3 draft', s == 200 and b['version'] == 3, (s, b))
s, b = call('GET', '/platform/templates?product=product_a', P); tp = [x for x in b if x['id'] == TID][0] if s == 200 else {}
check('template usage: latest v2, org pinned to v1, one override', s == 200 and tp['latestPublished'] == 2 and tp['draftVersion'] == 3 and tp['pinnedOrganizations'].get('1') == 1 and tp['organizationsWithOverrides'] == 1, (s, tp))
check('existing organization stays on v1', sql(f"select template_version from ntf.ntf_rule_channels where rule_id='{RID}' and channel='IN_APP'") == '1')
s, b = call('POST', f'/platform/templates/{TID}/versions/1/retire', P, {}); check('retire version in use 409', s == 409 and b['error'] == 'version_in_use', (s, b))
s, b = X('POST', f'/admin/templates/{TID}/upgrade', {}); check('upgrade organization to latest', s == 200 and b['upgraded'] == 1 and b['overridesCarried'] == 1 and b['skipped'] == 2, (s, b))
s, b = X('GET', f'/admin/templates/{TID}/effective?channel=IN_APP'); check('override carried to v2', s == 200 and b['master']['version'] == 2 and b['source'] == 'OVERRIDE' and b['effective']['body'] == 'org override body', (s, b))
s, b = X('POST', f'/admin/templates/{TID}/upgrade', {'version': 0}); check('upgrade version must be positive 422', s == 422, (s, b))
s, b = X('POST', f'/admin/templates/{TID}/upgrade', {}); check('upgrade again is a no-op', s == 200 and b['upgraded'] == 0, (s, b))
s, b = call('POST', f'/platform/templates/{TID}/versions/1/retire', P, {}); check('retire v1 still used by SMS and PUSH 409', s == 409, (s, b))

# ------------------------------------------------------------------ 8. member app (C1-C3) for a managed organization
s, b = call('GET', '/settings', UX, org=ORG_X)
check('member settings from the organization', s == 200 and b['managed'] and b['preferencesLocked'] and b['inbox']['retentionDays'] == 60 and b['push']['prompt'] == 'after_first_notification' and b['push']['explanation'] == 'Get approval alerts', (s, b))
s, b = call('GET', '/preferences', UX, org=ORG_X); check('member preferences are read-only', s == 200 and b['locked'] and all(i['locked'] and i['enabled'] for i in b['items']), (s, b))
s, b = call('POST', '/preferences', UX, {'items': [{'channel': 'SMS', 'enabled': False}]}, org=ORG_X); check('member cannot switch a channel off 403', s == 403 and b['error'] == 'preferences_locked', (s, b))
s, b = call('POST', '/preferences', UX, {'items': [{'channel': 'SMS', 'consent': False}]}, org=ORG_X); check('member can withdraw consent', s == 200 and any(i['channel'] == 'SMS' and not i['consent'] for i in b['items']), (s, b))
s, b = call('POST', '/preferences', UX, {'items': [{'channel': 'SMS', 'consent': True}]}, org=ORG_X); check('member can give consent', s == 200, (s, b))
s, b = call('GET', '/settings', U, org=ORG_A); check('unmanaged organization: member settings not locked', s == 200 and not b['managed'] and not b['preferencesLocked'], (s, b))
s, b = call('GET', '/settings', P); check('settings needs a member credential 403', s == 403, (s, b))
s, before = call('GET', '/notifications/unread-count', UX, org=ORG_X)
eid = sql(f"select id from ntf.ntf_event_log where tenant_id='{TX}' limit 1")
sql(f"insert into ntf.ntf_notifications(tenant_id,event_id,user_id,purpose,title,body,created_at) values('{TX}','{eid}','mx1','old-{RUN}','Old','Old',now()-interval '100 days')")
nid = sql(f"select id from ntf.ntf_notifications where purpose='old-{RUN}'")
sql(f"insert into ntf.ntf_deliveries(notification_id,tenant_id,channel,status,rendered_payload,template_snapshot) values('{nid}','{TX}','IN_APP','DELIVERED','{{}}','{{}}')")
s, b = call('GET', '/notifications?limit=100', UX, org=ORG_X); check('inbox hides notifications past retention', s == 200 and all(i['id'] != nid for i in b['items']) and len(b['items']) >= 1, (s, b))
s, after = call('GET', '/notifications/unread-count', UX, org=ORG_X); check('unread count ignores notifications past retention', s == 200 and after['count'] == before['count'], (before, after))

# ------------------------------------------------------------------ 9. org admin read-only switch
s, b = call('POST', '/admin/rules', A, {'event_code': 'APPROVED', 'recipient_strategy': 'ALL_ORG_USERS', 'purpose': 'x'}, org=ORG_A); check('org admin write blocked by default', s == 403 and b['error'] == 'org_admin_read_only', (s, b))
s, b = call('POST', '/admin/templates/preview', A, {'title': 'Hi {{n}}', 'context': {'n': 'A'}}, org=ORG_A); check('org admin preview still allowed', s == 200 and b['title'] == 'Hi A', (s, b))
sql("update ntf.ntf_platform_settings set value='true' where key='org_admin_writes'")
s, b = call('POST', '/admin/rules', A, {'event_code': 'APPROVED', 'recipient_strategy': 'ALL_ORG_USERS', 'purpose': 'oa-' + RUN}, org=ORG_A); check('org admin write allowed when switched on', s == 201, (s, b))
if s == 201: call('DELETE', f"/admin/rules/{b['id']}", A, org=ORG_A)
sql("update ntf.ntf_platform_settings set value='false' where key='org_admin_writes'")

# ------------------------------------------------------------------ 10. operations and audit
s, b = call('GET', '/platform/ops', P); check('ops: queues and dead letters', s == 200 and isinstance(b['queues'], list) and isinstance(b['deadLetters'], list), (s, b))
s, b = call('POST', f'/platform/deliveries/{uuid.uuid4()}/replay', P, {}); check('replay unknown delivery 404', s == 404, (s, b))
did = sql(f"select id from ntf.ntf_deliveries where tenant_id='{TX}' and channel='IN_APP' limit 1")
s, b = call('POST', f'/platform/deliveries/{did}/replay', P, {}); check('replay delivered in-app 409', s == 409, (s, b))
s, b = call('DELETE', f"/platform/tokens/{tok['id']}", P); check('revoke product token', s == 200, (s, b))
s, b = call('DELETE', f"/platform/tokens/{tok['id']}", P); check('revoke again 404', s == 404, (s, b))
s, b = call('POST', '/users/sync', PT, {'users': []}, org=ORG_X); check('revoked token rejected 401', s == 401, (s, b))
s, b = call('GET', '/platform/audit?platformOnly=true', P)
acts = {r['action'] for r in b} if s == 200 else set()
check('platform audit trail', s == 200 and {'platform.organization.create', 'platform.template.publish', 'platform.token.revoke'} <= acts, acts)
s, b = X('GET', '/admin/audit'); check('organization audit shows super admin actions', s == 200 and any(r['action'] == 'org_settings.update' and r['actor'].startswith('token:platform') for r in b), (s, b))

if FAILED: sys.exit('%d checks failed' % len(FAILED))
print('All platform checks passed')
