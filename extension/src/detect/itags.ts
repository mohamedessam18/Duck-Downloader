/**
 * YouTube format ids.
 *
 * A captured `videoplayback` URL carries its itag, and the itag alone says what
 * the stream is — resolution, codec, and whether it carries audio. That is the
 * whole reason capture needs no extraction step: the URL describes itself.
 *
 * Only the itags YouTube still serves are listed. An unknown one is not an
 * error; it falls back to a generic label and still downloads.
 */

export interface ItagInfo {
  label: string;
  height?: number;
  /** Video-only streams have to be merged with an audio track before saving. */
  videoOnly?: boolean;
  audioOnly?: boolean;
  container: 'mp4' | 'webm';
}

export const ITAGS: Record<string, ItagInfo> = {
  // Muxed — video and audio in one file, so no merge needed.
  18: { label: '360p', height: 360, container: 'mp4' },
  22: { label: '720p', height: 720, container: 'mp4' },

  // Video-only, H.264
  160: { label: '144p', height: 144, videoOnly: true, container: 'mp4' },
  133: { label: '240p', height: 240, videoOnly: true, container: 'mp4' },
  134: { label: '360p', height: 360, videoOnly: true, container: 'mp4' },
  135: { label: '480p', height: 480, videoOnly: true, container: 'mp4' },
  136: { label: '720p', height: 720, videoOnly: true, container: 'mp4' },
  137: { label: '1080p', height: 1080, videoOnly: true, container: 'mp4' },
  264: { label: '1440p', height: 1440, videoOnly: true, container: 'mp4' },
  266: { label: '2160p', height: 2160, videoOnly: true, container: 'mp4' },

  // Video-only, VP9
  278: { label: '144p', height: 144, videoOnly: true, container: 'webm' },
  242: { label: '240p', height: 240, videoOnly: true, container: 'webm' },
  243: { label: '360p', height: 360, videoOnly: true, container: 'webm' },
  244: { label: '480p', height: 480, videoOnly: true, container: 'webm' },
  247: { label: '720p', height: 720, videoOnly: true, container: 'webm' },
  248: { label: '1080p', height: 1080, videoOnly: true, container: 'webm' },
  271: { label: '1440p', height: 1440, videoOnly: true, container: 'webm' },
  313: { label: '2160p', height: 2160, videoOnly: true, container: 'webm' },

  // Video-only, AV1
  394: { label: '144p', height: 144, videoOnly: true, container: 'mp4' },
  395: { label: '240p', height: 240, videoOnly: true, container: 'mp4' },
  396: { label: '360p', height: 360, videoOnly: true, container: 'mp4' },
  397: { label: '480p', height: 480, videoOnly: true, container: 'mp4' },
  398: { label: '720p', height: 720, videoOnly: true, container: 'mp4' },
  399: { label: '1080p', height: 1080, videoOnly: true, container: 'mp4' },
  400: { label: '1440p', height: 1440, videoOnly: true, container: 'mp4' },
  401: { label: '2160p', height: 2160, videoOnly: true, container: 'mp4' },

  // Audio-only
  139: { label: 'Audio 48kbps', audioOnly: true, container: 'mp4' },
  140: { label: 'Audio 128kbps', audioOnly: true, container: 'mp4' },
  141: { label: 'Audio 256kbps', audioOnly: true, container: 'mp4' },
  249: { label: 'Audio 50kbps', audioOnly: true, container: 'webm' },
  250: { label: 'Audio 70kbps', audioOnly: true, container: 'webm' },
  251: { label: 'Audio 160kbps', audioOnly: true, container: 'webm' },
};

export function itagInfo(itag: string): ItagInfo | undefined {
  return ITAGS[itag];
}
