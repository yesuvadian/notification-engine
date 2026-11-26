// MSG91 Flow API (SMS, India DLT). config: {provider:"msg91", template_id?: "<flow/template id>", short_url?: 0|1}
// Vault secret JSON: {"authkey":"..."}
// Template content may set msg91_template_id and params ({"VAR1": "{{data.reference}}"}) which are rendered per recipient.
import { ChannelAdapter, SendRequest, SendResult, classifyHttp, fetchWithTimeout, retryAfterSeconds, str } from './types.ts';

const BASE = () => Deno.env.get('NTF_MSG91_BASE_URL') ?? 'https://control.msg91.com';

export class Msg91SmsAdapter implements ChannelAdapter {
  readonly provider = 'msg91';
  readonly channel = 'SMS' as const;
  async send(req: SendRequest): Promise<SendResult> {
    const authkey = str(req.secret.authkey);
    if (!authkey) return { outcome: 'FAILED', error: 'missing msg91 secret (authkey)' };
    const phone = req.recipient.phone;
    if (!phone || !/^\+[1-9]\d{6,14}$/.test(phone)) return { outcome: 'FAILED', error: 'recipient has no E.164 phone' };
    const templateId = str(req.payload.msg91_template_id) ?? str(req.config.template_id);
    if (!templateId) return { outcome: 'FAILED', error: 'msg91 template_id missing (DLT-approved flow required)' };
    const params = (req.payload.params && typeof req.payload.params === 'object' && !Array.isArray(req.payload.params))
      ? Object.fromEntries(Object.entries(req.payload.params as Record<string, unknown>).map(([k, v]) => [k, String(v)]))
      : {};
    let res: Response;
    try {
      res = await fetchWithTimeout(`${BASE()}/api/v5/flow`, {
        method: 'POST',
        headers: { authkey, 'Content-Type': 'application/json', accept: 'application/json' },
        body: JSON.stringify({ template_id: templateId, short_url: String(req.config.short_url ?? '0'), recipients: [{ mobiles: phone.slice(1), ...params }] })
      });
    } catch (e) {
      return { outcome: 'RETRY', error: `msg91 network error: ${(e as Error).name}` };
    }
    const j = await res.json().catch(() => ({}));
    if (res.ok && j.type === 'success') return { outcome: 'SENT', providerMessageId: String(j.message ?? ''), httpStatus: res.status };
    const outcome = res.ok ? 'FAILED' : classifyHttp(res.status);
    return { outcome, httpStatus: res.status, retryAfter: retryAfterSeconds(res.headers), error: `msg91 ${res.status} ${String(j.message ?? '').slice(0, 200)}`.trim() };
  }
}
