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
    h.update(hdr or {})
    r=urllib.request.Request(B+path,method=m,data=None if body is None else json.dumps(body).encode(),headers=h)
    try:
        with urllib.request.urlopen(r) as x: return x.status, json.loads(x.read() or 'null'), dict(x.headers)
    except urllib.error.HTTPError as e: return e.code, json.loads(e.read() or 'null'), dict(e.headers)
def check(name,cond,extra=''):
    print(('PASS ' if cond else 'FAIL ')+name, '' if cond else extra)
    if not cond: FAILED.append(name)
S='local-service-only'; U='local-user-only'; A='local-admin-only'; W='local-worker-only'
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
s,b,_=call('POST','/admin/overrides',A,{'template_id':'40000000-0000-0000-0000-000000000002','base_version':1,'channel':'IN_APP','version':1,'patch':{}},org=ORG); check('override other product 404',s==404,(s,b))
s,b,_=call('POST','/admin/channels',A,{'channel':'SMS','enabled':True},org=ORG); check('admin channel save',s==200,(s,b))
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

if FAILED:
    sys.exit('%d checks failed' % len(FAILED))
print('All contract checks passed')
