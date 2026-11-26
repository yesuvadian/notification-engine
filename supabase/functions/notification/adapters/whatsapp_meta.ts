// WhatsApp Business Cloud API (Meta). config: {provider:"meta", phone_number_id:"...", api_version?:"v21.0"}
// Vault secret JSON: {"access_token":"..."}
// Template content: {"template_name":"order_update","language":"en","params":["{{data.reference}}"]} (approved templates only).
import { ChannelAdapter, SendRequest, SendResult, classifyHttp, fetchWithTimeout, retryAfterSeconds, str } from './types.ts';

const BASE = () => Deno.env.get('NTF_META_BASE_URL') ?? 'https://graph.facebook.com';
// Meta throttling / temporary error codes that are safe to retry.
const RETRY_CODES = new Set([1, 2, 4, 17, 341, 80007, 130429, 131000, 131016, 131048, 131056, 133004]);

export class MetaWhatsAppAdapter implements ChannelAdapter {
  readonly provider = 'meta';
  readonly channel = 'WHATSAPP' as const;
  async send(req: SendRequest): Promise<SendResult> {
    const token = str(req.secret.access_token);
    if (!token) return { outcome: 'FAILED', error: 'missing meta secret (access_token)' };
    const phoneId = str(req.config.phone_number_id);
    if (!phoneId) return { outcome: 'FAILED', error: 'meta config needs phone_number_id' };
    const to = req.recipient.phone;
    if (!to || !/^\+[1-9]\d{6,14}$/.test(to)) return { outcome: 'FAILED', error: 'recipient has no E.164 phone' };
    const name = str(req.payload.template_name);
    if (!name) return { outcome: 'FAILED', error: 'whatsapp template_name missing (approved template required)' };
    const params = Array.isArray(req.payload.params) ? req.payload.params.map((p) => ({ type: 'text', text: String(p) })) : [];
    const body = {
      messaging_product: 'whatsapp', to: to.slice(1), type: 'template',
      template: {
        name, language: { code: str(req.payload.language) ?? req.recipient.locale ?? 'en' },
        ...(params.length ? { components: [{ type: 'body', parameters: params }] } : {})
      }
    };
    let res: Response;
    try {
      res = await fetchWithTimeout(`${BASE()}/${str(req.config.api_version) ?? 'v21.0'}/${encodeURIComponent(phoneId)}/messages`, {
        method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body)
      });
    } catch (e) {
      return { outcome: 'RETRY', error: `meta network error: ${(e as Error).name}` };
    }
    const j = await res.json().catch(() => ({}));
    if (res.ok && j.messages?.[0]?.id) return { outcome: 'SENT', providerMessageId: j.messages[0].id, httpStatus: res.status };
    const code = Number(j.error?.code);
    const outcome = RETRY_CODES.has(code) ? 'RETRY' : classifyHttp(res.status);
    return { outcome, httpStatus: res.status, retryAfter: retryAfterSeconds(res.headers), error: `meta ${res.status} ${code || ''} ${String(j.error?.message ?? '').slice(0, 200)}`.trim() };
  }
}
