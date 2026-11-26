export class NotificationClient {
 constructor(private baseUrl:string, private token:string){}
 async publish(event:Record<string,unknown>){const r=await fetch(this.baseUrl.replace(/\/$/,'')+'/v1/events/publish',{method:'POST',headers:{Authorization:`Bearer ${this.token}`,'Content-Type':'application/json'},body:JSON.stringify(event)});if(!r.ok)throw Error(`Notification API ${r.status}`);return r.json();}
}
