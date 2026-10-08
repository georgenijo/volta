import { randomBytes, createHash, timingSafeEqual } from 'node:crypto';
import type { DB, Row } from './db';
import { ApiError, invalid, missing } from './errors';
const hash = (value: string) => createHash('sha256').update(value).digest();
export const deviceShape = (row: Row) => ({ id: row.id, name: row.name, createdAt: row.created_at, lastSeenAt: row.last_seen_at });
export class Auth {
  constructor(private sql: DB) {}
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
    // Global, persisted limit: safe behind tailscale serve without trusting spoofable IP headers.
    const result = await this.sql.begin(async transaction => {
      // postgres.js TransactionSql omits its callable signature; runtime transaction is a SQL tag.
      const tx = transaction as unknown as DB;
      const [rate] = await tx`INSERT INTO volta.rate_limits AS r (key, window_start, attempts) VALUES ('pair', now(), 1)
        ON CONFLICT (key) DO UPDATE SET
        window_start = CASE WHEN r.window_start <= now() - interval '10 minutes' THEN now() ELSE r.window_start END,
        attempts = CASE WHEN r.window_start <= now() - interval '10 minutes' THEN 1 ELSE LEAST(r.attempts + 1, 31) END
        RETURNING attempts`;
      if (!rate || rate.attempts > 30) return { error: new ApiError(429, 'rate_limited', 'Too many pairing attempts; retry after ten minutes') };
      if (!body || typeof body !== 'object' || Array.isArray(body)) return { error: invalid('Expected code and deviceName') };
      const { code, deviceName } = body as Record<string, unknown>;
      if (typeof code !== 'string' || !/^[A-HJ-NP-Z2-9]{8}$/.test(code) || typeof deviceName !== 'string' || !deviceName.trim() || deviceName.trim().length > 100) return { error: invalid('Invalid code or deviceName') };
      const used = await tx`DELETE FROM volta.pairing_codes WHERE code_hash = ${hash(code)} AND expires_at > now() RETURNING code_hash`;
      if (!used.length) return { error: new ApiError(401, 'invalid_pairing_code', 'Pairing code is invalid or expired') };
      const token = randomBytes(32).toString('base64url');
      const [device] = await tx`INSERT INTO volta.devices (name, token_hash) VALUES (${deviceName.trim()}, ${hash(token)}) RETURNING *`;
      return { value: { token, device: deviceShape(device!) } };
    });
    if (result.error) throw result.error;
    return result.value!;
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
