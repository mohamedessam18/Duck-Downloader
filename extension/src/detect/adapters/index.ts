import type { Settings } from '@/core/types';
import { genericAdapter } from './generic';
import { instagramAdapter } from './instagram';
import { twitterAdapter } from './twitter';
import { youtubeAdapter } from './youtube';
import type { PageAdapter } from './types';

/** Specific adapters first; the generic one is the fallback and always matches. */
const ADAPTERS: PageAdapter[] = [
  youtubeAdapter,
  twitterAdapter,
  instagramAdapter,
  genericAdapter,
];

export function adapterFor(url: string, settings: Settings): PageAdapter {
  for (const adapter of ADAPTERS) {
    if (adapter.platform === 'youtube' && !settings.youtubeEnabled) continue;
    if (adapter.matches(url)) return adapter;
  }
  return genericAdapter;
}

export type { PageAdapter, OverlayAnchor } from './types';
