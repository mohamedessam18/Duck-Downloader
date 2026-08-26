import { log } from '@/core/logger';

/**
 * Hides content the platform itself has flagged as sensitive.
 *
 * X, Reddit and Instagram are not adult sites and blocking them wholesale would
 * be absurd — but each marks its own explicit content, and each offers to reveal
 * it behind one click. This removes those posts rather than relying on the
 * platform's own toggle, which the user can flip in a moment of weakness.
 *
 * Signals used are the platforms' own, never our guesswork about the media:
 *   - X wraps sensitive media in an interstitial with a known test id.
 *   - Reddit marks posts with an `nsfw` attribute or badge.
 *   - Instagram overlays a "Sensitive Content" cover.
 *
 * A blur would still leave the image loaded and one CSS edit away. These are
 * removed from the document instead.
 */

const SELECTORS: Array<{ host: RegExp; find: string[] }> = [
  {
    host: /(^|\.)(twitter|x)\.com$/i,
    find: [
      '[data-testid="sensitiveMediaInterstitial"]',
      '[data-testid="sensitive-media-warning"]',
    ],
  },
  {
    host: /(^|\.)reddit\.com$/i,
    find: ['[data-nsfw="true"]', 'shreddit-post[nsfw]', '.promotedlink.nsfw', '[data-blurred="true"]'],
  },
  {
    host: /(^|\.)instagram\.com$/i,
    // Instagram labels the cover in the accessible name rather than a test id.
    find: ['[aria-label*="Sensitive" i]', '[aria-label*="sensitive content" i]'],
  },
];

/** Climbs to the post that owns the warning, so the whole item goes, not the cover. */
const POST_CONTAINERS = 'article, shreddit-post, [data-testid="cellInnerDiv"], [role="article"]';

export function startFeedFilter(): () => void {
  const active = SELECTORS.filter((entry) => entry.host.test(location.hostname));
  if (active.length === 0) return () => {};

  const selector = active.flatMap((entry) => entry.find).join(', ');
  let removed = 0;

  const sweep = () => {
    for (const warning of document.querySelectorAll<HTMLElement>(selector)) {
      const post = warning.closest<HTMLElement>(POST_CONTAINERS) ?? warning;
      if (!post.isConnected) continue;
      post.replaceWith(placeholder());
      removed++;
    }
  };

  sweep();

  // Feeds are infinite: new posts stream in for as long as the tab is open.
  const observer = new MutationObserver(() => sweep());
  observer.observe(document.documentElement, { childList: true, subtree: true });

  log.debug('feed filter active for', location.hostname);
  return () => {
    observer.disconnect();
    log.debug(`feed filter removed ${removed} flagged posts`);
  };
}

/**
 * Leaves a marker rather than a silent gap. A feed that visibly jumps is
 * confusing; a line saying something was removed is honest and reassuring.
 */
function placeholder(): HTMLElement {
  const node = document.createElement('div');
  node.style.cssText = [
    'padding:14px 16px',
    'margin:8px 0',
    'border:1px dashed rgba(128,128,140,0.45)',
    'border-radius:12px',
    'font:13px ui-sans-serif,system-ui,sans-serif',
    'color:#8d8d9b',
    'text-align:center',
  ].join(';');
  node.textContent = 'Sensitive post hidden by Duck Content Guard';
  return node;
}
