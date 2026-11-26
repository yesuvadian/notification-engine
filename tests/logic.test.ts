// deno test tests/logic.test.ts
import { assert, assertEquals, assertThrows } from 'jsr:@std/assert@1';
import { applyMappings, backoffSeconds, contextRecipients, eligible, matchesConditions, renderContent } from '../supabase/functions/notification/logic.ts';
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
