import type { MediaCandidate, MediaFormat, Settings } from '@/core/types';
import type { OverlayAnchor } from '@/detect/adapters';
import { sendMessage, StaleContextError } from '@/core/messaging';
import { log } from '@/core/logger';
import { OVERLAY_CSS } from './overlay.css';

/**
 * The floating download button.
 *
 * Rendered into a closed shadow root attached to a single host element that
 * lives at the end of <body>, positioned over each anchor. Two decisions worth
 * keeping:
 *
 *  - Closed shadow root: the page cannot reach in and restyle or remove the
 *    button, and our styles cannot leak out and break the site.
 *  - One host for all anchors, positioned absolutely, instead of injecting into
 *    each anchor's own subtree. Sites like X recycle feed nodes aggressively;
 *    anything we place inside them gets destroyed on scroll.
 */

const HOST_ID = 'duck-downloader-overlay-host';

interface Mounted {
  root: HTMLElement;
  button: HTMLButtonElement;
  anchor: OverlayAnchor;
}

export class Overlay {
  private host: HTMLElement | null = null;
  private shadow: ShadowRoot | null = null;
  private mounted = new Map<string, Mounted>();
  private candidates = new Map<string, MediaCandidate>();
  private settings: Settings;
  private frame: number | null = null;
  private observer: ResizeObserver | null = null;

  constructor(settings: Settings) {
    this.settings = settings;
  }

  updateSettings(settings: Settings): void {
    this.settings = settings;
    if (!settings.overlayEnabled) this.destroy();
  }

  setCandidates(candidates: MediaCandidate[]): void {
    this.candidates = new Map(candidates.map((candidate) => [candidate.id, candidate]));
  }

  /** Reconciles the rendered buttons against the anchors the adapter reports. */
  render(anchors: OverlayAnchor[]): void {
    if (!this.settings.overlayEnabled) return;
    this.ensureHost();

    const wanted = new Set(anchors.map((anchor) => anchor.candidateId));
    for (const [candidateId, entry] of this.mounted) {
      if (!wanted.has(candidateId)) {
        entry.root.remove();
        this.mounted.delete(candidateId);
      }
    }

    for (const anchor of anchors) {
      const existing = this.mounted.get(anchor.candidateId);
      if (existing) {
        existing.anchor = anchor;
        continue;
      }
      this.mount(anchor);
    }

    this.scheduleReposition();
  }

  private ensureHost(): void {
    if (this.host?.isConnected) return;

    // A re-injected script finds the previous version's host still in the page.
    // Leaving it there would stack a dead button under the live one.
    document.getElementById(HOST_ID)?.remove();

    this.host = document.createElement('div');
    this.host.id = HOST_ID;
    // The host itself must not participate in layout or intercept clicks.
    this.host.style.cssText =
      'position:absolute;top:0;left:0;width:0;height:0;pointer-events:none;';
    this.shadow = this.host.attachShadow({ mode: 'closed' });

    const style = document.createElement('style');
    style.textContent = OVERLAY_CSS;
    this.shadow.append(style);

    document.body.append(this.host);

    // Anchors move on scroll, resize, and every SPA re-layout.
    window.addEventListener('scroll', this.scheduleReposition, { passive: true, capture: true });
    window.addEventListener('resize', this.scheduleReposition, { passive: true });
    this.observer = new ResizeObserver(this.scheduleReposition);
    this.observer.observe(document.documentElement);
  }

  private mount(anchor: OverlayAnchor): void {
    if (!this.shadow) return;

    const root = document.createElement('div');
    root.className = 'duck-root';
    root.dataset.placement = anchor.placement ?? 'top-right';

    const candidate = this.candidates.get(anchor.candidateId);
    const isProtected = candidate?.isProtected === true;

    const button = document.createElement('button');
    button.className = 'duck-button';
    button.type = 'button';
    if (isProtected) {
      // Labelled before it is pressed: a Download button that always refuses is
      // worse than one that never claimed it could.
      button.classList.add('is-protected');
      button.title = 'This video is protected by DRM';
      button.append(lockIcon(), labelNode('Protected'));
    } else {
      button.append(downloadIcon(), labelNode('Download'));
    }
    button.addEventListener('click', (event) => {
      event.preventDefault();
      event.stopPropagation();
      void this.onDownloadClick(anchor.candidateId, button);
    });

    root.append(button);
    this.shadow.append(root);
    this.mounted.set(anchor.candidateId, { root, button, anchor });

    // Fade in only once the anchor is actually on screen.
    const visibility = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) root.classList.toggle('is-visible', entry.isIntersecting);
      },
      { threshold: 0.25 },
    );
    visibility.observe(anchor.element);
  }

  private scheduleReposition = (): void => {
    if (this.frame !== null) return;
    this.frame = requestAnimationFrame(() => {
      this.frame = null;
      this.reposition();
    });
  };

  private reposition(): void {
    for (const [candidateId, entry] of this.mounted) {
      const element = entry.anchor.element;
      if (!element.isConnected) {
        entry.root.remove();
        this.mounted.delete(candidateId);
        continue;
      }

      const box = element.getBoundingClientRect();
      if (box.width === 0 && box.height === 0) {
        entry.root.style.display = 'none';
        continue;
      }

      entry.root.style.display = '';
      // Document coordinates, so the button stays put while the page scrolls.
      entry.root.style.top = `${box.top + window.scrollY}px`;
      entry.root.style.left = `${box.left + window.scrollX}px`;
      entry.root.style.width = `${box.width}px`;
      entry.root.style.height = `${box.height}px`;
    }
  }

  private async onDownloadClick(candidateId: string, button: HTMLButtonElement): Promise<void> {
    const candidate = this.candidates.get(candidateId);
    if (!candidate) {
      this.toast(candidateId, 'Still detecting this video — try again in a moment.', 'error');
      return;
    }

    if (candidate.isProtected) {
      this.toast(
        candidateId,
        'This video is protected by DRM. The file itself is encrypted, so there is nothing Duck can save.',
        'error',
      );
      return;
    }

    setBusy(button, true);
    try {
      // A carousel has to be taken whole. Downloading "the video" here would
      // silently drop every other slide in the post.
      if (candidate.isPost) {
        const { started } = await sendMessage('download:post', {
          pageUrl: candidate.pageUrl,
          title: candidate.title,
        });
        this.toast(
          candidateId,
          started > 1 ? `Downloading ${started} items.` : 'Download started.',
        );
        return;
      }

      const format = this.pickFormat(candidate);
      if (!format) {
        // Nothing resolved yet and no preference to apply: let the popup drive.
        this.toast(candidateId, 'Open Duck Downloader to choose a quality.');
        return;
      }

      await sendMessage('download:start', { candidate, format });
      this.toast(candidateId, 'Download started.');
    } catch (error) {
      if (error instanceof StaleContextError) {
        // Not a failure the user caused, and not one they can act on beyond a
        // refresh — so say exactly that instead of leaking the raw message.
        this.toast(candidateId, error.message, 'error');
        return;
      }

      log.error('overlay download failed', error);
      this.toast(
        candidateId,
        error instanceof Error ? error.message : 'Could not start the download.',
        'error',
      );
    } finally {
      setBusy(button, false);
    }
  }

  /**
   * Chooses without asking, but only when the user has actually opted into
   * that. An unresolved candidate still gets a placeholder format so the
   * background can resolve and re-match it — see `pickEquivalent` in the
   * download manager.
   */
  private pickFormat(candidate: MediaCandidate): MediaFormat | null {
    if (!this.settings.oneClickDownload) {
      if (candidate.formats.length === 1) return candidate.formats[0]!;
      if (candidate.needsResolve) return placeholderFormat(this.settings.preferredHeight);
      return null;
    }

    const videos = candidate.formats.filter((format) => format.kind === 'video');
    if (videos.length === 0) return candidate.formats[0] ?? placeholderFormat(this.settings.preferredHeight);

    const preferred = this.settings.preferredHeight;
    if (preferred > 0) {
      const atOrBelow = videos
        .filter((format) => (format.height ?? 0) <= preferred)
        .sort((a, b) => (b.height ?? 0) - (a.height ?? 0));
      if (atOrBelow[0]) return atOrBelow[0];
    }

    return [...videos].sort((a, b) => (b.height ?? 0) - (a.height ?? 0))[0]!;
  }

  private toast(candidateId: string, message: string, tone: 'info' | 'error' = 'info'): void {
    const entry = this.mounted.get(candidateId);
    if (!entry) return;

    entry.root.querySelector('.duck-toast')?.remove();
    const toast = document.createElement('div');
    toast.className = 'duck-toast';
    toast.dataset.tone = tone;
    toast.textContent = message;
    entry.root.append(toast);
    setTimeout(() => toast.remove(), 3200);
  }

  destroy(): void {
    window.removeEventListener('scroll', this.scheduleReposition, { capture: true });
    window.removeEventListener('resize', this.scheduleReposition);
    this.observer?.disconnect();
    this.observer = null;
    this.mounted.clear();
    this.host?.remove();
    this.host = null;
    this.shadow = null;
  }
}

/**
 * Stand-in for "whatever the resolver decides is best". Carries the user's
 * height preference so the manager can match an equivalent real format once the
 * candidate resolves.
 */
function placeholderFormat(preferredHeight: number): MediaFormat {
  return {
    id: 'auto',
    label: preferredHeight > 0 ? `${preferredHeight}p` : 'Best',
    ext: 'mp4',
    kind: 'video',
    protocol: 'https',
    height: preferredHeight > 0 ? preferredHeight : undefined,
    origin: 'overlay-auto',
  };
}

function setBusy(button: HTMLButtonElement, busy: boolean): void {
  button.disabled = busy;
  button.replaceChildren(
    busy ? spinner() : downloadIcon(),
    labelNode(busy ? 'Starting…' : 'Download'),
  );
}

function labelNode(text: string): Node {
  const span = document.createElement('span');
  span.textContent = text;
  return span;
}

function spinner(): Node {
  const element = document.createElement('span');
  element.className = 'duck-spinner';
  return element;
}

function lockIcon(): Node {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('fill', 'none');
  svg.setAttribute('stroke', 'currentColor');
  svg.setAttribute('stroke-width', '2.2');
  svg.setAttribute('stroke-linecap', 'round');
  svg.setAttribute('stroke-linejoin', 'round');
  svg.setAttribute('aria-hidden', 'true');

  const body = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
  body.setAttribute('x', '3');
  body.setAttribute('y', '11');
  body.setAttribute('width', '18');
  body.setAttribute('height', '11');
  body.setAttribute('rx', '2');

  const shackle = document.createElementNS('http://www.w3.org/2000/svg', 'path');
  shackle.setAttribute('d', 'M7 11V7a5 5 0 0 1 10 0v4');

  svg.append(body, shackle);
  return svg;
}

function downloadIcon(): Node {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('fill', 'none');
  svg.setAttribute('stroke', 'currentColor');
  svg.setAttribute('stroke-width', '2.2');
  svg.setAttribute('stroke-linecap', 'round');
  svg.setAttribute('stroke-linejoin', 'round');
  svg.setAttribute('aria-hidden', 'true');

  const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
  path.setAttribute('d', 'M12 3v12m0 0 4.5-4.5M12 15l-4.5-4.5M4 17v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-2');
  svg.append(path);
  return svg;
}
