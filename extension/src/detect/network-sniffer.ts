import type { MediaCandidate, MediaFormat, Protocol as Transport } from '@/core/types';
import { platformOf, sanitizeFilename } from '@/core/platform';
import { addCandidates } from '@/core/candidate-store';
import { log } from '@/core/logger';
import { isBlockedUrl } from '@/core/nsfw';

/**
 * Passive media detection by watching what the tab loads.
 *
 * MV3 removed *blocking* webRequest, but the observational API is intact and is
 * still the only way to see media a page fetches through JS with no <video src>
 * to scrape. This is what makes the extension work on sites we never wrote an
 * adapter for.
 *
 * The listener only ever fires for hosts we hold permission on, so on an
 * unsupported site nothing is observed until the user grants that site
 * explicitly from the popup.
 */

/** Streaming segments — noise. We want the manifest that lists them, not these. */
const SEGMENT_PATTERN = /\.(ts|m4s|aac|vtt|webvtt)(\?|$)/i;

const MANIFEST_PATTERN = /\.(m3u8|mpd)(\?|$)/i;

const FILE_PATTERN = /\.(mp4|webm|mkv|mov|m4v|mp3|m4a|ogg|opus|wav|flac)(\?|$)/i;

const MEDIA_CONTENT_TYPE = /^(video|audio)\//i;

const MANIFEST_CONTENT_TYPE =
  /(application\/(x-mpegurl|vnd\.apple\.mpegurl|dash\+xml)|audio\/mpegurl)/i;

/** Below this, a "video/mp4" response is a thumbnail preview or an ad bumper. */
const MIN_INTERESTING_BYTES = 300 * 1024;

interface Observed {
  url: string;
  contentType: string;
  contentLength: number;
  transport: Transport;
}

export function startNetworkSniffer(): void {
  chrome.webRequest.onHeadersReceived.addListener(
    (details) => {
      if (details.tabId < 0) return;
      if (isBlockedUrl(details.initiator ?? details.url)) return;
      if (!isRefetchable(details)) return;
      const observed = classify(details);
      if (!observed) return;
      void record(details.tabId, observed, details.initiator ?? details.url);
    },
    { urls: ['<all_urls>'], types: ['xmlhttprequest', 'media', 'other'] },
    ['responseHeaders'],
  );

  log.debug('network sniffer armed');
}

/**
 * Whether this response could be obtained again with a plain GET.
 *
 * The rule behind it: never offer a file that cannot actually be re-fetched.
 * A response driven by a request body is not addressable by its URL alone —
 * asking for that URL again returns something else, or nothing usable.
 *
 * YouTube is the case that forced this. Its media now arrives over
 * `POST /videoplayback` carrying a protobuf body, with the response framed in
 * UMP; the URL has no `itag` and re-requesting it yields data that is not a
 * media file. Offering it produced downloads that looked like audio and opened
 * in nothing.
 */
function isRefetchable(details: chrome.webRequest.WebResponseHeadersDetails): boolean {
  if (details.method !== 'GET') return false;
  // Even a GET here belongs to the capture engine, which requires the itag the
  // SABR endpoint no longer provides.
  if (/googlevideo\.com\/videoplayback/i.test(details.url)) return false;
  return true;
}

function classify(details: chrome.webRequest.WebResponseHeadersDetails): Observed | null {
  const url = details.url;
  if (!url.startsWith('http')) return null;
  if (SEGMENT_PATTERN.test(url)) return null;

  const headers = details.responseHeaders ?? [];
  const header = (name: string) =>
    headers.find((entry) => entry.name.toLowerCase() === name)?.value ?? '';

  const contentType = header('content-type').toLowerCase();
  const contentLength = Number(header('content-length')) || 0;

  const isManifest = MANIFEST_PATTERN.test(url) || MANIFEST_CONTENT_TYPE.test(contentType);
  if (isManifest) {
    return {
      url,
      contentType,
      contentLength,
      transport: url.includes('.mpd') || contentType.includes('dash') ? 'dash' : 'hls',
    };
  }

  const looksLikeMedia = MEDIA_CONTENT_TYPE.test(contentType) || FILE_PATTERN.test(url);
  if (!looksLikeMedia) return null;

  // A ranged response reports only the slice length, so its Content-Length says
  // nothing about the real file size — don't let the size filter reject it.
  const isPartial = details.statusCode === 206;
  if (!isPartial && contentLength > 0 && contentLength < MIN_INTERESTING_BYTES) return null;

  return { url, contentType, contentLength, transport: 'https' };
}

async function record(tabId: number, observed: Observed, pageUrl: string): Promise<void> {
  const format = toFormat(observed);
  const candidate: MediaCandidate = {
    id: `net:${await hashUrl(stripVolatileParams(observed.url))}`,
    platform: platformOf(pageUrl),
    pageUrl,
    title: guessTitle(observed.url),
    formats: [format],
    source: 'network',
    detectedAt: Date.now(),
    // HLS/DASH manifests still need parsing to know what tracks exist.
    needsResolve: observed.transport !== 'https',
  };

  await addCandidates(tabId, [candidate]);
}

function toFormat(observed: Observed): MediaFormat {
  const isAudio =
    observed.contentType.startsWith('audio/') ||
    /\.(mp3|m4a|ogg|opus|wav|flac)(\?|$)/i.test(observed.url);

  const ext = extensionFor(observed);

  return {
    id: `net:${observed.transport}:${ext}`,
    label: observed.transport === 'https' ? 'Direct file' : observed.transport.toUpperCase(),
    ext,
    kind: isAudio ? 'audio' : 'video',
    protocol: observed.transport,
    url: observed.url,
    filesize: observed.contentLength || undefined,
    origin: 'network-sniffer',
  };
}

function extensionFor(observed: Observed): string {
  if (observed.transport !== 'https') return 'mp4';
  const fromUrl = observed.url.match(FILE_PATTERN)?.[1];
  if (fromUrl) return fromUrl.toLowerCase();
  const fromType = observed.contentType.split('/')[1]?.split(';')[0];
  return fromType?.replace('x-', '') || 'mp4';
}

/**
 * Query strings on CDN media carry expiring tokens and byte ranges, so the raw
 * URL is useless as an identity — the same video would register as a new
 * candidate on every seek.
 */
function stripVolatileParams(url: string): string {
  try {
    const parsed = new URL(url);
    return `${parsed.origin}${parsed.pathname}`;
  } catch {
    return url;
  }
}

async function hashUrl(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-1', new TextEncoder().encode(value));
  return [...new Uint8Array(digest)]
    .slice(0, 8)
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('');
}

function guessTitle(url: string): string {
  try {
    const name = new URL(url).pathname.split('/').filter(Boolean).pop() ?? '';
    const withoutExt = decodeURIComponent(name).replace(/\.[a-z0-9]+$/i, '');
    return sanitizeFilename(withoutExt.replace(/[-_+]+/g, ' ').trim()) || 'Media file';
  } catch {
    return 'Media file';
  }
}
