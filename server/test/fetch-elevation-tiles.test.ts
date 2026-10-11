import { expect, test } from 'bun:test';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { gzipSync } from 'node:zlib';

function fixture(run: (dir: string, fetch: (...args: string[]) => ReturnType<typeof Bun.spawnSync>) => void) {
  const dir=mkdtempSync(join(tmpdir(),'volta-tile-fetch-')),bin=join(dir,'bin'),calls=join(dir,'calls');
  mkdirSync(bin);
  const curl=join(bin,'curl');
  writeFileSync(curl,`#!/usr/bin/env bash\nset -eu\nprintf '%s\\n' "\${@: -1}" >> "$TILE_TEST_CALLS"\nwhile [[ $# -gt 0 ]]; do if [[ $1 == -o ]]; then cp "$TILE_TEST_RESPONSE" "$2"; shift; fi; shift; done\nprintf '%s' "$TILE_TEST_CODE"\n`);
  chmodSync(curl,0o755);
  const response=join(dir,'response');writeFileSync(response,gzipSync(Buffer.alloc(1201*1201*2)));
  const fetch=(...args:string[])=>Bun.spawnSync(['bash','-c','umask 077; exec bash "$@"','tile-fetch',new URL('../scripts/fetch-elevation-tiles.sh',import.meta.url).pathname,join(dir,'tiles'),...args],{
    env:{...process.env,PATH:`${bin}:${process.env.PATH}`,TILE_TEST_CALLS:calls,TILE_TEST_RESPONSE:response,TILE_TEST_CODE:existsSync(join(dir,'code')) ? readFileSync(join(dir,'code'),'utf8') : '200'},
  });
  try { run(dir,fetch); } finally { rmSync(dir,{recursive:true,force:true}); }
}

test('named tile manifests deduplicate, fetch only public tile objects, and preserve valid tiles',()=>fixture((dir,fetch)=>{
  const manifest=join(dir,'region.tiles');writeFileSync(manifest,'N37W123\nN37W123\n\n');
  let r=fetch('--tiles-file',manifest);expect(r.exitCode).toBe(0);expect(r.stdout!.toString()).toContain('1 fetched');
  expect(readFileSync(join(dir,'calls'),'utf8')).toBe('https://s3.amazonaws.com/elevation-tiles-prod/skadi/N37/N37W123.hgt.gz\n');
  expect(readFileSync(join(dir,'tiles/N37/N37W123.hgt')).length).toBe(2884802);
  expect(statSync(join(dir,'tiles')).mode & 0o777).toBe(0o755);
  expect(statSync(join(dir,'tiles/N37')).mode & 0o777).toBe(0o755);
  r=fetch('--tiles-file',manifest);expect(r.exitCode).toBe(0);expect(r.stdout!.toString()).toContain('1 already present');
  expect(readFileSync(join(dir,'calls'),'utf8').trim().split('\n')).toHaveLength(1);
  writeFileSync(join(dir,'tiles/N37/N37W123.hgt'),'corrupt');
  expect(fetch('--tiles-file',manifest).exitCode).toBe(0);expect(readFileSync(join(dir,'tiles/N37/N37W123.hgt')).length).toBe(2884802);
}));

test('invalid, empty, oversized and traversal manifests fail before making network requests',()=>fixture((dir,fetch)=>{
  const manifest=join(dir,'region.tiles');
  for (const content of ['', '../N37W123','N90W123','N37W181','S00E000','N37E180','https://example.com/secret',
    Array.from({length:401},(_,i)=>`N${String(Math.floor(i/180)).padStart(2,'0')}E${String(i%180).padStart(3,'0')}`).join('\n')]) {
    writeFileSync(manifest,content);expect(fetch('--tiles-file',manifest).exitCode).not.toBe(0);
    expect(existsSync(join(dir,'calls'))).toBe(false);expect(existsSync(join(dir,'tiles'))).toBe(false);
  }
}));

test('missing public tiles are counted; malformed downloads never become terrain files or log names',()=>fixture((dir,fetch)=>{
  const manifest=join(dir,'region.tiles');writeFileSync(manifest,'N37W123');writeFileSync(join(dir,'code'),'404');
  let r=fetch('--tiles-file',manifest);expect(r.exitCode).toBe(0);expect(r.stdout!.toString()).toContain('1 not available');
  expect(existsSync(join(dir,'tiles/N37/N37W123.hgt'))).toBe(false);
  writeFileSync(join(dir,'code'),'200');writeFileSync(join(dir,'response'),gzipSync(Buffer.alloc(3)));
  r=fetch('--tiles-file',manifest);expect(r.exitCode).not.toBe(0);expect(r.stderr!.toString()).toContain('tile download failed');
  expect(r.stderr!.toString()).not.toContain('N37W123');expect(existsSync(join(dir,'tiles/N37/N37W123.hgt'))).toBe(false);
}));

test('legacy bounds convert locally to public names and reject invalid bounds before network use',()=>fixture((dir,fetch)=>{
  expect(fetch('bad','-122.4','37.7','-122.4').exitCode).not.toBe(0);
  expect(fetch('-90','-180','90','180').exitCode).not.toBe(0);expect(existsSync(join(dir,'calls'))).toBe(false);
  expect(fetch('37.7','-122.4','37.7','-122.4').exitCode).toBe(0);
  expect(readFileSync(join(dir,'calls'),'utf8')).toBe('https://s3.amazonaws.com/elevation-tiles-prod/skadi/N37/N37W123.hgt.gz\n');
}));
