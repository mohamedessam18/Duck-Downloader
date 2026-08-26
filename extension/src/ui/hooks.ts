import { useCallback, useEffect, useState } from 'react';
import type { DownloadJob, MediaCandidate, Settings } from '@/core/types';
import type { JobRecord } from '../../../contracts/duck-protocol';
import type { EngineStatus } from '@/engine/client';
import { DEFAULT_SETTINGS } from '@/core/types';
import { onEvent, sendMessage } from '@/core/messaging';

/** The tab the popup/side panel is acting on. */
export function useActiveTab(): chrome.tabs.Tab | null {
  const [tab, setTab] = useState<chrome.tabs.Tab | null>(null);

  useEffect(() => {
    void chrome.tabs
      .query({ active: true, currentWindow: true })
      .then(([found]) => setTab(found ?? null));
  }, []);

  return tab;
}

export function useCandidates(tabId?: number): {
  candidates: MediaCandidate[];
  loading: boolean;
  rescan: () => void;
} {
  const [candidates, setCandidates] = useState<MediaCandidate[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    if (tabId === undefined) return;
    let cancelled = false;

    void sendMessage('candidates:query', { tabId }).then((found) => {
      if (!cancelled) {
        setCandidates(found);
        setLoading(false);
      }
    });

    // The content script keeps detecting while the popup is open, so the list
    // fills in live rather than being frozen at open time.
    return onEvent('candidates:changed', (payload) => {
      if (payload.tabId === tabId) setCandidates(payload.candidates);
    });
  }, [tabId]);

  const rescan = useCallback(() => {
    if (tabId === undefined) return;
    setLoading(true);
    void sendMessage('candidates:rescan', { tabId }).then((found) => {
      setCandidates(found);
      setLoading(false);
    });
  }, [tabId]);

  useEffect(() => {
    if (!loading) return;
    const timer = setTimeout(() => setLoading(false), 2500);
    return () => clearTimeout(timer);
  }, [loading]);

  return { candidates, loading, rescan };
}

export function useJobs(): DownloadJob[] {
  const [jobs, setJobs] = useState<DownloadJob[]>([]);

  useEffect(() => {
    void sendMessage('jobs:query', {}).then(setJobs);
    return onEvent('jobs:changed', setJobs);
  }, []);

  return jobs;
}

export function useSettings(): [Settings, (patch: Partial<Settings>) => void] {
  const [settings, setSettings] = useState<Settings>(DEFAULT_SETTINGS);

  useEffect(() => {
    void sendMessage('settings:get', {}).then(setSettings);
  }, []);

  const update = useCallback((patch: Partial<Settings>) => {
    setSettings((current) => ({ ...current, ...patch }));
    void sendMessage('settings:set', { patch });
  }, []);

  return [settings, update];
}

/**
 * Tracks whether the extension may act on the current tab's origin.
 *
 * Sites outside the shipped host permissions are opt-in, so the popup has to be
 * able to ask — and asking must happen inside a user gesture, which is why
 * `request` is returned rather than called automatically.
 */
export function useSitePermission(url?: string): {
  granted: boolean | null;
  origin: string | null;
  request: () => Promise<boolean>;
} {
  const [granted, setGranted] = useState<boolean | null>(null);
  const origin = originOf(url);

  useEffect(() => {
    if (!origin) {
      setGranted(false);
      return;
    }
    void chrome.permissions.contains({ origins: [origin] }).then(setGranted);
  }, [origin]);

  const request = useCallback(async () => {
    if (!origin) return false;
    const result = await chrome.permissions.request({ origins: [origin] });
    setGranted(result);
    if (result) {
      const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
      // The content script was never injected into a site we had no access to,
      // so a reload is what actually starts detection.
      if (tab?.id !== undefined) await chrome.tabs.reload(tab.id);
    }
    return result;
  }, [origin]);

  return { granted, origin, request };
}

function originOf(url?: string): string | null {
  if (!url) return null;
  try {
    const parsed = new URL(url);
    if (!parsed.protocol.startsWith('http')) return null;
    return `${parsed.protocol}//${parsed.hostname}/*`;
  } catch {
    return null;
  }
}


/**
 * Jobs owned by Duck Engine.
 *
 * Returns `null` while the engine's availability is still unknown, so the UI can
 * tell "not installed" apart from "installed with nothing queued" — those need
 * very different messages.
 */
export function useEngineJobs(): { jobs: JobRecord[] | null; status: EngineStatus | null } {
  const [jobs, setJobs] = useState<JobRecord[] | null>(null);
  const [status, setStatus] = useState<EngineStatus | null>(null);

  useEffect(() => {
    let cancelled = false;

    void sendMessage('engine:status', {}).then((found) => {
      if (cancelled) return;
      setStatus(found);
      if (!found.connected) {
        setJobs([]);
        return;
      }
      void sendMessage('engine:jobs', {}).then((list) => {
        if (!cancelled) setJobs(list);
      });
    });

    // The engine pushes; nothing here polls.
    const stop = onEvent('engine:changed', (list) => setJobs(list));
    return () => {
      cancelled = true;
      stop();
    };
  }, []);

  return { jobs, status };
}
