import { describe, expect, test } from 'bun:test';
import worker, { CALLBACK_PATH, KEY_PATH, appCallback, publicKey } from './worker.js';
import config from './wrangler.toml';

// Synthetic P-256 public key; never a production key.
const PEM = `-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEyHGoqmVDtBNfZhImUqYCsqfaUKmw
b0pXP8nCDbPLDmBf3PZrZPCzxG7IhcFQSywF2R0ZBYP1uaQ42TlN0Z9vYQ==
-----END PUBLIC KEY-----`;
const env = { TESLA_PUBLIC_KEY_PEM: PEM };
const call = (path, init = {}, e = env) => worker.fetch(new Request(`https://example.com${path}`, init), e);
const securityHeaders = (res) => {
  expect(res.headers.get('cache-control')).toBe('no-store');
  expect(res.headers.get('referrer-policy')).toBe('no-referrer');
  expect(res.headers.get('x-content-type-options')).toBe('nosniff');
};

describe('callback bounce', () => {
  test('forwards only state and code into the app', async () => {
    const res = await call(`${CALLBACK_PATH}?code=SYNTHETIC-CODE&state=s1&issuer=https%3A%2F%2Fauth.example&locale=en-US`, { redirect: 'manual' });
    expect(res.status).toBe(302);
    expect(res.headers.get('location')).toBe('volta://tesla-callback?code=SYNTHETIC-CODE&state=s1');
    expect(await res.text()).toBe('');
    securityHeaders(res);
  });
  test('forwards a denial without its description', async () => {
    const res = await call(`${CALLBACK_PATH}?error=access_denied&error_description=user+said+no&state=s1`);
    expect(res.headers.get('location')).toBe('volta://tesla-callback?error=access_denied&state=s1');
  });
  test('rejects malformed queries', async () => {
    for (const q of ['', '?code=a', '?state=s', '?state=s&code=a&error=b', '?state=s&state=t&code=a', '?state=s&code=a&code=b', '?state=&code=a', '?state=s&code=', '?state=s&code=%zz', `?state=s&code=${'a'.repeat(5000)}`]) {
      const res = await call(CALLBACK_PATH + q);
      expect(res.status).toBe(400);
      expect(res.headers.get('location')).toBeNull();
      securityHeaders(res);
    }
  });
  test('only GET', async () => {
    expect((await call(`${CALLBACK_PATH}?state=s&code=a`, { method: 'POST' })).status).toBe(405);
  });
  test('escapes values safely', () => {
    expect(appCallback('state=a%26b%3Dc&code=x%2By')).toBe('volta://tesla-callback?code=x%2By&state=a%26b%3Dc');
  });
});

describe('public key', () => {
  test('serves the bound public key', async () => {
    const res = await call(KEY_PATH);
    expect(res.status).toBe(200);
    expect(res.headers.get('content-type')).toBe('application/x-pem-file');
    expect(await res.text()).toBe(PEM + '\n');
    securityHeaders(res);
    const head = await call(KEY_PATH, { method: 'HEAD' });
    expect(head.status).toBe(200);
  });
  test('refuses private keys and missing bindings', async () => {
    expect(publicKey('-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----')).toBeNull();
    expect(publicKey('-----BEGIN EC PRIVATE KEY-----\nAAAA\n-----END EC PRIVATE KEY-----')).toBeNull();
    expect(publicKey(`${PEM}\n-----BEGIN EC PRIVATE KEY-----\nAAAA\n-----END EC PRIVATE KEY-----`)).toBeNull();
    expect((await call(KEY_PATH, {}, {})).status).toBe(404);
    expect((await call(KEY_PATH, {}, { TESLA_PUBLIC_KEY_PEM: 'junk' })).status).toBe(404);
  });
});

describe('no fallthrough', () => {
  test('every other path is a local 404, never proxied', async () => {
    const original = globalThis.fetch;
    globalThis.fetch = () => { throw new Error('worker contacted an origin'); };
    try {
      for (const path of ['/', '/v1/vehicles', '/volta/oauth/callback/', '/volta/oauth', '/.well-known/other', `${CALLBACK_PATH}x?state=s&code=a`]) {
        const res = await call(path);
        expect(res.status).toBe(404);
        securityHeaders(res);
      }
    } finally {
      globalThis.fetch = original;
    }
  });
});

// Cloudflare route selection, per developers.cloudflare.com/workers/configuration/routing/routes:
// a pattern is matched against the whole URL including its query string, `*`
// matches zero or more of any character, patterns may not contain a query, and
// a pattern without a scheme matches http and https.
describe('routes', () => {
  const routeRegex = (pattern) => new RegExp(`^${pattern.split('*').map((s) => s.replace(/[.+?^${}()|[\]\\/]/g, '\\$&')).join('.*')}$`);
  const routed = (url) => {
    const u = new URL(url);
    return config.routes.some((r) => routeRegex(r.pattern).test(`${u.host}${u.pathname}${u.search}`));
  };
  const site = 'https://georgenijo.com';

  test('patterns are scheme-less, query-less and only trail a wildcard', () => {
    expect(config.routes.map((r) => r.pattern)).toEqual([`georgenijo.com${CALLBACK_PATH}*`, `georgenijo.com${KEY_PATH}`]);
    for (const { pattern, zone_name } of config.routes) {
      expect(zone_name).toBe('georgenijo.com');
      expect(pattern).not.toContain('?');
      expect(pattern).not.toContain('://');
      expect(pattern.indexOf('*')).toBeOneOf([-1, pattern.length - 1]);
    }
    expect(config.workers_dev).toBe(false);
    expect(config.preview_urls).toBe(false);
  });

  test('every real callback reaches the worker and bounces into the app', async () => {
    for (const q of ['?code=SYNTHETIC-CODE&state=s1', '?state=s1&code=SYNTHETIC-CODE&issuer=https%3A%2F%2Fauth.example', '?error=access_denied&error_description=no&state=s1']) {
      for (const scheme of ['https', 'http']) expect(routed(`${scheme}://georgenijo.com${CALLBACK_PATH}${q}`)).toBe(true);
      const res = await worker.fetch(new Request(`${site}${CALLBACK_PATH}${q}`), env);
      expect(res.status).toBe(302);
      expect(res.headers.get('location')).toStartWith('volta://tesla-callback?');
    }
    expect(routed(`${site}${KEY_PATH}`)).toBe(true);
  });

  test('the wildcard claims only the callback prefix, which 404s locally', async () => {
    for (const path of ['/', '/volta', '/volta/oauth', '/volta/oauth/', '/volta/oauth/callbac', '/blog?x=/volta/oauth/callback', '/.well-known/other', `/x${CALLBACK_PATH}?state=s&code=a`]) {
      expect(routed(`${site}${path}`)).toBe(false);
    }
    expect(routed(`https://www.georgenijo.com${CALLBACK_PATH}?state=s&code=a`)).toBe(false);
    for (const path of [`${CALLBACK_PATH}/`, `${CALLBACK_PATH}x?state=s&code=a`, `${CALLBACK_PATH}%2F?state=s&code=a`]) {
      const url = `${site}${path}`;
      expect(routed(url)).toBe(true);
      const res = await worker.fetch(new Request(url), env);
      expect(res.status).toBe(404);
      expect(res.headers.get('location')).toBeNull();
    }
  });
});
