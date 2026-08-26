import type { MediaCandidate, MediaFormat } from '@/core/types';
import { log } from '@/core/logger';

/**
 * YouTube format resolution through InnerTube (the API YouTube's own clients use).
 *
 * Not scraping the watch page on purpose: desktop web responses hand back
 * formats behind `signatureCipher`, undoable only by running YouTube's player
 * JS — a moving target and, decisively, remote code, which MV3 forbids. The
 * ANDROID_VR client context returns plain `url` fields with no cipher.
 *
 * Measured behaviour (probed against live YouTube while building this):
 *   - IOS and ANDROID contexts now answer 400 "Precondition check failed"
 *     unless the request carries the matching app User-Agent — and `User-Agent`
 *     is a forbidden header for `fetch`, so an extension cannot set it. Both are
 *     therefore useless here and are not attempted.
 *   - TVHTML5_SIMPLY_EMBEDDED_PLAYER and WEB_EMBEDDED_PLAYER answer ERROR.
 *   - ANDROID_VR answers OK with every format uncipher-ed, and needs no
 *     User-Agent — but anonymously it returns LOGIN_REQUIRED for most videos.
 *
 * That last point drives the design: the request is issued from the content
 * script running on youtube.com with `credentials: 'include'`, so it carries the
 * user's own session exactly as the page's own requests do. The background
 * worker can only ever make it anonymously, which is why it is the second
 * choice and the backend is the third.
 */

const CLIENT = {
  clientName: 'ANDROID_VR',
  clientVersion: '1.60.19',
  deviceMake: 'Oculus',
  deviceModel: 'Quest 3',
  androidSdkVersion: 32,
  osName: 'Android',
  osVersion: '12L',
  hl: 'en',
  gl: 'US',
} as const;

const CLIENT_ID = '28';
const INNERTUBE_KEY = 'AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8';
const ENDPOINT = `https://www.youtube.com/youtubei/v1/player?key=${INNERTUBE_KEY}&prettyPrint=false`;

interface RawFormat {
  itag: number;
  url?: string;
  signatureCipher?: string;
  mimeType: string;
  bitrate?: number;
  width?: number;
  height?: number;
  fps?: number;
  contentLength?: string;
  qualityLabel?: string;
}

interface PlayerResponse {
  playabilityStatus?: { status?: string; reason?: string };
  streamingData?: { formats?: RawFormat[]; adaptiveFormats?: RawFormat[] };
  videoDetails?: {
    title?: string;
    author?: string;
    lengthSeconds?: string;
    thumbnail?: { thumbnails?: Array<{ url: string; width: number }> };
  };
}

export interface ResolveOptions {
  /**
   * 'include' when called from a content script on youtube.com — the request is
   * same-origin there and the session is what lifts LOGIN_REQUIRED.
   * 'omit' anywhere else.
   */
  credentials: RequestCredentials;
}

export interface YouTubeProbe {
  /** InnerTube's own verdict: OK, LOGIN_REQUIRED, ERROR, UNPLAYABLE… */
  status: string;
  reason?: string;
  /** Formats that came back with a usable, uncipher-ed URL. */
  playable: number;
  total: number;
}

/**
 * Asks InnerTube what it would give us, and reports the answer verbatim.
 *
 * Whether YouTube can be resolved without a server depends entirely on the
 * session making the request, and that cannot be tested from anywhere except
 * the user's own signed-in browser. This turns that question into a button
 * rather than a copy-pasted console snippet.
 */
export async function probeYouTube(
  videoId: string,
  options: ResolveOptions,
): Promise<YouTubeProbe> {
  try {
    const response = await requestPlayer(videoId, options);
    const adaptive = response.streamingData?.adaptiveFormats ?? [];
    const muxed = response.streamingData?.formats ?? [];
    const all = [...muxed, ...adaptive];

    return {
      status: response.playabilityStatus?.status ?? 'UNKNOWN',
      reason: response.playabilityStatus?.reason,
      playable: all.filter((format) => format.url && !format.signatureCipher).length,
      total: all.length,
    };
  } catch (error) {
    return {
      status: 'REQUEST_FAILED',
      reason: error instanceof Error ? error.message : String(error),
      playable: 0,
      total: 0,
    };
  }
}

export async function resolveYouTube(
  videoId: string,
  options: ResolveOptions,
): Promise<Partial<MediaCandidate> | null> {
  let response: PlayerResponse;
  try {
    response = await requestPlayer(videoId, options);
  } catch (error) {
    log.debug('innertube request failed', error);
    return null;
  }

  const status = response.playabilityStatus?.status;
  if (status && status !== 'OK') {
    log.debug(`innertube not playable: ${status} (${response.playabilityStatus?.reason ?? ''})`);
    return null;
  }

  const formats = buildFormats(response);
  if (formats.length === 0) {
    log.debug('innertube returned no uncipher-ed formats');
    return null;
  }

  return {
    title: response.videoDetails?.title,
    author: response.videoDetails?.author,
    durationSec: Number(response.videoDetails?.lengthSeconds) || undefined,
    thumbnail: bestThumbnail(response),
    formats,
    needsResolve: false,
  };
}

async function requestPlayer(videoId: string, options: ResolveOptions): Promise<PlayerResponse> {
  const response = await fetch(ENDPOINT, {
    method: 'POST',
    credentials: options.credentials,
    headers: {
      'content-type': 'application/json',
      'x-youtube-client-name': CLIENT_ID,
      'x-youtube-client-version': CLIENT.clientVersion,
    },
    body: JSON.stringify({
      videoId,
      contentCheckOk: true,
      racyCheckOk: true,
      context: { client: CLIENT },
    }),
  });

  if (!response.ok) throw new Error(`innertube http ${response.status}`);
  return (await response.json()) as PlayerResponse;
}

function buildFormats(response: PlayerResponse): MediaFormat[] {
  const muxed = response.streamingData?.formats ?? [];
  const adaptive = response.streamingData?.adaptiveFormats ?? [];

  // A ciphered entry has no URL we can use; treat it as absent rather than
  // offering the user a format the download engine would choke on.
  const playable = (format: RawFormat) => Boolean(format.url) && !format.signatureCipher;

  const audioTracks = adaptive
    .filter((format) => playable(format) && format.mimeType.startsWith('audio/'))
    .sort((a, b) => (b.bitrate ?? 0) - (a.bitrate ?? 0));

  const bestAudio = audioTracks[0];
  const formats: MediaFormat[] = [];

  /**
   * Pairs a video track with audio from the same container family.
   *
   * YouTube's high resolutions are VP9/webm, and its mp4 tracks are AVC. Mixing
   * the two forces a container that has to hold codecs it was not designed for
   * (Opus in MP4, AVC in WebM) — `-c copy` either refuses or produces a file
   * some players will not open. Same-family pairing keeps the merge a pure
   * remux with no re-encoding.
   */
  const audioFor = (videoMime: string) => {
    const family = containerOf(videoMime);
    return (
      audioTracks.find((track) => containerOf(track.mimeType) === family) ?? bestAudio
    );
  };

  for (const format of muxed.filter(playable)) {
    formats.push({
      id: `yt:muxed:${format.itag}`,
      label: format.qualityLabel ?? `${format.height ?? '?'}p`,
      ext: extensionOf(format.mimeType),
      kind: 'video',
      protocol: 'https',
      url: format.url,
      width: format.width,
      height: format.height,
      fps: format.fps,
      filesize: Number(format.contentLength) || undefined,
      bitrate: format.bitrate,
      origin: 'innertube',
    });
  }

  // Video-only tracks are where the high resolutions live; each is paired with
  // the best audio track and merged at download time.
  if (bestAudio?.url) {
    for (const format of adaptive.filter(
      (entry) => playable(entry) && entry.mimeType.startsWith('video/'),
    )) {
      const audio = audioFor(format.mimeType);
      if (!audio?.url) continue;

      formats.push({
        id: `yt:adaptive:${format.itag}`,
        label: format.qualityLabel ?? `${format.height ?? '?'}p`,
        // The merged file keeps the video track's container, since that is the
        // side that cannot be rewrapped without re-encoding.
        ext: containerOf(format.mimeType),
        kind: 'video',
        protocol: 'https',
        url: format.url,
        needsMux: true,
        audioUrl: audio.url,
        width: format.width,
        height: format.height,
        fps: format.fps,
        filesize: (Number(format.contentLength) || 0) + (Number(audio.contentLength) || 0) || undefined,
        bitrate: format.bitrate,
        vcodec: codecOf(format.mimeType),
        acodec: codecOf(audio.mimeType),
        origin: 'innertube',
      });
    }
  }

  for (const format of audioTracks.slice(0, 3)) {
    formats.push({
      id: `yt:audio:${format.itag}`,
      label: `Audio ${Math.round((format.bitrate ?? 0) / 1000)}kbps`,
      ext: extensionOf(format.mimeType),
      kind: 'audio',
      protocol: 'https',
      url: format.url,
      filesize: Number(format.contentLength) || undefined,
      bitrate: format.bitrate,
      acodec: codecOf(format.mimeType),
      origin: 'innertube',
    });
  }

  return dedupeByResolution(formats);
}

/**
 * One entry per (kind, label). YouTube offers most resolutions twice — once as
 * WebM/VP9 and once as MP4/AVC or AV1 — and both read as "1080p" to the user,
 * so only one can be shown.
 *
 * Preference order:
 *   1. No merge needed, since that skips ffmpeg entirely.
 *   2. MP4, because it plays in far more places than WebM does — QuickTime,
 *      most TVs, and every phone gallery.
 */
function dedupeByResolution(formats: MediaFormat[]): MediaFormat[] {
  const best = new Map<string, MediaFormat>();

  const isBetter = (candidate: MediaFormat, current: MediaFormat) => {
    if (current.needsMux !== candidate.needsMux) return !candidate.needsMux;
    return current.ext !== 'mp4' && candidate.ext === 'mp4';
  };

  for (const format of formats) {
    const key = `${format.kind}:${format.label}`;
    const current = best.get(key);
    if (!current || isBetter(format, current)) best.set(key, format);
  }

  return [...best.values()].sort((a, b) => {
    if (a.kind !== b.kind) return a.kind === 'video' ? -1 : 1;
    return (b.height ?? b.bitrate ?? 0) - (a.height ?? a.bitrate ?? 0);
  });
}

/** 'webm' or 'mp4' — the family the track can be remuxed into for free. */
function containerOf(mimeType: string): string {
  return mimeType.includes('webm') ? 'webm' : 'mp4';
}

function extensionOf(mimeType: string): string {
  const subtype = mimeType.split(';')[0]?.split('/')[1] ?? 'mp4';
  if (subtype === 'mp4' && mimeType.startsWith('audio/')) return 'm4a';
  return subtype;
}

function codecOf(mimeType: string): string | undefined {
  return mimeType.match(/codecs="([^"]+)"/)?.[1];
}

function bestThumbnail(response: PlayerResponse): string | undefined {
  const thumbnails = response.videoDetails?.thumbnail?.thumbnails ?? [];
  return [...thumbnails].sort((a, b) => b.width - a.width)[0]?.url;
}

export function videoIdFrom(url: string): string | null {
  try {
    const parsed = new URL(url);
    if (parsed.hostname.endsWith('youtu.be')) return parsed.pathname.slice(1) || null;
    const fromQuery = parsed.searchParams.get('v');
    if (fromQuery) return fromQuery;
    return parsed.pathname.match(/^\/(shorts|embed|live)\/([\w-]{6,})/)?.[2] ?? null;
  } catch {
    return null;
  }
}
