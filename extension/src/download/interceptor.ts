import { PROTOCOL_VERSION, type JobRecipe } from '../../../contracts/duck-protocol';
import { engine } from '@/engine/client';
import { isBlockedUrl } from '@/core/nsfw';
import { getSettings } from '@/core/settings';
import { log } from '@/core/logger';

/**
 * Takes ordinary browser downloads over, the way IDM does.
 *
 * This is the difference between a video grabber and a download manager. Any
 * click that would have produced a browser download — an installer, an archive,
 * a PDF, a direct media file — is cancelled and handed to the engine instead,
 * which gives it segmented transfer, pause and resume, retries, and
 * verification.
 *
 * Three things are deliberately left to the browser:
 *   - `blob:` and `data:` URLs, which exist only inside the page and cannot be
 *     re-fetched by anything outside it.
 *   - Downloads the engine itself started, or the loop would be infinite.
 *   - Anything the engine cannot reach, because a download taken and then
 *     dropped is worse than one never taken.
 */

/** Extensions worth taking. Mirrors the categories IDM ships with. */
const TAKEOVER_EXTENSIONS = new Set([
  // archives
  'zip', 'rar', '7z', 'tar', 'gz', 'tgz', 'bz2', 'xz',
  // installers and images
  'exe', 'msi', 'dmg', 'pkg', 'deb', 'rpm', 'apk', 'iso', 'img',
  // video
  'mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm', 'm4v', 'mpg', 'mpeg', '3gp',
  // audio
  'mp3', 'm4a', 'wav', 'flac', 'aac', 'ogg', 'opus', 'wma',
  // documents
  'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'epub', 'mobi',
]);

/** Below this, the browser is simply faster than a handoff. */
const MIN_TAKEOVER_BYTES = 1024 * 1024;

export function startDownloadInterceptor(): void {
  chrome.downloads.onCreated.addListener((item) => {
    void consider(item);
  });

  log.debug('download interceptor armed');
}

async function consider(item: chrome.downloads.DownloadItem): Promise<void> {
  const settings = await getSettings();
  if (!settings.interceptDownloads) return;

  const url = item.finalUrl || item.url;
  if (!/^https?:/i.test(url)) return;
  if (isBlockedUrl(url)) return;

  // Anything the engine itself is saving arrives here too.
  if (item.byExtensionId === chrome.runtime.id) return;

  const filename = baseName(item.filename) || filenameFromUrl(url);
  const extension = extensionOf(filename);

  const wanted =
    TAKEOVER_EXTENSIONS.has(extension) ||
    // A size the browser already knows is large enough to be worth managing.
    (item.fileSize > MIN_TAKEOVER_BYTES && extension !== '');

  if (!wanted) return;

  // Confirm the engine is there *before* cancelling. Taking a download away and
  // then failing to start it would lose the user their file.
  const status = await engine.check();
  if (!status.connected) return;

  try {
    await chrome.downloads.cancel(item.id);
    await chrome.downloads.erase({ id: item.id });
  } catch {
    // Already finished or already cancelled — leave it alone.
    return;
  }

  const recipe: JobRecipe = {
    protocolVersion: PROTOCOL_VERSION,
    resourceId: `browser:${url}`,
    resourceClass: 'direct',
    pageUrl: item.referrer || url,
    title: filename,
    suggestedFilename: filename,
    kind: kindFor(extension),
    variant: {
      id: 'browser',
      label: 'Original',
      kind: kindFor(extension),
      container: extension || 'bin',
      url,
      size: item.fileSize > 0 ? item.fileSize : undefined,
    },
    // The browser was about to send these, so the server expects them.
    requestContext: item.referrer ? { referer: item.referrer } : undefined,
    capturedAt: Date.now(),
  };

  try {
    await engine.submit(recipe);
    log.info('took over a browser download:', filename);
  } catch (error) {
    log.error('could not hand the download to the engine', error);
    // Give it back rather than leaving the user with nothing.
    await chrome.downloads.download({ url, filename }).catch(() => undefined);
  }
}

function baseName(path: string): string {
  return path.split(/[\\/]/).pop() ?? '';
}

function filenameFromUrl(url: string): string {
  try {
    return decodeURIComponent(new URL(url).pathname.split('/').filter(Boolean).pop() ?? '') || 'download';
  } catch {
    return 'download';
  }
}

function extensionOf(filename: string): string {
  const dot = filename.lastIndexOf('.');
  return dot > 0 ? filename.slice(dot + 1).toLowerCase() : '';
}

function kindFor(extension: string): JobRecipe['kind'] {
  if (['mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm', 'm4v', 'mpg', 'mpeg', '3gp'].includes(extension)) {
    return 'video';
  }
  if (['mp3', 'm4a', 'wav', 'flac', 'aac', 'ogg', 'opus', 'wma'].includes(extension)) {
    return 'audio';
  }
  if (['jpg', 'jpeg', 'png', 'gif', 'webp'].includes(extension)) return 'image';
  if (['pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'epub', 'mobi'].includes(extension)) {
    return 'document';
  }
  if (['zip', 'rar', '7z', 'tar', 'gz', 'tgz', 'bz2', 'xz'].includes(extension)) return 'archive';
  return 'file';
}
