import { onEvent, sendMessage } from '@/core/messaging';
import { log } from '@/core/logger';

/**
 * Background-side control of the offscreen muxing document.
 *
 * Chrome allows exactly one offscreen document per extension, so creation is
 * funnelled through a single promise — two downloads starting at once must not
 * race into a "document already exists" error.
 */

const OFFSCREEN_PATH = 'offscreen.html';

let creating: Promise<void> | null = null;

async function hasDocument(): Promise<boolean> {
  const contexts = await chrome.runtime.getContexts({
    contextTypes: [chrome.runtime.ContextType.OFFSCREEN_DOCUMENT],
  });
  return (contexts ?? []).length > 0;
}

export async function ensureOffscreen(): Promise<void> {
  if (await hasDocument()) return;
  if (creating) return creating;

  creating = chrome.offscreen
    .createDocument({
      url: OFFSCREEN_PATH,
      reasons: [chrome.offscreen.Reason.WORKERS],
      justification:
        'Runs ffmpeg.wasm to merge separate video and audio tracks into one file.',
    })
    .catch((error: unknown) => {
      // A parallel call can win the race between our check and this create.
      if (String(error).includes('Only a single offscreen')) return;
      throw error;
    })
    .finally(() => {
      creating = null;
    });

  return creating;
}

/**
 * Closed once nothing is in flight. The document holds the ffmpeg core and any
 * output blobs in memory, so leaving it open costs the user real RAM.
 */
export async function closeOffscreen(): Promise<void> {
  if (!(await hasDocument())) return;
  await chrome.offscreen.closeDocument().catch(() => undefined);
  log.debug('offscreen document closed');
}

export interface MuxResult {
  objectUrl: string;
  bytes: number;
}

export interface MuxProgress {
  phase: 'fetching' | 'merging';
  progress: number;
  receivedBytes?: number;
  totalBytes?: number;
}

/**
 * Runs one merge. Resolves with an object URL owned by the offscreen document —
 * the caller must hand it to `chrome.downloads` and then call `revoke`.
 */
export async function mux(
  jobId: string,
  options: { videoUrl: string; audioUrl: string; container: string },
  onProgress: (progress: MuxProgress) => void,
): Promise<MuxResult> {
  await ensureOffscreen();

  return new Promise<MuxResult>((resolve, reject) => {
    const disposers = [
      onEvent('mux:progress', (payload) => {
        if (payload.jobId !== jobId) return;
        onProgress(payload);
      }),
      onEvent('mux:done', (payload) => {
        if (payload.jobId !== jobId) return;
        cleanup();
        resolve({ objectUrl: payload.objectUrl, bytes: payload.bytes });
      }),
      onEvent('mux:failed', (payload) => {
        if (payload.jobId !== jobId) return;
        cleanup();
        reject(new Error(payload.error));
      }),
    ];

    const cleanup = () => disposers.forEach((dispose) => dispose());

    void sendMessage('mux:run', { jobId, ...options }).catch((error: unknown) => {
      cleanup();
      reject(error instanceof Error ? error : new Error(String(error)));
    });
  });
}

export async function cancelMux(jobId: string): Promise<void> {
  if (!(await hasDocument())) return;
  await sendMessage('mux:cancel', { jobId }).catch(() => undefined);
}

export async function revoke(objectUrl: string): Promise<void> {
  if (!(await hasDocument())) return;
  await sendMessage('mux:revoke', { objectUrl }).catch(() => undefined);
}
