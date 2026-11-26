// Fake SMS/WhatsApp/FCM provider endpoints for tests/integration_providers.py (port 9100). LOCAL ONLY.
let calls: unknown[] = [];
Deno.serve({ port: 9100 }, async (req) => {
  const u = new URL(req.url);
  if (u.pathname === '/calls') { const c = calls; calls = []; return Response.json(c); }
  const body = await req.text();
  calls.push({ path: u.pathname, auth: req.headers.get('authorization')?.slice(0, 12), authkey: req.headers.get('authkey'), body: body.slice(0, 400) });
  if (u.pathname.includes('/Messages.json')) {
    if (body.includes('%2B910000000500')) return Response.json({ code: 20500, message: 'down' }, { status: 503, headers: { 'retry-after': '2' } });
    if (body.includes('%2B910000000400')) return Response.json({ code: 21211, message: 'invalid to' }, { status: 400 });
    return Response.json({ sid: 'SM123', status: 'queued' }, { status: 201 });
  }
  if (u.pathname === '/generic/send') return Response.json({ ok: 'yes', data: { id: 'gen-' + (JSON.parse(body).to ?? '?') } });
  if (u.pathname === '/generic/reject') return Response.json({ ok: 'no' });
  if (u.pathname === '/api/v5/flow') return Response.json({ type: 'success', message: 'req-91' });
  if (u.pathname.endsWith('/messages')) return Response.json({ messages: [{ id: 'wamid.1' }] });
  if (u.pathname === '/token') return Response.json({ access_token: 'ya29.x', expires_in: 3600 });
  if (u.pathname.endsWith('messages:send')) {
    if (body.includes('"dead-token"')) return Response.json({ error: { status: 'NOT_FOUND', message: 'Requested entity was not found.' } }, { status: 404 });
    return Response.json({ name: 'projects/p/messages/1' });
  }
  return new Response('nf', { status: 404 });
});
