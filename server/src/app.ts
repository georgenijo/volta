import { ServiceLog } from './service';
import { Hono } from 'hono';
import { bodyLimit } from 'hono/body-limit';
import { ApiError, invalid } from './errors';
import { Auth } from './auth';
import { Telemetry } from './telemetry';
import { TeslaLink, unavailableStatus } from './tesla';
import type { ChargingHistory } from './history';
import { choice, driveId, integer, listInput, page, timeZone } from './validation';

type Device = Awaited<ReturnType<Auth['authenticate']>>;
export function createApp(auth: Auth, telemetry: Telemetry, log: (entry: object) => void = entry => console.log(JSON.stringify(entry)), tesla: TeslaLink | null = null, history: ChargingHistory | null = null, service: ServiceLog | null = null) {
  const app = new Hono<{ Variables: { device: Device } }>();
  app.use('*', async (c, next) => {
    const started = performance.now();
    await next();
    // Route template only: no body, headers, token, query string, or user-controlled path.
    log({ method: c.req.method, route: c.req.routePath === '/*' ? 'unmatched' : c.req.routePath, status: c.res.status, durationMs: Math.round(performance.now()-started) });
  });
  app.use('*', bodyLimit({ maxSize: 4096, onError: c => c.json({ error: { code: 'payload_too_large', message: 'Body exceeds 4096 bytes' } }, 413) }));
  app.use('/v1/*', async (c, next) => {
    if (!((c.req.method === 'GET' && c.req.path === '/v1/health') || (c.req.method === 'POST' && c.req.path === '/v1/auth/pair'))) c.set('device', await auth.authenticate(c.req.header('Authorization')));
    await next();
  });
  app.onError((error, c) => {
    if (error instanceof ApiError) return c.json({ error: { code: error.code, message: error.message } }, error.status);
    // Postgres errors contain SQL and parameters. Never log the original error.
    log({ event: 'request_failed', category: 'internal' });
    return c.json({ error: { code: 'service_unavailable', message: 'Service temporarily unavailable' } }, 503);
  });
  app.notFound(c => c.json({ error: { code: 'not_found', message: 'Resource not found' } }, 404));
  app.get('/v1/health', async c => c.json(await telemetry.health()));
  app.post('/v1/auth/pair', async c => {
    let body: unknown;
    try { body = await c.req.json(); } catch (error) {
      if (error instanceof Error && error.name === 'BodyLimitError') throw error;
      body = null;
    }
    return c.json(await auth.pair(body));
  });
  app.get('/v1/me', c => c.json(c.get('device')));
  app.delete('/v1/me', async c => { await auth.revoke(c.get('device').id); return c.body(null, 204); });
  app.get('/v1/vehicles', async c => c.json(await telemetry.vehicles()));
  app.get('/v1/vehicles/:id/status', async c => c.json(await telemetry.status(integer(c.req.param('id'), 'id'))));
  app.get('/v1/vehicles/:id/summary', async c => {
    const id = integer(c.req.param('id'), 'id'); await telemetry.vehicle(id);
    return c.json(await telemetry.summary(id, choice(c.req.query('range'), ['today','7d','30d'], 'today'), timeZone(c.req.query('tz'))));
  });
  app.get('/v1/vehicles/:id/timeline', async c => {
    const id = integer(c.req.param('id'), 'id'); await telemetry.vehicle(id);
    return c.json(await telemetry.timeline(id, integer(c.req.query('hours'), 'hours', 48, 744)));
  });
  for (const kind of ['drives', 'charges', 'idles'] as const) {
    app.get(`/v1/vehicles/:id/${kind}`, async c => {
      const id = integer(c.req.param('id'), 'id'); await telemetry.vehicle(id);
      const scope = `${id}/${kind}`, q = listInput(c.req.query(), scope);
      const rows = await telemetry[kind](id, q);
      return c.json(page(rows, q, scope));
    });
  }
  app.get('/v1/drives/:id', async c => c.json(await telemetry.drive(driveId(c.req.param('id')))));
  app.get('/v1/charges/:id', async c => c.json(await telemetry.charge(integer(c.req.param('id'), 'id'))));
  app.get('/v1/vehicles/:id/battery', async c => { const id = integer(c.req.param('id'), 'id'); await telemetry.vehicle(id); return c.json(await telemetry.battery(id)); });
  app.get('/v1/vehicles/:id/mileage', async c => { const id = integer(c.req.param('id'), 'id'); await telemetry.vehicle(id); return c.json(await telemetry.mileage(id, choice(c.req.query('bucket'), ['day','week','month'], 'month'))); });
  app.get('/v1/vehicles/:id/firmware', async c => { const id = integer(c.req.param('id'), 'id'); await telemetry.vehicle(id); return c.json(await telemetry.firmware(id)); });
  app.get('/v1/vehicles/:id/places', async c => { await telemetry.vehicle(integer(c.req.param('id'), 'id')); return c.json(await telemetry.places()); });
  const services = () => { if (!service) throw new ApiError(503, 'service_unavailable', 'Service storage is unavailable'); return service; };
  app.get('/v1/vehicles/:id/service', async c => {
    const id = integer(c.req.param('id'), 'id'); await telemetry.vehicle(id);
    return c.json(await services().list(id, await telemetry.serviceOdometer(id)));
  });
  const serviceBody = async (c: any) => { try { return await c.req.json(); } catch (error) { if (error instanceof Error && error.name === 'BodyLimitError') throw error; throw invalid('Expected JSON body'); } };
  app.post('/v1/vehicles/:id/service', async c => {
    const id = integer(c.req.param('id'), 'id'); await telemetry.vehicle(id);
    return c.json(await services().add(id, await serviceBody(c)), 201);
  });
  app.post('/v1/vehicles/:id/service/:item/events', async c => {
    const id = integer(c.req.param('id'), 'id'); await telemetry.vehicle(id);
    return c.json(await services().complete(id, c.req.param('item'), await serviceBody(c)), 201);
  });
  app.patch('/v1/vehicles/:id/service/:item', async c => {
    const id=integer(c.req.param('id'),'id'); await telemetry.vehicle(id);
    return c.json(await services().update(id,c.req.param('item'),await serviceBody(c)));
  });
  app.delete('/v1/vehicles/:id/service/:item', async c => {
    const id=integer(c.req.param('id'),'id'); await telemetry.vehicle(id);
    await services().remove(id,c.req.param('item')); return c.body(null,204);
  });
  app.patch('/v1/vehicles/:id/service-events/:event', async c => {
    const id=integer(c.req.param('id'),'id'); await telemetry.vehicle(id);
    return c.json(await services().updateEvent(id,c.req.param('event'),await serviceBody(c)));
  });
  app.delete('/v1/vehicles/:id/service-events/:event', async c => {
    const id=integer(c.req.param('id'),'id'); await telemetry.vehicle(id);
    await services().removeEvent(id,c.req.param('event')); return c.body(null,204);
  });
  app.get('/v1/vehicles/:id/charger-locations', async c => {
    const id = integer(c.req.param('id'), 'id'); await telemetry.vehicle(id);
    return c.json(await telemetry.chargerLocations(id));
  });
  app.get('/v1/vehicles/:id/charger-locations/:location/sessions', async c => {
    const id = integer(c.req.param('id'), 'id'); await telemetry.vehicle(id);
    const location = c.req.param('location');
    if (!/^[gas]:[1-9]\d*$/.test(location)) throw invalid('Invalid charging location');
    const scope = `${id}/charger-locations/${location}`, q = listInput(c.req.query(), scope);
    return c.json(page(await telemetry.chargerSessions(id, location, q), q, scope));
  });
  const linked = () => { if (!tesla) throw new ApiError(501, 'tesla_link_unavailable', 'Tesla sign-in is not set up on this server'); return tesla; };
  app.get('/v1/tesla/status', async c => c.json(tesla ? await tesla.status() : unavailableStatus));
  app.post('/v1/tesla/link', async c => c.json(await linked().start(c.get('device').id)));
  app.post('/v1/tesla/link/complete', async c => {
    const t = linked();
    let body: any;
    try { body = await c.req.json(); } catch (error) {
      if (error instanceof Error && error.name === 'BodyLimitError') throw error;
      body = null;
    }
    return c.json(await t.complete(c.get('device').id, body?.callbackUrl));
  });
  app.delete('/v1/tesla/link', async c => { await linked().cancel(c.get('device').id); return c.body(null, 204); });
  app.delete('/v1/tesla/account', async c => { await linked().disconnect(); return c.body(null, 204); });
  // Tesla-billed sessions synced by the operator CLI; separate from TeslaMate charges.
  const billed = () => { if (!history) throw new ApiError(501, 'tesla_link_unavailable', 'Tesla sign-in is not set up on this server'); return history; };
  app.get('/v1/tesla/charging-history', async c => c.json(await billed().summary()));
  app.get('/v1/vehicles/:id/tesla-charging-sessions', async c => c.json(await billed().sessions(integer(c.req.param('id'), 'id'), c.req.query())));
  app.post('/v1/vehicles/:id/commands/:name', async c => {
    await telemetry.vehicle(integer(c.req.param('id'), 'id'));
    throw new ApiError(501, 'commands_unavailable', 'Vehicle commands are unavailable in phase 1');
  });
  return app;
}
