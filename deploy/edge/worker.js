// Volta's only public surface on the owner's domain: the Tesla sign-in
// redirect and the Tesla partner public key. Stateless, credential-free, and
// never forwards a request to any origin, so a non-matching path cannot reach
// the site or Volta's private API.
export const CALLBACK_PATH = '/volta/oauth/callback';
export const KEY_PATH = '/.well-known/appspecific/com.tesla.3p.public-key.pem';
const APP_CALLBACK = 'volta://tesla-callback';

const baseHeaders = {
  'Cache-Control': 'no-store',
  'Referrer-Policy': 'no-referrer',
  'X-Content-Type-Options': 'nosniff',
  'X-Robots-Tag': 'noindex',
  'Content-Security-Policy': "default-src 'none'; frame-ancestors 'none'",
};

const respond = (status, extra = {}, body = null) => new Response(body, { status, headers: { ...baseHeaders, ...extra } });
const text = (status, body) => respond(status, { 'Content-Type': 'text/plain; charset=utf-8' }, body);

// Exactly one state and exactly one of code or error, all non-empty. Anything
// else Tesla appends (issuer, locale, error_description) is dropped.
export function appCallback(rawQuery) {
  if (rawQuery.length > 4096) return null;
  let params;
  try {
    // URLSearchParams silently replaces malformed escapes; reject them instead.
    for (const part of rawQuery.split('&')) if (part) decodeURIComponent(part.replace(/\+/g, ' '));
    params = new URLSearchParams(rawQuery);
  } catch {
    return null;
  }
  const state = params.getAll('state');
  const code = params.getAll('code');
  const error = params.getAll('error');
  if (state.length !== 1 || !state[0] || code.length > 1 || error.length > 1 || code.length === error.length) return null;
  if ((code.length && !code[0]) || (error.length && !error[0])) return null;
  const out = new URLSearchParams();
  if (code.length) out.set('code', code[0]); else out.set('error', error[0]);
  out.set('state', state[0]);
  return `${APP_CALLBACK}?${out}`;
}

// The binding must hold one public key; a private key is refused outright.
export function publicKey(pem) {
  if (typeof pem !== 'string') return null;
  const trimmed = pem.trim();
  if (/PRIVATE/.test(trimmed)) return null;
  if (!/^-----BEGIN PUBLIC KEY-----\r?\n[A-Za-z0-9+/=\r\n]+-----END PUBLIC KEY-----$/.test(trimmed)) return null;
  return trimmed + '\n';
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === CALLBACK_PATH) {
      if (request.method !== 'GET') return text(405, 'Method not allowed\n');
      const target = appCallback(url.search.slice(1));
      if (!target) return text(400, 'Return to Volta and sign in again.\n');
      return respond(302, { Location: target });
    }
    if (url.pathname === KEY_PATH) {
      if (request.method !== 'GET' && request.method !== 'HEAD') return text(405, 'Method not allowed\n');
      const pem = publicKey(env.TESLA_PUBLIC_KEY_PEM);
      if (!pem) return text(404, 'Not found\n');
      return respond(200, { 'Content-Type': 'application/x-pem-file' }, request.method === 'HEAD' ? null : pem);
    }
    return text(404, 'Not found\n');
  },
};
