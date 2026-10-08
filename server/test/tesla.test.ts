import { afterAll, beforeEach, describe, expect, test } from 'bun:test';
import type { Auth } from '../src/auth';
import { createApp } from '../src/app';
import { ApiError } from '../src/errors';
import type { Telemetry } from '../src/telemetry';
import { TeslaLink, callbackParams, commanderURL } from '../src/tesla';

// Database-free: a stub device authenticator and a loopback fake commander.
const DEVICE_TOKEN = 'synthetic-device-token';
const SECRET = 'synthetic-commander-secret-0000000000';
const CODE = 'SYNTHETIC-CODE-0001', STATE = 'SYNTHETIC-STATE-0001';
const auth = { authenticate: async (header?: string) => { if (header !== `Bearer ${DEVICE_TOKEN}`) throw new ApiError(401, 'unauthorized', 'Valid device token required'); return { id: 7, name: 'Synthetic phone', createdAt: null, lastSeenAt: null }; } } as unknown as Auth;
const telemetry = {} as Telemetry;

let calls: { method: string; path: string; auth: string | null; body: any }[] = [];
let next: { status: number; body: any } | null = null;
const status = { available: true, connected: true, needsReauth: false, linkPending: false, collector: { enabled: true }, budget: { monthlyLimitUsd: 20, spentUsd: 1.5, paused: false }, accessToken: 'MUST-NOT-LEAK' };
const commander = Bun.serve({ hostname: '127.0.0.1', port: 0, async fetch(req) {
  const url = new URL(req.url);
  const body = req.method === 'GET' || req.method === 'DELETE' ? null : await req.json();
  calls.push({ method: req.method, path: url.pathname, auth: req.headers.get('authorization'), body });
  if (next) { const n = next; next = null; return Response.json(n.body, { status: n.status }); }
  if (url.pathname === '/oauth/start') return Response.json({ authorizationUrl: 'https://auth.example/authorize?state=x', callbackScheme: 'volta', expiresAt: '2026-10-07T12:10:00Z' });
  if (url.pathname === '/oauth/status' || url.pathname === '/oauth/complete') return Response.json(status);
  return Response.json({ ok: true });
} });
afterAll(() => commander.stop(true));

let logs: object[] = [];
const configured = createApp(auth, telemetry, e => logs.push(e), new TeslaLink(`http://127.0.0.1:${commander.port}`, SECRET));
const unconfigured = createApp(auth, telemetry, e => logs.push(e));
const call = (app: ReturnType<typeof createApp>, method: string, path: string, body?: unknown, token = DEVICE_TOKEN) =>
  app.request(path, { method, headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body) });
const code = async (r: Response) => (await r.json() as any).error.code;
beforeEach(() => { calls = []; next = null; logs = []; });

describe('tesla sign-in relay', () => {
  test('every route requires a paired device', async () => {
    for (const [method, path] of [['GET', '/v1/tesla/status'], ['POST', '/v1/tesla/link'], ['POST', '/v1/tesla/link/complete'], ['DELETE', '/v1/tesla/link'], ['DELETE', '/v1/tesla/account']] as const) {
      expect((await call(configured, method, path, undefined, 'wrong')).status).toBe(401);
    }
    expect(calls).toEqual([]);
  });

  test('unconfigured server reports unavailable and refuses to start', async () => {
    const s = await call(unconfigured, 'GET', '/v1/tesla/status');
    expect(s.status).toBe(200); expect((await s.json() as any).available).toBe(false);
    const r = await call(unconfigured, 'POST', '/v1/tesla/link', {});
    expect(r.status).toBe(501); expect(await code(r)).toBe('tesla_link_unavailable');
  });

  test('start binds the sign-in to the calling device', async () => {
    const r = await call(configured, 'POST', '/v1/tesla/link', {});
    expect(r.status).toBe(200);
    expect(await r.json()).toEqual({ authorizationUrl: 'https://auth.example/authorize?state=x', callbackScheme: 'volta', expiresAt: '2026-10-07T12:10:00Z' });
    expect(calls).toEqual([{ method: 'POST', path: '/oauth/start', auth: `Bearer ${SECRET}`, body: { deviceId: '7' } }]);
  });

  test('complete relays only state and code, then returns sanitized status', async () => {
    const r = await call(configured, 'POST', '/v1/tesla/link/complete', { callbackUrl: `volta://tesla-callback?code=${CODE}&state=${STATE}` });
    expect(r.status).toBe(200);
    const text = await r.text();
    expect(text).not.toContain('MUST-NOT-LEAK'); expect(text).not.toContain(SECRET);
    expect(JSON.parse(text)).toEqual({ available: true, connected: true, needsReauth: false, linkPending: false, collector: { enabled: true }, budget: { monthlyLimitUsd: 20, spentUsd: 1.5, paused: false } });
    expect(calls[0]).toEqual({ method: 'POST', path: '/oauth/complete', auth: `Bearer ${SECRET}`, body: { deviceId: '7', state: STATE, code: CODE, error: '' } });
    expect(JSON.stringify(logs)).not.toContain(CODE); expect(JSON.stringify(logs)).not.toContain(STATE);
    expect(logs).toContainEqual(expect.objectContaining({ route: '/v1/tesla/link/complete', status: 200 }));
  });

  test('malformed callbacks never reach commander', async () => {
    for (const callbackUrl of [undefined, 42, 'https://tesla-callback?state=s&code=c', 'volta://other?state=s&code=c', 'volta://tesla-callback/x?state=s&code=c', 'volta://tesla-callback?code=c', 'volta://tesla-callback?state=s', 'volta://tesla-callback?state=s&code=c&error=e', 'volta://tesla-callback?state=s&state=t&code=c', `volta://tesla-callback?state=s&code=${'a'.repeat(5000)}`]) {
      const r = await call(configured, 'POST', '/v1/tesla/link/complete', { callbackUrl });
      expect([400, 413]).toContain(r.status);
    }
    expect(calls).toEqual([]);
  });

  test('commander outcomes map to stable client errors', async () => {
    const cases: [number, string, number, string][] = [
      [400, 'oauth_state_invalid', 400, 'tesla_link_invalid'], [400, 'oauth_code_rejected', 400, 'tesla_link_invalid'],
      [400, 'oauth_denied', 400, 'tesla_link_denied'], [400, 'oauth_link_failed', 400, 'tesla_link_failed'], [409, 'oauth_device_mismatch', 409, 'tesla_link_device_mismatch'],
      [503, 'storage_unavailable', 503, 'tesla_unavailable'], [502, 'oauth_invalid_response', 503, 'tesla_unavailable'], [501, 'oauth_disabled', 501, 'tesla_link_unavailable'],
    ];
    for (const [upstream, upstreamCode, status, expected] of cases) {
      next = { status: upstream, body: { error: { code: upstreamCode, message: 'x' } } };
      const r = await call(configured, 'POST', '/v1/tesla/link/complete', { callbackUrl: `volta://tesla-callback?error=access_denied&state=${STATE}` });
      expect(r.status).toBe(status); expect(await code(r)).toBe(expected);
    }
    next = { status: 409, body: { error: { code: 'already_authorized' } } };
    const r = await call(configured, 'POST', '/v1/tesla/link', {});
    expect(r.status).toBe(409); expect(await code(r)).toBe('tesla_already_connected');
  });

  test('cancel and disconnect relay to commander', async () => {
    expect((await call(configured, 'DELETE', '/v1/tesla/link')).status).toBe(204);
    expect((await call(configured, 'DELETE', '/v1/tesla/account')).status).toBe(204);
    expect(calls.map(c => `${c.method} ${c.path} ${JSON.stringify(c.body)}`)).toEqual(['POST /oauth/cancel {"deviceId":"7"}', 'DELETE /oauth/account null']);
  });

  test('unreachable commander is a retryable 503', async () => {
    const app = createApp(auth, telemetry, () => {}, new TeslaLink('http://127.0.0.1:1', SECRET));
    const r = await call(app, 'GET', '/v1/tesla/status');
    expect(r.status).toBe(503); expect(await code(r)).toBe('tesla_unavailable');
  });

  test('configuration helpers are strict', () => {
    expect(commanderURL('http://commander:8090')).toBe('http://commander:8090');
    for (const bad of ['http://commander:8090/x', 'ftp://commander', 'http://u:p@commander:8090']) expect(() => commanderURL(bad)).toThrow();
    expect(callbackParams('volta://tesla-callback?error=access_denied&state=s')).toEqual({ state: 's', code: '', error: 'access_denied' });
  });
});
