import { afterAll, beforeEach, describe, expect, test } from 'bun:test';
import type { Auth } from '../src/auth';
import { createApp } from '../src/app';
import { ApiError } from '../src/errors';
import type { Telemetry } from '../src/telemetry';
import { TeslaLink } from '../src/tesla';
import { commandNames } from '../src/commands';

const DEVICE_TOKEN = 'synthetic-device-token';
const SECRET = 'synthetic-commander-secret-0000000000';
const INTENT = 'synthetic_intent_00000001';
const auth = { authenticate: async (header?: string) => {
  if (header !== `Bearer ${DEVICE_TOKEN}`) throw new ApiError(401, 'unauthorized', 'Valid device token required');
  return { id: 7, name: 'Synthetic phone', createdAt: null, lastSeenAt: null };
} } as unknown as Auth;
const telemetry = { vehicle: async (id: number) => {
  if (id !== 1) throw new ApiError(404, 'not_found', 'Resource not found');
  return { id: 1 };
} } as unknown as Telemetry;

type Call = { method: string; path: string; auth: string | null; key: string | null; contentType: string | null; body: string };
let calls: Call[] = [];
let replyMode: string | null = 'live';
let nextCapability: (() => Response) | null = null;
let nextCommand: (() => Response) | null = null;
const commander = Bun.serve({ hostname: '127.0.0.1', port: 0, async fetch(req) {
  const url = new URL(req.url), body = req.method === 'POST' ? await req.text() : '';
  calls.push({ method: req.method, path: url.pathname, auth: req.headers.get('Authorization'), key: req.headers.get('Idempotency-Key'), contentType: req.headers.get('Content-Type'), body });
  if (req.method === 'GET' && nextCapability) { const response = nextCapability(); nextCapability = null; return response; }
  if (req.method === 'POST' && nextCommand) { const response = nextCommand(); nextCommand = null; if (replyMode) response.headers.set('X-Volta-Command-Mode', replyMode); return response; }
  if (req.method === 'GET') return Response.json({ available: true, reason: null, commands: commandNames });
  return Response.json({ ok: true, command: url.pathname.split('/').at(-1), requestId: '0123456789abcdef' }, { headers: replyMode ? { 'X-Volta-Command-Mode': replyMode } : {} });
} });
afterAll(() => commander.stop(true));

const configured = createApp(auth, telemetry, () => {}, new TeslaLink(`http://127.0.0.1:${commander.port}`, SECRET));
const unconfigured = createApp(auth, telemetry, () => {});
const request = (app: ReturnType<typeof createApp>, method: string, path: string, body?: string, headers: Record<string, string> = {}) => app.request(path, {
  method, headers: { Authorization: `Bearer ${DEVICE_TOKEN}`, ...(body === undefined ? {} : { 'Content-Type': 'application/json' }), ...headers }, body,
});
const post = (name: string, body: string, headers: Record<string, string> = {}) => request(configured, 'POST', `/v1/vehicles/1/commands/${name}`, body, { 'Idempotency-Key': INTENT, ...headers });
const json = async (response: Response) => await response.json() as any;
beforeEach(() => { calls = []; nextCapability = null; nextCommand = null; replyMode = 'live'; });

describe('vehicle command capability', () => {
  test('capability is authenticated and checks local vehicle access before commander', async () => {
    expect((await configured.request('/v1/vehicles/1/commands')).status).toBe(401);
    const missing = await request(configured, 'GET', '/v1/vehicles/999/commands');
    expect(missing.status).toBe(404); expect(calls).toEqual([]);
  });

  test('an unconfigured relay fails closed without contacting commander', async () => {
    const response = await request(unconfigured, 'GET', '/v1/vehicles/1/commands');
    expect(response.status).toBe(200);
    expect(await json(response)).toEqual({ available: false, reason: 'commands_unavailable', commands: [] });
    expect(response.headers.get('Cache-Control')).toBe('no-store');
  });

  test('relays only the strict capability shape and internal authorization', async () => {
    const response = await request(configured, 'GET', '/v1/vehicles/1/commands');
    expect(await json(response)).toEqual({ available: true, reason: null, commands: commandNames });
    expect(calls).toEqual([{ method: 'GET', path: '/v1/vehicles/1/commands', auth: `Bearer ${SECRET}`, key: null, contentType: null, body: '' }]);
  });

  test('preserves safe unavailable reasons and rejects stub, locate, malformed, or absent capabilities', async () => {
    nextCapability = () => Response.json({ available: false, reason: 'command_scope_required', commands: [] });
    expect(await json(await request(configured, 'GET', '/v1/vehicles/1/commands'))).toEqual({ available: false, reason: 'command_scope_required', commands: [] });
    for (const response of [
      () => Response.json({ available: false, reason: 'stub_mode', commands: [] }),
      () => Response.json({ available: true, reason: null, commands: ['lock', 'locate'] }),
      () => Response.json({ available: true, reason: null, commands: ['lock'], secret: 'must-not-leak' }),
      () => Response.json({ error: { code: 'not_found', message: 'old commander' } }, { status: 404 }),
    ]) {
      nextCapability = response;
      const result = await request(configured, 'GET', '/v1/vehicles/1/commands');
      const body = await json(result);
      if (body.reason === 'stub_mode') expect(body).toEqual({ available: false, reason: 'stub_mode', commands: [] });
      else expect(body).toEqual({ available: false, reason: 'commands_unavailable', commands: [] });
      expect(JSON.stringify(body)).not.toContain('must-not-leak');
    }
  });
});

describe('vehicle command relay', () => {
  test('requires device auth and local vehicle access before relay', async () => {
    expect((await configured.request('/v1/vehicles/1/commands/lock', { method: 'POST', body: '{}' })).status).toBe(401);
    const missing = await request(configured, 'POST', '/v1/vehicles/999/commands/lock', '{}', { 'Idempotency-Key': INTENT });
    expect(missing.status).toBe(404); expect(calls).toEqual([]);
  });

  test('forwards validated typed parameters, intent key, and no device credential', async () => {
    const response = await post('set_temps', '{"passengerTempC":21,"driverTempC":20}');
    expect(response.status).toBe(200);
    expect(await json(response)).toEqual({ ok: true, command: 'set_temps', requestId: '0123456789abcdef' });
    expect(calls).toEqual([
      { method: 'GET', path: '/v1/vehicles/1/commands', auth: `Bearer ${SECRET}`, key: null, contentType: null, body: '' },
      { method: 'POST', path: '/v1/vehicles/1/commands/set_temps', auth: `Bearer ${SECRET}`, key: INTENT, contentType: 'application/json', body: '{"passengerTempC":21,"driverTempC":20}' },
    ]);
  });

  test('accepts the added typed heat commands', async () => {
    for (const [name, body] of [['seat_heater', '{"heater":5,"level":3}'], ['steering_wheel_heat', '{"on":true}'], ['defrost', '{"on":false}']] as const) {
      const response = await post(name, body);
      expect(response.status).toBe(200); expect((await json(response)).command).toBe(name);
    }
    expect(calls.filter(call => call.method === 'POST').map(call => call.body)).toEqual(['{"heater":5,"level":3}', '{"on":true}', '{"on":false}']);
  });

  test('accepts every parameterized command shape at documented boundaries', async () => {
    for (const [name, body] of [
      ['set_temps', '{"driverTempC":15,"passengerTempC":28}'],
      ['set_charge_limit', '{"percent":100}'],
      ['actuate_trunk', '{"whichTrunk":"front"}'],
      ['window_control', '{"command":"close"}'],
      ['trigger_homelink', '{"latitude":-90,"longitude":180}'],
    ] as const) expect((await post(name, body)).status).toBe(200);
    expect(calls.filter(call => call.method === 'POST')).toHaveLength(5);
  });

  test('rejects missing keys, unsupported commands, non-JSON, extra and duplicate parameters before relay', async () => {
    const cases: [string, string, Record<string, string>?, string?][] = [
      ['lock', '{}', { 'Idempotency-Key': '' }, 'idempotency_key_required'],
      ['locate', '{}', undefined, 'invalid_command'],
      ['set_charge_limit', '{"percent":80.5}', undefined, 'invalid_params'],
      ['set_temps', '{"driverTempC":"20","passengerTempC":21}', undefined, 'invalid_params'],
      ['trigger_homelink', '{"latitude":91,"longitude":0}', undefined, 'invalid_params'],
      ['seat_heater', '{"heater":6,"level":2}', undefined, 'invalid_params'],
      ['seat_heater', '{"heater":1,"level":2,"extra":true}', undefined, 'invalid_params'],
      ['seat_heater', '{"heater":1,"level":2,"he\\u0061ter":2}', undefined, 'invalid_params'],
      ['steering_wheel_heat', '{"on":1}', undefined, 'invalid_params'],
      ['defrost', '{"on":true}', { 'Content-Type': 'text/plain' }, 'invalid_params'],
    ];
    for (const [name, body, headers, expected] of cases) {
      const response = await post(name, body, headers);
      expect(response.status).toBe(400); expect((await json(response)).error.code).toBe(expected);
    }
    expect(calls).toEqual([]);
  });

  test('rejects command bodies over 4096 bytes before relay', async () => {
    const response = await post('lock', `{"padding":"${'a'.repeat(4096)}"}`);
    expect(response.status).toBe(413); expect((await json(response)).error.code).toBe('payload_too_large');
    expect(calls).toEqual([]);
  });

  test('preserves safe upstream status, receipt, and retry/idempotency headers but replaces messages', async () => {
    nextCommand = () => Response.json({ error: { code: 'command_in_progress', message: `raw ${SECRET}` }, command: 'lock', requestId: 'fedcba9876543210', private: SECRET }, { status: 409, headers: { 'Retry-After': '2', 'Idempotency-Replayed': 'true' } });
    const response = await post('lock', '{}');
    expect(response.status).toBe(409); expect(response.headers.get('Retry-After')).toBe('2'); expect(response.headers.get('Idempotency-Replayed')).toBe('true');
    const text = await response.text();
    expect(text).not.toContain(SECRET);
    expect(JSON.parse(text)).toEqual({ error: { code: 'command_in_progress', message: 'Another command is running; retry this same intent shortly' }, command: 'lock', requestId: 'fedcba9876543210' });
  });

  test('preserves command budget failures with fixed safe messages', async () => {
    for (const [status, code, message] of [
      [503, 'command_budget_unavailable', 'Vehicle command accounting is temporarily unavailable; the command was not sent'],
      [429, 'command_budget_exhausted', 'The monthly vehicle command budget is spent'],
    ] as const) {
      nextCommand = () => Response.json({ error: { code, message: `unsafe ${SECRET}` } }, { status });
      const response = await post('lock', '{}');
      expect(response.status).toBe(status); expect(await json(response)).toEqual({ error: { code, message } });
    }
  });

  test('successful replays preserve the receipt header', async () => {
    nextCommand = () => Response.json({ ok: true, command: 'lock', requestId: '0123456789abcdef', private: SECRET }, { headers: { 'Idempotency-Replayed': 'true' } });
    const response = await post('lock', '{}');
    expect(response.status).toBe(200); expect(response.headers.get('Idempotency-Replayed')).toBe('true');
    expect(await json(response)).toEqual({ ok: true, command: 'lock', requestId: '0123456789abcdef' });
  });

  test('malformed responses and transport ambiguity become command_outcome_unknown without retrying', async () => {
    nextCommand = () => Response.json({ ok: true, command: 'unlock', requestId: SECRET });
    let response = await post('lock', '{}');
    expect(response.status).toBe(502); expect((await json(response)).error.code).toBe('command_outcome_unknown');
    expect(calls.filter(call => call.method === 'POST')).toHaveLength(1);

    const failingFetch = (async (_input: RequestInfo | URL, init?: RequestInit) => {
      if (init?.method === 'GET') return Response.json({ available: true, reason: null, commands: commandNames });
      throw new Error('synthetic timeout detail');
    }) as unknown as typeof fetch;
    const app = createApp(auth, telemetry, () => {}, new TeslaLink('http://127.0.0.1:1', SECRET, failingFetch));
    response = await request(app, 'POST', '/v1/vehicles/1/commands/lock', '{}', { 'Idempotency-Key': INTENT });
    expect(response.status).toBe(504); expect(await json(response)).toEqual({ error: { code: 'command_outcome_unknown', message: 'Command may have run; check the vehicle before trying again' } });
  });

  test('fresh capability preflight blocks cached-live clients after commander enters stub mode', async () => {
    nextCapability = () => Response.json({ available: false, reason: 'stub_mode', commands: [] });
    const response = await post('lock', '{}');
    expect(response.status).toBe(501); expect(await json(response)).toEqual({ error: { code: 'stub_mode', message: 'Live vehicle commands are unavailable in stub mode' } });
    expect(calls.map(call => call.method)).toEqual(['GET']);
  });

  test('success cannot be mistaken for live execution if the process changes after preflight', async () => {
    for (const mode of ['stub', null]) {
      replyMode = mode;
      const response = await post('lock', '{}');
      expect(response.status).toBe(502);
      expect((await json(response)).error.code).toBe('command_outcome_unknown');
    }
  });

  test('unknown inherited error-property names remain ambiguous', async () => {
    nextCommand = () => Response.json({ error: { code: 'constructor' } }, { status: 503 });
    const response = await post('lock', '{}');
    expect(response.status).toBe(502);
    expect((await json(response)).error.code).toBe('command_outcome_unknown');
  });

  test('fresh capability preflight blocks commands omitted by a ready commander', async () => {
    nextCapability = () => Response.json({ available: true, reason: null, commands: ['unlock'] });
    const response = await post('lock', '{}');
    expect(response.status).toBe(400); expect((await json(response)).error.code).toBe('invalid_command');
    expect(calls.map(call => call.method)).toEqual(['GET']);
  });

  test('unconfigured servers retain the phase-one 501 behavior', async () => {
    const response = await request(unconfigured, 'POST', '/v1/vehicles/1/commands/wake', '{}');
    expect(response.status).toBe(501); expect((await json(response)).error.code).toBe('commands_unavailable');
  });
});
