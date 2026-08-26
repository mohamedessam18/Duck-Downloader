import type { MediaCandidate, MediaFormat, MediaKind } from '@/core/types';
import { getSettings } from '@/core/settings';
import { log } from '@/core/logger';

/**
 * Client for the Duck backend (FastAPI + yt-dlp). This is the fallback half of
 * the hybrid engine: it only runs when local resolution fails, which keeps
 * server cost and platform rate-limiting proportional to the hard cases.
 *
 * Shapes mirror backend/app/models.py.
 */

interface BackendFormat {
  id: string;
  label: string;
  ext?: string | null;
  height?: number | null;
  width?: number | null;
  filesize?: number | null;
  acodec?: string | null;
  vcodec?: string | null;
}

interface ExtractResponse {
  title: string;
  thumbnail?: string | null;
  duration?: string | null;
  platform: string;
  qualities: BackendFormat[];
  audio_formats: BackendFormat[];
}

interface PlaylistItem {
  url: string;
  title: string;
  thumbnail?: string | null;
  width?: number | null;
  height?: number | null;
  source?: string | null;
  isPreview?: boolean;
  isVideo?: boolean;
}

interface PlaylistExtractResponse {
  title: string;
  platform: string;
  items: PlaylistItem[];
}

export interface StatusResponse {
  progress: number;
  speed?: string | null;
  eta?: string | null;
  status: string;
  fileUrl?: string | null;
  filename?: string | null;
  error?: string | null;
}

const TIMEOUT_MS = 30_000;

async function call<T>(path: string, init?: RequestInit): Promise<T> {
  const { backendUrl } = await getSettings();
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);

  try {
    const response = await fetch(`${backendUrl}${path}`, {
      ...init,
      signal: controller.signal,
      headers: {
        'content-type': 'application/json',
        // Ask for JSON explicitly: the backend's content-negotiation middleware
        // serves its HTML dashboard to anything that accepts text/html.
        accept: 'application/json',
        ...(init?.headers ?? {}),
      },
    });

    if (!response.ok) {
      const detail = await response.text().catch(() => '');
      throw new Error(`Backend ${response.status}: ${detail.slice(0, 200)}`);
    }
    return (await response.json()) as T;
  } finally {
    clearTimeout(timer);
  }
}

export async function extract(url: string): Promise<Partial<MediaCandidate>> {
  const data = await call<ExtractResponse>('/api/extract', {
    method: 'POST',
    body: JSON.stringify({ url }),
  });

  return {
    title: data.title,
    thumbnail: data.thumbnail ?? undefined,
    durationSec: parseDuration(data.duration),
    formats: [
      ...data.qualities.map((format) => toFormat(format, 'video')),
      ...data.audio_formats.map((format) => toFormat(format, 'audio')),
    ],
  };
}

/**
 * Enumerates every piece of media in a post.
 *
 * This is what makes an Instagram carousel work: one post can hold images,
 * videos, or both, and `/api/extract` only ever describes a single item. The
 * backend already maps each entry with an `isVideo` flag, so a hybrid post
 * comes back correctly typed rather than being forced into one kind.
 */
export async function extractPost(url: string): Promise<MediaCandidate[]> {
  const data = await call<PlaylistExtractResponse>('/api/playlist/extract', {
    method: 'POST',
    body: JSON.stringify({ url }),
  });

  return data.items
    // Preview entries are low-resolution stand-ins for the real media.
    .filter((item) => !item.isPreview)
    .map((item, index) => toCandidate(item, index, url, data));
}

function toCandidate(
  item: PlaylistItem,
  index: number,
  postUrl: string,
  post: PlaylistExtractResponse,
): MediaCandidate {
  const kind: MediaKind = item.isVideo ? 'video' : 'image';
  const ext = extensionOf(item.url) ?? (kind === 'video' ? 'mp4' : 'jpg');

  return {
    id: `post:${postUrl}#${index}`,
    platform: 'generic',
    // The item's own URL, so re-resolving it later hits the media directly
    // rather than re-enumerating the whole post.
    pageUrl: item.url,
    title: item.title || `${post.title} ${index + 1}`,
    thumbnail: item.thumbnail ?? (kind === 'image' ? item.url : undefined),
    formats: [
      {
        id: `post:${index}`,
        label: item.height ? `${item.height}p` : kind === 'image' ? 'Original' : 'Best',
        ext,
        kind,
        protocol: /\.m3u8(\?|$)/i.test(item.url) ? 'hls' : 'https',
        url: item.url,
        width: item.width ?? undefined,
        height: item.height ?? undefined,
        origin: 'backend-post',
      },
    ],
    source: 'backend',
    detectedAt: Date.now(),
    needsResolve: false,
  };
}

function extensionOf(url: string): string | null {
  try {
    return new URL(url).pathname.match(/\.([a-z0-9]{2,5})$/i)?.[1]?.toLowerCase() ?? null;
  } catch {
    return null;
  }
}

export async function startDownload(options: {
  url: string;
  type: MediaKind;
  quality?: string;
}): Promise<string> {
  const data = await call<{ downloadId: string }>('/api/download', {
    method: 'POST',
    body: JSON.stringify({
      url: options.url,
      type: options.type,
      quality: options.quality ?? null,
    }),
  });
  return data.downloadId;
}

export function getStatus(downloadId: string): Promise<StatusResponse> {
  return call<StatusResponse>(`/api/status/${downloadId}`);
}

export function cancelDownload(downloadId: string): Promise<StatusResponse> {
  return call<StatusResponse>(`/api/download/${downloadId}/cancel`, { method: 'POST' });
}

export function pauseDownload(downloadId: string): Promise<StatusResponse> {
  return call<StatusResponse>(`/api/download/${downloadId}/pause`, { method: 'POST' });
}

export function resumeDownload(downloadId: string): Promise<StatusResponse> {
  return call<StatusResponse>(`/api/download/${downloadId}/resume`, { method: 'POST' });
}

/**
 * Live progress over the backend's WebSocket. Returns a disposer.
 *
 * The socket is opened from the service worker, which can be torn down at any
 * time — the download manager therefore treats this as an optimisation and
 * keeps an HTTP poll as the source of truth.
 */
export async function watchProgress(
  downloadId: string,
  onUpdate: (status: StatusResponse) => void,
): Promise<() => void> {
  const { backendUrl } = await getSettings();
  const wsUrl = `${backendUrl.replace(/^http/, 'ws')}/ws/download/${downloadId}`;

  let socket: WebSocket | null = null;
  try {
    socket = new WebSocket(wsUrl);
    socket.onmessage = (event) => {
      try {
        onUpdate(JSON.parse(String(event.data)) as StatusResponse);
      } catch {
        /* keep-alive frames and other non-JSON payloads */
      }
    };
    socket.onerror = () => log.debug('progress socket error', downloadId);
  } catch (error) {
    log.warn('could not open progress socket', error);
  }

  return () => socket?.close();
}

export async function fileUrl(path: string): Promise<string> {
  if (/^https?:/i.test(path)) return path;
  const { backendUrl } = await getSettings();
  return `${backendUrl}${path.startsWith('/') ? '' : '/'}${path}`;
}

function toFormat(format: BackendFormat, kind: MediaKind): MediaFormat {
  return {
    id: `backend:${kind}:${format.id}`,
    label: format.label,
    ext: format.ext ?? (kind === 'audio' ? 'mp3' : 'mp4'),
    kind,
    protocol: 'https',
    height: format.height ?? undefined,
    width: format.width ?? undefined,
    filesize: format.filesize ?? undefined,
    vcodec: format.vcodec ?? undefined,
    acodec: format.acodec ?? undefined,
    // No URL: the backend downloads server-side and hands back a file path.
    origin: 'backend',
  };
}

/** Backend returns "H:MM:SS" or "MM:SS". */
function parseDuration(value?: string | null): number | undefined {
  if (!value) return undefined;
  const parts = value.split(':').map(Number);
  if (parts.some(Number.isNaN)) return undefined;
  return parts.reduce((total, part) => total * 60 + part, 0);
}
