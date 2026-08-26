import type { MediaCandidate, MediaFormat } from '@/core/types';
import { addCandidates } from '@/core/candidate-store';
import { platformOf } from '@/core/platform';
import { isBlockedUrl } from '@/core/nsfw';
import { log } from '@/core/logger';
import { itagInfo } from './itags';

/**
 * Stream capture: take the URLs the player itself is using.
 *
 * Every other approach tries to *derive* a playable URL — solve YouTube's
 * signature cipher, impersonate a mobile client, or hand the link to a server
 * running yt-dlp. All three are guesses at what the site will accept, and all
 * three break whenever the site decides they should.
 *
 * This does the opposite. When a video plays, the browser fetches its bytes from
 * URLs the site itself minted, already signed and already valid. `webRequest`
 * sees them. The rule that falls out is a good one:
 *
 *     if the user can watch it, we can download it.
 *
 * No cipher, no client impersonation, no cookies, no server. The page did the
 * work before we arrived.
 *
 * The cost is that playback has to have started — a second is enough — and that
 * only the qualities actually fetched can be captured. DRM is out entirely: for
 * Widevine content the bytes on the wire are encrypted.
 */

/** YouTube's media endpoint. The query string carries everything we need. */
const VIDEOPLAYBACK = /googlevideo\.com\/videoplayback/i;

/** Generic media, for every other site. */
const MEDIA_FILE = /\.(mp4|webm|m4a|mp3|mov|m4v)(\?|$)/i;

export function startStreamCapture(): void {
  chrome.webRequest.onBeforeRequest.addListener(
    (details) => {
      if (details.tabId < 0) return;
      if (isBlockedUrl(details.initiator ?? details.url)) return;

      if (VIDEOPLAYBACK.test(details.url)) {
        void captureYouTube(details.tabId, details.url);
      } else if (details.type === 'media' && MEDIA_FILE.test(details.url)) {
        void captureGeneric(details.tabId, details.url);
      }
    },
    { urls: ['<all_urls>'], types: ['xmlhttprequest', 'media', 'other'] },
  );

  log.debug('stream capture armed');
}

/**
 * A `videoplayback` URL describes itself completely:
 *   itag  — which format this is
 *   mime  — video/mp4, audio/webm, …
 *   clen  — the full content length, regardless of the range being fetched
 *   dur   — duration in seconds
 *
 * So one intercepted request yields a fully described, immediately downloadable
 * format. No extraction step at all.
 */
async function captureYouTube(tabId: number, url: string): Promise<void> {
  let params: URLSearchParams;
  try {
    params = new URL(url).searchParams;
  } catch {
    return;
  }

  const itag = params.get('itag');
  const mime = params.get('mime');
  if (!itag || !mime) return;

  const info = itagInfo(itag);
  const format: MediaFormat = {
    id: `capture:${itag}`,
    label: info?.label ?? (mime.startsWith('audio/') ? 'Audio' : 'Captured'),
    ext: info?.container ?? (mime.includes('webm') ? 'webm' : 'mp4'),
    kind: info?.audioOnly || mime.startsWith('audio/') ? 'audio' : 'video',
    protocol: 'https',
    url: fullFileUrl(url),
    height: info?.height,
    filesize: Number(params.get('clen')) || undefined,
    // Paired with a captured audio track by pairCapturedFormats.
    needsMux: info?.videoOnly,
    origin: 'stream-capture',
  };

  // Audio tracks are stored as m4a rather than mp4 so the pairing step can match
  // containers without re-deriving the codec.
  if (format.kind === 'audio' && format.ext === 'mp4') format.ext = 'm4a';

  const tab = await chrome.tabs.get(tabId).catch(() => undefined);
  const pageUrl = tab?.url ?? '';
  const videoId = youtubeIdOf(pageUrl);
  if (!videoId) return;

  await addCandidates(tabId, [
    {
      // Same id the YouTube adapter uses, so captured formats land on the
      // candidate the user is already looking at instead of beside it.
      id: `youtube:${videoId}`,
      platform: 'youtube',
      pageUrl: `https://www.youtube.com/watch?v=${videoId}`,
      title: (tab?.title ?? '').replace(/\s*-\s*YouTube\s*$/, '').trim() || 'YouTube video',
      thumbnail: `https://i.ytimg.com/vi/${videoId}/maxresdefault.jpg`,
      durationSec: Number(params.get('dur')) || undefined,
      formats: [format],
      source: 'network',
      detectedAt: Date.now(),
      // Captured formats are already playable URLs; nothing left to resolve.
      needsResolve: false,
    },
  ]);
}

async function captureGeneric(tabId: number, url: string): Promise<void> {
  const tab = await chrome.tabs.get(tabId).catch(() => undefined);
  const pageUrl = tab?.url ?? url;

  await addCandidates(tabId, [
    {
      id: `capture:${await hash(stripQuery(url))}`,
      platform: platformOf(pageUrl),
      pageUrl,
      title: (tab?.title ?? 'Media').trim(),
      formats: [
        buildFormat({
          id: 'capture:file',
          url: fullFileUrl(url),
          mime: guessMime(url),
        }),
      ],
      source: 'network',
      detectedAt: Date.now(),
      needsResolve: false,
    },
  ]);
}

function buildFormat(input: {
  id: string;
  url: string;
  mime: string;
  bytes?: number;
}): MediaFormat {
  const isAudio = input.mime.startsWith('audio/');
  const container = input.mime.includes('webm') ? 'webm' : 'mp4';

  return {
    id: input.id,
    label: isAudio ? 'Audio' : 'Captured',
    ext: isAudio ? (container === 'webm' ? 'webm' : 'm4a') : container,
    kind: isAudio ? 'audio' : 'video',
    protocol: 'https',
    url: input.url,
    filesize: input.bytes,
    origin: 'stream-capture',
  };
}

/**
 * Players request media in slices. Dropping the range parameters turns the same
 * signed URL into a request for the whole file — the signature covers the path
 * and expiry, not the slice.
 */
function fullFileUrl(url: string): string {
  try {
    const parsed = new URL(url);
    for (const key of ['range', 'rn', 'rbuf', 'ump', 'srfvp']) {
      parsed.searchParams.delete(key);
    }
    return parsed.toString();
  } catch {
    return url;
  }
}

function youtubeIdOf(url: string): string | null {
  try {
    const parsed = new URL(url);
    if (!/(^|\.)(youtube\.com|youtu\.be)$/i.test(parsed.hostname)) return null;
    if (parsed.hostname.endsWith('youtu.be')) return parsed.pathname.slice(1) || null;
    return (
      parsed.searchParams.get('v') ??
      parsed.pathname.match(/^\/(shorts|embed|live)\/([\w-]{6,})/)?.[2] ??
      null
    );
  } catch {
    return null;
  }
}

function guessMime(url: string): string {
  const ext = url.match(MEDIA_FILE)?.[1]?.toLowerCase() ?? 'mp4';
  if (['m4a', 'mp3'].includes(ext)) return `audio/${ext}`;
  return `video/${ext}`;
}

function stripQuery(url: string): string {
  try {
    const parsed = new URL(url);
    return `${parsed.origin}${parsed.pathname}`;
  } catch {
    return url;
  }
}

async function hash(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-1', new TextEncoder().encode(value));
  return [...new Uint8Array(digest)]
    .slice(0, 8)
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('');
}
