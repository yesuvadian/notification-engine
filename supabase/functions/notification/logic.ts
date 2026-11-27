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

/** The roles an ALL_USERS_IN_ROLE rule notifies: role_codes, else the older single role_code. */
export function ruleRoleCodes(rule: { role_codes?: unknown; role_code?: unknown }): string[] {
  const many = Array.isArray(rule.role_codes) ? rule.role_codes.filter((c): c is string => typeof c === 'string' && c.length > 0) : [];
  if (many.length) return [...new Set(many)];
  return typeof rule.role_code === 'string' && rule.role_code ? [rule.role_code] : [];
}

/**
 * The role fields of a rule create/update body. role_codes (a list) wins over role_code; role_code alone is
 * kept working as a one-role list. Returns null when the body names no roles. Throws a message on bad input.
 */
export function roleFields(b: Record<string, unknown>): { role_code: string | null; role_codes: string[] } | null {
  if ('role_codes' in b) {
    const v = b.role_codes;
    if (!Array.isArray(v) || v.length > 20 || v.some((c) => typeof c !== 'string' || !c.trim() || c.length > 100)) {
      throw new Error('role_codes must be a list of up to 20 role codes');
    }
    const codes = [...new Set(v.map((c) => (c as string).trim()))];
    return { role_code: codes[0] ?? null, role_codes: codes };
  }
  if ('role_code' in b) {
    const c = b.role_code;
    if (c !== null && (typeof c !== 'string' || !c.trim() || c.length > 100)) throw new Error('role_code must be a role code');
    const code = typeof c === 'string' ? c.trim() : null;
    return { role_code: code, role_codes: code ? [code] : [] };
  }
  return null;
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

export interface TemplateVariable { path: string; type: string; required: boolean; description?: string }

/** Flattens a JSON schema into insertable template variable paths (objects recurse, arrays expose [0] and count). */
export function schemaVariables(schema: unknown, prefix: string, depth = 0): TemplateVariable[] {
  const s = (schema ?? {}) as Record<string, unknown>;
  const props = (s.properties ?? {}) as Record<string, Record<string, unknown>>;
  const required = new Set(Array.isArray(s.required) ? (s.required as string[]) : []);
  const out: TemplateVariable[] = [];
  for (const k of new Set([...Object.keys(props), ...required])) {
    const ps = props[k] ?? {};
    const t = String(ps.type ?? 'string');
    const path = `${prefix}.${k}`;
    if (t === 'object' && depth < 4) out.push(...schemaVariables(ps, path, depth + 1));
    else out.push({ path, type: t, required: required.has(k), ...(typeof ps.description === 'string' ? { description: ps.description } : {}) });
  }
  return out;
}

/** Deep-equality for JSON values regardless of object key order (jsonb reorders keys). */
export function jsonEqual(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (typeof a !== typeof b || a === null || b === null || typeof a !== 'object') return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  if (Array.isArray(a)) return a.length === (b as unknown[]).length && a.every((x, i) => jsonEqual(x, (b as unknown[])[i]));
  const ka = Object.keys(a as object), kb = Object.keys(b as object);
  return ka.length === kb.length && ka.every((k) => Object.hasOwn(b as object, k) && jsonEqual((a as Record<string, unknown>)[k], (b as Record<string, unknown>)[k]));
}

/** A variable a product's events may send in `data` (spec: variables are product level, seeded from platform defaults). */
export interface VariableDef { name: string; type: string; description?: string | null; example?: string | null; source?: string }
export const VARIABLE_TYPES = ['string', 'number', 'integer', 'boolean', 'object', 'array'];
export const VARIABLE_NAME_RE = /^[A-Za-z][A-Za-z0-9_]{0,49}$/;

/** Fields the engine adds to every render context; they are not sent by products. */
export const BUILT_IN_VARIABLES: TemplateVariable[] = [
  { path: 'recipient.name', type: 'string', required: false, description: 'Recipient display name' },
  { path: 'recipient.id', type: 'string', required: true, description: 'Recipient user id' },
  { path: 'recipient.locale', type: 'string', required: false, description: 'Recipient locale' },
  { path: 'organization.name', type: 'string', required: false, description: 'Organization name' }
];

/** The top-level fields of an event's payload schema with their JSON types (string when unstated). */
export function schemaFields(schema: unknown): { name: string; type: string }[] {
  const s = (schema ?? {}) as Record<string, unknown>;
  const props = (s.properties ?? {}) as Record<string, Record<string, unknown>>;
  const required = Array.isArray(s.required) ? (s.required as string[]) : [];
  return [...new Set([...Object.keys(props), ...required])].map((name) => ({ name, type: String(props[name]?.type ?? 'string') }));
}

/**
 * Compares an event's fields with the product's variables: `unknown` are fields the product has not declared yet,
 * `mismatched` are fields whose type differs from the declared variable, `invalid` are names a variable cannot have.
 */
export function variableIssues(schema: unknown, vars: VariableDef[]) {
  const byName = new Map(vars.map((v) => [v.name, v]));
  const unknown: { name: string; type: string }[] = [];
  const mismatched: { name: string; type: string; expected: string }[] = [];
  const invalid: string[] = [];
  for (const f of schemaFields(schema)) {
    if (!VARIABLE_NAME_RE.test(f.name) || !VARIABLE_TYPES.includes(f.type)) { invalid.push(f.name); continue; }
    const v = byName.get(f.name);
    if (!v) unknown.push(f);
    else if (v.type !== f.type) mismatched.push({ ...f, expected: v.type });
  }
  return { unknown, mismatched, invalid };
}

/** Template variables for an event: its data fields described from the product's variables, then the built-ins. */
export function eventVariables(schema: unknown, vars: VariableDef[]): (TemplateVariable & { source: string; example?: string })[] {
  const byName = new Map(vars.map((v) => [v.name, v]));
  return [
    ...schemaVariables(schema, 'data').map((t) => {
      const v = byName.get(t.path.split('.')[1]);
      return {
        ...t,
        ...(t.description ? {} : v?.description ? { description: v.description } : {}),
        ...(v?.example ? { example: v.example } : {}),
        source: v?.source ?? 'product'
      };
    }),
    ...BUILT_IN_VARIABLES.map((t) => ({ ...t, source: 'built-in' }))
  ];
}

/**
 * The product's variables for the console: each with the events that send it and whether it matches the platform
 * default of the same name; plus defaults the product has not copied and event fields it has not declared.
 */
export function productVariableReport(
  vars: VariableDef[],
  defaults: { name: string; type: string }[],
  events: { code: string; version: number; payload_schema: unknown }[]
) {
  const def = new Map(defaults.map((d) => [d.name, d.type]));
  const usedBy = new Map<string, string[]>();
  const problems: { event: string; name: string; type: string; expected: string | null }[] = [];
  for (const e of events) {
    const { unknown, mismatched } = variableIssues(e.payload_schema, vars);
    for (const f of schemaFields(e.payload_schema)) {
      usedBy.set(f.name, [...(usedBy.get(f.name) ?? []), `${e.code} v${e.version}`]);
    }
    for (const u of unknown) problems.push({ event: `${e.code} v${e.version}`, name: u.name, type: u.type, expected: null });
    for (const x of mismatched) problems.push({ event: `${e.code} v${e.version}`, name: x.name, type: x.type, expected: x.expected });
  }
  const have = new Set(vars.map((v) => v.name));
  return {
    variables: vars.map((v) => ({
      ...v,
      events: usedBy.get(v.name) ?? [],
      matchesPlatform: !def.has(v.name) || def.get(v.name) === v.type
    })),
    missingDefaults: defaults.filter((d) => !have.has(d.name)).map((d) => d.name),
    problems
  };
}
