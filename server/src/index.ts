import { ServiceLog } from './service';
import { createApp } from './app';
import { AppleVerifier } from './apple';
import { Auth } from './auth';
import { connect, requiredEnv } from './db';
import { ChargingHistory } from './history';
import { DriveDetail } from './drive-detail';
import { Dem } from './elevation';
import { Telemetry } from './telemetry';
import { TeslaLink, commanderURL } from './tesla';
import { integer } from './validation';
const telemetryDb = connect(requiredEnv('TESLAMATE_DATABASE_URL'), true);
const authDb = connect(requiredEnv('AUTH_DATABASE_URL'));
const currency = process.env.CURRENCY || null;
if (currency !== null && !/^[A-Z]{3}$/.test(currency)) throw new Error('CURRENCY must be a three-letter ISO currency code');
// Tesla sign-in stays disabled (501) unless commander is configured.
const commanderSecret = process.env.COMMANDER_INTERNAL_SECRET || '';
if (process.env.COMMANDER_URL && commanderSecret.length < 32) throw new Error('COMMANDER_INTERNAL_SECRET must contain at least 32 characters');
const tesla = process.env.COMMANDER_URL ? new TeslaLink(commanderURL(process.env.COMMANDER_URL), commanderSecret) : null;
const fleetEnabled = process.env.FLEET_TELEMETRY_ENABLED === 'true';
// Optional: serve only this TeslaMate car id; every other car answers 404.
const vehicleId = process.env.VOLTA_VEHICLE_ID ? integer(process.env.VOLTA_VEHICLE_ID, 'VOLTA_VEHICLE_ID', 1, 2097151) : null;
const log = (entry: object) => console.log(JSON.stringify(entry));
if (process.env.FLEET_TELEMETRY_ENABLED && !['true','false'].includes(process.env.FLEET_TELEMETRY_ENABLED)) throw new Error('FLEET_TELEMETRY_ENABLED must be true or false');
// Sign in with Apple stays disabled (501) unless the app's bundle ID is configured.
const apple = process.env.APPLE_BUNDLE_ID ? new AppleVerifier(process.env.APPLE_BUNDLE_ID) : null;
const app = createApp(new Auth(authDb, apple), new Telemetry(telemetryDb, currency, undefined, fleetEnabled, log, vehicleId), log, tesla, new ChargingHistory(authDb, telemetryDb, tesla), new ServiceLog(authDb), new DriveDetail(telemetryDb, Dem.fromEnv(), log));
// A rebuilt TeslaMate can renumber cars; say so rather than serve an empty list silently.
if (vehicleId !== null) telemetryDb`SELECT 1 FROM public.cars WHERE id=${vehicleId}`
  .then(rows => { if (!rows.length) log({ level: 'warn', event: 'vehicle_filter_unknown', message: 'VOLTA_VEHICLE_ID is not a TeslaMate car; /v1/vehicles is empty' }); })
  // Only the error code: connection errors can name hosts.
  .catch((error: any) => log({ level: 'warn', event: 'vehicle_filter_check_failed', code: String(error?.code ?? error?.name ?? 'unknown') }));
// Commander can spend up to 65 seconds waking and executing a command. Keep the
// inbound connection alive beyond the relay's 75-second deadline.
const server = Bun.serve({ hostname: process.env.HOST || '127.0.0.1', port: integer(process.env.PORT, 'PORT', 8080, 65535), idleTimeout: 90, fetch: app.fetch });
for (const signal of ['SIGTERM', 'SIGINT'] as const) process.on(signal, async () => { server.stop(); await Promise.all([telemetryDb.end(), authDb.end()]); process.exit(0); });
console.log(JSON.stringify({ event: 'started', port: server.port, version: '0.1.0' }));
