// deno test tests/logic.test.ts
import { assert, assertEquals, assertThrows } from 'jsr:@std/assert@1';
import { applyMappings, backoffSeconds, contextRecipients, eligible, eventVariables, matchesConditions, productVariableReport, renderContent, roleFields, ruleRoleCodes, schemaFields, variableIssues } from '../supabase/functions/notification/logic.ts';
import { decodeCursor, encodeCursor, mapDbError, DbError, safeEqual, normalizePath } from '../supabase/functions/notification/http.ts';

Deno.test('backoff grows, is capped and honours Retry-After', () => {
  assertEquals(backoffSeconds(1, undefined, () => 1), 30);
  assertEquals(backoffSeconds(3, undefined, () => 1), 120);
  assertEquals(backoffSeconds(20, undefined, () => 1), 3600);
  assertEquals(backoffSeconds(1, undefined, () => 0), 15);
  assertEquals(backoffSeconds(1, 300, () => 0), 300);
});

Deno.test('renderContent renders nested strings and keeps design untouched', () => {
  const out = renderContent({ title: 'Hi {{recipient.name}}', params: ['{{data.ref}}'], design: { color: '#fff' } },
    { recipient: { name: 'A' }, data: { ref: 'R1' } }) as Record<string, unknown>;
  assertEquals(out, { title: 'Hi A', params: ['R1'], design: { color: '#fff' } });
  assertThrows(() => renderContent({ body: '{{data.missing}}' }, { data: {} }));
});

Deno.test('conditions, recipients, eligibility, mappings', () => {
  assert(matchesConditions({ 'data.status': 'OK' }, { data: { status: 'OK' } }));
  assert(!matchesConditions({ 'data.status': 'OK' }, { data: { status: 'NO' } }));
  assertEquals(contextRecipients('RECORD_OWNER', { recipientContext: { record_owner: ['u1', 5, 'u2'] } }), ['u1', 'u2']);
  assert(eligible('IN_APP', true, undefined));
  assert(!eligible('SMS', true, undefined));
  assert(eligible('SMS', true, { enabled: true, consent_at: '2026-01-01' }));
  assert(!eligible('SMS', false, { enabled: true, consent_at: '2026-01-01' }));
  assert(!eligible('IN_APP', true, { enabled: false, consent_at: null }));
  assertEquals(applyMappings({ data: { a: 1 } }, { x: { type: 'PATH', path: 'data.a' }, y: { type: 'STATIC', value: 'v' } }), { x: 1, y: 'v' });
});

Deno.test('http helpers', () => {
  const c = encodeCursor('2026-11-26T10:00:00.000Z', '30000000-0000-0000-0000-000000000001');
  assertEquals(decodeCursor(c).id, '30000000-0000-0000-0000-000000000001');
  assertThrows(() => decodeCursor('garbage'));
  assertEquals(mapDbError(new DbError('23505', 'dup')).status, 409);
  assertEquals(mapDbError(new DbError('23503', 'fk')).status, 422);
  assertEquals(mapDbError(new DbError('XX000', 'boom')).status, 500);
  assert(safeEqual('abc', 'abc') && !safeEqual('abc', 'abd') && !safeEqual('abc', 'abcd'));
  assertEquals(normalizePath('https://x.supabase.co/functions/v1/notification/v1/health/'), '/v1/health');
});

Deno.test('generic http provider url guard', async () => {
  const { allowedProviderUrl } = await import('../supabase/functions/notification/adapters/http_generic.ts');
  assertEquals(allowedProviderUrl('https://api.sms.example.com/send').hostname, 'api.sms.example.com');
  for (const u of ['http://api.example.com', 'https://localhost/', 'https://169.254.169.254/', 'https://10.1.2.3/', 'https://192.168.1.1/', 'https://[::1]/']) {
    assertThrows(() => allowedProviderUrl(u));
  }
});

Deno.test('jsonEqual ignores key order but not values', async () => {
  const { jsonEqual } = await import('../supabase/functions/notification/logic.ts');
  assert(jsonEqual({ type: 'object', required: ['a'], properties: { a: { type: 'string' }, b: { type: 'number' } } },
    { properties: { b: { type: 'number' }, a: { type: 'string' } }, required: ['a'], type: 'object' }));
  assert(!jsonEqual({ required: ['a', 'b'] }, { required: ['b', 'a'] }));
  assert(!jsonEqual({ a: 1 }, { a: 1, b: 2 }));
});

const VARS = [
  { name: 'subject', type: 'string', description: 'Short subject or title line', example: 'Water tank', source: 'platform' },
  { name: 'body', type: 'string', description: 'Main message text', source: 'platform' },
  { name: 'flat', type: 'string', description: 'Flat number', source: 'product' }
];

Deno.test('schemaFields lists top-level fields with their types, required ones included', () => {
  assertEquals(schemaFields({ type: 'object', required: ['a', 'c'], properties: { a: { type: 'number' }, b: {} } }), [
    { name: 'a', type: 'number' }, { name: 'b', type: 'string' }, { name: 'c', type: 'string' }
  ]);
  assertEquals(schemaFields(null), []);
});

Deno.test('variableIssues: declared fields match, new ones are unknown, other types and bad names are refused', () => {
  const r = variableIssues({ properties: { subject: { type: 'string' }, body: { type: 'number' }, due: { type: 'string' }, 'bad-name': {} } }, VARS);
  assertEquals(r.unknown, [{ name: 'due', type: 'string' }]);
  assertEquals(r.mismatched, [{ name: 'body', type: 'number', expected: 'string' }]);
  assertEquals(r.invalid, ['bad-name']);
  const ok = variableIssues({ required: ['subject', 'body'], properties: { subject: { type: 'string' }, body: { type: 'string' } } }, VARS);
  assertEquals([ok.unknown, ok.mismatched, ok.invalid], [[], [], []]);
});

Deno.test('eventVariables describes data fields from the product variables and adds the built-ins', () => {
  const v = eventVariables({ required: ['subject'], properties: { subject: { type: 'string' }, flat: { type: 'string', description: 'Own text' }, x: {} } }, VARS);
  const by = new Map(v.map((x) => [x.path, x]));
  assertEquals(by.get('data.subject'), { path: 'data.subject', type: 'string', required: true, description: 'Short subject or title line', example: 'Water tank', source: 'platform' });
  assertEquals(by.get('data.flat')?.description, 'Own text');
  assertEquals(by.get('data.x')?.source, 'product');
  assertEquals(by.get('organization.name')?.source, 'built-in');
  assert(by.has('recipient.name'));
});

Deno.test('productVariableReport: events per variable, platform match, missing defaults and problems', () => {
  const r = productVariableReport(
    [...VARS, { name: 'amount', type: 'string', source: 'product' }],
    [{ name: 'subject', type: 'string' }, { name: 'amount', type: 'number' }, { name: 'link', type: 'string' }],
    [
      { code: 'A', version: 1, payload_schema: { properties: { subject: {}, body: {} } } },
      { code: 'A', version: 2, payload_schema: { properties: { subject: {}, flat: {}, due: {}, body: { type: 'number' } } } }
    ]
  );
  const by = new Map(r.variables.map((x) => [x.name, x]));
  assertEquals(by.get('subject')?.events, ['A v1', 'A v2']);
  assertEquals(by.get('amount')?.matchesPlatform, false);
  assertEquals(by.get('flat')?.matchesPlatform, true);
  assertEquals(r.missingDefaults, ['link']);
  assertEquals(r.problems, [
    { event: 'A v2', name: 'due', type: 'string', expected: null },
    { event: 'A v2', name: 'body', type: 'number', expected: 'string' }
  ]);
});

Deno.test('a rule can name several roles; older one-role rules keep working', () => {
  assertEquals(ruleRoleCodes({ role_codes: ['admin', 'treasurer', 'admin'], role_code: 'admin' }), ['admin', 'treasurer']);
  assertEquals(ruleRoleCodes({ role_codes: [], role_code: 'manager' }), ['manager']);
  assertEquals(ruleRoleCodes({ role_code: 'manager' }), ['manager']);
  assertEquals(ruleRoleCodes({ role_codes: null, role_code: null }), []);
  assertEquals(ruleRoleCodes({ role_codes: ['', 5, 'x'] }), ['x']);
});

Deno.test('rule bodies: role_codes wins, role_code alone is a one-role list, bad input is refused', () => {
  assertEquals(roleFields({ role_codes: [' a ', 'b', 'a'] }), { role_code: 'a', role_codes: ['a', 'b'] });
  assertEquals(roleFields({ role_codes: [] }), { role_code: null, role_codes: [] });
  assertEquals(roleFields({ role_code: 'm' }), { role_code: 'm', role_codes: ['m'] });
  assertEquals(roleFields({ role_code: null }), { role_code: null, role_codes: [] });
  assertEquals(roleFields({ role_codes: ['x'], role_code: 'y' }), { role_code: 'x', role_codes: ['x'] });
  assertEquals(roleFields({ purpose: 'p' }), null);
  assertThrows(() => roleFields({ role_codes: 'a' }));
  assertThrows(() => roleFields({ role_codes: [1] }));
  assertThrows(() => roleFields({ role_codes: [''] }));
  assertThrows(() => roleFields({ role_codes: Array.from({ length: 21 }, (_, i) => `r${i}`) }));
  assertThrows(() => roleFields({ role_code: 7 }));
});
