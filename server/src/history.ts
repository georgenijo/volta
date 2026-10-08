import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import type { DB, Row } from './db';
import { ApiError, invalid, missing } from './errors';
import { HistoryCallError, type TeslaLink } from './tesla';
import { integer } from './validation';

// Tesla-billed charging sessions (commander GET /v1/history/charging, from Tesla's
// GET /api/1/dx/charging/history). These are Tesla's billing records, kept apart
// from TeslaMate charging processes: billed energy is what Tesla invoiced, not
// energy added to the battery, and no SoC, location or currency is inferred.

const ACCOUNT = /^[a-f0-9]{64}$/, VIN = /^[A-HJ-NPR-Z0-9]{17}$/, ID = /^[1-9]\d{0,18}$/;
const DECIMAL = /^-?\d{1,9}(?:\.\d{1,9})?$/, TOKEN = /^[A-Za-z0-9_ -]{1,32}$/, CONTENT = /^[A-Za-z0-9._:-]{1,128}$/;
const TIME = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,9})?(?:Z|[+-]\d\d:\d\d)$/, UTC_SECOND = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/;
const AMOUNTS = ['rateBase', 'rateTier1', 'rateTier2', 'rateTier3', 'rateTier4', 'usageBase', 'usageTier1', 'usageTier2', 'usageTier3', 'usageTier4',
  'totalBase', 'totalTier1', 'totalTier2', 'totalTier3', 'totalTier4', 'totalDue', 'netDue'] as const;
const LOCATIONS = ['top', 'response', 'both', 'conflict', 'none'];
// MAX_PAGE_NO matches commander's own pageNo bound.
export const MAX_PAGE_SIZE = 50, MAX_SYNC_PAGES = 20, MAX_PAGE_NO = 200;
// Sessions with no timestamp at all sort last instead of being given a fake time.
const UNDATED = '1970-01-01T00:00:00Z';

type Fee = { feeType: string | null; currency: string | null; pricingType: string | null; unit: string | null; isPaid: boolean | null; status: string | null; amounts: Record<string, string> };
type Invoice = { fileName: string | null; contentId: string | null; invoiceType: string | null };
export type Session = { id: string; vin: string | null; site: string | null; countryCode: string | null; start: string | null; stop: string | null; unlatch: string | null; billingType: string | null; vehicleMakeType: string | null; fees: Fee[]; invoices: Invoice[] };
export type Page = { account: string; pageNo: number; pageSize: number; startTime: string; endTime: string; totalResults: number | null; totalResultsLocation: string; sessions: Session[]; rejected: number };

// Commander already re-validated Tesla's reply; anything off-contract here is a
// commander defect or tampering, so the whole page is refused rather than repaired.
const malformed = () => new HistoryCallError(502, 'commander_invalid_page', null);
const object = (v: unknown): Record<string, unknown> => { if (!v || typeof v !== 'object' || Array.isArray(v)) throw malformed(); return v as Record<string, unknown>; };
const list = (v: unknown, max: number): unknown[] => { if (!Array.isArray(v) || v.length > max) throw malformed(); return v; };
const nullable = <T>(v: unknown, check: (v: unknown) => v is T): T | null => { if (v === null || v === undefined) return null; if (!check(v)) throw malformed(); return v; };
const matches = (re: RegExp) => (v: unknown): v is string => typeof v === 'string' && re.test(v);
const label = (max: number) => (v: unknown): v is string => typeof v === 'string' && v.length > 0 && [...v].length <= max && !/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u.test(v);
const instant = (v: unknown): v is string => typeof v === 'string' && TIME.test(v) && Number.isFinite(Date.parse(v));
const count = (v: unknown, max = 1_000_000): v is number => Number.isSafeInteger(v) && (v as number) >= 0 && (v as number) <= max;

function parseFee(v: unknown): Fee {
  const f = object(v), amounts = object(f.amounts), out: Record<string, string> = {};
  for (const [k, n] of Object.entries(amounts)) {
    if (!(AMOUNTS as readonly string[]).includes(k) || !matches(DECIMAL)(n)) throw malformed();
  }
  for (const k of AMOUNTS) if (amounts[k] !== undefined) out[k] = amounts[k] as string;
  return {
    feeType: nullable(f.feeType, matches(TOKEN)), currency: nullable(f.currencyCode, matches(/^[A-Z]{3}$/)), pricingType: nullable(f.pricingType, matches(TOKEN)),
    unit: nullable(f.uom, matches(TOKEN)), isPaid: nullable(f.isPaid, (b: unknown): b is boolean => typeof b === 'boolean'), status: nullable(f.status, matches(TOKEN)), amounts: out,
  };
}

function parseSession(v: unknown): Session {
  const s = object(v);
  if (!matches(ID)(s.sessionId)) throw malformed();
  const fileName = (n: unknown): n is string => label(200)(n) && !/[\\/]/.test(n);
  return {
    id: s.sessionId, vin: nullable(s.vin, matches(VIN)), site: nullable(s.siteLocationName, label(200)), countryCode: nullable(s.countryCode, matches(/^[A-Z]{2}$/)),
    start: nullable(s.chargeStartDateTime, instant), stop: nullable(s.chargeStopDateTime, instant), unlatch: nullable(s.unlatchDateTime, instant),
    billingType: nullable(s.billingType, matches(TOKEN)), vehicleMakeType: nullable(s.vehicleMakeType, matches(TOKEN)),
    fees: list(s.fees, 20).map(parseFee),
    invoices: list(s.invoices, 10).map(i => { const o = object(i); return { fileName: nullable(o.fileName, fileName), contentId: nullable(o.contentId, matches(CONTENT)), invoiceType: nullable(o.invoiceType, matches(TOKEN)) }; }),
  };
}

export function parsePage(data: unknown, expected: { pageNo: number; pageSize: number; startTime: string; endTime: string }): Page {
  const p = object(data);
  if (p.ok !== true || !matches(ACCOUNT)(p.account) || p.pageNo !== expected.pageNo || p.pageSize !== expected.pageSize
    || p.startTime !== expected.startTime || p.endTime !== expected.endTime || !LOCATIONS.includes(p.totalResultsLocation as string) || !count(p.rejected, MAX_PAGE_SIZE)) throw malformed();
  const totalResults = nullable(p.totalResults, (n: unknown): n is number => count(n));
  const sessions = list(p.sessions, expected.pageSize).map(parseSession);
  if (new Set(sessions.map(s => s.id)).size !== sessions.length || sessions.length + (p.rejected as number) > expected.pageSize) throw malformed();
  return { account: p.account, pageNo: expected.pageNo, pageSize: expected.pageSize, startTime: expected.startTime, endTime: expected.endTime, totalResults, totalResultsLocation: p.totalResultsLocation as string, sessions, rejected: p.rejected as number };
}

// Exact decimal arithmetic at nine places; money never passes through a float.
const units = (s: string) => { const negative = s.startsWith('-'), [whole, fraction = ''] = s.replace('-', '').split('.'); const u = BigInt(whole + fraction.padEnd(9, '0')); return negative ? -u : u; };
const decimal = (u: bigint) => { const negative = u < 0n, digits = (negative ? -u : u).toString().padStart(10, '0'); return (negative ? '-' : '') + `${digits.slice(0, -9)}.${digits.slice(-9)}`.replace(/\.?0+$/, ''); };

export function derive(fees: Fee[]) {
  // One currency across every fee, or none: never assume or mix currencies.
  const currencies = new Set(fees.map(f => f.currency));
  const currency = fees.length > 0 && currencies.size === 1 && !currencies.has(null) ? fees[0]!.currency : null;
  // Each fee's totalDue/netDue already includes its base and tiers; sum only those.
  const sum = (key: 'totalDue' | 'netDue') => currency && fees.every(f => f.amounts[key] !== undefined) ? decimal(fees.reduce((t, f) => t + units(f.amounts[key]!), 0n)) : null;
  // Tesla's published example bills totalBase alongside a non-zero usageTier2, so
  // tier usage semantics are unknown: report energy only for one plain kWh line.
  const charging = fees.filter(f => f.feeType === 'CHARGING');
  const only = charging.length === 1 ? charging[0]! : null;
  const plain = only !== null && only.unit?.toLowerCase() === 'kwh' && only.amounts.usageBase !== undefined && units(only.amounts.usageBase) >= 0n
    && (['usageTier1', 'usageTier2', 'usageTier3', 'usageTier4'] as const).every(k => only.amounts[k] === undefined || units(only.amounts[k]!) === 0n);
  return { currency, totalDue: sum('totalDue'), netDue: sum('netDue'), billedEnergyKwh: plain ? decimal(units(only.amounts.usageBase!)) : null };
}

// Writes one page's sessions inside the caller's transaction.
async function writeSessions(tx: DB, page: Page) {
  const counts = { inserted: 0, updated: 0, unchanged: 0 };
  for (const s of page.sessions) {
    const d = derive(s.fees);
    const stored = [s.vin, s.site, s.countryCode, s.start, s.stop, s.unlatch, s.billingType, s.vehicleMakeType, s.fees, s.invoices];
    const hash = createHash('sha256').update(JSON.stringify(stored)).digest();
    const [row] = await tx`INSERT INTO volta.tesla_charging_sessions AS t (account_key, session_id, vin, site_location_name, country_code, charge_start, charge_stop, unlatch_at,
        billing_type, vehicle_make_type, fees, invoices, currency, total_due, net_due, billed_energy_kwh, sort_at, content_hash)
      VALUES (${page.account}, ${s.id}, ${s.vin}, ${s.site}, ${s.countryCode}, ${s.start}, ${s.stop}, ${s.unlatch}, ${s.billingType}, ${s.vehicleMakeType},
        ${tx.json(s.fees as any)}, ${tx.json(s.invoices as any)}, ${d.currency}, ${d.totalDue}, ${d.netDue}, ${d.billedEnergyKwh}, ${s.start ?? s.stop ?? s.unlatch ?? UNDATED}, ${hash})
      ON CONFLICT (account_key, session_id) DO UPDATE SET vin = EXCLUDED.vin, site_location_name = EXCLUDED.site_location_name, country_code = EXCLUDED.country_code,
        charge_start = EXCLUDED.charge_start, charge_stop = EXCLUDED.charge_stop, unlatch_at = EXCLUDED.unlatch_at, billing_type = EXCLUDED.billing_type,
        vehicle_make_type = EXCLUDED.vehicle_make_type, fees = EXCLUDED.fees, invoices = EXCLUDED.invoices, currency = EXCLUDED.currency, total_due = EXCLUDED.total_due,
        net_due = EXCLUDED.net_due, billed_energy_kwh = EXCLUDED.billed_energy_kwh, sort_at = EXCLUDED.sort_at, content_hash = EXCLUDED.content_hash, updated_at = now()
      WHERE t.content_hash IS DISTINCT FROM EXCLUDED.content_hash
      RETURNING (xmax = 0) AS inserted`;
    if (!row) counts.unchanged++; else if (row.inserted) counts.inserted++; else counts.updated++;
  }
  return counts;
}

export async function upsertPage(sql: DB, page: Page) {
  // postgres.js TransactionSql omits its callable signature; runtime transaction is a SQL tag.
  return sql.begin(transaction => writeSessions(transaction as unknown as DB, page));
}

// Binds device cursors to the issuing link without revealing it: a one-way digest
// of the link namespace (itself a digest of a random per-sign-in ID) and the scope.
const LINK_MARK = /^[A-Za-z0-9_-]{22}$/;
const linkMark = (account: string, scope: string) => createHash('sha256').update(`volta-history-cursor-v2\n${account}\n${scope}`).digest('base64url').slice(0, 22);

const iso = (v: unknown) => v instanceof Date ? v.toISOString() : null;
const amount = (v: string | undefined) => v === undefined ? null : Number(v);
// Device-facing shape: no VIN, invoice identifiers, file names or tier details.
const item = (r: Row) => ({
  id: String(r.session_id), source: 'tesla_billed', site: r.site_location_name, countryCode: r.country_code,
  startedAt: iso(r.charge_start), endedAt: iso(r.charge_stop), unlatchedAt: iso(r.unlatch_at), billingType: r.billing_type,
  billedEnergyKwh: r.billed_energy_kwh, currency: r.currency, totalDue: r.total_due, netDue: r.net_due,
  fees: (r.fees as Fee[]).map(f => ({ type: f.feeType, currency: f.currency, pricingType: f.pricingType, unit: f.unit, isPaid: f.isPaid, status: f.status, totalDue: amount(f.amounts.totalDue), netDue: amount(f.amounts.netDue) })),
  invoiceCount: (r.invoices as Invoice[]).length,
});

export class ChargingHistory {
  constructor(private store: DB, private telemetry: DB, private tesla: TeslaLink | null) {}

  // Reads follow the currently linked account only; earlier links stay stored but hidden.
  private async link() {
    if (!this.tesla) throw new ApiError(501, 'tesla_link_unavailable', 'Tesla sign-in is not set up on this server');
    return this.tesla.historyLink();
  }

  // The link is read from commander before the queries and again after them,
  // never cached: a disconnect or relink while a query is in flight discards
  // its rows instead of returning the earlier link's history.
  private async fenced<T>(read: (link: { enabled: boolean; account: string | null }) => Promise<T>): Promise<T> {
    const before = await this.link();
    const out = await read(before);
    if ((await this.link()).account !== before.account) throw new ApiError(409, 'tesla_link_changed', 'The Tesla account changed during the read; try again');
    return out;
  }

  async summary() {
    if (!this.tesla) return { available: false, enabled: false, connected: false, sessions: 0, unmatched: 0, lastSync: null };
    return this.fenced(async ({ enabled, account }) => {
      if (!account) return { available: true, enabled, connected: false, sessions: 0, unmatched: 0, lastSync: null };
      const vins = new Set((await this.telemetry`SELECT vin FROM cars WHERE vin IS NOT NULL`).map(r => r.vin as string));
      const groups = await this.store`SELECT vin, count(*)::int AS n FROM volta.tesla_charging_sessions WHERE account_key = ${account} GROUP BY vin`;
      const [sync] = await this.store`SELECT finished_at, window_start, window_end, window_complete, outcome FROM volta.tesla_history_syncs WHERE account_key = ${account} ORDER BY finished_at DESC, id DESC LIMIT 1`;
      return {
        available: true, enabled, connected: true,
        sessions: groups.reduce((t, g) => t + g.n, 0),
        // Rows without an exact VIN match to a TeslaMate car stay stored but are not shown.
        unmatched: groups.reduce((t, g) => t + (g.vin && vins.has(g.vin) ? 0 : g.n), 0),
        lastSync: sync ? { finishedAt: iso(sync.finished_at), windowStart: iso(sync.window_start), windowEnd: iso(sync.window_end), windowComplete: sync.window_complete, outcome: sync.outcome } : null,
      };
    });
  }

  async sessions(vehicleId: number, query: Record<string, string>) {
    const [car] = await this.telemetry`SELECT vin FROM cars WHERE id = ${vehicleId}`;
    if (!car) throw missing();
    const scope = `tesla-billed/${vehicleId}`, limit = integer(query.limit, 'limit', 25, MAX_PAGE_SIZE);
    let before: { link: string; at: string; id: string } | null = null;
    if (query.cursor !== undefined) {
      try {
        if (query.cursor.length > 512 || !/^[A-Za-z0-9_-]+$/.test(query.cursor)) throw new Error();
        const c = JSON.parse(Buffer.from(query.cursor, 'base64url').toString());
        // Only the current version is accepted; earlier unbound cursors were never served by a deployed build.
        if (!c || typeof c !== 'object' || Object.keys(c).sort().join() !== 'at,id,link,scope,v' || c.v !== 2 || c.scope !== scope || !matches(LINK_MARK)(c.link)
          || typeof c.at !== 'string' || !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z$/.test(c.at) || !matches(ID)(c.id)) throw new Error();
        before = { link: c.link, at: c.at, id: c.id };
      } catch { throw invalid('Invalid cursor'); }
    }
    return this.fenced(async ({ account }) => {
      if (!account) throw new ApiError(409, 'tesla_not_connected', 'Connect a Tesla account to see Tesla-billed charging');
      // A cursor continues only the link that issued it; its position means nothing in another account's rows.
      const mark = linkMark(account, scope);
      if (before && !timingSafeEqual(Buffer.from(before.link), Buffer.from(mark))) throw new ApiError(409, 'tesla_link_changed', 'The Tesla account changed since this page; start again from the first page');
      // Exact full-VIN equality only; a car without a valid VIN matches nothing.
      if (typeof car.vin !== 'string' || !VIN.test(car.vin)) return { items: [], nextCursor: null };
      const rows = await this.store`SELECT session_id, site_location_name, country_code, charge_start, charge_stop, unlatch_at, billing_type, fees, invoices,
          currency, total_due, net_due, billed_energy_kwh, to_char(sort_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS cursor_at
        FROM volta.tesla_charging_sessions WHERE account_key = ${account} AND vin = ${car.vin}
        ${before ? this.store`AND (sort_at, session_id) < (${before.at}::timestamptz, ${before.id}::bigint)` : this.store``}
        ORDER BY sort_at DESC, session_id DESC LIMIT ${limit + 1}`;
      const last = rows.length > limit ? rows[limit - 1] : null;
      return { items: rows.slice(0, limit).map(item), nextCursor: last ? Buffer.from(JSON.stringify({ v: 2, scope, link: mark, at: last.cursor_at, id: String(last.session_id) })).toString('base64url') : null };
    });
  }
}

export type Window = { since: string; until: string; pageSize: number };
const params = (w: Window, pageNo: number) => new URLSearchParams({ pageNo: String(pageNo), pageSize: String(w.pageSize), startTime: w.since, endTime: w.until, sortOrder: 'ASC' });
const fetchPage = async (tesla: TeslaLink, w: Window, pageNo: number) =>
  parsePage(await tesla.chargingHistory(params(w, pageNo)), { pageNo, pageSize: w.pageSize, startTime: w.since, endTime: w.until });

export function window(since: string | undefined, until: string | undefined, pageSize: number, now = new Date()): Window {
  const end = until ?? now.toISOString().slice(0, 19) + 'Z';
  if (!since || !UTC_SECOND.test(since) || !UTC_SECOND.test(end) || !Number.isFinite(Date.parse(since)) || !Number.isFinite(Date.parse(end))
    || Date.parse(since) >= Date.parse(end) || Date.parse(end) > now.getTime() || new Date(since).toISOString().slice(0, 19) + 'Z' !== since) throw new RangeError('since/until must be past UTC times like 2026-01-01T00:00:00Z, since before until');
  if (!Number.isSafeInteger(pageSize) || pageSize < 1 || pageSize > MAX_PAGE_SIZE) throw new RangeError(`page size must be 1-${MAX_PAGE_SIZE}`);
  return { since, until: end, pageSize };
}

// One page, nothing stored. The digest lets an operator compare pages 0 and 1
// to learn the undocumented page base without printing session identifiers.
export async function probe(tesla: TeslaLink, w: Window, pageNo: number) {
  const page = await fetchPage(tesla, w, pageNo);
  const starts = page.sessions.map(s => s.start).filter((s): s is string => s !== null).map(s => new Date(s).toISOString()).sort();
  return {
    pageNo, pageSize: w.pageSize, startTime: w.since, endTime: w.until, received: page.sessions.length, rejected: page.rejected,
    totalResults: page.totalResults, totalResultsLocation: page.totalResultsLocation, withVin: page.sessions.filter(s => s.vin).length,
    earliestStart: starts[0] ?? null, latestStart: starts.at(-1) ?? null,
    pageDigest: page.sessions.length ? createHash('sha256').update(page.sessions.map(s => s.id).sort().join(',')).digest('hex').slice(0, 16) : null,
  };
}

export type SyncOptions = Window & { firstPage: 0 | 1; maxPages: number; apply: boolean };
export type ResumeOptions = { token: string; maxPages: number; apply: boolean };
// Hands an applied run's resume token to the operator before any Tesla call,
// so a run that crashes after paying for pages can still be continued. If it
// throws, the run stops before calling.
export type Announce = (token: string) => Promise<void>;
const quiet: Announce = async () => {};
const pause = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));
const RESUME = /^[A-Za-z0-9_-]{43}$/;
const digest = (token: string) => createHash('sha256').update(token).digest();
// A crashed run's claim on its row lapses after this long. A live run renews
// it before every Tesla call, each of which commander bounds to seconds.
const CLAIM_LEASE = '30 minutes';
// Recorded while a run is going, or when it stopped before recording its end.
const IN_PROGRESS = 'in_progress';

// The claim a run holds on its own sync row: the row ID plus a random owner
// generation. A run whose lease lapsed and was taken over can no longer write,
// release, retire or complete the chain.
type Lease = { id: number; owner: Buffer };
export class ResumeLost extends RangeError {
  constructor() { super('Another run took over this resume token; this run stopped and wrote nothing more'); }
}
// Checked inside each write's transaction; the row lock keeps a takeover out
// until that transaction commits.
async function holding(tx: DB, lease: Lease) {
  const [row] = await tx`SELECT id FROM volta.tesla_history_syncs WHERE id = ${lease.id} AND claim_owner = ${lease.owner} AND resumed_at IS NULL
    AND claimed_at >= now() - ${CLAIM_LEASE}::interval FOR UPDATE`;
  if (!row) throw new ResumeLost();
}
// Before a paid call: still the owner, and the lease runs for another full term.
async function renew(store: DB, lease: Lease) {
  const [row] = await store`UPDATE volta.tesla_history_syncs SET claimed_at = now() WHERE id = ${lease.id} AND claim_owner = ${lease.owner} AND resumed_at IS NULL
    AND claimed_at >= now() - ${CLAIM_LEASE}::interval RETURNING id`;
  if (!row) throw new ResumeLost();
}
// After a failure: frees this run's own claim so its token works again at
// once, but never a claim a later run has taken over.
const release = (store: DB, lease: Lease) =>
  store`UPDATE volta.tesla_history_syncs SET claimed_at = NULL, claim_owner = NULL WHERE id = ${lease.id} AND claim_owner = ${lease.owner} AND resumed_at IS NULL`.catch(() => {});

// Everything a bounded run needs to continue an earlier one: the link it was
// read under, the exact window and page geometry, and the pagination evidence
// gathered so far (counts, Tesla's total and every session ID already seen).
type Chain = { account: string; window: Window; firstPage: 0 | 1; nextPage: number; pages: number; received: number; rejected: number; totalResults: number | null; seen: Set<string> };
type Stats = { calls: number; pages: number; received: number; rejected: number; inserted: number; updated: number; unchanged: number; windowComplete: boolean; outcome: string; nextPage: number | null };
const maxPagesCheck = (n: number) => { if (!Number.isSafeInteger(n) || n < 1 || n > MAX_SYNC_PAGES) throw new RangeError(`max pages must be 1-${MAX_SYNC_PAGES}`); };

// Opens this run's own sync row, claimed by it and holding its token's hash,
// before any Tesla call. A resumed run moves the chain over in the same
// transaction, retiring the earlier row and token under that row's claim.
async function open(store: DB, c: Chain, owner: Buffer, token: string, from: Lease | null): Promise<Lease> {
  const id = await store.begin(async transaction => {
    const tx = transaction as unknown as DB;
    if (from) await holding(tx, from);
    const [row] = await tx`INSERT INTO volta.tesla_history_syncs (account_key, window_start, window_end, first_page, page_size, pages, received, rejected, inserted, updated, unchanged,
        chain_pages, chain_received, chain_rejected, total_results, seen_ids, window_complete, outcome, next_page, resume_hash, resumed_from, claimed_at, claim_owner, started_at)
      VALUES (${c.account}, ${c.window.since}, ${c.window.until}, ${c.firstPage}, ${c.window.pageSize}, 0, 0, 0, 0, 0, 0,
        ${c.pages}, ${c.received}, ${c.rejected}, ${c.totalResults}, ${[...c.seen]}::bigint[], false, ${IN_PROGRESS}, ${c.nextPage}, ${digest(token)}, ${from?.id ?? null}, now(), ${owner}, now())
      RETURNING id`;
    if (from) await tx`UPDATE volta.tesla_history_syncs SET resumed_at = now(), claimed_at = NULL, claim_owner = NULL WHERE id = ${from.id}`;
    return row!.id as number;
  });
  return { id, owner };
}

// One atomic checkpoint under the run's claim: the page's sessions (if any),
// the run's counts and the chain's progress and evidence, written together.
// A chain that ends here also drops its token and claim in the same commit,
// so a page whose rows were kept is never bought again through a stale token.
async function checkpoint(store: DB, lease: Lease, c: Chain, r: Stats, page: Page | null, end: boolean) {
  const written = await store.begin(async transaction => {
    const tx = transaction as unknown as DB;
    await holding(tx, lease);
    const w = page ? await writeSessions(tx, page) : { inserted: 0, updated: 0, unchanged: 0 };
    const done = r.nextPage === null;
    await tx`UPDATE volta.tesla_history_syncs SET pages = ${r.pages}, received = ${r.received}, rejected = ${r.rejected},
        inserted = ${r.inserted + w.inserted}, updated = ${r.updated + w.updated}, unchanged = ${r.unchanged + w.unchanged},
        chain_pages = ${c.pages}, chain_received = ${c.received}, chain_rejected = ${c.rejected}, total_results = ${c.totalResults}, seen_ids = ${[...c.seen]}::bigint[],
        window_complete = ${r.windowComplete}, outcome = ${end ? r.outcome : IN_PROGRESS}, next_page = ${r.nextPage},
        resume_hash = ${done ? null : tx`resume_hash`}, claimed_at = ${end ? null : tx`claimed_at`}, claim_owner = ${end ? null : tx`claim_owner`}, finished_at = now()
      WHERE id = ${lease.id}`;
    return w;
  });
  r.inserted += written.inserted; r.updated += written.updated; r.unchanged += written.unchanged;
}

// Fixed window, ascending order, explicit page base and a hard page cap. Without
// --apply nothing is called. windowComplete needs Tesla's own total, matched
// exactly with nothing rejected, for this window only; it never claims the
// account's whole Tesla history.
export async function sync(store: DB, tesla: TeslaLink, o: SyncOptions, spacingMs = 1100, announce = quiet) {
  maxPagesCheck(o.maxPages);
  const plan = { startTime: o.since, endTime: o.until, firstPage: o.firstPage, pageSize: o.pageSize, maxCalls: o.maxPages };
  if (!o.apply) return { applied: false, plan, calls: 0 };
  const { enabled, account } = await tesla.historyLink();
  if (!enabled || !account) throw new RangeError('Charging history is off or no Tesla account is linked; nothing was called');
  const chain: Chain = { account, window: { since: o.since, until: o.until, pageSize: o.pageSize }, firstPage: o.firstPage, nextPage: o.firstPage, pages: 0, received: 0, rejected: 0, totalResults: null, seen: new Set() };
  const owner = randomBytes(32), token = randomBytes(32).toString('base64url');
  await announce(token);
  const lease = await open(store, chain, owner, token, null);
  let finished = false;
  try {
    const out = await run(store, tesla, chain, o.maxPages, spacingMs, lease, token);
    finished = true;
    return { applied: true, plan, ...out };
  } finally { if (!finished) await release(store, lease); }
}

// Continues a run from its resume token. The window, page size, page base,
// next page and evidence come from storage, not the operator; a token works
// once, only for the link it was issued under, and only one run holds it.
export async function resume(store: DB, tesla: TeslaLink, o: ResumeOptions, spacingMs = 1100, announce = quiet) {
  maxPagesCheck(o.maxPages);
  if (!RESUME.test(o.token)) throw new RangeError('Unknown, used or busy resume token');
  const owner = randomBytes(32);
  const [row] = o.apply
    ? await store`UPDATE volta.tesla_history_syncs SET claimed_at = now(), claim_owner = ${owner} WHERE resume_hash = ${digest(o.token)} AND resumed_at IS NULL
        AND (claimed_at IS NULL OR claimed_at < now() - ${CLAIM_LEASE}::interval) RETURNING *`
    : await store`SELECT * FROM volta.tesla_history_syncs WHERE resume_hash = ${digest(o.token)} AND resumed_at IS NULL`;
  if (!row) throw new RangeError('Unknown, used or busy resume token');
  const chain: Chain = { account: row.account_key, window: { since: iso(row.window_start)!.replace('.000Z', 'Z'), until: iso(row.window_end)!.replace('.000Z', 'Z'), pageSize: row.page_size },
    firstPage: row.first_page, nextPage: row.next_page, pages: row.chain_pages, received: row.chain_received, rejected: row.chain_rejected,
    totalResults: row.total_results, seen: new Set((row.seen_ids as (string | bigint)[]).map(String)) };
  const plan = { startTime: chain.window.since, endTime: chain.window.until, firstPage: chain.firstPage, pageSize: chain.window.pageSize, nextPage: chain.nextPage, maxCalls: o.maxPages };
  if (!o.apply) return { applied: false, plan, calls: 0 };
  let held: Lease | null = { id: row.id, owner };
  try {
    // Spend nothing if the link already changed: the chain belongs to the old one.
    if ((await tesla.historyLink()).account !== chain.account) {
      const from = held;
      await store.begin(async transaction => {
        const tx = transaction as unknown as DB;
        await holding(tx, from);
        await tx`UPDATE volta.tesla_history_syncs SET resumed_at = now(), claimed_at = NULL, claim_owner = NULL WHERE id = ${from.id}`;
      });
      held = null;
      return { applied: true, plan, calls: 0, pages: 0, received: 0, rejected: 0, inserted: 0, updated: 0, unchanged: 0, windowComplete: false, outcome: 'account_changed', nextPage: null, resume: null };
    }
    const token = randomBytes(32).toString('base64url');
    await announce(token);
    held = await open(store, chain, owner, token, held);
    const out = await run(store, tesla, chain, o.maxPages, spacingMs, held, token);
    held = null;
    return { applied: true, plan, ...out };
  } finally { if (held) await release(store, held); }
}

async function run(store: DB, tesla: TeslaLink, c: Chain, maxPages: number, spacingMs: number, lease: Lease, token: string) {
  const r: Stats = { calls: 0, pages: 0, received: 0, rejected: 0, inserted: 0, updated: 0, unchanged: 0, windowComplete: false, outcome: 'max_pages', nextPage: c.nextPage };
  let ended = false;
  for (let i = 0; i < maxPages; i++) {
    const pageNo = r.nextPage!;
    if (i > 0) await pause(spacingMs);
    await renew(store, lease);
    r.calls++;
    let page: Page;
    try { page = await fetchPage(tesla, c.window, pageNo); } catch (error) {
      if (!(error instanceof HistoryCallError)) throw error;
      // Refusals and failures keep nextPage on this page so it can be retried.
      r.outcome = error.code; break;
    }
    r.pages++; c.pages++;
    // Anomalies stop the run before anything from the suspect page is written.
    const anomaly = page.account !== c.account ? 'account_changed'
      // Tesla's two totals disagree: no total can be trusted for this chain, so
      // it ends here and its earlier rows have unknown coverage.
      : page.totalResultsLocation === 'conflict' ? 'total_conflict'
      : page.sessions.some(s => c.seen.has(s.id)) ? 'repeated_page'
      : c.totalResults !== null && page.totalResults !== null && page.totalResults !== c.totalResults ? 'total_changed' : null;
    if (anomaly) { r.outcome = anomaly; r.nextPage = null; break; }
    for (const s of page.sessions) c.seen.add(s.id);
    r.received += page.sessions.length; r.rejected += page.rejected;
    c.received += page.sessions.length; c.rejected += page.rejected; c.totalResults ??= page.totalResults;
    const rows = page.sessions.length + page.rejected, covered = c.received + c.rejected;
    r.nextPage = pageNo + 1;
    // Complete only when Tesla's total is matched exactly and every row was kept.
    if (c.totalResults !== null && covered > c.totalResults) { r.outcome = 'total_exceeded'; r.nextPage = null; }
    else if (c.totalResults !== null && covered === c.totalResults) { r.windowComplete = c.rejected === 0; r.outcome = c.rejected === 0 ? 'total_reached' : 'rows_rejected'; r.nextPage = null; }
    // An empty page ends paging but proves nothing without a matching total;
    // an empty first page may also mean a wrong page base.
    else if (rows === 0) { r.outcome = c.pages === 1 ? 'empty_first_page' : c.totalResults === null ? 'end_unverified' : 'total_mismatch'; r.nextPage = null; }
    // Commander serves pages up to 200: a chain that would need page 201 ends
    // with this page, so no continuation points past the bound.
    else if (r.nextPage > MAX_PAGE_NO) { r.outcome = 'page_limit'; r.nextPage = null; }
    // A short page is not proof of the end; the next call confirms it.
    else r.outcome = rows < c.window.pageSize ? 'end_unconfirmed' : 'max_pages';
    ended = r.nextPage === null;
    await checkpoint(store, lease, c, r, page, ended);
    if (ended) break;
  }
  // Every kept page is already recorded; this only records why the run
  // stopped and frees its claim. If it fails, the row still continues from
  // the first page not yet kept.
  if (!ended) await checkpoint(store, lease, c, r, null, true);
  return { ...r, resume: r.nextPage !== null ? token : null };
}
