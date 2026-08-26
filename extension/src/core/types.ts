/** Shared domain model. Everything crossing a message boundary is defined here. */

export type Platform =
  | 'youtube'
  | 'twitter'
  | 'instagram'
  | 'tiktok'
  | 'facebook'
  | 'reddit'
  | 'threads'
  | 'soundcloud'
  | 'generic';

export type MediaKind = 'video' | 'audio' | 'image';

/** How a candidate was found. Ordered loosely by trustworthiness. */
export type DetectionSource = 'adapter' | 'network' | 'dom' | 'backend';

/** Transport of a format's URL. `hls`/`dash` always need remuxing before saving. */
export type Protocol = 'https' | 'hls' | 'dash';

/** Which engine will actually pull the bytes. */
export type Engine = 'direct' | 'muxed' | 'backend';

export interface MediaFormat {
  id: string;
  label: string;
  ext: string;
  kind: MediaKind;
  protocol: Protocol;
  /** Direct URL when we already know it. Absent means the resolver must fetch it. */
  url?: string;
  /**
   * Set when `url` carries video with no audio track (YouTube adaptive formats,
   * DASH). The download engine pairs it with `audioUrl` and muxes the two.
   */
  needsMux?: boolean;
  audioUrl?: string;
  width?: number;
  height?: number;
  fps?: number;
  filesize?: number;
  bitrate?: number;
  vcodec?: string;
  acodec?: string;
  /** Free-form marker for the resolver that produced this format. */
  origin?: string;
}

export interface MediaCandidate {
  /** Stable across re-detections of the same media on the same page. */
  id: string;
  platform: Platform;
  pageUrl: string;
  title: string;
  thumbnail?: string;
  durationSec?: number;
  author?: string;
  formats: MediaFormat[];
  source: DetectionSource;
  detectedAt: number;
  /**
   * True when formats are a guess and the resolver must be called before the
   * download can start. Network-sniffed candidates start out this way.
   */
  needsResolve?: boolean;
  /**
   * True when the link is a post that may hold several pieces of media — an
   * Instagram carousel of images, videos, or both. Acting on one of these means
   * enumerating the post, not downloading a single file.
   */
  isPost?: boolean;
  /**
   * The player is decrypting this through EME, so the bytes on the wire are
   * encrypted and the key never leaves the platform's secure module. There is
   * no file to save — saying so up front is the honest answer, and far better
   * than downloading something unplayable.
   */
  isProtected?: boolean;
}

export type JobStatus =
  | 'queued'
  | 'resolving'
  | 'downloading'
  | 'muxing'
  | 'paused'
  | 'completed'
  | 'failed'
  | 'canceled';

export interface DownloadJob {
  id: string;
  title: string;
  filename: string;
  platform: Platform;
  kind: MediaKind;
  formatLabel: string;
  pageUrl: string;
  thumbnail?: string;
  status: JobStatus;
  /** 0-100. -1 when the size is unknown and progress cannot be computed. */
  progress: number;
  receivedBytes: number;
  totalBytes: number;
  speedBps?: number;
  etaSec?: number;
  error?: string;
  engine: Engine;
  /** Handle from chrome.downloads, when the browser is doing the transfer. */
  browserDownloadId?: number;
  /** Handle from the Duck backend, when it is doing the transfer. */
  backendDownloadId?: string;
  createdAt: number;
  updatedAt: number;
}

export interface Settings {
  /** Injects the floating download button into supported pages. */
  overlayEnabled: boolean;
  /** Preferred max height, e.g. 1080. 0 means "always ask". */
  preferredHeight: number;
  /** Skip the quality sheet and take the best match for `preferredHeight`. */
  oneClickDownload: boolean;
  /**
   * Merge video and audio tracks in the browser with ffmpeg.wasm instead of
   * sending the job to the server.
   */
  localMux: boolean;
  /**
   * Take ordinary browser downloads over and run them through Duck Engine —
   * segmented, resumable, verified. This is what makes Duck a download
   * manager rather than only a media grabber.
   */
  interceptDownloads: boolean;
  /** Allow falling back to the Duck backend when local resolution fails. */
  backendFallback: boolean;
  backendUrl: string;
  /** Master switch for the YouTube module. See README for why this exists. */
  youtubeEnabled: boolean;
  theme: 'system' | 'light' | 'dark';
  locale: 'en' | 'ar';
}

export const DEFAULT_SETTINGS: Settings = {
  overlayEnabled: true,
  preferredHeight: 0,
  oneClickDownload: false,
  interceptDownloads: true,
  localMux: true,
  backendFallback: true,
  backendUrl: 'https://api.duckdownloader.site',
  youtubeEnabled: true,
  theme: 'system',
  locale: 'en',
};
