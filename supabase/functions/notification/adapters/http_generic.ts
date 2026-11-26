// Generic HTTP provider for any SMS or WhatsApp API, configured entirely in provider_config.
//
// provider_config example:
// {
//   "provider": "http",
//   "url": "https://api.example.com/v1/messages",
//   "method": "POST",                                   // optional, default POST
//   "content_type": "json",                              // json (default) | form
//   "headers": {"Authorization": "Bearer {{secret.api_key}}"},
//   "body": {"to": "{{to}}", "text": "{{body}}", "sender": "ACME"},
//   "message_id_path": "data.message_id",                // optional: where the provider returns its id
//   "success_path": "status", "success_values": ["ok"],  // optional: business-level success check on 2xx
//   "secret_name": "ntf_p_<product>_myprovider"
// }
// Vault secret JSON: any keys, referenced as {{secret.<key>}} in url, headers or body. Never put raw credentials in config.
// Template variables: to (E.164), to_digits (no +), body, title, template_name, language, params, delivery_id, user_id, secret.*
import { path, render } from '../parser.mjs';
import { Channel, ChannelAdapter, SendRequest, SendResult, classifyHttp, fetchWithTimeout, retryAfterSeconds, str } from './types.ts';

function renderDeep(v: unknown, ctx: Record<string, unknown>): unknown {
  if (typeof v === 'string') return render(v, ctx);
  if (Array.isArray(v)) return v.map((x) => renderDeep(x, ctx));
  if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, renderDeep(x, ctx)]));
  return v;
}

/** Blocks plain http, localhost and private/link-local IP literals. NTF_HTTP_PROVIDER_ALLOWED_HOSTS (comma list) narrows further. */
export function allowedProviderUrl(raw: string): URL {
  const u = new URL(raw);
  if (Deno.env.get('NTF_HTTP_PROVIDER_TEST_MODE') === 'true') return u; // local tests only, never set in DEV/prod
  if (u.protocol !== 'https:') throw new Error('provider url must use https');
  const h = u.hostname.toLowerCase();
  if (h === 'localhost' || h.endsWith('.local') || h.endsWith('.internal') || h === 'metadata.google.internal' ||
    /^(127\.|10\.|192\.168\.|169\.254\.|0\.|172\.(1[6-9]|2\d|3[01])\.)/.test(h) || h.startsWith('[')) {
    throw new Error('provider url host is not allowed');
  }
  const allow = (Deno.env.get('NTF_HTTP_PROVIDER_ALLOWED_HOSTS') ?? '').split(',').map((x) => x.trim().toLowerCase()).filter(Boolean);
  if (allow.length && !allow.some((a) => h === a || h.endsWith('.' + a))) throw new Error('provider url host is not in NTF_HTTP_PROVIDER_ALLOWED_HOSTS');
  return u;
}

export class GenericHttpAdapter implements ChannelAdapter {
  readonly provider = 'http';
  constructor(readonly channel: Channel) {}

  async send(req: SendRequest): Promise<SendResult> {
    const phone = req.recipient.phone;
    if (!phone || !/^\+[1-9]\d{6,14}$/.test(phone)) return { outcome: 'FAILED', error: 'recipient has no E.164 phone' };
    const cfg = req.config;
    if (!str(cfg.url)) return { outcome: 'FAILED', error: 'http provider config needs url' };
    const ctx: Record<string, unknown> = {
      ...req.payload,
      to: phone, to_digits: phone.slice(1), body: String(req.payload.sms_body ?? req.payload.body ?? ''),
      title: String(req.payload.title ?? ''), language: req.payload.language ?? req.recipient.locale ?? 'en',
      params: req.payload.params ?? [], delivery_id: req.deliveryId, user_id: req.recipient.userId, secret: req.secret
    };
    let url: URL, headers: Record<string, string>, body: string | undefined;
    const method = String(cfg.method ?? 'POST').toUpperCase();
    try {
      url = allowedProviderUrl(render(String(cfg.url), ctx));
      headers = Object.fromEntries(Object.entries((renderDeep(cfg.headers ?? {}, ctx) ?? {}) as Record<string, unknown>).map(([k, v]) => [k, String(v)]));
      if (method !== 'GET' && cfg.body !== undefined) {
        const rendered = renderDeep(cfg.body, ctx);
        if (cfg.content_type === 'form') {
          headers['Content-Type'] ??= 'application/x-www-form-urlencoded';
          body = new URLSearchParams(Object.entries(rendered as Record<string, unknown>).map(([k, v]) => [k, typeof v === 'string' ? v : JSON.stringify(v)])).toString();
        } else {
          headers['Content-Type'] ??= 'application/json';
          body = JSON.stringify(rendered);
        }
      }
    } catch (e) {
      return { outcome: 'FAILED', error: `http provider config: ${String((e as Error).message).slice(0, 200)}` };
    }
    let res: Response;
    try {
      res = await fetchWithTimeout(url.toString(), { method, headers, body, redirect: 'manual' });
    } catch (e) {
      return { outcome: 'RETRY', error: `http provider network error: ${(e as Error).name}` };
    }
    const text = await res.text().catch(() => '');
    let j: unknown = undefined;
    try { j = text ? JSON.parse(text) : undefined; } catch { /* non-JSON response */ }
    if (res.ok) {
      if (str(cfg.success_path) && Array.isArray(cfg.success_values)) {
        const v = j === undefined ? undefined : path(j, String(cfg.success_path));
        if (!(cfg.success_values as unknown[]).map(String).includes(String(v))) {
          return { outcome: 'FAILED', httpStatus: res.status, error: `http provider rejected: ${String(v).slice(0, 100)}` };
        }
      }
      const id = str(cfg.message_id_path) && j !== undefined ? path(j, String(cfg.message_id_path)) : undefined;
      return { outcome: 'SENT', httpStatus: res.status, providerMessageId: id == null ? undefined : String(id) };
    }
    return { outcome: classifyHttp(res.status), httpStatus: res.status, retryAfter: retryAfterSeconds(res.headers), error: `http provider ${res.status} ${text.slice(0, 150)}` };
  }
}
