import type { DownloadJob, MediaCandidate, MediaFormat, Settings } from './types';
import type { GuardStatus } from './guard-types';
import type { JobRecord } from '../../../contracts/duck-protocol';
import type { EngineStatus } from '@/engine/client';
import { log } from './logger';

/**
 * Typed request/response contract for every runtime message in the extension.
 * Adding a channel here is the only place a new message shape gets declared, so
 * the content script and the background worker can never drift apart.
 */
export interface Protocol {
  'candidates:report': { req: { candidates: MediaCandidate[] }; res: void };
  'candidates:query': { req: { tabId?: number }; res: MediaCandidate[] };
  'candidates:rescan': { req: { tabId: number }; res: MediaCandidate[] };
  'download:start': {
    req: { candidate: MediaCandidate; format: MediaFormat };
    res: { jobId: string };
  };
  /**
   * Download every item in a post in one action. What the overlay button does
   * on a carousel, where downloading "the video" would silently drop the other
   * eleven slides.
   */
  'download:post': { req: { pageUrl: string; title?: string }; res: { started: number } };
  'download:cancel': { req: { jobId: string }; res: void };
  'download:pause': { req: { jobId: string }; res: void };
  'download:resume': { req: { jobId: string }; res: void };
  'download:remove': { req: { jobId: string }; res: void };
  'jobs:query': { req: Record<string, never>; res: DownloadJob[] };
  'settings:get': { req: Record<string, never>; res: Settings };
  'settings:set': { req: { patch: Partial<Settings> }; res: Settings };
  /**
   * Engine access is proxied through the background on purpose. A native port
   * opened per UI surface would spawn a bridge process every time the popup is
   * opened; one port in the worker keeps it to a single connection.
   */
  'engine:status': { req: Record<string, never>; res: EngineStatus };
  'engine:jobs': { req: Record<string, never>; res: JobRecord[] };
  'engine:action': {
    req: { action: 'pause' | 'resume' | 'cancel' | 'remove' | 'retry' | 'reveal'; jobId: string };
    res: void;
  };
  /** Runs the InnerTube probe inside the page, using the signed-in session. */
  'diagnose:youtube': {
    req: { tabId?: number };
    res: { status: string; reason?: string; playable: number; total: number } | null;
  };
  'guard:status': { req: Record<string, never>; res: GuardStatus };
  'guard:enable': {
    req: { pin: string; cooldownHours: number; blockMessage?: string };
    res: GuardStatus;
  };
  'guard:requestUnlock': { req: { pin: string }; res: GuardStatus };
  'guard:cancelUnlock': { req: Record<string, never>; res: GuardStatus };
  'guard:completeUnlock': { req: Record<string, never>; res: GuardStatus };
  'guard:update': {
    req: {
      patch: Partial<Pick<GuardStatus, 'blockMessage' | 'customDomains' | 'safeSearch' | 'feedFilter'>>;
      pin?: string;
    };
    res: GuardStatus;
  };
  /** Content script asking the worker to open the side panel (needs a user gesture). */
  'panel:open': { req: { tabId: number }; res: void };
  /**
   * Worker asking a youtube.com content script to resolve formats on its
   * behalf, so the request goes out same-origin with the user's session.
   */
  'resolve:youtube': {
    req: { videoId: string };
    res: Partial<MediaCandidate> | null;
  };
  /**
   * Worker asking the offscreen document to merge a video and an audio track.
   * Acknowledged immediately; the outcome arrives as a `mux:done` /
   * `mux:failed` event, because a merge can outlive a message port.
   */
  'mux:run': {
    req: { jobId: string; videoUrl: string; audioUrl: string; container: string };
    res: void;
  };
  'mux:cancel': { req: { jobId: string }; res: void };
  /**
   * Resolve whatever media a page holds from its URL alone — the escape hatch
   * for players that expose nothing scrapeable.
   *
   * Returns a list because one link is not one file: an Instagram carousel is
   * several images, several videos, or a mix of both, and every one of them has
   * to be individually downloadable.
   */
  'resolve:page': { req: { pageUrl: string; title?: string }; res: MediaCandidate[] };
  /** Releases an object URL once the browser has finished saving it. */
  'mux:revoke': { req: { objectUrl: string }; res: void };
}

export type Channel = keyof Protocol;

interface Envelope<K extends Channel> {
  __duck: true;
  channel: K;
  payload: Protocol[K]['req'];
}

/** Broadcast-only events, fire-and-forget, no response expected. */
export interface EventMap {
  'jobs:changed': DownloadJob[];
  /** Pushed whenever the engine reports a change, so the UI never polls. */
  'engine:changed': JobRecord[];
  'candidates:changed': { tabId: number; candidates: MediaCandidate[] };
  'mux:progress': {
    jobId: string;
    phase: 'fetching' | 'merging';
    progress: number;
    receivedBytes?: number;
    totalBytes?: number;
  };
  'mux:done': { jobId: string; objectUrl: string; bytes: number };
  'mux:failed': { jobId: string; error: string };
}

interface EventEnvelope<K extends keyof EventMap> {
  __duckEvent: true;
  event: K;
  payload: EventMap[K];
}

function isEnvelope(value: unknown): value is Envelope<Channel> {
  return typeof value === 'object' && value !== null && '__duck' in value;
}

function isEventEnvelope(value: unknown): value is EventEnvelope<keyof EventMap> {
  return typeof value === 'object' && value !== null && '__duckEvent' in value;
}

/** Thrown when the page is running a content script from a replaced version. */
export class StaleContextError extends Error {
  constructor() {
    super('Duck was updated. Reload this page to use it here.');
    this.name = 'StaleContextError';
  }
}

export async function sendMessage<K extends Channel>(
  channel: K,
  payload: Protocol[K]['req'],
): Promise<Protocol[K]['res']> {
  const envelope: Envelope<K> = { __duck: true, channel, payload };

  let reply: unknown;
  try {
    reply = await chrome.runtime.sendMessage(envelope);
  } catch (error) {
    // Reloading the extension leaves the previous content script running in
    // every open tab with a dead `chrome.runtime` handle. Nothing can be done
    // from inside that script except tell the user to reload the page.
    if (/context invalidated|Extension context/i.test(String(error))) {
      throw new StaleContextError();
    }
    throw error;
  }

  if (reply && typeof reply === 'object' && 'error' in reply) {
    throw new Error(String((reply as { error: unknown }).error));
  }
  return (reply as { data: Protocol[K]['res'] } | undefined)?.data as Protocol[K]['res'];
}

/** Same as `sendMessage`, but targeted at a specific tab's content script. */
export async function sendToTab<K extends Channel>(
  tabId: number,
  channel: K,
  payload: Protocol[K]['req'],
): Promise<Protocol[K]['res'] | undefined> {
  try {
    const envelope: Envelope<K> = { __duck: true, channel, payload };
    const reply = await chrome.tabs.sendMessage(tabId, envelope);
    return (reply as { data: Protocol[K]['res'] } | undefined)?.data;
  } catch {
    // No content script in that tab (chrome:// page, not-yet-injected, closed).
    return undefined;
  }
}

type Handler<K extends Channel> = (
  payload: Protocol[K]['req'],
  sender: chrome.runtime.MessageSender,
) => Promise<Protocol[K]['res']> | Protocol[K]['res'];

/**
 * Handlers are stored with their payload types erased. Each entry was type-safe
 * at registration, but a Map cannot carry the per-key relationship, so the cast
 * is confined to this one line rather than leaking into every call site.
 */
type ErasedHandler = (payload: never, sender: chrome.runtime.MessageSender) => unknown;

const handlers = new Map<Channel, ErasedHandler>();
let listening = false;

/**
 * Registers the single runtime.onMessage listener the first time it is needed.
 * One listener that dispatches beats N listeners racing to answer: only one
 * `sendResponse` can win, and MV3 gives no warning when they collide.
 */
export function onMessage<K extends Channel>(channel: K, handler: Handler<K>): void {
  handlers.set(channel, handler as ErasedHandler);
  if (listening) return;
  listening = true;

  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (!isEnvelope(message)) return false;
    const found = handlers.get(message.channel);
    if (!found) return false;

    Promise.resolve(found(message.payload as never, sender))
      .then((data) => sendResponse({ data }))
      .catch((error: unknown) => {
        log.error('handler failed', message.channel, error);
        sendResponse({ error: error instanceof Error ? error.message : String(error) });
      });

    // Keeps the message port open for the async reply above.
    return true;
  });
}

export function emit<K extends keyof EventMap>(event: K, payload: EventMap[K]): void {
  const envelope: EventEnvelope<K> = { __duckEvent: true, event, payload };
  // No receiver is a normal state (no popup open), so the rejection is expected.
  chrome.runtime.sendMessage(envelope).catch(() => {});
}

export function onEvent<K extends keyof EventMap>(
  event: K,
  handler: (payload: EventMap[K]) => void,
): () => void {
  const listener = (message: unknown) => {
    if (!isEventEnvelope(message) || message.event !== event) return;
    handler(message.payload as EventMap[K]);
  };
  chrome.runtime.onMessage.addListener(listener);
  return () => chrome.runtime.onMessage.removeListener(listener);
}
