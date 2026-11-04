// Bundles the Worker into one ES module that Sites can serve, and copies the
// static UI next to it. Run with: npm run build
import { cp, mkdir, rm } from 'node:fs/promises';

import { build } from 'esbuild';

const out = 'dist';

await rm(out, { recursive: true, force: true });
await mkdir(`${out}/public`, { recursive: true });

await build({
  entryPoints: ['src/worker.js'],
  outfile: `${out}/worker.js`,
  bundle: true,
  format: 'esm',
  platform: 'neutral',
  target: 'es2022',
  minify: true,
  // Provided by the Workers runtime, never bundled.
  external: ['cloudflare:*', 'node:*'],
  logLevel: 'info',
});

await cp('public', `${out}/public`, { recursive: true });
console.log('built dist/worker.js and dist/public');
