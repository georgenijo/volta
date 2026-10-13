import { ApiError } from './errors';
import { commandCapability, type CommandCapability, type CommandName, type CommandParams } from './commands';

// Tesla sign-in is owned by commander on a private network. volta-api relays a
// paired device's requests and never sees Tesla tokens or the client secret.
export type TeslaStatus = {
  available: boolean; connected: boolean; needsReauth: boolean; linkPending: boolean;
  commandsEnabled: boolean; commandScopeRequired: boolean;
  collector: { enabled: boolean }; budget: { monthlyLimitUsd: number; spentUsd: number; paused: boolean };
};
export const unavailableStatus: TeslaStatus = { available: false, connected: false, needsReauth: false, linkPending: false, commandsEnabled: false, commandScopeRequired: false, collector: { enabled: false }, budget: { monthlyLimitUsd: 0, spentUsd: 0, paused: false } };

export type CommandRelay = { status: number; body: Record<string, unknown>; retryAfter: string | null; replayed: boolean };
const unavailableCommands = (): CommandCapability => ({ available: false, reason: 'commands_unavailable', commands: [] });
const requestID = (value: unknown) => typeof value === 'string' && /^[a-f0-9]{16}$/.test(value) ? value : null;
const commandMessages: Record<string, string> = {
  commands_unavailable: 'Vehicle commands are unavailable',
  authorization_required: 'Connect the Tesla account before using vehicle controls',
  reauthorization_required: 'Reconnect the Tesla account before using vehicle controls',
  command_scope_required: 'Enable Tesla vehicle-control access before using commands',
  virtual_key_missing: "Pair Volta's virtual key in the Tesla app",
  vehicle_asleep: 'Vehicle is asleep; try again later',
  vehicle_offline: 'Vehicle is offline; check its connectivity',
  vehicle_unavailable: 'Vehicle cannot accept this command in its current state',
  command_rejected: 'Vehicle rejected the command; check vehicle state',
  command_outcome_unknown: 'Command may have run; check the vehicle before trying again',
  idempotency_conflict: 'This intent key was already used for a different command',
  command_in_progress: 'Another command is running; retry this same intent shortly',
  request_cancelled: 'Request was cancelled before command acceptance',
  rate_limited: 'Too many vehicle commands; wait before trying again',
  tesla_rate_limited: 'Tesla asked Volta to wait before trying again',
  command_not_sent: 'The command deadline elapsed before sending; try again later',
  command_budget_unavailable: 'Vehicle command accounting is temporarily unavailable; the command was not sent',
  command_budget_exhausted: 'The monthly vehicle command budget is spent',
  invalid_command: 'Command is not supported',
  invalid_params: 'Command parameters are invalid',
  idempotency_key_required: 'A valid Idempotency-Key is required',
  unauthorized: 'Vehicle command service authentication failed',
  permission_denied: 'Tesla denied this command; check account permissions and scopes',
  vehicle_not_found: 'Vehicle is not configured for commands',
  oauth_unavailable: 'Tesla authorization is temporarily unavailable',
  oauth_invalid_response: 'Tesla returned an invalid authorization response',
  region_unavailable: 'Tesla account region is temporarily unavailable',
  upstream_unavailable: 'Vehicle command service is temporarily unavailable',
  storage_unavailable: 'Vehicle command could not be safely recorded',
};
const relayStatus = new Set([400, 401, 403, 404, 408, 409, 429, 501, 502, 503, 504]);
const unknownCommandOutcome = (status = 502): CommandRelay => ({
  status, replayed: false, retryAfter: null,
  body: { error: { code: 'command_outcome_unknown', message: commandMessages.command_outcome_unknown } },
});

const unavailable = () => new ApiError(501, 'tesla_link_unavailable', 'Tesla sign-in is not set up on this server');
const down = () => new ApiError(503, 'tesla_unavailable', 'Tesla sign-in is temporarily unavailable; try again');
const invalidLink = () => new ApiError(400, 'tesla_link_invalid', 'Sign-in expired or was already used; start again');
const errors: Record<string, () => ApiError> = {
  oauth_disabled: unavailable,
  already_authorized: () => new ApiError(409, 'tesla_already_connected', 'A Tesla account is already connected'),
  oauth_state_invalid: invalidLink,
  oauth_code_rejected: invalidLink,
  oauth_link_failed: () => new ApiError(400, 'tesla_link_failed', 'Tesla sign-in could not finish; start again'),
  oauth_denied: () => new ApiError(400, 'tesla_link_denied', 'Tesla sign-in was cancelled or denied'),
  oauth_device_mismatch: () => new ApiError(409, 'tesla_link_device_mismatch', 'Finish signing in on the device that started it'),
};

// Charging-history refusals reach only the operator CLI, never a paired device.
export class HistoryCallError extends Error {
  constructor(public status: number, public code: string, public retryAfter: number | null) { super(`Charging history refused: ${code}`); }
}
const historyCodes = new Set(['history_unavailable', 'invalid_query', 'unauthorized', 'authorization_required', 'reauthorization_required',
  'storage_unavailable', 'history_scope_missing', 'tesla_rate_limited', 'history_paced', 'account_changed', 'budget_exhausted',
  'history_daily_limit', 'history_monthly_limit', 'tesla_unavailable', 'history_auth_refreshing', 'tesla_payment_required',
  'history_rejected', 'history_outcome_unknown', 'history_invalid_response', 'history_response_too_large', 'oauth_unavailable', 'oauth_invalid_response', 'region_unavailable']);

export function commanderURL(value: string) {
  const url = new URL(value);
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash || url.pathname !== '/') throw new Error('COMMANDER_URL must be an origin such as http://commander:8090');
  return url.origin;
}

// Accept only the app's own callback and exactly one state plus code or error.
export function callbackParams(input: unknown) {
  if (typeof input !== 'string' || input.length > 4096) throw invalidLink();
  let url: URL;
  try { url = new URL(input); } catch { throw invalidLink(); }
  const one = (name: string) => { const values = url.searchParams.getAll(name); if (values.length > 1) throw invalidLink(); return values[0] ?? ''; };
  const params = { state: one('state'), code: one('code'), error: one('error') };
  if (url.protocol !== 'volta:' || url.hostname !== 'tesla-callback' || url.pathname || url.hash || url.username || !params.state || !params.code === !params.error) throw invalidLink();
  return params;
}

export class TeslaLink {
  constructor(private base: string, private secret: string, private fetcher: typeof fetch = fetch) {}

  private async call(method: string, path: string, body?: object) {
    let response: Response;
    try {
      response = await this.fetcher(this.base + path, {
        method, redirect: 'error', signal: AbortSignal.timeout(35000),
        headers: { Authorization: `Bearer ${this.secret}`, ...(body ? { 'Content-Type': 'application/json' } : {}) },
        body: body ? JSON.stringify(body) : undefined,
      });
    } catch { throw down(); }
    const data = await response.json().catch(() => null) as any;
    if (response.ok) return data;
    const mapped = errors[data?.error?.code];
    throw mapped ? mapped() : down();
  }

  async status(): Promise<TeslaStatus> {
    const s = await this.call('GET', '/oauth/status');
    const number = (n: unknown) => typeof n === 'number' && Number.isFinite(n) ? n : 0;
    return {
      available: s?.available === true, connected: s?.connected === true, needsReauth: s?.needsReauth === true, linkPending: s?.linkPending === true,
      commandsEnabled: s?.commandsEnabled === true, commandScopeRequired: s?.commandScopeRequired === true,
      collector: { enabled: s?.collector?.enabled === true },
      budget: { monthlyLimitUsd: number(s?.budget?.monthlyLimitUsd), spentUsd: number(s?.budget?.spentUsd), paused: s?.budget?.paused === true },
    };
  }

  async start(deviceId: number) {
    const s = await this.call('POST', '/oauth/start', { deviceId: String(deviceId) });
    if (typeof s?.authorizationUrl !== 'string' || s.callbackScheme !== 'volta' || typeof s.expiresAt !== 'string') throw down();
    return { authorizationUrl: s.authorizationUrl as string, callbackScheme: 'volta', expiresAt: s.expiresAt as string };
  }

  async complete(deviceId: number, callbackUrl: unknown) {
    const params = callbackParams(callbackUrl);
    await this.call('POST', '/oauth/complete', { deviceId: String(deviceId), ...params });
    return this.status();
  }

  // Opaque per-link namespace for stored history; internal, never in TeslaStatus.
  async historyLink(): Promise<{ enabled: boolean; account: string | null }> {
    const s = await this.call('GET', '/oauth/status');
    const account = s?.history?.account;
    return { enabled: s?.history?.enabled === true, account: s?.connected === true && typeof account === 'string' && /^[a-f0-9]{64}$/.test(account) ? account : null };
  }

  // One bounded page from commander; the caller re-validates the body.
  async chargingHistory(query: URLSearchParams): Promise<unknown> {
    let response: Response;
    try {
      // Commander may wait for the collector's in-flight read before its own 20 s call.
      response = await this.fetcher(`${this.base}/v1/history/charging?${query}`, { method: 'GET', redirect: 'error', signal: AbortSignal.timeout(90000), headers: { Authorization: `Bearer ${this.secret}` } });
    } catch { throw new HistoryCallError(0, 'commander_unreachable', null); }
    const text = await response.text().catch(() => '');
    let data: any = null;
    try { data = text.length <= 8 << 20 ? JSON.parse(text) : null; } catch { data = null; }
    if (response.ok) return data;
    const retry = Number(response.headers.get('Retry-After'));
    throw new HistoryCallError(response.status, historyCodes.has(data?.error?.code) ? data.error.code : 'unknown', Number.isInteger(retry) && retry > 0 ? retry : null);
  }

  async commandCapabilities(vehicleID: number): Promise<CommandCapability> {
    let response: Response;
    try {
      response = await this.fetcher(`${this.base}/v1/vehicles/${vehicleID}/commands`, {
        method: 'GET', redirect: 'error', signal: AbortSignal.timeout(5000), headers: { Authorization: `Bearer ${this.secret}` },
      });
    } catch { return unavailableCommands(); }
    if (!response.ok) return unavailableCommands();
    const text = await response.text().catch(() => '');
    if (text.length > 16384) return unavailableCommands();
    let data: unknown;
    try { data = JSON.parse(text); } catch { return unavailableCommands(); }
    return commandCapability(data) ?? unavailableCommands();
  }

  async command(vehicleID: number, name: CommandName, params: CommandParams, key: string): Promise<CommandRelay> {
    let response: Response;
    try {
      response = await this.fetcher(`${this.base}/v1/vehicles/${vehicleID}/commands/${name}`, {
        method: 'POST', redirect: 'error', signal: AbortSignal.timeout(75000),
        headers: { Authorization: `Bearer ${this.secret}`, 'Content-Type': 'application/json', 'Idempotency-Key': key },
        body: JSON.stringify(params),
      });
    } catch { return unknownCommandOutcome(504); }
    const text = await response.text().catch(() => '');
    let data: any = null;
    try { data = text.length <= 65536 ? JSON.parse(text) : null; } catch { data = null; }
    const replayed = response.headers.get('Idempotency-Replayed') === 'true';
    const retryValue = response.headers.get('Retry-After');
    const retryAfter = retryValue && /^[1-9]\d{0,4}$/.test(retryValue) && Number(retryValue) <= 86400 ? retryValue : null;
    if (response.ok) {
      const receipt = requestID(data?.requestId);
      if (response.headers.get('X-Volta-Command-Mode') !== 'live' || data?.ok !== true || data?.command !== name || !receipt) return unknownCommandOutcome();
      return { status: response.status, replayed, retryAfter, body: { ok: true, command: name, requestId: receipt } };
    }
    const code = typeof data?.error?.code === 'string' && Object.hasOwn(commandMessages, data.error.code) ? data.error.code : null;
    if (!code || !relayStatus.has(response.status)) return unknownCommandOutcome();
    const body: Record<string, unknown> = { error: { code, message: commandMessages[code] } };
    if (data?.command === name) body.command = name;
    const receipt = requestID(data?.requestId);
    if (receipt) body.requestId = receipt;
    return { status: response.status, replayed, retryAfter, body };
  }

  async cancel(deviceId: number) { await this.call('POST', '/oauth/cancel', { deviceId: String(deviceId) }); }
  async disconnect() { await this.call('DELETE', '/oauth/account'); }
}
