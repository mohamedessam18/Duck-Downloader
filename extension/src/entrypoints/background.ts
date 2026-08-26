import { emit, onMessage, sendToTab } from '@/core/messaging';
import { getSettings, setSettings } from '@/core/settings';
import { addCandidates, clearTab, getCandidates, pruneClosedTabs } from '@/core/candidate-store';
import { pairCapturedFormats } from '@/detect/pair-captured';
import { isBlockedHost } from '@/core/nsfw';
import { startNetworkSniffer } from '@/detect/network-sniffer';
import { startStreamCapture } from '@/detect/stream-capture';
import { startDownloadInterceptor } from '@/download/interceptor';
import { resolveCandidate, backend } from '@/resolve';
import { platformOf } from '@/core/platform';
import type { MediaCandidate } from '@/core/types';
import {
  cancelJob,
  deleteJob,
  listJobs,
  pauseJob,
  reconcile,
  resumeJob,
  startDownload,
} from '@/download/manager';
import { log } from '@/core/logger';
import { engine } from '@/engine/client';
import type { JobRecord } from '../../../contracts/duck-protocol';
import {
  cancelUnlock,
  completeUnlock,
  enableGuard,
  getGuard,
  requestUnlock,
  restoreGuard,
  toStatus,
  updateGuard,
} from '@/core/guard';

export default defineBackground(() => {
  log.info('background worker started');

  startNetworkSniffer();
  // Captures the URLs players actually use, which needs no extraction at all.
  startStreamCapture();
  // Ordinary browser downloads go to the engine too, the way a download
  // manager is expected to behave.
  startDownloadInterceptor();

  // Downloads outlive the worker, so state is re-synced on every startup rather
  // than assumed to be whatever it was when the worker last died.
  void reconcile();
  void pruneClosedTabs();
  // Enabled rulesets do not survive a browser restart on their own.
  void restoreGuard();

  void reinjectAfterUpdate();
  registerEngineBridge();
  registerMessageHandlers();
  registerTabLifecycle();
  registerActionBehavior();
});

/**
 * Keeps a local mirror of the engine's job list.
 *
 * The engine pushes changes; this caches them so the popup can render instantly
 * on open instead of waiting on a round trip through the bridge. It is a cache,
 * never the source of truth — `engine:jobs` re-reads from the engine.
 */
let engineJobs: JobRecord[] = [];

/**
 * Puts the current content script back into tabs that are already open.
 *
 * Replacing an extension leaves every open tab running the previous version,
 * whose `chrome.runtime` handle is dead — the user sees "Extension context
 * invalidated" and has to refresh each tab by hand. Re-injecting removes that
 * entirely: after an update, pages simply keep working.
 */
async function reinjectAfterUpdate(): Promise<void> {
  const tabs = await chrome.tabs.query({ url: ['http://*/*', 'https://*/*'] });

  await Promise.all(
    tabs.map(async (tab) => {
      if (tab.id === undefined || !tab.url) return;
      // Adult hosts never receive the script, updates included.
      if (isBlockedHost(safeHost(tab.url))) return;

      try {
        await chrome.scripting.executeScript({
          target: { tabId: tab.id },
          files: ['content-scripts/content.js'],
        });
      } catch {
        // Restricted pages (the web store, other extensions' pages) refuse
        // injection, and that is expected rather than a problem.
      }
    }),
  );

  log.debug(`re-injected into ${tabs.length} open tab(s)`);
}

function safeHost(url: string): string {
  try {
    return new URL(url).hostname;
  } catch {
    return '';
  }
}

function registerEngineBridge(): void {
  engine.onEvent((event) => {
    if (event.type === 'jobUpdated') {
      const index = engineJobs.findIndex((job) => job.id === event.job.id);
      if (index >= 0) engineJobs[index] = event.job;
      else engineJobs.unshift(event.job);
      emit('engine:changed', engineJobs);
      return;
    }

    if (event.type === 'jobRemoved') {
      engineJobs = engineJobs.filter((job) => job.id !== event.jobId);
      emit('engine:changed', engineJobs);
      return;
    }

    if (event.type === 'needSource') {
      // The engine hit an expired link and cannot continue without a fresh one.
      // Re-detection happens in the tab that produced it, so the page mints a
      // new signature exactly as it did the first time.
      void refreshSourceFor(event.jobId, event.pageUrl, event.tabId);
    }
  });
}

/**
 * Answers the engine's request for a new URL.
 *
 * Deliberately does not restart the job: the engine keeps every byte already on
 * disk and only swaps the address it is reading from.
 */
async function refreshSourceFor(
  jobId: string,
  pageUrl: string,
  tabId?: number,
): Promise<void> {
  log.debug('engine asked for a fresh source for', pageUrl);

  const tab =
    tabId !== undefined
      ? await chrome.tabs.get(tabId).catch(() => undefined)
      : (await chrome.tabs.query({ url: pageUrl })).at(0);

  if (!tab?.id) {
    log.debug('the page that could refresh this link is not open');
    return;
  }

  await sendToTab(tab.id, 'candidates:rescan', { tabId: tab.id });
  // Detection is debounced in the content script, so give it a moment to report.
  await new Promise((resolve) => setTimeout(resolve, 1200));

  const candidates = await getCandidates(tab.id);
  const fresh = candidates.find((candidate) => candidate.formats.some((f) => f.url));
  const format = fresh?.formats.find((f) => f.url);
  if (!fresh || !format) {
    log.debug('nothing re-captured for', pageUrl);
    return;
  }

  await engine.refreshedSource(jobId, format, fresh.detectedAt);
}

function registerMessageHandlers(): void {
  onMessage('candidates:report', async ({ candidates }, sender) => {
    const tabId = sender.tab?.id;
    if (tabId === undefined) return;
    await addCandidates(tabId, candidates);
  });

  onMessage('candidates:query', async ({ tabId }) => {
    const target = tabId ?? (await activeTabId());
    if (target === undefined) return [];
    return (await getCandidates(target)).map(pairCapturedFormats);
  });

  onMessage('candidates:rescan', async ({ tabId }) => {
    // The content script re-reports through 'candidates:report', so its reply
    // is ignored and the store stays the single source of truth.
    await sendToTab(tabId, 'candidates:rescan', { tabId });
    return getCandidates(tabId);
  });

  onMessage('resolve:page', async ({ pageUrl, title }) => {
    // Enumerate first. A post with several items has to come back as several
    // candidates; falling straight to single extraction would silently return
    // only the first slide of a carousel.
    try {
      const items = await backend.extractPost(pageUrl);
      if (items.length > 1) return items;
    } catch (error) {
      log.debug('post enumeration failed, treating as a single item', error);
    }

    const candidate: MediaCandidate = {
      id: `page:${pageUrl}`,
      platform: platformOf(pageUrl),
      pageUrl,
      title: title?.trim() || 'Media',
      formats: [],
      source: 'adapter',
      detectedAt: Date.now(),
      needsResolve: true,
    };
    return [await resolveCandidate(candidate)];
  });

  onMessage('download:start', async ({ candidate, format }) => ({
    jobId: await startDownload(candidate, format),
  }));

  onMessage('download:post', async ({ pageUrl, title }) => {
    const items = await backend.extractPost(pageUrl).catch(() => []);

    if (items.length === 0) {
      // Not a multi-item post after all — fall back to the single-media path so
      // the click still does something.
      const candidate: MediaCandidate = {
        id: `page:${pageUrl}`,
        platform: platformOf(pageUrl),
        pageUrl,
        title: title?.trim() || 'Media',
        formats: [],
        source: 'adapter',
        detectedAt: Date.now(),
        needsResolve: true,
      };
      const resolved = await resolveCandidate(candidate);
      const best = resolved.formats[0];
      if (!best) throw new Error('Nothing downloadable found on this page.');
      await startDownload(resolved, best);
      return { started: 1 };
    }

    let started = 0;
    for (const item of items) {
      const format = item.formats[0];
      if (!format) continue;
      await startDownload(item, format);
      started++;
    }
    return { started };
  });

  onMessage('download:cancel', ({ jobId }) => cancelJob(jobId));
  onMessage('download:pause', ({ jobId }) => pauseJob(jobId));
  onMessage('download:resume', ({ jobId }) => resumeJob(jobId));
  onMessage('download:remove', ({ jobId }) => deleteJob(jobId));
  onMessage('jobs:query', () => listJobs());

  onMessage('engine:status', () => engine.check());

  onMessage('engine:jobs', async () => {
    const status = engine.getStatus();
    if (!status.connected) return [];
    engineJobs = await engine.list();
    return engineJobs;
  });

  onMessage('engine:action', async ({ action, jobId }) => {
    await engine[action](jobId);
  });

  onMessage('diagnose:youtube', async ({ tabId }) => {
    const target =
      tabId ?? (await chrome.tabs.query({ url: ['*://*.youtube.com/watch*'] })).at(0)?.id;
    if (target === undefined) return null;
    return (await sendToTab(target, 'diagnose:youtube', { tabId: target })) ?? null;
  });

  onMessage('guard:status', async () => toStatus(await getGuard()));
  onMessage('guard:enable', async (options) => toStatus(await enableGuard(options)));
  onMessage('guard:requestUnlock', async ({ pin }) => toStatus(await requestUnlock(pin)));
  onMessage('guard:cancelUnlock', async () => toStatus(await cancelUnlock()));
  onMessage('guard:completeUnlock', async () => toStatus(await completeUnlock()));
  onMessage('guard:update', async ({ patch, pin }) => toStatus(await updateGuard(patch, pin)));

  onMessage('settings:get', () => getSettings());
  onMessage('settings:set', ({ patch }) => setSettings(patch));

  onMessage('panel:open', async ({ tabId }) => {
    await chrome.sidePanel.open({ tabId });
  });
}

function registerTabLifecycle(): void {
  // Navigating away invalidates every candidate found on the old page. SPAs
  // change URL without a document swap, so this fires on history updates too.
  chrome.webNavigation.onCommitted.addListener((details) => {
    if (details.frameId !== 0) return;
    void clearTab(details.tabId);
  });

  chrome.webNavigation.onHistoryStateUpdated.addListener((details) => {
    if (details.frameId !== 0) return;
    void clearTab(details.tabId);
  });

  chrome.tabs.onRemoved.addListener((tabId) => {
    void clearTab(tabId);
  });
}

function registerActionBehavior(): void {
  // The action opens the popup (declared by the popup entrypoint); the side
  // panel is opened explicitly from there. Setting this to true instead would
  // swallow the popup entirely.
  chrome.sidePanel
    .setPanelBehavior({ openPanelOnActionClick: false })
    .catch((error: unknown) => log.warn('side panel behavior', error));
}

async function activeTabId(): Promise<number | undefined> {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  return tab?.id;
}
