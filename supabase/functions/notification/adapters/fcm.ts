// Firebase Cloud Messaging HTTP v1 (PUSH). config: {provider:"fcm"}
// Vault secret JSON: the Firebase service-account key {"project_id","client_email","private_key",...}
import { importPKCS8, SignJWT } from 'npm:jose@5';
import { ChannelAdapter, SendRequest, SendResult, classifyHttp, fetchWithTimeout, str } from './types.ts';

const TOKEN_URL = () => Deno.env.get('NTF_GOOGLE_TOKEN_URL') ?? 'https://oauth2.googleapis.com/token';
const FCM_BASE = () => Deno.env.get('NTF_FCM_BASE_URL') ?? 'https://fcm.googleapis.com';
const accessTokens = new Map<string, { token: string; exp: number }>();

async function accessToken(sa: Record<string, unknown>): Promise<string> {
  const email = str(sa.client_email)!, key = str(sa.private_key)!;
  const cached = accessTokens.get(email);
  if (cached && cached.exp > Date.now() + 60000) return cached.token;
  const now = Math.floor(Date.now() / 1000);
  const assertion = await new SignJWT({ scope: 'https://www.googleapis.com/auth/firebase.messaging' })
    .setProtectedHeader({ alg: 'RS256', typ: 'JWT' }).setIssuer(email).setSubject(email)
    .setAudience('https://oauth2.googleapis.com/token').setIssuedAt(now).setExpirationTime(now + 3600)
    .sign(await importPKCS8(key, 'RS256'));
  const res = await fetchWithTimeout(TOKEN_URL(), {
    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion })
  });
  const j = await res.json().catch(() => ({}));
  if (!res.ok || !j.access_token) throw new Error(`google oauth ${res.status}`);
  accessTokens.set(email, { token: j.access_token, exp: Date.now() + (Number(j.expires_in ?? 3600) * 1000) });
  return j.access_token;
}

function stringMap(v: unknown): Record<string, string> {
  if (!v || typeof v !== 'object' || Array.isArray(v)) return {};
  return Object.fromEntries(Object.entries(v as Record<string, unknown>).map(([k, x]) => [k, typeof x === 'string' ? x : JSON.stringify(x)]));
}

export class FcmPushAdapter implements ChannelAdapter {
  readonly provider = 'fcm';
  readonly channel = 'PUSH' as const;
  async send(req: SendRequest): Promise<SendResult> {
    const projectId = str(req.secret.project_id) ?? str(req.config.project_id);
    if (!projectId || !str(req.secret.client_email) || !str(req.secret.private_key)) {
      return { outcome: 'FAILED', error: 'missing fcm secret (service account project_id, client_email, private_key)' };
    }
    if (!req.recipient.deviceTokens.length) return { outcome: 'FAILED', error: 'recipient has no registered device' };
    let bearer: string;
    try {
      bearer = await accessToken(req.secret);
    } catch (e) {
      return { outcome: 'RETRY', error: String((e as Error).message).slice(0, 200) };
    }
    const data = { ...stringMap(req.payload.data), deliveryId: req.deliveryId, ...(req.payload.action ? { action: JSON.stringify(req.payload.action) } : {}) };
    let sent = 0, retry = 0;
    const ids: string[] = [], invalid: string[] = [], errors: string[] = [];
    for (const t of req.recipient.deviceTokens) {
      try {
        const res = await fetchWithTimeout(`${FCM_BASE()}/v1/projects/${encodeURIComponent(projectId)}/messages:send`, {
          method: 'POST', headers: { Authorization: `Bearer ${bearer}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({ message: { token: t.token, notification: { title: String(req.payload.title ?? ''), body: String(req.payload.body ?? '') }, data } })
        });
        const j = await res.json().catch(() => ({}));
        if (res.ok) { sent++; ids.push(String(j.name ?? '')); continue; }
        const status = String(j.error?.status ?? '');
        if (res.status === 404 || status === 'UNREGISTERED' || (res.status === 400 && /registration token/i.test(String(j.error?.message)))) invalid.push(t.id);
        else if (classifyHttp(res.status) === 'RETRY') retry++;
        errors.push(`${res.status} ${status}`);
      } catch (e) {
        retry++;
        errors.push(`network ${(e as Error).name}`);
      }
    }
    const response = { devices: req.recipient.deviceTokens.length, sent, invalid: invalid.length };
    if (sent) return { outcome: 'SENT', providerMessageId: ids[0], response, invalidTokenIds: invalid };
    return { outcome: retry ? 'RETRY' : 'FAILED', error: `fcm ${errors.slice(0, 3).join(', ')}`, response, invalidTokenIds: invalid };
  }
}
