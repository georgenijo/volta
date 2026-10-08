import { Auth } from './auth';
import { connect, requiredEnv } from './db';
import { ApiError } from './errors';
import { probe, resume, sync, window } from './history';
import { HistoryCallError, TeslaLink, commanderURL } from './tesla';
import { integer } from './validation';

const usage = `Usage: bun run cli pair|devices|revoke <id>
  history-probe --since <UTC> [--until <UTC>] [--page 0|1|N] [--page-size N]
  history-sync --since <UTC> [--until <UTC>] --first-page 0|1 [--max-pages N] [--page-size N] [--apply]
  history-sync --resume <token> [--max-pages N] [--apply]`;
// Strict --name value pairs; unknown or repeated options are refused.
function options(args: string[], allowed: string[], flags: string[] = []) {
  const out: Record<string, string> = {};
  for (let i = 0; i < args.length; i++) {
    const name = args[i]!.replace(/^--/, '');
    if (!args[i]!.startsWith('--') || name in out || (!allowed.includes(name) && !flags.includes(name))) throw new RangeError(usage);
    if (flags.includes(name)) { out[name] = 'true'; continue; }
    const value = args[++i];
    if (value === undefined || value.startsWith('--')) throw new RangeError(usage);
    out[name] = value;
  }
  return out;
}
const pageNumber = (value: string | undefined, fallback: number) => value === undefined ? fallback : value === '0' ? 0 : integer(value, 'page', undefined, 200);
// An applied sync's resume token goes to stderr before its first Tesla call,
// so a run that crashes after paying for pages can still be continued; if it
// cannot be written, the run stops before calling.
const announce = (token: string) => new Promise<void>((resolve, reject) =>
  process.stderr.write(`Resume token (continues this run if it stops early): ${token}\n`, error => error ? reject(error) : resolve()));
function commander() {
  const secret = requiredEnv('COMMANDER_INTERNAL_SECRET');
  if (secret.length < 32) throw new RangeError('COMMANDER_INTERNAL_SECRET must contain at least 32 characters');
  return new TeslaLink(commanderURL(requiredEnv('COMMANDER_URL')), secret);
}

const [command, ...args] = process.argv.slice(2);
const history = command?.startsWith('history-');
const sql = history && command === 'history-probe' ? null : connect(requiredEnv('AUTH_DATABASE_URL'));
try {
  switch (command) {
    case 'pair': if (args.length) throw new RangeError(usage); console.log(`Pairing code (valid 10 minutes, single use): ${await new Auth(sql!).createPairingCode()}`); break;
    case 'devices': if (args.length) throw new RangeError(usage); console.log(JSON.stringify(await new Auth(sql!).devices(), null, 2)); break;
    case 'revoke': if (args.length !== 1) throw new RangeError(usage); await new Auth(sql!).revoke(integer(args[0], 'device id')); console.log('Device revoked'); break;
    // Exactly one Tesla call; nothing is stored. Prints counts only, never VINs or IDs.
    case 'history-probe': {
      const o = options(args, ['since', 'until', 'page', 'page-size']);
      const w = window(o.since, o.until, o['page-size'] === undefined ? 10 : integer(o['page-size'], 'page size', undefined, 50));
      console.log(JSON.stringify(await probe(commander(), w, pageNumber(o.page, 0)), null, 2));
      break;
    }
    // Without --apply this prints the bounded plan and makes no Tesla call.
    case 'history-sync': {
      const o = options(args, ['since', 'until', 'first-page', 'max-pages', 'page-size', 'resume'], ['apply']);
      const maxPages = o['max-pages'] === undefined ? 5 : integer(o['max-pages'], 'max pages', undefined, 20);
      // A resumed run takes its window, page size and page base from storage.
      if (o.resume !== undefined) {
        if (['since', 'until', 'first-page', 'page-size'].some(k => k in o)) throw new RangeError('--resume continues a stored run; it takes only --max-pages and --apply');
        console.log(JSON.stringify(await resume(sql!, commander(), { token: o.resume, maxPages, apply: o.apply === 'true' }, undefined, announce), null, 2));
        break;
      }
      if (o['first-page'] !== '0' && o['first-page'] !== '1') throw new RangeError('--first-page 0|1 is required; settle it with history-probe first');
      const w = window(o.since, o.until, o['page-size'] === undefined ? 50 : integer(o['page-size'], 'page size', undefined, 50));
      console.log(JSON.stringify(await sync(sql!, commander(), { ...w, firstPage: Number(o['first-page']) as 0 | 1, maxPages, apply: o.apply === 'true' }, undefined, announce), null, 2));
      break;
    }
    default: throw new RangeError(usage);
  }
} catch (error) {
  // Validation and commander refusal codes are safe to print; database errors are not.
  if (error instanceof HistoryCallError) console.error(`Charging history refused: ${error.code}${error.retryAfter ? ` (retry after ${error.retryAfter}s)` : ''}`);
  else if (history && (error instanceof RangeError || error instanceof ApiError)) console.error(error.message);
  else console.error('CLI failed. Check command, device id, and database configuration.');
  process.exitCode = 1;
}
finally { await sql?.end(); }
