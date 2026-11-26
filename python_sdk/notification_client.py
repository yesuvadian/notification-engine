import json
from urllib.request import Request, urlopen
class NotificationClient:
    def __init__(self, base_url, token):
        self.base_url, self.token = base_url.rstrip('/'), token
    def publish(self, event):
        req = Request(self.base_url+'/v1/events/publish', data=json.dumps(event).encode(), headers={'Authorization':'Bearer '+self.token,'Content-Type':'application/json'})
        with urlopen(req, timeout=20) as response:
            return json.load(response)
