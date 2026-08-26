import { FFmpeg } from '@ffmpeg/ffmpeg';
import { emit, onMessage } from '@/core/messaging';
import { log } from '@/core/logger';

/**
 * Offscreen document: the only place in an MV3 extension that can run a long
 * ffmpeg.wasm job.
 *
 * The service worker cannot host this — it is torn down after ~30s idle and has
 * no DOM for the worker ffmpeg.wasm spawns. A content script could not either:
 * the page's CSP would block the wasm, and the tab can navigate away mid-merge.
 *
 * Everything ffmpeg needs is loaded from `chrome-extension://` URLs shipped in
 * the bundle. MV3 forbids remote code, so a CDN core is not an option.
 */

const CORE_BASE = 'ffmpeg/';

/**
 * ffmpeg.wasm holds both inputs *and* the output in its virtual filesystem, so
 * peak memory is roughly twice the total input. The wasm build is 32-bit and
 * caps out around 2GB, well before that the tab starts thrashing — so anything
 * larger goes to the server instead of being attempted and failing slowly.
 */
const MAX_INPUT_BYTES = 400 * 1024 * 1024;

let ffmpeg: FFmpeg | null = null;
let loading: Promise<FFmpeg> | null = null;
const canceled = new Set<string>();

async function getFFmpeg(): Promise<FFmpeg> {
  if (ffmpeg) return ffmpeg;
  if (loading) return loading;

  loading = (async () => {
    const instance = new FFmpeg();
    instance.on('log', ({ message }) => log.debug('[ffmpeg]', message));

    await instance.load({
      // `classWorkerURL` is what keeps this MV3-legal: without it the library
      // spawns its worker from a blob: URL, which the extension CSP rejects.
      classWorkerURL: chrome.runtime.getURL(`${CORE_BASE}worker.js`),
      coreURL: chrome.runtime.getURL(`${CORE_BASE}ffmpeg-core.js`),
      wasmURL: chrome.runtime.getURL(`${CORE_BASE}ffmpeg-core.wasm`),
    });

    ffmpeg = instance;
    log.info('ffmpeg loaded');
    return instance;
  })();

  return loading;
}

onMessage('mux:cancel', ({ jobId }) => {
  canceled.add(jobId);
});

onMessage('mux:revoke', ({ objectUrl }) => {
  URL.revokeObjectURL(objectUrl);
});

onMessage('mux:run', ({ jobId, videoUrl, audioUrl, container }) => {
  // Acknowledge immediately and report the outcome as an event: a merge can run
  // for minutes, far longer than a message port stays open.
  void run(jobId, videoUrl, audioUrl, container).catch((error: unknown) => {
    emit('mux:failed', {
      jobId,
      error: error instanceof Error ? error.message : String(error),
    });
  });
});

async function run(
  jobId: string,
  videoUrl: string,
  audioUrl: string,
  container: string,
): Promise<void> {
  canceled.delete(jobId);

  const videoName = `${jobId}-v.bin`;
  const audioName = `${jobId}-a.bin`;
  const outputName = `${jobId}-out.${container}`;

  const instance = await getFFmpeg();

  // Fetch both tracks, reporting one combined progress figure.
  const sizes = await Promise.all([contentLength(videoUrl), contentLength(audioUrl)]);
  const expected = sizes.reduce((total, size) => total + size, 0);

  if (expected > MAX_INPUT_BYTES) {
    throw new Error(
      `Too large to merge in the browser (${Math.round(expected / 1024 / 1024)}MB).`,
    );
  }

  let fetched = 0;
  const onChunk = (bytes: number) => {
    fetched += bytes;
    emit('mux:progress', {
      jobId,
      phase: 'fetching',
      // Fetching is the bulk of the wall time, so it owns most of the bar.
      progress: expected > 0 ? Math.min(90, Math.round((fetched / expected) * 90)) : -1,
      receivedBytes: fetched,
      totalBytes: expected,
    });
  };

  const [video, audio] = await Promise.all([
    download(videoUrl, jobId, onChunk),
    download(audioUrl, jobId, onChunk),
  ]);

  assertLive(jobId);

  await instance.writeFile(videoName, video);
  await instance.writeFile(audioName, audio);

  emit('mux:progress', { jobId, phase: 'merging', progress: 92 });

  // `-c copy` remuxes without re-encoding: no quality loss, and it finishes in
  // seconds rather than the minutes a transcode would take.
  const code = await instance.exec([
    '-i', videoName,
    '-i', audioName,
    '-c', 'copy',
    '-map', '0:v:0',
    '-map', '1:a:0',
    // Moves the index to the front so the file plays before it is fully
    // downloaded. MP4-only — the WebM muxer rejects the flag outright.
    ...(container === 'mp4' ? ['-movflags', '+faststart'] : []),
    outputName,
  ]);

  if (code !== 0) throw new Error(`ffmpeg exited with code ${code}`);
  assertLive(jobId);

  const output = await instance.readFile(outputName);
  const bytes = output instanceof Uint8Array ? output : new TextEncoder().encode(output);

  // The wasm filesystem is not garbage collected; leaving these behind would
  // keep hundreds of megabytes resident for the life of the document.
  await Promise.all(
    [videoName, audioName, outputName].map((name) =>
      instance.deleteFile(name).catch(() => undefined),
    ),
  );

  const blob = new Blob([bytes as BlobPart], { type: mimeFor(container) });
  const objectUrl = URL.createObjectURL(blob);

  emit('mux:progress', { jobId, phase: 'merging', progress: 100 });
  emit('mux:done', { jobId, objectUrl, bytes: blob.size });
}

/** Streams a URL into memory, reporting each chunk so the UI can move. */
async function download(
  url: string,
  jobId: string,
  onChunk: (bytes: number) => void,
): Promise<Uint8Array> {
  const response = await fetch(url);
  if (!response.ok || !response.body) {
    throw new Error(`Could not fetch media (HTTP ${response.status}).`);
  }

  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;

  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    assertLive(jobId, () => void reader.cancel());
    chunks.push(value);
    total += value.length;
    onChunk(value.length);
  }

  const merged = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    merged.set(chunk, offset);
    offset += chunk.length;
  }
  return merged;
}

async function contentLength(url: string): Promise<number> {
  try {
    // A ranged GET rather than HEAD: some CDNs reject HEAD on signed media URLs.
    const response = await fetch(url, { headers: { range: 'bytes=0-0' } });
    const range = response.headers.get('content-range');
    const size = range?.match(/\/(\d+)$/)?.[1];
    return size ? Number(size) : Number(response.headers.get('content-length')) || 0;
  } catch {
    return 0;
  }
}

function assertLive(jobId: string, cleanup?: () => void): void {
  if (!canceled.has(jobId)) return;
  cleanup?.();
  throw new Error('Canceled');
}

function mimeFor(container: string): string {
  return container === 'webm' ? 'video/webm' : 'video/mp4';
}
