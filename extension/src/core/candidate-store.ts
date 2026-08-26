import type { MediaCandidate } from './types';
import { emit } from './messaging';
import { log } from './logger';

/**
 * Per-tab registry of detected media.
 *
 * Backed by `chrome.storage.session` rather than a plain module-level Map:
 * the MV3 service worker is torn down after ~30s idle, and an in-memory store
 * would silently forget everything the user detected while they were reading
 * the page. Session storage lives as long as the browser profile session and is
 * never written to disk.
 */

const KEY = 'duck:candidates';
const MAX_PER_TAB = 40;

type Snapshot = Record<number, MediaCandidate[]>;

async function readAll(): Promise<Snapshot> {
  const stored = await chrome.storage.session.get(KEY);
  return (stored[KEY] as Snapshot | undefined) ?? {};
}

async function writeAll(snapshot: Snapshot): Promise<void> {
  await chrome.storage.session.set({ [KEY]: snapshot });
}

export async function getCandidates(tabId: number): Promise<MediaCandidate[]> {
  return (await readAll())[tabId] ?? [];
}

/**
 * Merges new detections into a tab, newest first. Candidates are keyed by `id`,
 * so an adapter re-reporting richer metadata for media the sniffer found first
 * upgrades the entry in place instead of duplicating it.
 */
export async function addCandidates(
  tabId: number,
  incoming: MediaCandidate[],
): Promise<MediaCandidate[]> {
  if (incoming.length === 0) return getCandidates(tabId);

  const snapshot = await readAll();
  const existing = snapshot[tabId] ?? [];
  const byId = new Map(existing.map((candidate) => [candidate.id, candidate]));

  for (const candidate of incoming) {
    const previous = byId.get(candidate.id);
    byId.set(candidate.id, previous ? mergeCandidate(previous, candidate) : candidate);
  }

  const merged = [...byId.values()]
    .sort((a, b) => b.detectedAt - a.detectedAt)
    .slice(0, MAX_PER_TAB);

  snapshot[tabId] = merged;
  await writeAll(snapshot);
  emit('candidates:changed', { tabId, candidates: merged });
  return merged;
}

/**
 * A later detection wins on metadata only where it actually has something —
 * the network sniffer knows a URL but not a title, the page adapter knows the
 * title but sometimes not every format.
 */
function mergeCandidate(previous: MediaCandidate, next: MediaCandidate): MediaCandidate {
  const formats = [...previous.formats];
  for (const format of next.formats) {
    const index = formats.findIndex((existing) => existing.id === format.id);
    if (index >= 0) formats[index] = { ...formats[index], ...format };
    else formats.push(format);
  }

  return {
    ...previous,
    ...next,
    title: next.title || previous.title,
    thumbnail: next.thumbnail ?? previous.thumbnail,
    durationSec: next.durationSec ?? previous.durationSec,
    author: next.author ?? previous.author,
    formats,
    // Only an adapter or the backend can clear the "needs resolving" flag.
    needsResolve: next.needsResolve ?? previous.needsResolve,
    detectedAt: Math.max(previous.detectedAt, next.detectedAt),
  };
}

export async function clearTab(tabId: number): Promise<void> {
  const snapshot = await readAll();
  if (!snapshot[tabId]) return;
  delete snapshot[tabId];
  await writeAll(snapshot);
  emit('candidates:changed', { tabId, candidates: [] });
}

/** Drops state for tabs that no longer exist, so session storage cannot grow forever. */
export async function pruneClosedTabs(): Promise<void> {
  const snapshot = await readAll();
  const openTabs = new Set((await chrome.tabs.query({})).map((tab) => tab.id));
  let changed = false;
  for (const key of Object.keys(snapshot)) {
    if (!openTabs.has(Number(key))) {
      delete snapshot[Number(key)];
      changed = true;
    }
  }
  if (changed) {
    await writeAll(snapshot);
    log.debug('pruned closed tabs from candidate store');
  }
}
