#!/usr/bin/env bun
import { createHash } from 'node:crypto';
import { mkdir, readFile, readdir } from 'node:fs/promises';
import { cpus, platform, release } from 'node:os';
import { basename, dirname, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const FIXED_NOW = '2026-10-13T06:00:00.000Z';
const FROM_30D = '2026-09-13T06:00:00.000Z';
const FROM_7D = '2026-10-06T06:00:00.000Z';

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
type Sample = { phase: 'warmup' | 'measured'; iteration: number; durationMs: number; digest: string; responseBytes: number; profile: Json };

function args() {
  const values = process.argv.slice(2), result: Record<string, string[]> = {};
  for (let i = 0; i < values.length; i++) {
    const key = values[i]!;
    if (!key.startsWith('--')) throw new Error(`Unexpected argument: ${key}`);
    if (key === '--compare') {
      result.compare = [values[++i]!, values[++i]!];
      continue;
    }
    const value = values[++i];
    if (value === undefined || value.startsWith('--')) throw new Error(`Missing value for ${key}`);
    (result[key.slice(2)] ??= []).push(value);
  }
  return result;
}

function stable(value: unknown): string {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stable).join(',')}]`;
  return `{${Object.entries(value as Record<string, unknown>)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([key, item]) => `${JSON.stringify(key)}:${stable(item)}`).join(',')}}`;
}

function digest(value: unknown) {
  return createHash('sha256').update(stable(value)).digest('hex');
}

async function sourceTreeHash(root: string) {
  const files: string[] = [];
  const visit = async (directory: string) => {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const path = resolve(directory, entry.name);
      if (entry.isDirectory()) await visit(path);
      else if (entry.isFile() && entry.name.endsWith('.ts')) files.push(path);
    }
  };
  await visit(root);
  const hash = createHash('sha256');
  for (const file of files.sort()) {
    hash.update(file.slice(root.length + 1)).update('\0').update(await readFile(file)).update('\0');
  }
  return hash.digest('hex');
}

function stats(samples: number[]) {
  const sorted = [...samples].sort((a, b) => a - b);
  const percentile = (p: number) => sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * p) - 1)]!;
  const rounded = (n: number) => Math.round(n * 1000) / 1000;
  return {
    count: sorted.length,
    minMs: rounded(sorted[0]!),
    medianMs: rounded(percentile(0.5)),
    p95Ms: rounded(percentile(0.95)),
    maxMs: rounded(sorted.at(-1)!),
    meanMs: rounded(sorted.reduce((sum, n) => sum + n, 0) / sorted.length),
  };
}

async function compareFiles(baselinePath: string, workingPath: string, outputPath: string) {
  const baseline = JSON.parse(await readFile(baselinePath, 'utf8'));
  const working = JSON.parse(await readFile(workingPath, 'utf8'));
  const cases = Object.keys(baseline.cases);
  const compared = cases.map(name => {
    const before = baseline.cases[name], after = working.cases[name];
    if (!after) throw new Error(`Working result is missing case ${name}`);
    const baselineMs = before.statistics.medianMs, workingMs = after.statistics.medianMs;
    return {
      name,
      semanticEqual: before.semanticDigest === after.semanticDigest,
      semanticDigest: before.semanticDigest,
      baselineMedianMs: baselineMs,
      workingMedianMs: workingMs,
      speedup: Math.round((baselineMs / workingMs) * 1000) / 1000,
      reductionPercent: Math.round((1 - workingMs / baselineMs) * 100000) / 1000,
    };
  });
  const comparison = {
    formatVersion: 1,
    baseline: { label: baseline.label, revision: baseline.revision, implementationSha256: baseline.implementationSha256, file: basename(baselinePath) },
    working: { label: working.label, revision: working.revision, implementationSha256: working.implementationSha256, file: basename(workingPath) },
    fixedNow: baseline.fixedNow,
    sameDatabase: baseline.dataset.databaseIdentity === working.dataset.databaseIdentity,
    sameFixture: baseline.dataset.fixtureSha256 === working.dataset.fixtureSha256,
    sameDataset: baseline.dataset.fingerprint === working.dataset.fingerprint,
    allSemanticsEqual: compared.every(row => row.semanticEqual),
    cases: compared,
  };
  await mkdir(dirname(resolve(outputPath)), { recursive: true });
  await Bun.write(resolve(outputPath), JSON.stringify(comparison, null, 2) + '\n');
  console.log(JSON.stringify(comparison, null, 2));
  if (!comparison.sameDatabase || !comparison.sameFixture || !comparison.sameDataset || !comparison.allSemanticsEqual) process.exitCode = 2;
}

async function benchmark(options: Record<string, string[]>) {
  const sourceRoot = resolve(options['source-root']?.[0] ?? resolve(import.meta.dir, '../..'));
  const output = resolve(options.output?.[0] ?? '/tmp/volta-load-benchmark/working.json');
  const label = options.label?.[0] ?? 'working';
  const revision = options.revision?.[0] ?? 'working-tree';
  const sampleCount = Number(options.samples?.[0] ?? '5');
  const selected = new Set(options.case ?? []);
  if (!Number.isSafeInteger(sampleCount) || sampleCount < 1 || sampleCount > 100) throw new Error('--samples must be an integer from 1 to 100');
  for (const name of selected) if (!['dashboard_summaries', 'drives_30d_page100', 'drives_7d_page100', 'stats_history_paging_30d'].includes(name)) throw new Error(`Unknown case: ${name}`);

  const testUrl = process.env.TEST_DATABASE_URL;
  const readerUrl = process.env.TESLAMATE_DATABASE_URL;
  const authUrl = process.env.AUTH_DATABASE_URL;
  if (!testUrl || !readerUrl || !authUrl) throw new Error('TEST_DATABASE_URL, TESLAMATE_DATABASE_URL, and AUTH_DATABASE_URL are required');
  const urls = [testUrl, readerUrl, authUrl].map(value => new URL(value));
  for (const url of urls) {
    if (!['postgres:', 'postgresql:'].includes(url.protocol)
      || url.pathname !== '/volta_benchmark'
      || !['127.0.0.1', 'localhost'].includes(url.hostname)) {
      throw new Error('Refusing to benchmark outside an isolated localhost volta_benchmark database');
    }
  }
  const endpoints = new Set(urls.map(url => `${url.hostname}:${url.port || '5432'}`));
  if (endpoints.size !== 1) throw new Error('All benchmark database URLs must use the same localhost host and port');

  const moduleUrl = (relative: string) => pathToFileURL(resolve(sourceRoot, 'server/src', relative)).href;
  const [{ connect }, { Auth }, { Telemetry }, { createApp }] = await Promise.all([
    import(moduleUrl('db.ts')),
    import(moduleUrl('auth.ts')),
    import(moduleUrl('telemetry.ts')),
    import(moduleUrl('app.ts')),
  ]);
  const owner = connect(testUrl, false, 120000);
  const reader = connect(readerUrl, true);
  const authDb = connect(authUrl);
  try {
    const [counts] = await owner`SELECT
      (SELECT count(*)::integer FROM public.drives) AS drives,
      (SELECT count(*)::integer FROM public.positions) AS positions,
      (SELECT count(*)::integer FROM public.charging_processes) AS charging_processes,
      (SELECT count(*)::integer FROM public.charges) AS charges,
      (SELECT count(*)::integer FROM public.states) AS states,
      (SELECT count(*)::integer FROM volta_telemetry.samples) AS fleet_samples,
      (SELECT count(*)::integer FROM volta_telemetry.sessions) AS fleet_sessions,
      (SELECT count(*)::integer FROM volta_telemetry.gaps) AS fleet_gaps`;
    const [identity] = await owner`SELECT system_identifier::text AS value FROM pg_control_system()`;
    const [sizes] = await owner`SELECT
      pg_database_size(current_database())::text AS database_bytes,
      pg_total_relation_size('public.positions')::text AS positions_bytes,
      pg_total_relation_size('volta_telemetry.samples')::text AS fleet_samples_bytes`;
    const fixtureSha256 = createHash('sha256').update(await readFile(resolve(import.meta.dir, '../test/load-benchmark-fixtures.sql'))).digest('hex');
    const fixtureFingerprint = digest({ fixtureSha256, counts });
    const implementationSha256 = await sourceTreeHash(resolve(sourceRoot, 'server/src'));

    const auth = new Auth(authDb);
    const paired = await auth.pair({ code: await auth.createPairingCode(), deviceName: `Synthetic benchmark ${label}` });
    const telemetry = new Telemetry(reader, 'USD', () => new Date(FIXED_NOW), true, () => {});
    const app = createApp(auth, telemetry, () => {});
    const headers = { Authorization: `Bearer ${paired.token}` };
    let requestCount = 0;
    const get = async (path: string) => {
      requestCount++;
      const response = await app.request(path, { headers });
      const body = await response.json();
      if (response.status !== 200) throw new Error(`${path}: HTTP ${response.status} ${JSON.stringify(body)}`);
      return body as any;
    };
    const pagePath = (kind: 'drives' | 'charges', from: string, cursor?: string) =>
      `/v1/vehicles/1/${kind}?from=${encodeURIComponent(from)}&to=${encodeURIComponent(FIXED_NOW)}&limit=100${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ''}`;
    const paginate = async (kind: 'drives' | 'charges', from: string) => {
      const pages: any[] = [];
      let cursor: string | undefined;
      do {
        const page = await get(pagePath(kind, from, cursor));
        pages.push(page);
        cursor = page.nextCursor ?? undefined;
      } while (cursor);
      return pages;
    };
    const cases: Record<string, () => Promise<any>> = {
      dashboard_summaries: () => Promise.all(['today', '7d', '30d'].map(range =>
        get(`/v1/vehicles/1/summary?range=${range}&tz=UTC`))),
      drives_30d_page100: () => get(pagePath('drives', FROM_30D)),
      drives_7d_page100: () => get(pagePath('drives', FROM_7D)),
      stats_history_paging_30d: async () => {
        const [drives, charges] = await Promise.all([paginate('drives', FROM_30D), paginate('charges', FROM_30D)]);
        return { drives, charges };
      },
    };
    const profile = (name: string, value: any): Json => {
      if (name === 'dashboard_summaries') return value.map((summary: any) => ({ range: summary.range, driveCount: summary.driveCount, chargeCount: summary.chargeCount })) as Json;
      if (name.startsWith('drives_')) return { items: value.items.length, hasNextPage: value.nextCursor !== null };
      return {
        drivePages: value.drives.length,
        driveItems: value.drives.reduce((sum: number, page: any) => sum + page.items.length, 0),
        chargePages: value.charges.length,
        chargeItems: value.charges.reduce((sum: number, page: any) => sum + page.items.length, 0),
      };
    };
    const measured: Record<string, any> = {};
    for (const [name, run] of Object.entries(cases)) {
      if (selected.size && !selected.has(name)) continue;
      const samples: Sample[] = [];
      for (let iteration = 0; iteration <= sampleCount; iteration++) {
        requestCount = 0;
        const started = performance.now();
        const value = await run();
        const durationMs = performance.now() - started;
        const rendered = stable(value);
        const sample: Sample = {
          phase: iteration === 0 ? 'warmup' : 'measured',
          iteration,
          durationMs: Math.round(durationMs * 1000) / 1000,
          digest: createHash('sha256').update(rendered).digest('hex'),
          responseBytes: Buffer.byteLength(rendered),
          profile: { ...(profile(name, value) as Record<string, Json>), httpRequests: requestCount },
        };
        samples.push(sample);
        console.error(`${label} ${name} ${sample.phase} ${iteration}: ${sample.durationMs} ms ${sample.digest.slice(0, 12)}`);
      }
      const semanticDigests = new Set(samples.map(sample => sample.digest));
      if (semanticDigests.size !== 1) throw new Error(`${name} returned different semantic digests across warmup/measured runs`);
      measured[name] = {
        semanticDigest: samples[0]!.digest,
        responseBytes: samples[0]!.responseBytes,
        profile: samples[0]!.profile,
        warmup: samples[0],
        samples: samples.slice(1),
        statistics: stats(samples.slice(1).map(sample => sample.durationMs)),
      };
    }
    const result = {
      formatVersion: 1,
      label,
      revision,
      implementationSha256,
      fixedNow: FIXED_NOW,
      ranges: { sevenDaysFrom: FROM_7D, thirtyDaysFrom: FROM_30D, to: FIXED_NOW },
      samplesPerCase: sampleCount,
      warmupsPerCase: 1,
      measuredAt: new Date().toISOString(),
      runtime: {
        bun: process.versions.bun,
        platform: `${platform()} ${release()}`,
        cpu: cpus()[0]?.model ?? 'unknown',
        cpuCount: cpus().length,
      },
      dataset: { fingerprint: fixtureFingerprint, fixtureSha256, databaseIdentity: identity!.value, counts, sizes },
      cases: measured,
    };
    await mkdir(dirname(output), { recursive: true });
    await Bun.write(output, JSON.stringify(result, null, 2) + '\n');
    console.log(JSON.stringify({ output, label, revision, fixedNow: FIXED_NOW, dataset: result.dataset, cases: Object.fromEntries(Object.entries(measured).map(([name, value]) => [name, value.statistics])) }, null, 2));
  } finally {
    await Promise.allSettled([owner.end(), reader.end(), authDb.end()]);
  }
}

const options = args();
if (options.compare) {
  const output = options.output?.[0];
  if (!output) throw new Error('--compare requires --output');
  await compareFiles(options.compare[0]!, options.compare[1]!, output);
} else {
  await benchmark(options);
}
