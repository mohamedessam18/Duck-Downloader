import type { MediaCandidate } from '@/core/types';
import type { OverlayAnchor, PageAdapter } from './types';

/**
 * X / Twitter adapter.
 *
 * X plays video through MSE, so `<video src>` is a `blob:` URL that is useless
 * outside the page. What the DOM *does* give us reliably is identity: the tweet
 * id, its text, and the poster frame. The playable variants are picked up either
 * by the network sniffer (video.twimg.com) or by the resolver, and joined onto
 * this candidate by id.
 */
export const twitterAdapter: PageAdapter = {
  platform: 'twitter',

  matches(url) {
    return /(^|\.)(twitter\.com|x\.com)$/i.test(safeHost(url));
  },

  detect() {
    const candidates: MediaCandidate[] = [];
    const seen = new Set<string>();

    for (const article of document.querySelectorAll<HTMLElement>('article[role="article"]')) {
      const tweetId = tweetIdOf(article);
      if (!tweetId || seen.has(tweetId)) continue;
      if (!hasMedia(article)) continue;
      seen.add(tweetId);

      candidates.push({
        id: `twitter:${tweetId}`,
        platform: 'twitter',
        pageUrl: permalinkOf(article) ?? `https://x.com/i/status/${tweetId}`,
        title: tweetText(article) || `X post ${tweetId}`,
        thumbnail: posterOf(article),
        author: handleOf(article),
        durationSec: durationOf(article),
        formats: [],
        source: 'adapter',
        detectedAt: Date.now(),
        needsResolve: true,
      });
    }

    return candidates;
  },

  anchors() {
    const anchors: OverlayAnchor[] = [];
    for (const article of document.querySelectorAll<HTMLElement>('article[role="article"]')) {
      const tweetId = tweetIdOf(article);
      const player = article.querySelector<HTMLElement>('[data-testid="videoPlayer"]');
      if (!tweetId || !player) continue;
      anchors.push({
        element: player,
        candidateId: `twitter:${tweetId}`,
        placement: 'top-right',
      });
    }
    return anchors;
  },
};

function hasMedia(article: HTMLElement): boolean {
  return Boolean(
    article.querySelector('[data-testid="videoPlayer"], video, [data-testid="tweetPhoto"]'),
  );
}

/**
 * Status links appear on the timestamp and on quoted tweets alike, so we take
 * the first one whose href belongs to this article's own permalink row rather
 * than any `/status/` anywhere inside it.
 */
function tweetIdOf(article: HTMLElement): string | null {
  const links = article.querySelectorAll<HTMLAnchorElement>('a[href*="/status/"]');
  for (const link of links) {
    const match = link.getAttribute('href')?.match(/\/status\/(\d+)/);
    if (match?.[1]) return match[1];
  }
  return null;
}

function permalinkOf(article: HTMLElement): string | null {
  const link = article.querySelector<HTMLAnchorElement>('a[href*="/status/"]');
  const href = link?.getAttribute('href');
  return href ? new URL(href, 'https://x.com').toString() : null;
}

function tweetText(article: HTMLElement): string {
  const text = article.querySelector('[data-testid="tweetText"]')?.textContent?.trim() ?? '';
  return text.replace(/\s+/g, ' ').slice(0, 100);
}

function handleOf(article: HTMLElement): string | undefined {
  const link = article.querySelector<HTMLAnchorElement>('[data-testid="User-Name"] a[href^="/"]');
  const href = link?.getAttribute('href');
  return href ? href.replace(/^\//, '@').split('/')[0] : undefined;
}

function posterOf(article: HTMLElement): string | undefined {
  const video = article.querySelector<HTMLVideoElement>('video[poster]');
  if (video?.poster) return video.poster;
  const image = article.querySelector<HTMLImageElement>('[data-testid="tweetPhoto"] img');
  return image?.src;
}

function durationOf(article: HTMLElement): number | undefined {
  const video = article.querySelector<HTMLVideoElement>('video');
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
