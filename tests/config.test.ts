// Unit tests for provider configuration validation (platform channels, spec §50). Run: deno test -A tests/config.test.ts
import { assertEquals, assertThrows } from 'jsr:@std/assert@1';
import { validateProviderConfig } from '../supabase/functions/notification/config.ts';

Deno.test('every provider option is accepted for its channel', () => {
  assertEquals(validateProviderConfig('SMS', { provider: 'msg91' })?.provider, 'msg91');
  assertEquals(validateProviderConfig('SMS', { provider: 'TWILIO', from: '+1555' })?.provider, 'twilio');
  assertEquals(validateProviderConfig('WHATSAPP', { provider: 'meta', phone_number_id: '1' })?.provider, 'meta');
  assertEquals(validateProviderConfig('PUSH', { provider: 'fcm' })?.provider, 'fcm');
  assertEquals(validateProviderConfig('SMS', { provider: 'http', url: 'https://api.example.com/send' })?.provider, 'http');
  assertEquals(validateProviderConfig('SMS', {})?.provider, 'mock');
  assertEquals(validateProviderConfig('SMS', undefined), undefined);
});

Deno.test('provider must match the channel', () => {
  assertThrows(() => validateProviderConfig('PUSH', { provider: 'twilio' }));
  assertThrows(() => validateProviderConfig('SMS', { provider: 'fcm' }));
});

Deno.test('inline credentials are rejected; secret_name is allowed', () => {
  for (const k of ['api_key', 'auth_token', 'password', 'private_key', 'secret']) {
    assertThrows(() => validateProviderConfig('SMS', { provider: 'msg91', [k]: 'x' }));
  }
  assertEquals(validateProviderConfig('SMS', { provider: 'msg91', secret_name: 'ntf_shared_sms' })?.secret_name, 'ntf_shared_sms');
});

Deno.test('http provider needs a safe url and object headers', () => {
  assertThrows(() => validateProviderConfig('SMS', { provider: 'http' }));
  assertThrows(() => validateProviderConfig('SMS', { provider: 'http', url: 'http://10.0.0.1/send' }));
  assertThrows(() => validateProviderConfig('SMS', { provider: 'http', url: 'https://api.example.com', headers: [] }));
});

Deno.test('config must be a small object', () => {
  assertThrows(() => validateProviderConfig('SMS', 'msg91'));
  assertThrows(() => validateProviderConfig('SMS', [1]));
  assertThrows(() => validateProviderConfig('SMS', { provider: 'msg91', note: 'x'.repeat(5000) }));
});
