import type { MediaCandidate, MediaFormat } from '@/core/types';
import { platformOf, sanitizeFilename } from '@/core/platform';
import type { OverlayAnchor, PageAdapter } from './types';

/**
 * Fallback adapter for every site without a dedicated one.
 *
 * Two kinds of media get handled differently:
 *
 *  - **Plain sources.** A `<video src="https://...">` is directly downloadable,
 *    so the format is filled in here and the download skips resolving entirely.
 *
 *  - **MSE sources.** Facebook, Instagram, TikTok and most modern players feed
 *    the element through Media Source Extensions, leaving a `blob:` URL that
 *    means nothing outside the page's own JS. Those still get a candidate and a
 *    button — identity comes from the page URL and the bytes come from the
 *    resolver. Skipping them, as this adapter used to, is why the button never
 *    appeared on those sites at all.
 */

/** Below this, an element is a thumbnail preview or a tracking pixel. */
const MIN_ANCHOR_SIZE = 120;

export const genericAdapter: PageAdapter = {
  platform: 'generic',

  matches() {
    return true;
  },

  detect() {
    const candidates: MediaCandidate[] = [];

    for (const [index, element] of mediaElements().entries()) {
      const sources = directSources(element);
      const kind = element instanceof HTMLVideoElement ? 'video' : 'audio';

      const formats: MediaFormat[] = sources.map((url, position) => ({
        id: `dom:${position}`,
        label: labelFor(element, url),
        ext: extensionOf(url) ?? (kind === 'video' ? 'mp4' : 'mp3'),
        kind,
        protocol: /\.m3u8(\?|$)/i.test(url) ? 'hls' : /\.mpd(\?|$)/i.test(url) ? 'dash' : 'https',
        url,
        width: element instanceof HTMLVideoElement ? element.videoWidth || undefined : undefined,
        height: element instanceof HTMLVideoElement ? element.videoHeight || undefined : undefined,
        origin: 'dom',
      }));

      const pageUrl = permalinkFor(element) ?? location.href;

      candidates.push({
        id: candidateId(element, index),
        platform: platformOf(pageUrl),
        pageUrl,
        isProtected: isDrmProtected(element),
        title: titleFor(element),
        thumbnail:
          element instanceof HTMLVideoElement && element.poster ? element.poster : undefined,
        durationSec: Number.isFinite(element.duration) ? Math.round(element.duration) : undefined,
        formats,
        source: 'dom',
        detectedAt: Date.now(),
        // No plain source, or only a manifest: the resolver has to step in.
        needsResolve: formats.length === 0 || formats.every((f) => f.protocol !== 'https'),
      });
    }

    return candidates;
  },

  anchors() {
    return mediaElements()
      .map((element, index) => ({
        element: anchorFor(element),
        candidateId: candidateId(element, index),
        placement: 'top-right' as const,
      }))
      .filter((anchor) => anchor.element.isConnected);
  },
};

/**
 * URL shapes that identify a single piece of media on the big social sites.
 * Matching on the path rather than on class names is deliberate: these routes
 * are public API surface and change on the order of years, while the markup
 * around them is obfuscated and rebuilt constantly.
 */
const PERMALINK_PATTERNS = [
  /\/videos?\/\d+/,          // facebook.com/<page>/videos/<id>
  /\/reels?\/[\w-]+/,        // facebook.com/reel/<id>, instagram.com/reel/<id>
  /\/watch\/?\?v=\d+/,       // facebook.com/watch/?v=<id>
  /\/p\/[\w-]+/,             // instagram.com/p/<id>
  /\/status\/\d+/,           // x.com/<user>/status/<id>
  /\/video\/\d+/,            // tiktok.com/@<user>/video/<id>
  /\/comments\/\w+/,         // reddit.com/r/<sub>/comments/<id>
];

/**
 * Finds the permalink for the post containing this element.
 *
 * In a feed, `location.href` is the feed itself — resolving that would hand the
 * backend the wrong video, or none at all. The post's own link is almost always
 * on the timestamp or the media wrapper somewhere above the player.
 */
function permalinkFor(element: HTMLMediaElement): string | null {
  let node: HTMLElement | null = element;

  for (let depth = 0; depth < 12 && node; depth++) {
    for (const link of node.querySelectorAll<HTMLAnchorElement>('a[href]')) {
      const href = link.getAttribute('href');
      if (!href || href.startsWith('#')) continue;
      if (!PERMALINK_PATTERNS.some((pattern) => pattern.test(href))) continue;
      try {
        return new URL(href, location.href).toString();
      } catch {
        continue;
      }
    }
    node = node.parentElement;
  }

  // On a media page the URL already is the permalink.
  return PERMALINK_PATTERNS.some((pattern) => pattern.test(location.pathname + location.search))
    ? location.href
    : null;
}

/**
 * Whether the player is decrypting this through EME.
 *
 * `mediaKeys` is only ever set on an element the page has attached a CDM to, so
 * its presence is a direct statement from the player that the stream is
 * encrypted — not a guess based on the site's name.
 */
function isDrmProtected(element: HTMLMediaElement): boolean {
  try {
    return element.mediaKeys != null;
  } catch {
    return false;
  }
}

/** Every media element big enough that a user would call it "the video". */
function mediaElements(): HTMLMediaElement[] {
  return [...document.querySelectorAll<HTMLMediaElement>('video, audio')].filter((element) => {
    if (element instanceof HTMLAudioElement) return true;
    const box = element.getBoundingClientRect();
    return box.width >= MIN_ANCHOR_SIZE && box.height >= MIN_ANCHOR_SIZE;
  });
}

/**
 * Anchors to the player's wrapper rather than the `<video>` itself. Players
 * commonly stretch the element under a controls layer, and a button pinned to
 * the raw element ends up behind them.
 */
function anchorFor(element: HTMLMediaElement): HTMLElement {
  const box = element.getBoundingClientRect();
  let best: HTMLElement = element;
  let node = element.parentElement;

  for (let depth = 0; depth < 3 && node; depth++) {
    const candidate = node.getBoundingClientRect();
    // Only adopt an ancestor that is still essentially the same box. A test for
    // "bigger than the video" is satisfied by <body> too, which parks the button
    // in the page corner instead of on the player.
    const framesSameMedia =
      candidate.width <= box.width * 1.15 &&
      candidate.height <= box.height * 1.4 &&
      candidate.width >= box.width * 0.95;

    if (!framesSameMedia) break;
    best = node;
    node = node.parentElement;
  }

  return best;
}

/**
 * Identity has to survive re-detection while the page mutates around it. A
 * poster or plain source is stable; for an MSE element with neither, position in
 * the document is the only thing left.
 */
function candidateId(element: HTMLMediaElement, index: number): string {
  const stable =
    directSources(element)[0] ??
    (element instanceof HTMLVideoElement ? element.poster : '') ??
    '';
  return stable ? `dom:${hashString(stable)}` : `dom:idx${index}`;
}

function directSources(element: HTMLMediaElement): string[] {
  const urls: string[] = [];
  const push = (value: string | null | undefined) => {
    if (!value || !/^https?:/i.test(value)) return;
    if (!urls.includes(value)) urls.push(value);
  };

  push(element.getAttribute('src'));
  for (const source of element.querySelectorAll('source')) push(source.getAttribute('src'));
  return urls;
}

function labelFor(element: HTMLMediaElement, url: string): string {
  if (element instanceof HTMLVideoElement && element.videoHeight) {
    return `${element.videoHeight}p`;
  }
  return extensionOf(url)?.toUpperCase() ?? 'Source';
}

function titleFor(element: HTMLMediaElement): string {
  const explicit =
    element.getAttribute('title') ||
    element.getAttribute('aria-label') ||
    document.querySelector('meta[property="og:title"]')?.getAttribute('content');
  return sanitizeFilename(explicit?.trim() || document.title.trim() || 'Media');
}

function extensionOf(url: string): string | null {
  try {
    return new URL(url).pathname.match(/\.([a-z0-9]{2,5})$/i)?.[1]?.toLowerCase() ?? null;
  } catch {
    return null;
  }
}

/** Small non-cryptographic hash — this only needs to be stable within a page. */
function hashString(value: string): string {
  let hash = 2166136261;
  for (let index = 0; index < value.length; index++) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return (hash >>> 0).toString(16);
}
