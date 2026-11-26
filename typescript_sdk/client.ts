// Minimal server-side client for the notification engine (spec §40, §41). Trusted backends only.

export class NotificationError extends Error {
  constructor(public status: number, public code?: string, message?: string, public correlationId?: string) {
    super(message ?? `Notification API ${status}${code ? ' ' + code : ''}`);
  }
}

export interface NotificationClientOptions {
  /** Required with a product-level token; optional with a tenant service token. */
  organizationId?: string;
  maxRetries?: number;
  timeoutMs?: number;
}

export class NotificationClient {
  /** baseUrl is the function root, e.g. https://<ref>.supabase.co/functions/v1/notification */
  constructor(private baseUrl: string, private token: string, private opts: NotificationClientOptions = {}) {}

  private async call<T>(method: string, path: string, body?: unknown, organizationId?: string): Promise<T> {
    const org = organizationId ?? this.opts.organizationId;
    const headers: Record<string, string> = { Authorization: `Bearer ${this.token}`, 'Content-Type': 'application/json' };
    if (org) headers['X-Organization-Id'] = org;
    const max = this.opts.maxRetries ?? 3;
    for (let attempt = 0; ; attempt++) {
      let delay = Math.min(30, 2 ** attempt);
      try {
        const r = await fetch(this.baseUrl.replace(/\/$/, '') + path, {
          method, headers, body: body === undefined ? undefined : JSON.stringify(body),
          signal: AbortSignal.timeout(this.opts.timeoutMs ?? 20000)
        });
        const text = await r.text();
        const j = text ? JSON.parse(text) : null;
        if (r.ok) return j as T;
        const retryable = r.status === 429 || r.status >= 500;
        if (!retryable || attempt >= max) throw new NotificationError(r.status, j?.error, j?.message, j?.correlationId);
        delay = Number(r.headers.get('retry-after')) || delay;
      } catch (e) {
        if (e instanceof NotificationError || attempt >= max) throw e;
      }
      await new Promise((res) => setTimeout(res, delay * 1000 * (0.5 + Math.random() / 2)));
    }
  }

  /** Durable acceptance; identical retries return the same id, a reused key with a different payload throws 409. */
  publish(event: Record<string, unknown>, organizationId?: string) {
    return this.call<{ id: string; status: string }>('POST', '/v1/events/publish', event, organizationId);
  }
  syncUsers(users: Record<string, unknown>[], organizationId?: string) {
    return this.call<{ synced: number }>('POST', '/v1/users/sync', { users }, organizationId);
  }
  syncRoles(roles: Record<string, unknown>[], organizationId?: string) {
    return this.call<{ synced: number }>('POST', '/v1/roles/sync', { roles }, organizationId);
  }
  exchangeToken(userId: string, scope: 'user' | 'admin' = 'user', ttlSeconds = 3600, organizationId?: string) {
    return this.call<{ accessToken: string; expiresAt: string; scope: string }>('POST', '/v1/auth/exchange', { userId, scope, ttlSeconds }, organizationId);
  }
  /** Registers versioned event contracts; changing an existing version throws 409. */
  syncMetadata(events: Record<string, unknown>[], organizationId?: string) {
    return this.call<{ created: number; unchanged: number }>('POST', '/v1/metadata/sync', { events }, organizationId);
  }
  provisionTenant(organizationId: string, organizationName?: string, channels: Record<string, boolean> = {}) {
    return this.call<{ tenantId: string; status: string }>('POST', '/v1/tenants/provision', { organizationId, organizationName, notificationChannels: channels });
  }
}
