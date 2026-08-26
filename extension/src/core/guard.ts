import { log } from './logger';
import type { GuardStatus } from './guard-types';

/**
 * Content Guard: blocking that the user deliberately makes hard to undo.
 *
 * The design assumption is that the person who turns this on and the person who
 * later wants it off are the same person in two different moods. So the lock is
 * not really about secrecy — it is about *time*. A PIN alone is defeated by
 * remembering the PIN; a mandatory wait defeats the impulse that made someone
 * want it gone.
 *
 * What this can and cannot do is stated plainly in the UI: an extension can
 * always be removed from the browser's own extensions page. Making it truly
 * immovable needs an enterprise policy on the machine — see POLICY.md.
 */

const KEY = 'duck:guard';

/** Blocking rules live in a static ruleset toggled on and off wholesale. */
export const ADULT_RULESET_ID = 'adult';

export interface GuardState {
  enabled: boolean;
  /** PBKDF2 hash of the PIN. Null only while Guard has never been set up. */
  pinHash: string | null;
  pinSalt: string | null;
  /** How long a confirmed unlock has to wait before it takes effect. */
  cooldownHours: number;
  /** When the correct PIN was entered to begin an unlock; null when not pending. */
  unlockRequestedAt: number | null;
  /** Shown on the block page. The user's own words carry more weight than ours. */
  blockMessage: string;
  /** Extra domains the user chose to block, beyond the adult list. */
  customDomains: string[];
  safeSearch: boolean;
  feedFilter: boolean;
}

export const DEFAULT_GUARD: GuardState = {
  enabled: false,
  pinHash: null,
  pinSalt: null,
  cooldownHours: 24,
  unlockRequestedAt: null,
  blockMessage: 'You asked to be stopped here.',
  customDomains: [],
  safeSearch: true,
  feedFilter: true,
};

export async function getGuard(): Promise<GuardState> {
  const stored = await chrome.storage.local.get(KEY);
  return { ...DEFAULT_GUARD, ...(stored[KEY] as Partial<GuardState> | undefined) };
}

async function write(state: GuardState): Promise<GuardState> {
  await chrome.storage.local.set({ [KEY]: state });
  await applyRules(state);
  return state;
}

/**
 * PBKDF2 rather than a bare hash: a 4-digit PIN has 10,000 possibilities, and a
 * plain SHA-256 of all of them is computed faster than this sentence is read.
 * 250k iterations makes an offline sweep of the storage value tedious rather
 * than instant.
 */
const ITERATIONS = 250_000;

async function hashPin(pin: string, saltHex: string): Promise<string> {
  const encoder = new TextEncoder();
  const salt = Uint8Array.from(saltHex.match(/.{2}/g)!.map((byte) => parseInt(byte, 16)));

  const key = await crypto.subtle.importKey('raw', encoder.encode(pin), 'PBKDF2', false, [
    'deriveBits',
  ]);
  const bits = await crypto.subtle.deriveBits(
    { name: 'PBKDF2', salt: salt as BufferSource, iterations: ITERATIONS, hash: 'SHA-256' },
    key,
    256,
  );
  return [...new Uint8Array(bits)].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

function randomSalt(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return [...bytes].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

export async function enableGuard(options: {
  pin: string;
  cooldownHours: number;
  blockMessage?: string;
}): Promise<GuardState> {
  const salt = randomSalt();
  const current = await getGuard();

  return write({
    ...current,
    enabled: true,
    pinHash: await hashPin(options.pin, salt),
    pinSalt: salt,
    cooldownHours: options.cooldownHours,
    unlockRequestedAt: null,
    blockMessage: options.blockMessage?.trim() || current.blockMessage,
  });
}

export async function verifyPin(pin: string): Promise<boolean> {
  const state = await getGuard();
  if (!state.pinHash || !state.pinSalt) return false;
  return (await hashPin(pin, state.pinSalt)) === state.pinHash;
}

/** Starts the wait. Guard stays fully active until it elapses. */
export async function requestUnlock(pin: string): Promise<GuardState> {
  if (!(await verifyPin(pin))) throw new Error('Wrong PIN.');
  const state = await getGuard();
  if (state.unlockRequestedAt) return state;
  return write({ ...state, unlockRequestedAt: Date.now() });
}

export async function cancelUnlock(): Promise<GuardState> {
  const state = await getGuard();
  return write({ ...state, unlockRequestedAt: null });
}

export function unlockReadyAt(state: GuardState): number | null {
  if (!state.unlockRequestedAt) return null;
  return state.unlockRequestedAt + state.cooldownHours * 3_600_000;
}

export function msUntilUnlock(state: GuardState): number | null {
  const readyAt = unlockReadyAt(state);
  return readyAt === null ? null : Math.max(0, readyAt - Date.now());
}

/** Completes an unlock, but only once the wait has actually elapsed. */
export async function completeUnlock(): Promise<GuardState> {
  const state = await getGuard();
  const remaining = msUntilUnlock(state);
  if (remaining === null) throw new Error('No unlock is pending.');
  if (remaining > 0) throw new Error('The waiting period has not finished yet.');

  return write({ ...state, enabled: false, unlockRequestedAt: null });
}

/** Settings that only tighten protection need no PIN; loosening always does. */
export async function updateGuard(
  patch: Partial<Pick<GuardState, 'blockMessage' | 'customDomains' | 'safeSearch' | 'feedFilter'>>,
  pin?: string,
): Promise<GuardState> {
  const state = await getGuard();

  const loosening =
    (patch.safeSearch === false && state.safeSearch) ||
    (patch.feedFilter === false && state.feedFilter) ||
    (patch.customDomains !== undefined &&
      state.customDomains.some((domain) => !patch.customDomains!.includes(domain)));

  if (state.enabled && loosening) {
    if (!pin || !(await verifyPin(pin))) throw new Error('That change needs the PIN.');
  }

  return write({ ...state, ...patch });
}

/**
 * Pushes the current state into the browser's own request rules.
 *
 * Blocking happens in the network stack, before the page reaches the renderer.
 * A content script could only hide a page that had already loaded.
 */
export async function applyRules(state: GuardState): Promise<void> {
  try {
    await chrome.declarativeNetRequest.updateEnabledRulesets(
      state.enabled
        ? { enableRulesetIds: [ADULT_RULESET_ID] }
        : { disableRulesetIds: [ADULT_RULESET_ID] },
    );
    await applyDynamicRules(state);
  } catch (error) {
    log.error('could not apply guard rules', error);
  }
}

/** Ids above this range belong to the static adult ruleset. */
const DYNAMIC_ID_BASE = 100_000;

async function applyDynamicRules(state: GuardState): Promise<void> {
  const existing = await chrome.declarativeNetRequest.getDynamicRules();
  const removeRuleIds = existing.map((rule) => rule.id);

  const addRules: chrome.declarativeNetRequest.Rule[] = [];
  let id = DYNAMIC_ID_BASE;

  if (state.enabled) {
    for (const domain of state.customDomains) {
      addRules.push({
        id: id++,
        priority: 1,
        action: {
          type: 'redirect' as chrome.declarativeNetRequest.RuleActionType,
          redirect: { extensionPath: '/blocked.html' },
        },
        condition: {
          urlFilter: `||${domain}^`,
          resourceTypes: ['main_frame' as chrome.declarativeNetRequest.ResourceType],
        },
      });
    }

    if (state.safeSearch) addRules.push(...safeSearchRules(() => id++));
  }

  await chrome.declarativeNetRequest.updateDynamicRules({ removeRuleIds, addRules });
}

/**
 * Forces the search engines' own filters on.
 *
 * This matters more than blocking sites: a filtered results page never offers
 * the link in the first place, so there is nothing to resist. Google and
 * DuckDuckGo honour a query parameter; Bing and YouTube take a header that their
 * servers apply account-wide for the request.
 */
function safeSearchRules(nextId: () => number): chrome.declarativeNetRequest.Rule[] {
  const redirect = (
    id: number,
    urlFilter: string,
    key: string,
    value: string,
  ): chrome.declarativeNetRequest.Rule => ({
    id,
    priority: 2,
    action: {
      type: 'redirect' as chrome.declarativeNetRequest.RuleActionType,
      redirect: { transform: { queryTransform: { addOrReplaceParams: [{ key, value }] } } },
    },
    condition: {
      urlFilter,
      resourceTypes: ['main_frame' as chrome.declarativeNetRequest.ResourceType],
    },
  });

  const header = (
    id: number,
    urlFilter: string,
    headerName: string,
    headerValue: string,
  ): chrome.declarativeNetRequest.Rule => ({
    id,
    priority: 2,
    action: {
      type: 'modifyHeaders' as chrome.declarativeNetRequest.RuleActionType,
      requestHeaders: [
        {
          header: headerName,
          operation: 'set' as chrome.declarativeNetRequest.HeaderOperation,
          value: headerValue,
        },
      ],
    },
    condition: {
      urlFilter,
      resourceTypes: [
        'main_frame' as chrome.declarativeNetRequest.ResourceType,
        'xmlhttprequest' as chrome.declarativeNetRequest.ResourceType,
      ],
    },
  });

  return [
    redirect(nextId(), '||google.com/search', 'safe', 'active'),
    redirect(nextId(), '||duckduckgo.com/', 'kp', '1'),
    header(nextId(), '||bing.com/', 'Sec-Ch-Safe-Search', 'strict'),
    // YouTube's restricted mode is a request header its servers honour.
    header(nextId(), '||youtube.com/', 'YouTube-Restrict', 'Strict'),
  ];
}

/** The PIN hash never leaves this module. */
export function toStatus(state: GuardState): GuardStatus {
  return {
    enabled: state.enabled,
    configured: state.pinHash !== null,
    cooldownHours: state.cooldownHours,
    pendingUnlock: state.unlockRequestedAt !== null,
    msUntilUnlock: msUntilUnlock(state),
    blockMessage: state.blockMessage,
    customDomains: state.customDomains,
    safeSearch: state.safeSearch,
    feedFilter: state.feedFilter,
  };
}

/** Re-applies rules on startup, since rulesets do not persist by themselves. */
export async function restoreGuard(): Promise<void> {
  const state = await getGuard();
  await applyRules(state);
  if (state.enabled) log.info('content guard active');
}
