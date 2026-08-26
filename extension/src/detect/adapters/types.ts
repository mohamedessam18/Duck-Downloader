import type { MediaCandidate, Platform } from '@/core/types';

/**
 * A page adapter's job is identity and metadata — which media is on this page,
 * what it is called, what it looks like. Resolving playable URLs is deliberately
 * *not* its job: that happens in the background worker where we have host
 * permissions and no page CSP to fight.
 */
export interface PageAdapter {
  platform: Platform;
  matches(url: string): boolean;
  detect(): MediaCandidate[];
  /**
   * Elements the floating download button should attach to. Returning several
   * is normal on feed pages, where every post is its own candidate.
   */
  anchors?(): OverlayAnchor[];
}

export interface OverlayAnchor {
  /** The element the button is positioned against. */
  element: HTMLElement;
  candidateId: string;
  /** Corner placement within the anchor. */
  placement?: 'top-right' | 'bottom-right' | 'bottom-left';
}
