// Pure helpers shared by the worker (unit-tested in tests/logic.test.ts).
import { path, render } from './parser.mjs';

/** Exponential backoff with jitter: 30s, 60s, 120s ... capped at 1h, jittered to 50–100%. */
export function backoffSeconds(attempt: number, retryAfter?: number, rand = Math.random): number {
  const base = Math.min(3600, 30 * 2 ** Math.max(0, attempt - 1));
  const jittered = Math.round(base * (0.5 + rand() * 0.5));
  return Math.max(retryAfter ?? 0, jittered, 1);
}

/** Renders every string leaf of a template content object; the design block is copied untouched. */
export function renderContent(content: unknown, ctx: Record<string, unknown>, key = ''): unknown {
  if (key === 'design') return content;
  if (typeof content === 'string') return render(content, ctx);
  if (Array.isArray(content)) return content.map((x) => renderContent(x, ctx));
  if (content && typeof content === 'object') {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(content)) out[k] = renderContent(v, ctx, k);
    return out;
  }
  return content;
}

/** Simple equality conditions: {"data.status": "APPROVED"}. */
export function matchesConditions(conditions: Record<string, unknown> | null | undefined, payload: unknown): boolean {
  return Object.entries(conditions ?? {}).every(([k, v]) => JSON.stringify(path(payload, k)) === JSON.stringify(v));
}

/** Recipient ids a rule asks for: role/org strategies are resolved by the caller; others come from recipientContext. */
export function contextRecipients(strategy: string, payload: Record<string, unknown>): string[] {
  const rc = payload.recipientContext as Record<string, unknown> | undefined;
  const v = rc?.[strategy.toLowerCase()];
  return Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string' && x.length <= 200) : [];
}

export interface Preference { enabled: boolean; consent_at: string | null }

/** In-app needs no consent; external channels need an enabled channel plus recorded consent. */
export function eligible(channel: string, channelEnabled: boolean, pref: Preference | undefined): boolean {
  if (!channelEnabled) return false;
  if (pref?.enabled === false) return false;
  return channel === 'IN_APP' || !!pref?.consent_at;
}

/** Resolves {{vars.x}} mappings for a rule channel. */
export function applyMappings(ctx: Record<string, unknown>, mappings: Record<string, { type: string; value?: unknown; path?: string }>) {
  const vars: Record<string, unknown> = {};
  for (const [k, m] of Object.entries(mappings ?? {})) vars[k] = m.type === 'STATIC' ? m.value : path(ctx, m.path ?? '');
  return vars;
}
