// Twilio Programmable Messaging (SMS). config: {provider:"twilio", from?: "+1...", messaging_service_sid?: "MG..."}
// Vault secret JSON: {"account_sid":"AC...","auth_token":"..."}
import { ChannelAdapter, SendRequest, SendResult, classifyHttp, fetchWithTimeout, retryAfterSeconds, str } from './types.ts';

const BASE = () => Deno.env.get('NTF_TWILIO_BASE_URL') ?? 'https://api.twilio.com';

export class TwilioSmsAdapter implements ChannelAdapter {
  readonly provider = 'twilio';
  readonly channel = 'SMS' as const;
  async send(req: SendRequest): Promise<SendResult> {
    const sid = str(req.secret.account_sid), token = str(req.secret.auth_token);
    if (!sid || !token) return { outcome: 'FAILED', error: 'missing twilio secret (account_sid, auth_token)' };
    const to = req.recipient.phone;
    if (!to || !/^\+[1-9]\d{6,14}$/.test(to)) return { outcome: 'FAILED', error: 'recipient has no E.164 phone' };
    const body = str(req.payload.sms_body) ?? str(req.payload.body);
    if (!body) return { outcome: 'FAILED', error: 'empty SMS body' };
    const form = new URLSearchParams({ To: to, Body: body.slice(0, 1600) });
    const svc = str(req.config.messaging_service_sid), from = str(req.config.from);
    if (svc) form.set('MessagingServiceSid', svc);
    else if (from) form.set('From', from);
    else return { outcome: 'FAILED', error: 'twilio config needs from or messaging_service_sid' };
    if (str(req.config.status_callback)) form.set('StatusCallback', String(req.config.status_callback));
    let res: Response;
    try {
      res = await fetchWithTimeout(`${BASE()}/2010-04-01/Accounts/${encodeURIComponent(sid)}/Messages.json`, {
        method: 'POST',
        headers: { Authorization: 'Basic ' + btoa(`${sid}:${token}`), 'Content-Type': 'application/x-www-form-urlencoded' },
        body: form
      });
    } catch (e) {
      return { outcome: 'RETRY', error: `twilio network error: ${(e as Error).name}` };
    }
    const j = await res.json().catch(() => ({}));
    if (res.ok) return { outcome: 'SENT', providerMessageId: j.sid, httpStatus: res.status, response: { status: j.status } };
    return { outcome: classifyHttp(res.status), httpStatus: res.status, retryAfter: retryAfterSeconds(res.headers), error: `twilio ${res.status} ${j.code ?? ''} ${String(j.message ?? '').slice(0, 200)}`.trim() };
  }
}
