import type { MediaCandidate } from '@/core/types';
import type { OverlayAnchor, PageAdapter } from './types';

/**
 * Instagram adapter.
 *
 * Instagram is the reason the whole post-enumeration path exists. A single link
 * can be:
 *   - one image
 *   - one video or reel
 *   - a carousel of images
 *   - a carousel of videos
 *   - a carousel mixing both
 *
 * Scraping that from the DOM is a losing game — a carousel only keeps the
 * neighbouring slides mounted, images carry `srcset` with several resolutions,
 * and videos are MSE with `blob:` sources. So this adapter does one job only:
 * work out the post's canonical shortcode URL. Everything else is enumerated
 * from that link by the backend, which returns each item already typed.
 *
 * Candidates are flagged `isPost`, which is what makes the overlay button
 * download the entire carousel instead of whichever slide happened to be
 * on screen.
 */

/** /p/<code>, /reel/<code>, /reels/<code>, /tv/<code> — every post route. */
const POST_PATH = /\/(p|reel|reels|tv)\/([A-Za-z0-9_-]+)/;

export const instagramAdapter: PageAdapter = {
  platform: 'instagram',

  matches(url) {
    try {
      return /(^|\.)instagram\.com$/i.test(new URL(url).hostname);
    } catch {
      return false;
    }
  },

  detect() {
    const posts = visiblePosts();
    return posts.map(({ shortcode, url, container }) => ({
      id: `instagram:${shortcode}`,
      platform: 'instagram' as const,
      pageUrl: url,
      title: captionOf(container) || `Instagram ${shortcode}`,
      thumbnail: posterOf(container),
      author: authorOf(container),
      formats: [],
      source: 'adapter' as const,
      detectedAt: Date.now(),
      needsResolve: true,
      isPost: true,
    })) satisfies MediaCandidate[];
  },

  anchors() {
    return visiblePosts().map(({ shortcode, container }) => ({
      element: container,
      candidateId: `instagram:${shortcode}`,
      placement: 'top-right' as const,
    })) satisfies OverlayAnchor[];
  },
};

interface FoundPost {
  shortcode: string;
  url: string;
  container: HTMLElement;
}

/**
 * Every post currently on screen, keyed by shortcode.
 *
 * On a post page the URL itself is the answer. In a feed each post is an
 * `<article>`; where Instagram changes that, the fallback is the nearest
 * ancestor of the permalink that actually frames some media.
 */
function visiblePosts(): FoundPost[] {
  const found = new Map<string, FoundPost>();

  const onPostPage = location.pathname.match(POST_PATH);
  if (onPostPage?.[2]) {
    const container = mediaContainer(document.body);
    if (container) {
      found.set(onPostPage[2], {
        shortcode: onPostPage[2],
        url: canonicalUrl(onPostPage[1]!, onPostPage[2]),
        container,
      });
    }
  }

  for (const article of document.querySelectorAll<HTMLElement>('article')) {
    const link = [...article.querySelectorAll<HTMLAnchorElement>('a[href]')]
      .map((anchor) => anchor.getAttribute('href') ?? '')
      .find((href) => POST_PATH.test(href));
    if (!link) continue;

    const match = link.match(POST_PATH);
    const shortcode = match?.[2];
    if (!shortcode || found.has(shortcode)) continue;

    const container = mediaContainer(article);
    if (!container) continue;

    found.set(shortcode, {
      shortcode,
      url: canonicalUrl(match![1]!, shortcode),
      container,
    });
  }

  return [...found.values()];
}

/**
 * The element that actually frames the media, so the button lands on the photo
 * rather than floating over the caption or the like button.
 */
function mediaContainer(scope: HTMLElement): HTMLElement | null {
  const media = scope.querySelector<HTMLElement>('video, img[srcset], img[decoding]');
  if (!media) return null;

  let best: HTMLElement = media;
  let node = media.parentElement;
  const box = media.getBoundingClientRect();
  if (box.width < 120 || box.height < 120) return null;

  for (let depth = 0; depth < 3 && node && node !== scope; depth++) {
    const candidate = node.getBoundingClientRect();
    if (candidate.width <= box.width * 1.1 && candidate.height <= box.height * 1.4) best = node;
    else break;
    node = node.parentElement;
  }
  return best;
}

/**
 * Reels and posts are the same object to the backend, but the canonical form
 * has to keep the route: /reel/<code> and /p/<code> are not interchangeable for
 * every extractor.
 */
function canonicalUrl(route: string, shortcode: string): string {
  const normalized = route === 'reels' ? 'reel' : route;
  return `https://www.instagram.com/${normalized}/${shortcode}/`;
}

function captionOf(container: HTMLElement): string {
  const article = container.closest('article') ?? container;
  const image = article.querySelector<HTMLImageElement>('img[alt]');
  const alt = image?.getAttribute('alt')?.trim();
  if (alt && alt.length > 3 && !/^Photo by/i.test(alt)) return alt.slice(0, 90);

  const heading = article.querySelector('h1')?.textContent?.trim();
  return heading?.slice(0, 90) ?? '';
}

function authorOf(container: HTMLElement): string | undefined {
  const article = container.closest('article') ?? container;
  const link = article.querySelector<HTMLAnchorElement>('a[href^="/"][role="link"]');
  const href = link?.getAttribute('href');
  const handle = href?.match(/^\/([\w.]+)\/?$/)?.[1];
  return handle ? `@${handle}` : undefined;
}

function posterOf(container: HTMLElement): string | undefined {
  const video = container.querySelector<HTMLVideoElement>('video[poster]');
  if (video?.poster) return video.poster;
  const image = container.querySelector<HTMLImageElement>('img[srcset], img[src]');
  return image?.currentSrc || image?.src || undefined;
}
