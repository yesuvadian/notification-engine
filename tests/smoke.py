import json, urllib.request, uuid, os
base=os.getenv('NOTIFICATION_BASE_URL','http://127.0.0.1:54321/functions/v1/notification/v1').rstrip('/')
def call(path,token,body=None):
    req=urllib.request.Request(base+path, data=None if body is None else json.dumps(body).encode(),headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'})
    with urllib.request.urlopen(req,timeout=60) as r:return json.load(r)
e={'eventCode':'APPROVED','triggerType':'WORKFLOW_TRANSITION','idempotencyKey':str(uuid.uuid4()),'data':{'reference':'PR-TEST'}}
a=call('/events/publish',os.getenv('NOTIFICATION_SERVICE_TOKEN','local-service-only'),e);assert a==call('/events/publish',os.getenv('NOTIFICATION_SERVICE_TOKEN','local-service-only'),e)
call('/worker',os.getenv('NOTIFICATION_WORKER_TOKEN','local-worker-only'),{})
items=call('/notifications',os.getenv('NOTIFICATION_USER_TOKEN','local-user-only'))['items'];n=next(x for x in items if x['event_id']==a['id']);assert 'PR-TEST' in n['body'];call('/notifications/'+n['id']+'/read',os.getenv('NOTIFICATION_USER_TOKEN','local-user-only'),{});print('Smoke passed')
