import type { RequestContext } from '../../../contracts/duck-protocol.js';

/**
 * What the server will actually give us, asked before committing to a strategy.
 *
 * Range support and content length decide whether the file can be split, and
 * whether resuming is possible at all. Guessing either one produces the classic
 * download-manager bug: a "resumed" file that is silently corrupt because the
 * server ignored the Range header and sent the whole body again.
 */
export interface ProbeResult {
  /** After redirects — the URL that must be used for every part. */
  finalUrl: string;
  status: number;
  contentType: string;
  /** 0 when the server did not say. */
  size: number;
  acceptsRanges: boolean;
  filename?: string;
  /** The server answered with a web page where media was expected. */
  looksLikeHtml: boolean;
}

export async function probe(
  url: string,
  context: RequestContext | undefined,
  signal: AbortSignal,
): Promise<ProbeResult> {
  // A one-byte ranged GET rather than HEAD: many media hosts reject HEAD on
  // signed URLs, and this proves range support instead of trusting the header.
  const response = await fetch(url, {
    method: 'GET',
    headers: { ...buildHeaders(context), range: 'bytes=0-0' },
    redirect: 'follow',
    signal,
  });

  // Read the single byte so the connection can be reused rather than reset.
  await response.arrayBuffer().catch(() => undefined);

  const contentType = (response.headers.get('content-type') ?? '').toLowerCase();
  const contentRange = response.headers.get('content-range');

  // 206 with a Content-Range is the only trustworthy proof of range support.
  const acceptsRanges =
    response.status === 206 &&
    /^bytes /i.test(contentRange ?? '') &&
    !/\/\*$/.test(contentRange ?? '');

  const size = acceptsRanges
    ? Number(contentRange?.match(/\/(\d+)$/)?.[1] ?? 0)
    : Number(response.headers.get('content-length') ?? 0);

  return {
    finalUrl: response.url || url,
    status: response.status,
    contentType,
    size: Number.isFinite(size) ? size : 0,
    acceptsRanges,
    filename: filenameFrom(response.headers.get('content-disposition')),
    looksLikeHtml: contentType.includes('text/html'),
  };
}

export function buildHeaders(context: RequestContext | undefined): Record<string, string> {
  const headers: Record<string, string> = {
    // Some CDNs serve a different body, or none, without an explicit accept.
    accept: '*/*',
  };
  if (context?.referer) headers.referer = context.referer;
  if (context?.origin) headers.origin = context.origin;
  for (const [key, value] of Object.entries(context?.headers ?? {})) {
    // Never replay credentials. See RequestContext in the contract.
    if (/^(cookie|authorization|proxy-authorization)$/i.test(key)) continue;
    headers[key.toLowerCase()] = value;
  }
  return headers;
}

/** RFC 5987 `filename*` wins over the plain form when both are present. */
function filenameFrom(header: string | null): string | undefined {
  if (!header) return undefined;

  const extended = header.match(/filename\*\s*=\s*[^']*'[^']*'([^;]+)/i)?.[1];
  if (extended) {
    try {
      return decodeURIComponent(extended.trim().replace(/^"|"$/g, ''));
    } catch {
      /* fall through to the plain form */
    }
  }

  const plain = header.match(/filename\s*=\s*("([^"]*)"|([^;]+))/i);
  return (plain?.[2] ?? plain?.[3])?.trim() || undefined;
}
