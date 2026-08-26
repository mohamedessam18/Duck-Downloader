import type {
  JobRecipe,
  MediaKind,
  ResourceClass,
  ResourceVariant,
} from '../../../contracts/duck-protocol';
import { PROTOCOL_VERSION } from '../../../contracts/duck-protocol';
import type { MediaCandidate, MediaFormat } from '@/core/types';
import { sanitizeFilename } from '@/core/platform';

/**
 * Turns what the extension found into what the engine needs.
 *
 * This is the seam between the two halves of Duck, and the reason it exists as
 * its own step: the engine runs outside the browser, so anything it cannot
 * re-derive on its own has to be carried across now — the page the media came
 * from, the headers the CDN expects, and when the URL stops working.
 */
export function toRecipe(
  candidate: MediaCandidate,
  format: MediaFormat,
  options: { tabId?: number } = {},
): JobRecipe {
  const variant: ResourceVariant = {
    id: format.id,
    label: format.label,
    kind: toKind(format.kind),
    container: format.ext,
    url: format.url,
    audioUrl: format.audioUrl,
    width: format.width,
    height: format.height,
    bitrate: format.bitrate,
    size: format.filesize,
    codecs: [format.vcodec, format.acodec].filter(Boolean).join(', ') || undefined,
  };

  return {
    protocolVersion: PROTOCOL_VERSION,
    // Carries the format, so picking 1080p after 720p is a second job rather
    // than a silent no-op against the first.
    resourceId: `${candidate.id}#${format.id}`,
    resourceClass: classify(candidate, format),
    pageUrl: candidate.pageUrl,
    tabId: options.tabId,
    title: candidate.title,
    suggestedFilename: buildFilename(candidate, format),
    kind: toKind(format.kind),
    variant,
    requestContext: buildContext(candidate),
    capturedAt: candidate.detectedAt,
    expiresAt: expiryOf(format.url),
  };
}

function classify(candidate: MediaCandidate, format: MediaFormat): ResourceClass {
  if (candidate.isPost) return 'bundle';
  if (format.protocol === 'hls') return 'hls';
  if (format.protocol === 'dash') return 'dash';
  if (format.needsMux && format.audioUrl) return 'paired';
  return 'direct';
}

function toKind(kind: MediaFormat['kind']): MediaKind {
  return kind;
}

function buildFilename(candidate: MediaCandidate, format: MediaFormat): string {
  const base = sanitizeFilename(candidate.title).slice(0, 100);
  const suffix = format.kind === 'video' && format.label ? ` [${format.label}]` : '';
  return `${base}${suffix}`;
}

/**
 * The context a media CDN checks before serving.
 *
 * Referer and Origin only. Cookies and Authorization are deliberately absent:
 * a download that only works by replaying someone's session is the boundary
 * Duck does not cross, and the engine strips them again on its own side.
 */
function buildContext(candidate: MediaCandidate): JobRecipe['requestContext'] {
  try {
    const page = new URL(candidate.pageUrl);
    return { referer: candidate.pageUrl, origin: page.origin };
  } catch {
    return undefined;
  }
}

/**
 * Reads the expiry a signed media URL usually advertises.
 *
 * Knowing it in advance is what lets the engine ask the page for a fresh link
 * *before* spending an hour on a transfer that was always going to 403 —
 * `expire` is YouTube's, `Expires` is CloudFront's, `oe` appears on Facebook's
 * CDN as a hex timestamp.
 */
function expiryOf(url?: string): number | undefined {
  if (!url) return undefined;
  try {
    const params = new URL(url).searchParams;

    const seconds = params.get('expire') ?? params.get('Expires');
    if (seconds && /^\d+$/.test(seconds)) return Number(seconds) * 1000;

    const hex = params.get('oe');
    if (hex && /^[0-9a-f]+$/i.test(hex)) return parseInt(hex, 16) * 1000;

    return undefined;
  } catch {
    return undefined;
  }
}
