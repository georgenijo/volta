import { ApiError } from './errors';

// Tesla sign-in is owned by commander on a private network. volta-api relays a
// paired device's requests and never sees Tesla tokens or the client secret.
export type TeslaStatus = {
  available: boolean; connected: boolean; needsReauth: boolean; linkPending: boolean;
  collector: { enabled: boolean }; budget: { monthlyLimitUsd: number; spentUsd: number; paused: boolean };
};
export const unavailableStatus: TeslaStatus = { available: false, connected: false, needsReauth: false, linkPending: false, collector: { enabled: false }, budget: { monthlyLimitUsd: 0, spentUsd: 0, paused: false } };

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

  async cancel(deviceId: number) { await this.call('POST', '/oauth/cancel', { deviceId: String(deviceId) }); }
  async disconnect() { await this.call('DELETE', '/oauth/account'); }
}
