import { copyFile, mkdir, rm } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

/**
 * Copies ffmpeg.wasm out of node_modules and into the bundle's public folder.
 *
 * MV3 forbids remote code, so the core cannot be pulled from a CDN at runtime —
 * it has to ship inside the extension. Doing that here, from the installed
 * package, rather than committing vendored binaries keeps the copies in step
 * with package.json on every install.
 *
 * The ESM core is used rather than the UMD one, and the single-threaded core
 * rather than `core-mt`: the multi-threaded build needs SharedArrayBuffer, which
 * needs COEP `require-corp` on every extension page, which blocks the popup's
 * cross-origin thumbnails.
 */

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..');
const target = join(root, 'src/public/ffmpeg');

const FILES = [
  // The worker plus the two modules it imports relatively.
  ['@ffmpeg/ffmpeg/dist/esm/worker.js', 'worker.js'],
  ['@ffmpeg/ffmpeg/dist/esm/const.js', 'const.js'],
  ['@ffmpeg/ffmpeg/dist/esm/errors.js', 'errors.js'],
  ['@ffmpeg/core/dist/esm/ffmpeg-core.js', 'ffmpeg-core.js'],
  ['@ffmpeg/core/dist/esm/ffmpeg-core.wasm', 'ffmpeg-core.wasm'],
];

await rm(target, { recursive: true, force: true });
await mkdir(target, { recursive: true });

for (const [from, to] of FILES) {
  await copyFile(join(root, 'node_modules', from), join(target, to));
}

console.log(`synced ${FILES.length} ffmpeg files -> src/public/ffmpeg`);
