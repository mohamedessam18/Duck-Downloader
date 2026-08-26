import { adapterFor, type PageAdapter } from '@/detect/adapters';
import { getSettings, onSettingsChanged } from '@/core/settings';
import { onMessage, sendMessage } from '@/core/messaging';
import { Overlay } from '@/ui/overlay';
import { probeYouTube, resolveYouTube } from '@/resolve/youtube';
import { videoIdFrom } from '@/resolve/youtube';
import { log } from '@/core/logger';
import { isBlockedHost } from '@/core/nsfw';
import { startFeedFilter } from '@/detect/feed-filter';
import { sendMessage as send } from '@/core/messaging';
import type { MediaCandidate, Settings } from '@/core/types';

/**
 * Content script: run the page adapter, report what it finds, keep the overlay
 * in sync.
 *
 * Every site we support is a single-page app, so detection is not a one-shot
 * job at document_idle — it is a debounced reaction to DOM mutations and
 * history changes for as long as the tab is open.
 */

const DETECT_DEBOUNCE_MS = 350;

export default defineContentScript({
  // Duck is meant to work wherever media plays, so this runs everywhere and
  // filters in `main` instead of relying on a host list that can never be
  // complete.
  matches: ['<all_urls>'],
  runAt: 'document_idle',
  allFrames: false,

  async main() {
    // Nothing runs on adult hosts: no detection, no overlay, no reporting.
    if (isBlockedHost(location.hostname)) return;

    const settings = await getSettings();
    const controller = new PageController(settings);
    controller.start();

    // Runs independently of media detection: the filter has to keep working
    // even on pages where there is nothing to download.
    const guard = await send('guard:status', {}).catch(() => null);
    if (guard?.enabled && guard.feedFilter) startFeedFilter();
  },
});

class PageController {
  private adapter: PageAdapter;
  private overlay: Overlay;
  private settings: Settings;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private lastSignature = '';

  constructor(settings: Settings) {
    this.settings = settings;
    this.adapter = adapterFor(location.href, settings);
    this.overlay = new Overlay(settings);
  }

  start(): void {
    log.debug('content script active', this.adapter.platform);

    this.schedule();
    this.watchDom();
    this.watchNavigation();

    onSettingsChanged((settings) => {
      this.settings = settings;
      this.adapter = adapterFor(location.href, settings);
      this.overlay.updateSettings(settings);
      this.schedule();
    });

    onMessage('candidates:rescan', () => {
      this.detect();
      return [];
    });

    // Resolving here rather than in the worker is deliberate: on youtube.com
    // this fetch is same-origin and carries the user's session, which is what
    // turns InnerTube's LOGIN_REQUIRED into a real answer.
    onMessage('resolve:youtube', ({ videoId }) =>
      resolveYouTube(videoId, { credentials: 'include' }),
    );

    onMessage('diagnose:youtube', () => {
      const videoId = videoIdFrom(location.href);
      if (!videoId) return null;
      return probeYouTube(videoId, { credentials: 'include' });
    });
  }

  private watchDom(): void {
    const observer = new MutationObserver(() => this.schedule());
    observer.observe(document.documentElement, {
      childList: true,
      subtree: true,
      // Attribute noise on these sites is constant; structural changes are what
      // signal new media, and ignoring attributes cuts the callback rate hard.
      attributes: false,
    });
  }

  /**
   * SPA navigations do not fire `load`, and `popstate` misses pushState. Patching
   * history is the only way to see a YouTube video change without polling.
   */
  private watchNavigation(): void {
    const notify = () => {
      this.lastSignature = '';
      this.adapter = adapterFor(location.href, this.settings);
      this.schedule();
    };

    for (const method of ['pushState', 'replaceState'] as const) {
      const original = history[method];
      history[method] = function patched(this: History, ...args: Parameters<History['pushState']>) {
        const result = original.apply(this, args);
        queueMicrotask(notify);
        return result;
      };
    }

    window.addEventListener('popstate', notify);
  }

  private schedule(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = setTimeout(() => this.detect(), DETECT_DEBOUNCE_MS);
  }

  private detect(): void {
    let candidates: MediaCandidate[] = [];
    try {
      candidates = this.adapter.detect();
    } catch (error) {
      log.warn('adapter detect failed', error);
      return;
    }

    this.overlay.setCandidates(candidates);
    this.overlay.render(this.adapter.anchors?.() ?? []);

    // Mutation observers fire constantly on these sites; only tell the worker
    // when the set of media actually changed.
    const signature = candidates.map((candidate) => candidate.id).join('|');
    if (signature === this.lastSignature) return;
    this.lastSignature = signature;

    if (candidates.length === 0) return;
    void sendMessage('candidates:report', { candidates }).catch((error: unknown) => {
      log.debug('report failed (worker asleep?)', error);
    });
  }
}
