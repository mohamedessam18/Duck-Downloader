import type { MediaCandidate } from '@/core/types';
import { getSettings } from '@/core/settings';
import { sendToTab } from '@/core/messaging';
import { log } from '@/core/logger';
import { isBlockedUrl } from '@/core/nsfw';
import { pairCapturedFormats } from '@/detect/pair-captured';
import { resolveYouTube, videoIdFrom } from './youtube';
import * as backend from './backend';

/**
 * Turns a detected candidate into one with playable formats.
 *
 * The order is the whole point of the hybrid design:
 *   1. In-page — ask a content script on the site itself. Requests go out
 *      same-origin with the user's own session, which is what gets past the
 *      login gates an anonymous request runs into.
 *   2. In-worker — the same resolver, anonymously. Works for a minority of
 *      YouTube videos, costs nothing to try.
 *   3. The Duck backend — yt-dlp handles what neither can, at the cost of the
 *      page link being sent to our server.
 *
 * A candidate that already carries a direct URL skips all three.
 */
export async function resolveCandidate(candidate: MediaCandidate): Promise<MediaCandidate> {
  // Last line of defence: a candidate can reach here from the popup or a stale
  // store entry without having passed the content script's check.
  if (isBlockedUrl(candidate.pageUrl)) {
    throw new Error('Adult content is blocked.');
  }

  // Captured streams are already playable URLs — the fastest path there is, and
  // the one that needs no server at all.
  const paired = pairCapturedFormats(candidate);
  if (!paired.needsResolve && paired.formats.some((format) => format.url)) {
    return paired;
  }

  const settings = await getSettings();

  if (candidate.platform === 'youtube' && settings.youtubeEnabled) {
    const resolved = await resolveYouTubeAnywhere(candidate);
    if (resolved?.formats?.length) {
      return { ...candidate, ...resolved, needsResolve: false };
    }
    log.debug('local youtube resolution failed, falling back to backend');
  }

  if (!settings.backendFallback) {
    throw new Error('Could not resolve this media locally, and server fallback is turned off.');
  }

  const extracted = await backend.extract(candidate.pageUrl);
  if (!extracted.formats?.length) {
    throw new Error('No downloadable formats found for this link.');
  }

  return {
    ...candidate,
    ...extracted,
    // Keep what the page adapter knew; the backend's title is often worse.
    title: candidate.title || extracted.title || 'Media',
    thumbnail: candidate.thumbnail ?? extracted.thumbnail,
    needsResolve: false,
  };
}

async function resolveYouTubeAnywhere(
  candidate: MediaCandidate,
): Promise<Partial<MediaCandidate> | null> {
  const videoId = videoIdFrom(candidate.pageUrl);
  if (!videoId) return null;

  const tabId = await findYouTubeTab(videoId);
  if (tabId !== undefined) {
    const resolved = await sendToTab(tabId, 'resolve:youtube', { videoId });
    if (resolved?.formats?.length) {
      log.debug('resolved youtube in page context');
      return resolved;
    }
  }

  return resolveYouTube(videoId, { credentials: 'omit' });
}

/**
 * Prefers the tab actually showing this video, so the session used is the one
 * that is already watching it, and falls back to any open YouTube tab.
 */
async function findYouTubeTab(videoId: string): Promise<number | undefined> {
  const tabs = await chrome.tabs.query({ url: ['*://*.youtube.com/*', '*://*.youtu.be/*'] });
  const showingVideo = tabs.find((tab) => tab.url && videoIdFrom(tab.url) === videoId);
  return (showingVideo ?? tabs[0])?.id;
}

export { backend };
