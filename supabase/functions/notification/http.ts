// HTTP helpers: CORS, error envelope, database error mapping.

export const corsHeaders: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization,content-type,x-organization-id,x-product-code,x-correlation-id,apikey,x-client-info',
  'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
  'Access-Control-Expose-Headers': 'x-correlation-id,idempotent-replayed'
};

export class ApiError extends Error {
  constructor(
    public status: number,
    public code: string,
    message?: string,
    public details?: unknown
  ) {
    super(message ?? code);
  }
}

/** Database error carrying the Postgres / PostgREST code. */
export class DbError extends Error {
  constructor(public code: string | undefined, message: string) {
    super(message);
  }
}

/** Maps Postgres / PostgREST error codes to API errors without leaking SQL details. */
export function mapDbError(e: DbError): ApiError {
  switch (e.code) {
    case '23505':
      return new ApiError(409, 'conflict', 'A record with the same key already exists');
    case '23503':
      return new ApiError(422, 'invalid_reference', 'A referenced record does not exist');
    case '23502':
    case '23514':
    case '22P02':
    case '22023':
      return new ApiError(422, 'invalid_request', e.message);
    case '42501':
      return new ApiError(403, 'forbidden', e.message);
    case 'PGRST116':
      return new ApiError(404, 'not_found', 'Record not found');
    default:
      return new ApiError(500, 'internal_error', 'Request failed');
  }
}

export function toApiError(e: unknown): ApiError {
  if (e instanceof ApiError) return e;
  if (e instanceof DbError) return mapDbError(e);
  return new ApiError(500, 'internal_error', 'Request failed');
}

export function json(body: unknown, status = 200, correlationId?: string, extra: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      'Content-Type': 'application/json',
      ...(correlationId ? { 'x-correlation-id': correlationId } : {}),
      ...extra
    }
  });
}

/** Error envelope. `error` stays a string code for backward compatibility with 0.1.x clients. */
export function errorResponse(err: ApiError, correlationId: string) {
  const body: Record<string, unknown> = { error: err.code, message: err.message, correlationId };
  if (err.details !== undefined) body.details = err.details;
  const extra: Record<string, string> = err.status === 429 ? { 'Retry-After': '30' } : {};
  return json(body, err.status, correlationId, extra);
}

/** Normalizes `/functions/v1/notification/v1/x/` → `/v1/x`. */
export function normalizePath(url: string): string {
  const rawPath = new URL(url).pathname;
  const p = rawPath.replace(/^(?:\/functions\/v1)?\/notification(?=\/|$)/, '').replace(/\/+$/, '');
  return p || '/';
}

export const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function requireString(v: unknown, name: string, max = 500): string {
  if (typeof v !== 'string' || v.trim() === '' || v.length > max) {
    throw new ApiError(422, 'invalid_request', `${name} must be a non-empty string of at most ${max} characters`);
  }
  return v;
}

export function requireArray(v: unknown, name: string, max: number): unknown[] {
  if (!Array.isArray(v)) throw new ApiError(422, 'invalid_request', `${name} must be an array`);
  if (v.length > max) throw new ApiError(413, 'payload_too_large', `${name} accepts at most ${max} items per call`);
  return v;
}

/** Constant-time string comparison for shared secrets. */
export function safeEqual(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

export async function sha256Hex(s: string): Promise<string> {
  const d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s));
  return Array.from(new Uint8Array(d)).map((x) => x.toString(16).padStart(2, '0')).join('');
}

export function randomToken(prefix = 'ntf_'): string {
  const b = crypto.getRandomValues(new Uint8Array(32));
  return prefix + btoa(String.fromCharCode(...b)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** Opaque inbox cursor: base64url("created_at|id"). */
export function encodeCursor(createdAt: string, id: string): string {
  return btoa(`${createdAt}|${id}`).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function decodeCursor(c: string): { createdAt: string; id: string } {
  try {
    const s = atob(c.replace(/-/g, '+').replace(/_/g, '/'));
    const [createdAt, id] = s.split('|');
    if (!createdAt || !UUID_RE.test(id) || isNaN(Date.parse(createdAt))) throw Error();
    return { createdAt, id };
  } catch {
    throw new ApiError(422, 'invalid_request', 'Invalid cursor');
  }
}
