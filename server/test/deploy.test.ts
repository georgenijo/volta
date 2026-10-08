import { expect, test } from 'bun:test';
import { mkdtemp, rm, chmod } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

test('startup guard passes only when the configured address actually exists', async () => {
  const dir = await mkdtemp(join(tmpdir(),'volta-tailnet-guard-'));
  try {
    await Bun.write(join(dir,'ip'), '#!/bin/sh\nif [ "$MOCK_ASSIGNED" = yes ]; then echo "8: tailscale0 inet 100.64.0.1/32 scope global tailscale0"; fi\n');
    await Bun.write(join(dir,'sleep'), '#!/bin/sh\nexit 0\n');
    await Promise.all([chmod(join(dir,'ip'),0o755),chmod(join(dir,'sleep'),0o755)]);
    const run = (assigned: string, address: string) => Bun.spawn(['sh',new URL('../../deploy/ubuntu/wait-tailnet.sh',import.meta.url).pathname,address],
      {env:{...process.env,PATH:`${dir}:${process.env.PATH}`,MOCK_ASSIGNED:assigned},stdout:'pipe',stderr:'pipe'});
    expect(await run('yes','100.64.0.1').exited).toBe(0);
    const absent = run('no','100.64.0.1'); expect(await absent.exited).toBe(1);
    expect(await new Response(absent.stderr).text()).toContain('not assigned');
    expect(await run('yes','100.64.0.2').exited).toBe(1);
  } finally { await rm(dir,{recursive:true,force:true}); }
});
