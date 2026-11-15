import { randomBytes, createHash, timingSafeEqual } from 'node:crypto';
import { AppleTokenError, appleClockToleranceSeconds, appleTokenMaxAgeSeconds, type AppleVerifier } from './apple';
import type { DB, Row } from './db';
import { ApiError, invalid, missing } from './errors';
const hash = (value: string) => createHash('sha256').update(value).digest();
export const deviceShape = (row: Row) => ({ id: row.id, name: row.name, createdAt: row.created_at, lastSeenAt: row.last_seen_at });
// Global, persisted limit: safe behind tailscale serve without trusting spoofable IP headers.
const limited = async (sql: DB, key: string) => {
  const [rate] = await sql`INSERT INTO volta.rate_limits AS r (key, window_start, attempts) VALUES (${key}, now(), 1)
    ON CONFLICT (key) DO UPDATE SET
    window_start = CASE WHEN r.window_start <= now() - interval '10 minutes' THEN now() ELSE r.window_start END,
    attempts = CASE WHEN r.window_start <= now() - interval '10 minutes' THEN 1 ELSE LEAST(r.attempts + 1, 31) END
    RETURNING attempts`;
  return !rate || rate.attempts > 30;
};
const fields = (body: unknown) => body && typeof body === 'object' && !Array.isArray(body) ? body as Record<string, unknown> : {};
const validToken = (value: unknown): value is string => typeof value === 'string' && /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(value);
const validName = (value: unknown): value is string => typeof value === 'string' && !!value.trim() && value.trim().length <= 100;
export class Auth {
  constructor(private sql: DB, private apple: AppleVerifier | null = null) {}
  async createPairingCode() {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    const code = [...randomBytes(8)].map(n => alphabet[n & 31]).join('');
    await this.sql.begin(async transaction => {
      // postgres.js TransactionSql omits its callable signature; runtime transaction is a SQL tag.
      const tx = transaction as unknown as DB;
      await tx`DELETE FROM volta.pairing_codes WHERE expires_at <= now()`;
      await tx`INSERT INTO volta.pairing_codes (code_hash, expires_at) VALUES (${hash(code)}, now() + interval '10 minutes')`;
    });
    return code;
  }
  async pair(body: unknown) {
    const result = await this.sql.begin(async transaction => {
      // postgres.js TransactionSql omits its callable signature; runtime transaction is a SQL tag.
      const tx = transaction as unknown as DB;
      if (await limited(tx, 'pair')) return { error: new ApiError(429, 'rate_limited', 'Too many pairing attempts; retry after ten minutes') };
      if (!body || typeof body !== 'object' || Array.isArray(body)) return { error: invalid('Expected code and deviceName') };
      const { code, deviceName } = body as Record<string, unknown>;
      if (typeof code !== 'string' || !/^[A-HJ-NP-Z2-9]{8}$/.test(code) || !validName(deviceName)) return { error: invalid('Invalid code or deviceName') };
      const used = await tx`DELETE FROM volta.pairing_codes WHERE code_hash = ${hash(code)} AND expires_at > now() RETURNING code_hash`;
      if (!used.length) return { error: new ApiError(401, 'invalid_pairing_code', 'Pairing code is invalid or expired') };
      const token = randomBytes(32).toString('base64url');
      const [device] = await tx`INSERT INTO volta.devices (name, token_hash) VALUES (${deviceName.trim()}, ${hash(token)}) RETURNING *`;
      return { value: { token, device: deviceShape(device!) } };
    });
    if (result.error) throw result.error;
    return result.value!;
  }
  /** Whether this server accepts Sign in with Apple, and whether an Apple Account is enrolled. */
  async appleStatus() {
    if (!this.apple) return { available: false, linked: false };
    const [row] = await this.sql`SELECT EXISTS (SELECT FROM volta.apple_owners) AS linked`;
    return { available: true, linked: row?.linked === true };
  }
  /** Lets the next Apple Account that signs in within ten minutes enroll itself. */
  async openAppleEnrollment() {
    await this.sql`INSERT INTO volta.apple_enrollment (expires_at) VALUES (now() + interval '10 minutes')
      ON CONFLICT (id) DO UPDATE SET expires_at = excluded.expires_at`;
  }
  /** Forgets every enrolled Apple Account. Devices they signed in keep their tokens until revoked. */
  async resetApple() {
    return this.sql.begin(async transaction => {
      const tx = transaction as unknown as DB;
      await tx`DELETE FROM volta.apple_enrollment`;
      return (await tx`DELETE FROM volta.apple_owners RETURNING subject_hash`).length;
    });
  }
  // Every attempt counts against the limit, including ones refused below.
  private async appleGate() {
    if (!this.apple) throw new ApiError(501, 'apple_sign_in_unavailable', 'Sign in with Apple is not configured on this server');
    if (await limited(this.sql, 'apple')) throw new ApiError(429, 'rate_limited', 'Too many sign-in attempts; retry after ten minutes');
    return this.apple;
  }
  // Runs outside any transaction because verification can fetch Apple's keys.
  // `rejected` is the status for a bad token: 401 would tell a signed-in app
  // that its own device token is dead.
  private async appleSubject(apple: AppleVerifier, identityToken: string, rejected: 400 | 401) {
    try { return hash(await apple.subject(identityToken)); } catch (error) {
      if (error instanceof AppleTokenError) throw new ApiError(rejected, 'invalid_apple_token', 'Apple sign-in could not be verified; try again');
      throw new ApiError(503, 'apple_unreachable', 'Apple could not be reached to verify the sign-in; try again');
    }
  }
  // An identity token is accepted once. It is known by what Apple signed, not
  // by its text: the same signature can be written in more than one base64url
  // spelling. A token can verify from one tolerance before its issue time to
  // one tolerance after its maximum age, and verification compares whole
  // seconds, so it is remembered for that span plus a minute.
  private async consumeAppleToken(tx: DB, identityToken: string) {
    const signed = identityToken.slice(0, identityToken.lastIndexOf('.'));
    await tx`DELETE FROM volta.apple_tokens WHERE expires_at <= now()`;
    const used = await tx`INSERT INTO volta.apple_tokens (token_hash, expires_at)
      VALUES (${hash(signed)}, now() + make_interval(secs => ${appleTokenMaxAgeSeconds + 2 * appleClockToleranceSeconds + 60}))
      ON CONFLICT (token_hash) DO NOTHING RETURNING token_hash`;
    return used.length === 1;
  }
  /** Issues a device token to an enrolled Apple Account, or to the first one to sign in while enrollment is open. */
  async appleSignIn(body: unknown) {
    const apple = await this.appleGate();
    const { identityToken, deviceName } = fields(body);
    if (!validToken(identityToken) || !validName(deviceName)) throw invalid('Expected identityToken and deviceName');
    const subject = await this.appleSubject(apple, identityToken, 401);
    const result = await this.sql.begin(async transaction => {
      const tx = transaction as unknown as DB;
      if (!await this.consumeAppleToken(tx, identityToken)) return { error: new ApiError(401, 'invalid_apple_token', 'Apple sign-in could not be verified; try again') };
      const enrolled = async () => (await tx`SELECT subject_hash FROM volta.apple_owners WHERE subject_hash = ${subject}`).length === 1;
      if (!await enrolled()) {
        // One open window enrolls one Apple Account; a concurrent sign-in finds
        // it gone. If that was the same account signing in twice, the winner
        // has committed its enrollment by the time the loser gets here.
        const opened = await tx`DELETE FROM volta.apple_enrollment WHERE expires_at > now() RETURNING id`;
        if (!opened.length && !await enrolled()) return { error: new ApiError(403, 'apple_id_not_enrolled', 'This Apple Account is not enrolled on this server. Link it from a paired device, or run `bun run cli apple-enroll` on the server and sign in again within ten minutes.') };
        if (opened.length) await tx`INSERT INTO volta.apple_owners (subject_hash) VALUES (${subject}) ON CONFLICT (subject_hash) DO NOTHING`;
      }
      const token = randomBytes(32).toString('base64url');
      const [device] = await tx`INSERT INTO volta.devices (name, token_hash) VALUES (${deviceName.trim()}, ${hash(token)}) RETURNING *`;
      return { value: { token, device: deviceShape(device!) } };
    });
    if (result.error) throw result.error;
    return result.value!;
  }
  /** Enrolls the Apple Account that a paired device just signed in with. */
  async appleLink(body: unknown) {
    const apple = await this.appleGate();
    const { identityToken } = fields(body);
    if (!validToken(identityToken)) throw invalid('Expected identityToken');
    const subject = await this.appleSubject(apple, identityToken, 400);
    const linked = await this.sql.begin(async transaction => {
      const tx = transaction as unknown as DB;
      if (!await this.consumeAppleToken(tx, identityToken)) return false;
      await tx`INSERT INTO volta.apple_owners (subject_hash) VALUES (${subject}) ON CONFLICT (subject_hash) DO NOTHING`;
      return true;
    });
    if (!linked) throw new ApiError(400, 'invalid_apple_token', 'Apple sign-in could not be verified; try again');
  }
  async authenticate(header: string | undefined) {
    const match = /^Bearer ([A-Za-z0-9_-]{43})$/.exec(header ?? '');
    const digest = hash(match?.[1] ?? '');
    const [device] = await this.sql`SELECT * FROM volta.devices WHERE token_hash = ${digest} AND revoked_at IS NULL`;
    const expected = device ? Buffer.from(device.token_hash) : Buffer.alloc(32);
    const equal = timingSafeEqual(digest, expected);
    if (!match || !device || !equal) throw new ApiError(401, 'unauthorized', 'Valid device token required');
    const [updated] = await this.sql`UPDATE volta.devices SET last_seen_at = now() WHERE id = ${device.id} AND revoked_at IS NULL RETURNING *`;
    if (!updated) throw new ApiError(401, 'unauthorized', 'Valid device token required');
    return deviceShape(updated);
  }
  async devices() { return (await this.sql`SELECT id, name, created_at, last_seen_at FROM volta.devices WHERE revoked_at IS NULL ORDER BY id`).map(deviceShape); }
  async revoke(id: number) {
    const rows = await this.sql`UPDATE volta.devices SET revoked_at = now() WHERE id = ${id} AND revoked_at IS NULL RETURNING id`;
    if (!rows.length) throw missing();
  }
}
