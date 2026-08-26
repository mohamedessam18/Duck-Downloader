import type { MediaCandidate } from '@/core/types';
import type { OverlayAnchor, PageAdapter } from './types';

/**
 * YouTube adapter.
 *
 * Isolated to a single module on purpose: YouTube support is the one part of
 * this extension that carries store-policy risk, and `settings.youtubeEnabled`
 * gates it end to end. Dropping this file and its resolver removes the feature
 * completely, with nothing left behind in the manifest or the UI.
 */
export const youtubeAdapter: PageAdapter = {
  platform: 'youtube',

  matches(url) {
    return /(^|\.)(youtube\.com|youtu\.be)$/i.test(safeHost(url));
  },

  detect() {
    const videoId = currentVideoId();
    if (!videoId) return [];

    const candidate: MediaCandidate = {
      id: `youtube:${videoId}`,
      platform: 'youtube',
      pageUrl: `https://www.youtube.com/watch?v=${videoId}`,
      title: readTitle(),
      thumbnail: `https://i.ytimg.com/vi/${videoId}/maxresdefault.jpg`,
      durationSec: readDuration(),
      author: readAuthor(),
      formats: [],
      source: 'adapter',
      detectedAt: Date.now(),
      // Formats come from the InnerTube resolver in the background worker.
      needsResolve: true,
    };

    return [candidate];
  },

  anchors() {
    const videoId = currentVideoId();
    const player = document.querySelector<HTMLElement>('#movie_player');
    if (!videoId || !player) return [];
    return [{ element: player, candidateId: `youtube:${videoId}`, placement: 'top-right' }];
  },
};

/**
 * Reads the id from the URL rather than the player, because YouTube is a SPA:
 * the DOM lags behind navigation by a few hundred milliseconds, but
 * `location` is updated synchronously by the history push.
 */
function currentVideoId(): string | null {
  try {
    const url = new URL(location.href);
    if (url.hostname.endsWith('youtu.be')) {
      return url.pathname.slice(1).split('/')[0] || null;
    }
    const fromQuery = url.searchParams.get('v');
    if (fromQuery) return fromQuery;
    // /shorts/<id>, /embed/<id>, /live/<id>
    const match = url.pathname.match(/^\/(shorts|embed|live)\/([\w-]{6,})/);
    return match?.[2] ?? null;
  } catch {
    return null;
  }
}

function readTitle(): string {
  const selectors = [
    'h1.ytd-watch-metadata yt-formatted-string',
    'h1.title yt-formatted-string',
    '#title h1',
    'meta[name="title"]',
  ];
  for (const selector of selectors) {
    const element = document.querySelector(selector);
    const text =
      element instanceof HTMLMetaElement ? element.content : element?.textContent?.trim();
    if (text) return text;
  }
  return document.title.replace(/\s*-\s*YouTube\s*$/, '').trim() || 'YouTube video';
}

function readAuthor(): string | undefined {
  return (
    document.querySelector('#owner #channel-name a')?.textContent?.trim() ||
    document.querySelector('ytd-channel-name a')?.textContent?.trim() ||
    undefined
  );
}

function readDuration(): number | undefined {
  const video = document.querySelector<HTMLVideoElement>('#movie_player video');
  return video && Number.isFinite(video.duration) && video.duration > 0
    ? Math.round(video.duration)
    : undefined;
}

function safeHost(url: string): string {
  try {
    return new URL(url).hostname;
  } catch {
    return '';
  }
}

export type { OverlayAnchor };
