import type { DownloadJob, Engine, MediaCandidate, MediaFormat } from '@/core/types';
import { sanitizeFilename } from '@/core/platform';
import { log } from '@/core/logger';
import { getSettings } from '@/core/settings';
import { resolveCandidate, backend } from '@/resolve';
import { activeJobs, allJobs, getJob, patchJob, putJob, removeJob } from './job-store';
import { cancelMux, closeOffscreen, mux, revoke } from './mux';
import { engine as duckEngine } from '@/engine/client';
import { toRecipe } from '@/engine/recipe';

/**
 * Download orchestration.
 *
 * Two engines, picked per format:
 *   - `direct`  → hand the URL to `chrome.downloads`. The browser owns the
 *     transfer, so it survives the service worker being torn down, costs no
 *     extension memory, and resumes on its own.
 *   - `muxed`  → fetch both tracks and merge them with ffmpeg.wasm in the
 *     offscreen document. Keeps adaptive video (where the high resolutions live)
 *     entirely on the user's machine.
 *   - `backend` → the Duck API downloads and merges server-side, then we pull
 *     the finished file with `chrome.downloads`. The fallback for anything the
 *     first two cannot handle.
 */

const DOWNLOAD_FOLDER = 'Duck Downloader';
const POLL_INTERVAL_MS = 1000;

let pollTimer: ReturnType<typeof setInterval> | null = null;

export async function startDownload(
  candidate: MediaCandidate,
  format: MediaFormat,
): Promise<string> {
  // Duck Engine owns downloads when it is available: it survives the browser
  // closing, resumes across restarts, and verifies what it wrote. The in-browser
  // path below is the fallback for machines without it installed.
  const status = await duckEngine.check();
  if (status.connected) {
    // Resolve first. The engine runs outside the browser and cannot work a URL
    // out from a page — handing it an unresolved format means handing it
    // nothing, which it can only report as a failure it had no way to avoid.
    let target = format;
    let source = candidate;

    if (!target.url || candidate.needsResolve) {
      source = await resolveCandidate(candidate);
      target = pickEquivalent(source, format);
    }

    const tab = await activeTabId();
    return duckEngine.submit(toRecipe(source, target, { tabId: tab }));
  }

  const jobId = crypto.randomUUID();
  const engine = await engineFor(format);

  const job: DownloadJob = {
    id: jobId,
    title: candidate.title,
    filename: buildFilename(candidate.title, format),
    platform: candidate.platform,
    kind: format.kind,
    formatLabel: format.label,
    pageUrl: candidate.pageUrl,
    thumbnail: candidate.thumbnail,
    status: 'queued',
    progress: 0,
    receivedBytes: 0,
    totalBytes: format.filesize ?? 0,
    engine,
    createdAt: Date.now(),
    updatedAt: Date.now(),
  };

  await putJob(job);

  // Deliberately not awaited: the caller is a message handler and the popup
  // should get its job id immediately, not when the transfer finishes.
  void run(job, candidate, format).catch(async (error: unknown) => {
    log.error('download failed', error);
    await patchJob(jobId, {
      status: 'failed',
      error: error instanceof Error ? error.message : String(error),
    });
  });

  return jobId;
}

async function engineFor(format: MediaFormat): Promise<Engine> {
  // HLS and DASH need manifest parsing before anything can be fetched, which
  // the local engine does not do yet.
  if (format.protocol !== 'https') return 'backend';
  if (!format.url) return 'backend';

  if (format.needsMux) {
    if (!format.audioUrl) return 'backend';
    const { localMux } = await getSettings();
    return localMux ? 'muxed' : 'backend';
  }

  return 'direct';
}

async function run(
  job: DownloadJob,
  candidate: MediaCandidate,
  format: MediaFormat,
): Promise<void> {
  let target = format;

  if (!target.url || candidate.needsResolve) {
    await patchJob(job.id, { status: 'resolving' });
    const resolved = await resolveCandidate(candidate);
    target = pickEquivalent(resolved, format);
  }

  const engine = await engineFor(target);
  await patchJob(job.id, { status: 'downloading', engine });

  if (engine === 'direct') await runDirect(job.id, target);
  else if (engine === 'muxed') await runMuxed(job.id, target);
  else await runBackend(job.id, candidate.pageUrl, target);
}

/**
 * Fetches the video and audio tracks and merges them locally.
 *
 * A failure here is not fatal: the backend can do the same job server-side, so
 * anything short of an explicit cancel falls through to it rather than
 * surfacing an error the user cannot act on.
 */
async function runMuxed(jobId: string, format: MediaFormat): Promise<void> {
  const job = await getJob(jobId);
  if (!job) return;

  const container = format.ext === 'webm' ? 'webm' : 'mp4';

  try {
    const result = await mux(
      jobId,
      { videoUrl: format.url!, audioUrl: format.audioUrl!, container },
      (progress) => {
        void patchJob(jobId, {
          status: progress.phase === 'merging' ? 'muxing' : 'downloading',
          progress: progress.progress,
          receivedBytes: progress.receivedBytes ?? job.receivedBytes,
          totalBytes: progress.totalBytes ?? job.totalBytes,
        });
      },
    );

    const browserDownloadId = await chrome.downloads.download({
      url: result.objectUrl,
      filename: `${DOWNLOAD_FOLDER}/${job.filename}`,
      saveAs: false,
      conflictAction: 'uniquify',
    });

    await patchJob(jobId, {
      browserDownloadId,
      totalBytes: result.bytes,
      progress: 100,
    });

    // The blob stays alive in the offscreen document until the browser has
    // finished writing it to disk; revoking earlier truncates the file.
    void waitForSave(browserDownloadId).then(() => revoke(result.objectUrl));
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (message === 'Canceled') throw error;

    log.warn('local merge failed, falling back to the server', message);
    const current = await getJob(jobId);
    if (!current) return;

    await patchJob(jobId, { engine: 'backend', progress: 0, receivedBytes: 0 });
    await runBackend(jobId, current.pageUrl, format);
  } finally {
    await closeIfIdle();
  }
}

/** Resolves once chrome.downloads reports the item is no longer in progress. */
function waitForSave(browserDownloadId: number): Promise<void> {
  return new Promise((resolve) => {
    const listener = (delta: chrome.downloads.DownloadDelta) => {
      if (delta.id !== browserDownloadId) return;
      if (delta.state?.current === 'in_progress') return;
      chrome.downloads.onChanged.removeListener(listener);
      resolve();
    };
    chrome.downloads.onChanged.addListener(listener);
  });
}

/** Frees the ffmpeg core once no job still needs it. */
async function closeIfIdle(): Promise<void> {
  const remaining = await activeJobs();
  if (remaining.some((job) => job.engine === 'muxed')) return;
  await closeOffscreen();
}

/**
 * Re-selects the user's chosen format on a freshly resolved candidate. Format
 * ids are not stable across resolvers (the sniffer's id is not InnerTube's), so
 * matching falls back to the closest height, then to the best of the same kind.
 */
function pickEquivalent(resolved: MediaCandidate, wanted: MediaFormat): MediaFormat {
  const sameKind = resolved.formats.filter((format) => format.kind === wanted.kind);
  const pool = sameKind.length > 0 ? sameKind : resolved.formats;
  if (pool.length === 0) throw new Error('Resolver returned no formats.');

  const byId = pool.find((format) => format.id === wanted.id);
  if (byId) return byId;

  if (wanted.height) {
    return [...pool].sort(
      (a, b) =>
        Math.abs((a.height ?? 0) - wanted.height!) - Math.abs((b.height ?? 0) - wanted.height!),
    )[0]!;
  }

  return [...pool].sort((a, b) => (b.height ?? 0) - (a.height ?? 0))[0]!;
}

async function runDirect(jobId: string, format: MediaFormat): Promise<void> {
  const job = await getJob(jobId);
  if (!job) return;

  const browserDownloadId = await chrome.downloads.download({
    url: format.url!,
    filename: `${DOWNLOAD_FOLDER}/${job.filename}`,
    saveAs: false,
    conflictAction: 'uniquify',
  });

  await patchJob(jobId, { browserDownloadId, status: 'downloading' });
  ensurePolling();
}

async function runBackend(
  jobId: string,
  pageUrl: string,
  format: MediaFormat,
): Promise<void> {
  const backendDownloadId = await backend.startDownload({
    url: pageUrl,
    type: format.kind,
    quality: format.label,
  });

  await patchJob(jobId, { backendDownloadId, status: 'downloading' });
  ensurePolling();
}

/**
 * One timer reconciles every in-flight job.
 *
 * `chrome.downloads.onChanged` does not reliably report byte progress, and the
 * backend socket dies with the service worker, so polling is the source of
 * truth. It only runs while something is actually in flight.
 */
function ensurePolling(): void {
  if (pollTimer) return;
  pollTimer = setInterval(() => {
    void tick();
  }, POLL_INTERVAL_MS);
}

function stopPolling(): void {
  if (!pollTimer) return;
  clearInterval(pollTimer);
  pollTimer = null;
}

async function tick(): Promise<void> {
  const jobs = await activeJobs();
  if (jobs.length === 0) {
    stopPolling();
    return;
  }

  await Promise.all(
    jobs.map(async (job) => {
      try {
        if (job.browserDownloadId !== undefined) await syncBrowserJob(job);
        else if (job.backendDownloadId) await syncBackendJob(job);
      } catch (error) {
        log.warn('sync failed for job', job.id, error);
      }
    }),
  );
}

async function syncBrowserJob(job: DownloadJob): Promise<void> {
  const [item] = await chrome.downloads.search({ id: job.browserDownloadId });
  if (!item) return;

  const total = item.totalBytes > 0 ? item.totalBytes : job.totalBytes;
  const received = item.bytesReceived;
  const elapsedSec = Math.max(1, (Date.now() - job.createdAt) / 1000);
  const speedBps = received / elapsedSec;

  const patch: Partial<DownloadJob> = {
    receivedBytes: received,
    totalBytes: total,
    progress: total > 0 ? Math.min(100, Math.round((received / total) * 100)) : -1,
    speedBps,
    etaSec: total > received && speedBps > 0 ? Math.round((total - received) / speedBps) : undefined,
  };

  if (item.state === 'complete') {
    Object.assign(patch, { status: 'completed', progress: 100, filename: baseName(item.filename) });
  } else if (item.state === 'interrupted') {
    Object.assign(patch, {
      status: item.error === 'USER_CANCELED' ? 'canceled' : 'failed',
      error: item.error ?? 'Download interrupted',
    });
  } else if (item.paused) {
    patch.status = 'paused';
  } else {
    patch.status = 'downloading';
  }

  await patchJob(job.id, patch);
}

async function syncBackendJob(job: DownloadJob): Promise<void> {
  const status = await backend.getStatus(job.backendDownloadId!);

  if (status.status === 'error' || status.error) {
    await patchJob(job.id, { status: 'failed', error: status.error ?? 'Backend error' });
    return;
  }

  if (status.fileUrl && (status.status === 'completed' || status.progress >= 100)) {
    // Server-side work is done; hand the finished file to the browser so the
    // transfer to disk gets the same treatment as a direct download.
    const url = await backend.fileUrl(status.fileUrl);
    const browserDownloadId = await chrome.downloads.download({
      url,
      filename: `${DOWNLOAD_FOLDER}/${status.filename ?? job.filename}`,
      saveAs: false,
      conflictAction: 'uniquify',
    });
    await patchJob(job.id, { browserDownloadId, backendDownloadId: undefined, progress: 99 });
    return;
  }

  await patchJob(job.id, {
    status: status.status === 'paused' ? 'paused' : 'downloading',
    // Server progress covers fetch + mux; cap it so it cannot read 100% while
    // the file still has to come down to the browser.
    progress: Math.min(98, status.progress),
    speedBps: parseSpeed(status.speed),
    etaSec: parseEta(status.eta),
  });
}

export async function cancelJob(jobId: string): Promise<void> {
  const job = await getJob(jobId);
  if (!job) return;

  if (job.browserDownloadId !== undefined) {
    await chrome.downloads.cancel(job.browserDownloadId).catch(() => {});
  }
  if (job.backendDownloadId) {
    await backend.cancelDownload(job.backendDownloadId).catch(() => {});
  }
  if (job.engine === 'muxed') {
    await cancelMux(jobId);
    await closeIfIdle();
  }
  await patchJob(jobId, { status: 'canceled' });
}

export async function pauseJob(jobId: string): Promise<void> {
  const job = await getJob(jobId);
  if (!job) return;

  if (job.browserDownloadId !== undefined) {
    await chrome.downloads.pause(job.browserDownloadId).catch(() => {});
  }
  if (job.backendDownloadId) {
    await backend.pauseDownload(job.backendDownloadId).catch(() => {});
  }
  await patchJob(jobId, { status: 'paused' });
}

export async function resumeJob(jobId: string): Promise<void> {
  const job = await getJob(jobId);
  if (!job) return;

  if (job.browserDownloadId !== undefined) {
    await chrome.downloads.resume(job.browserDownloadId).catch(() => {});
  }
  if (job.backendDownloadId) {
    await backend.resumeDownload(job.backendDownloadId).catch(() => {});
  }
  await patchJob(jobId, { status: 'downloading' });
  ensurePolling();
}

export async function deleteJob(jobId: string): Promise<void> {
  await cancelJob(jobId).catch(() => {});
  await removeJob(jobId);
}

export function listJobs(): Promise<DownloadJob[]> {
  return allJobs();
}

/**
 * Called on every service worker startup. Downloads keep running while the
 * worker is dead, so without this a job would be stuck showing 40% forever.
 */
export async function reconcile(): Promise<void> {
  const jobs = await activeJobs();
  if (jobs.length === 0) return;
  log.debug(`reconciling ${jobs.length} active job(s) after worker restart`);
  await tick();
  ensurePolling();
}

function buildFilename(title: string, format: MediaFormat): string {
  const base = sanitizeFilename(title).slice(0, 100);
  // Only video gets a quality suffix. "[Original]" on a JPEG is noise, and an
  // audio file's quality is already implied by its extension.
  const suffix = format.kind === 'video' ? ` [${format.label}]` : '';
  return `${base}${suffix}.${format.ext}`;
}

function baseName(path: string): string {
  return path.split(/[\\/]/).pop() ?? path;
}

async function activeTabId(): Promise<number | undefined> {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  return tab?.id;
}

/** Backend reports human strings like "1.2MiB/s"; the UI wants bytes/second. */
function parseSpeed(value?: string | null): number | undefined {
  if (!value) return undefined;
  const match = value.match(/([\d.]+)\s*([KMG])?i?B\/s/i);
  if (!match?.[1]) return undefined;
  const scale = { K: 1024, M: 1024 ** 2, G: 1024 ** 3 }[match[2]?.toUpperCase() ?? ''] ?? 1;
  return Number(match[1]) * scale;
}

/** Backend reports "MM:SS" or "H:MM:SS". */
function parseEta(value?: string | null): number | undefined {
  if (!value || value === 'Unknown') return undefined;
  const parts = value.split(':').map(Number);
  if (parts.some(Number.isNaN)) return undefined;
  return parts.reduce((total, part) => total * 60 + part, 0);
}
