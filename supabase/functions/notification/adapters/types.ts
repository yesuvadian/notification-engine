// Channel adapter contract (spec §8 "Channel adapters", §26 provider adapters).

export type Channel = 'IN_APP' | 'PUSH' | 'SMS' | 'WHATSAPP';

export interface Recipient {
  userId: string;
  displayName: string | null;
  phone: string | null;
  email: string | null;
  locale: string | null;
  /** Active FCM registration tokens (PUSH only). */
  deviceTokens: { id: string; token: string }[];
}

export interface SendRequest {
  deliveryId: string;
  tenantId: string;
  channel: Channel;
  /** Rendered template content: title, body and channel-specific fields (template_name, params, data...). */
  payload: Record<string, unknown>;
  recipient: Recipient;
  /** Non-secret provider settings from ntf_channels.provider_config. */
  config: Record<string, unknown>;
  /** Secret JSON loaded from Vault (never logged or stored). */
  secret: Record<string, unknown>;
}

export interface SendResult {
  outcome: 'SENT' | 'ACCEPTED' | 'RETRY' | 'FAILED';
  providerMessageId?: string;
  httpStatus?: number;
  /** Short sanitized error, never includes secrets or full recipient data. */
  error?: string;
  /** Seconds to wait before retrying (from Retry-After). */
  retryAfter?: number;
  /** Sanitized response fields worth keeping. */
  response?: Record<string, unknown>;
  /** Device token ids the provider reported as invalid (PUSH). */
  invalidTokenIds?: string[];
}

export interface ChannelAdapter {
  readonly provider: string;
  readonly channel: Channel;
  send(req: SendRequest): Promise<SendResult>;
}

/** Classifies an HTTP status from a provider into retry / permanent failure. */
export function classifyHttp(status: number): 'RETRY' | 'FAILED' {
  return status === 408 || status === 425 || status === 429 || status >= 500 ? 'RETRY' : 'FAILED';
}

export function retryAfterSeconds(h: Headers): number | undefined {
  const v = h.get('retry-after');
  if (!v) return undefined;
  const n = Number(v);
  if (!isNaN(n)) return Math.min(Math.max(n, 1), 3600);
  const t = Date.parse(v);
  return isNaN(t) ? undefined : Math.min(Math.max(Math.round((t - Date.now()) / 1000), 1), 3600);
}

/** fetch with a hard timeout; network errors and timeouts surface as RETRY results by callers. */
export async function fetchWithTimeout(url: string, init: RequestInit, ms = 15000): Promise<Response> {
  const c = new AbortController();
  const t = setTimeout(() => c.abort(), ms);
  try {
    return await fetch(url, { ...init, signal: c.signal });
  } finally {
    clearTimeout(t);
  }
}

export function str(v: unknown): string | undefined {
  return typeof v === 'string' && v.trim() !== '' ? v : undefined;
}
