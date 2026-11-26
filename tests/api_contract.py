"""API contract checks against a local stack seeded with supabase/seed.sql (LOCAL ONLY tokens).

supabase start && supabase db reset && supabase functions serve notification --env-file .env.local
python tests/api_contract.py
"""
import json, os, urllib.request, urllib.error, uuid, sys
B=os.getenv('NOTIFICATION_BASE_URL','http://127.0.0.1:54321/functions/v1/notification/v1').rstrip('/')
FAILED=[]
ORG='20000000-0000-0000-0000-000000000001'
def call(m,path,tok=None,body=None,org=None,hdr=None):
    h={'Content-Type':'application/json'}
    if tok: h['Authorization']='Bearer '+tok
    if org: h['X-Organization-Id']=org
    if tok==P: h['X-Product-Code']='product_a'  # platform super admin acting on Org A
    h.update(hdr or {})
    r=urllib.request.Request(B+path,method=m,data=None if body is None else json.dumps(body).encode(),headers=h)
    try:
        with urllib.request.urlopen(r) as x: return x.status, json.loads(x.read() or 'null'), dict(x.headers)
    except urllib.error.HTTPError as e: return e.code, json.loads(e.read() or 'null'), dict(e.headers)
def check(name,cond,extra=''):
    print(('PASS ' if cond else 'FAIL ')+name, '' if cond else extra)
    if not cond: FAILED.append(name)
S='local-service-only'; U='local-user-only'; A='local-admin-only'; W='local-worker-only'; P='local-platform-only'
e={'eventCode':'APPROVED','triggerType':'WORKFLOW_TRANSITION','idempotencyKey':str(uuid.uuid4()),'data':{'reference':'PR-1'}}
s1,b1,_=call('POST','/events/publish',S,e); s2,b2,h2=call('POST','/events/publish',S,e)
check('publish 202',s1==202,b1); check('dup same body',b1==b2 and s2==202 and h2.get('Idempotent-Replayed')=='true',(s2,b2,h2))
e2=dict(e,data={'reference':'PR-2'}); s,b,_=call('POST','/events/publish',S,e2); check('conflict 409',s==409 and b['error']=='idempotency_conflict',(s,b))
s,b,_=call('POST','/events/publish',S,dict(e,idempotencyKey='x'+str(uuid.uuid4()),data={})); check('schema 422',s==422 and b['error']=='invalid_payload',(s,b))
s,b,_=call('POST','/events/publish',S,dict(e,eventCode='NOPE')); check('unknown event 422',s==422,(s,b))
s,b,_=call('POST','/events/publish',U,e,org=ORG); check('user cannot publish 403',s==403,(s,b))
s,b,_=call('POST','/events/publish','bogus',e); check('bad token 401',s==401,(s,b))
s,b,_=call('POST','/worker','wrong',{}); check('worker wrong 403',s==403,(s,b))
s,b,_=call('POST','/worker',W,{}); check('worker ok',s==200,(s,b)); print('  worker',b)
s,b,_=call('GET','/notifications',U); check('inbox w/o org 400',s==400 and b['error']=='organization_required',(s,b))
s,b,_=call('GET','/notifications',U,org='20000000-0000-0000-0000-000000000009'); check('inbox wrong org 403',s==403,(s,b))
s,b,_=call('GET','/notifications?limit=1',U,org=ORG); check('inbox ok',s==200 and len(b['items'])==1 and 'PR-1' in b['items'][0]['body'],(s,b))
first=b['items'][0]['id'] if s==200 and b['items'] else None
s,c,_=call('GET','/notifications/unread-count',U,org=ORG); check('unread',s==200 and c['count']>=1,(s,c))
s,b,_=call('POST','/notifications/%s/read'%first,U,{},org=ORG); check('mark read',s==200,(s,b))
s,b,_=call('POST','/notifications/%s/read'%uuid.uuid4(),U,{},org=ORG); check('mark read 404',s==404,(s,b))
s,b,_=call('POST','/notifications/mark-read',U,{'all':True},org=ORG); check('mark all',s==200,(s,b))
s,b,_=call('GET','/admin/templates',A,org=ORG); check('admin templates scoped',s==200 and all(r['template']['product_id'] in (None,'10000000-0000-0000-0000-000000000001') for r in b) and len(b)>=1,(s,b))
s,b,_=call('GET','/admin/templates',U,org=ORG); check('user no admin 403',s==403,(s,b))
s,b,_=call('POST','/admin/channels',A,{'channel':'SMS','enabled':True},org=ORG); check('org admin writes blocked 403',s==403 and b['error']=='org_admin_read_only',(s,b))
s,b,_=call('GET','/admin/rules',A,org=ORG); check('org admin can still read',s==200,(s,b))
s,b,_=call('POST','/admin/overrides',P,{'template_id':'40000000-0000-0000-0000-000000000002','base_version':1,'channel':'IN_APP','version':1,'patch':{}},org=ORG); check('override other product 404',s==404,(s,b))
s,b,_=call('POST','/admin/channels',P,{'channel':'SMS','enabled':True},org=ORG); check('admin channel save',s==200,(s,b))
s,b,_=call('GET','/admin/audit',A,org=ORG); check('audit has channel.save',s==200 and any(r['action']=='channel.save' for r in b),(s,b))
s,b,_=call('POST','/roles/sync',S,{'roles':[{'code':'ntfadmin','name':'Notif admin','notificationAdmin':True}]}); check('roles sync',s==200,(s,b))
s,b,_=call('POST','/users/sync',S,{'users':[{'userId':'auth-uid-1','displayName':'Jwt User','roles':['manager','ntfadmin']}]}); check('users sync',s==200,(s,b))
s,b,_=call('POST','/users/sync',S,{'users':[{'userId':'x','roles':['missing']}]}); check('users sync bad role 422',s==422,(s,b))
s,b,_=call('POST','/auth/exchange',S,{'userId':'auth-uid-1','scope':'user','ttlSeconds':600}); check('exchange',s==200 and b['accessToken'].startswith('ntf_'),(s,b))
xt=b.get('accessToken')
s,b,_=call('GET','/notifications/unread-count',xt,org=ORG); check('exchanged token works',s==200,(s,b))
s,b,_=call('POST','/auth/exchange',S,{'userId':'u1','scope':'admin'}); check('exchange admin w/o role 403',s==403,(s,b))
s,b,_=call('GET','/nope',U,org=ORG); check('404 route',s==404,(s,b))
s,b,h=call('GET','/notifications',U,org=ORG,hdr={'X-Correlation-Id':'abc'}); check('correlation echo',h.get('x-correlation-id')=='abc',h)

# ---------------------------------------------------------------- Part A: admin APIs
import random
s,b,_=call('POST','/admin/rules',P,{'event_code':'APPROVED','recipient_strategy':'ALL_USERS_IN_ROLE','role_code':'manager','purpose':'contract-'+str(uuid.uuid4())[:8],'active':False},org=ORG); check('A rule create 201',s==201,(s,b))
rid=b.get('id') if isinstance(b,dict) else None
s,b,_=call('PUT','/admin/rules/%s'%rid,P,{'active':True,'priority':5},org=ORG); check('A rule update',s==200 and b['active'] is True and b['priority']==5,(s,b))
s,b,_=call('PUT','/admin/rules/%s'%rid,P,{'active':'yes'},org=ORG); check('A rule update bad type 422',s==422,(s,b))
s,b,_=call('PUT','/admin/rules/%s'%uuid.uuid4(),P,{'active':True},org=ORG); check('A rule update unknown 404',s==404,(s,b))
s,b,_=call('PUT','/admin/rules/%s'%rid,U,{'active':True},org=ORG); check('A rule update by user 403',s==403,(s,b))
TPL='40000000-0000-0000-0000-000000000001'
s,b,_=call('POST','/admin/rule-channels',P,{'rule_id':rid,'channel':'IN_APP','template_id':TPL,'template_version':1},org=ORG); check('A rule-channel bind',s==200,(s,b))
s,b,_=call('DELETE','/admin/rule-channels/%s/IN_APP'%rid,P,org=ORG); check('A rule-channel delete',s==200,(s,b))
s,b,_=call('DELETE','/admin/rule-channels/%s/IN_APP'%rid,P,org=ORG); check('A rule-channel delete again 404',s==404,(s,b))
s,b,_=call('DELETE','/admin/rules/%s'%rid,P,org=ORG); check('A rule delete',s==200,(s,b))
s,b,_=call('GET','/admin/rules',A,org=ORG); check('A rule gone',s==200 and all(r['id']!=rid for r in b),(s,b))
s,b,_=call('GET','/admin/templates/%s/effective?channel=IN_APP&locale=en'%TPL,A,org=ORG); check('A template effective',s==200 and b['master']['version']==1 and 'title' in b['effective'],(s,b))
s,b,_=call('POST','/admin/overrides',P,{'template_id':TPL,'base_version':1,'channel':'IN_APP','patch':{'title':'Override one'}},org=ORG); check('A override publish',s==201,(s,b))
o1=b.get('id'); v1=b.get('version')
s,b,_=call('POST','/admin/overrides',P,{'template_id':TPL,'base_version':1,'channel':'IN_APP','patch':{'title':'Override two'}},org=ORG); check('A override republish auto-version',s==201 and b['version']==v1+1,(s,b))
o2=b.get('id')
s,b,_=call('GET','/admin/templates/%s/effective?channel=IN_APP'%TPL,A,org=ORG); check('A effective uses latest override',s==200 and b['source']=='OVERRIDE' and b['effective']['title']=='Override two',(s,b))
s,b,_=call('POST','/admin/overrides',P,{'template_id':TPL,'base_version':1,'channel':'IN_APP','patch':'x'},org=ORG); check('A override bad patch 422',s==422,(s,b))
s,b,_=call('DELETE','/admin/overrides/%s'%o1,P,org=ORG); check('A reset retired override 404',s==404,(s,b))
s,b,_=call('DELETE','/admin/overrides/%s'%o2,P,org=ORG); check('A reset to master',s==200,(s,b))
s,b,_=call('GET','/admin/templates/%s/effective?channel=IN_APP'%TPL,A,org=ORG); check('A effective back to master',s==200 and b['source']=='MASTER',(s,b))
s,b,_=call('GET','/admin/templates/%s/effective?channel=WHATSAPP&locale=xx'%TPL,A,org=ORG); check('A effective missing channel 404',s==404,(s,b))
s,b,_=call('GET','/admin/events/APPROVED/variables?version=1',A,org=ORG); check('A event variables',s==200 and any(v['path']=='data.reference' and v['required'] for v in b['variables']) and any(v['path']=='recipient.name' for v in b['variables']),(s,b))
s,b,_=call('GET','/admin/events/NOPE/variables',A,org=ORG); check('A event variables unknown 404',s==404,(s,b))
s,b,_=call('GET','/admin/deliveries?channel=IN_APP',A,org=ORG); check('A deliveries filtered',s==200 and all(d['channel']=='IN_APP' for d in b) and (not b or 'notification' in b[0]),(s,b))
did=b[0]['id'] if s==200 and b else str(uuid.uuid4())
s,b,_=call('GET','/admin/deliveries/%s/attempts'%did,A,org=ORG); check('A delivery attempts',s==200 and isinstance(b,list),(s,b))
s,b,_=call('POST','/admin/deliveries/%s/retry'%did,P,{},org=ORG); check('A retry in-app/delivered 409',s==409 and b['error']=='not_retryable',(s,b))
s,b,_=call('POST','/admin/channels',P,{'channel':'SMS','enabled':True},org=ORG)
s,b,_=call('POST','/admin/channels/SMS/test',P,{'phone':'+919800000001'},org=ORG); check('A test send (configured or mock)',s==200 and b['outcome'] in ('ACCEPTED','SENT','FAILED','RETRY') and 'provider' in b,(s,b))
s,b,_=call('POST','/admin/channels/SMS/test',P,{'phone':'12345'},org=ORG); check('A test send bad phone 422',s==422,(s,b))
s,b,_=call('POST','/admin/channels/IN_APP/test',P,{'phone':'+919800000001'},org=ORG); check('A test send in-app 422',s==422,(s,b))
s,b,_=call('GET','/admin/nope/x',A,org=ORG); check('A unknown sub-resource 404',s==404,(s,b))
# metadata sync must ignore key order in schemas
code='CONTRACT_EV_%d'%random.randint(1,10**9)
ev1={'code':code,'version':1,'moduleCode':'TEST','triggerType':'ACTION','payloadSchema':{'type':'object','required':['a'],'properties':{'a':{'type':'string'},'b':{'type':'number'}}}}
ev2=dict(ev1,payloadSchema={'properties':{'b':{'type':'number'},'a':{'type':'string'}},'required':['a'],'type':'object'})
s,b,_=call('POST','/metadata/sync',S,{'events':[ev1]}); check('A metadata create',s==200 and b['created']==1,(s,b))
s,b,_=call('POST','/metadata/sync',S,{'events':[ev2]}); check('A metadata same schema other key order',s==200 and b['unchanged']==1,(s,b))
s,b,_=call('POST','/metadata/sync',S,{'events':[dict(ev1,payloadSchema={'type':'object','required':['b']})]}); check('A metadata changed contract 409',s==409,(s,b))

if FAILED:
    sys.exit('%d checks failed' % len(FAILED))
print('All contract checks passed')
