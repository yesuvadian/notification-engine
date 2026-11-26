import { createClient } from 'npm:@supabase/supabase-js@2';
import { DbError } from './http.ts';

export const db = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  { db: { schema: 'ntf' }, auth: { persistSession: false, autoRefreshToken: false } }
);

/** Awaits a PostgREST builder and throws DbError (with the Postgres code) on failure. */
// deno-lint-ignore no-explicit-any
// deno-lint-ignore no-explicit-any
export async function q(p: PromiseLike<{ data: any; error: any }>): Promise<any> {
  const { data, error } = await p;
  if (error) {
    console.error('NTF Database Error:', JSON.stringify({ code: error.code, message: error.message }));
    throw new DbError(error.code, error.message);
  }
  return data;
}

export interface AuditEntry {
  tenantId?: string | null;
  productId?: string | null;
  actor: string;
  action: string;
  details?: Record<string, unknown>;
  correlationId?: string;
}

/** Best-effort audit write; never fails the request. Never pass tokens or secrets in details. */
export async function audit(e: AuditEntry) {
  const { error } = await db.from('ntf_audit_logs').insert({
    tenant_id: e.tenantId ?? null,
    product_id: e.productId ?? null,
    actor: e.actor,
    action: e.action,
    details: e.details ?? {},
    correlation_id: e.correlationId ?? null
  });
  if (error) console.error('NTF Audit Error:', JSON.stringify({ code: error.code, action: e.action }));
}
