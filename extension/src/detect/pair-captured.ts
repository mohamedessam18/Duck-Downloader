import type { MediaCandidate, MediaFormat } from '@/core/types';

/**
 * Joins captured video-only streams to a captured audio stream.
 *
 * Capture sees each request separately, so a 1080p video track and its audio
 * arrive as two unrelated formats. Offering them to the user like that would
 * hand them a silent file. Pairing here means the download manager's existing
 * merge engine picks them up exactly as it does for any other adaptive format.
 *
 * Applied on read rather than on capture: the formats accumulate one request at
 * a time, and only the merged view knows which audio tracks are available.
 */
export function pairCapturedFormats(candidate: MediaCandidate): MediaCandidate {
  const captured = candidate.formats.filter((format) => format.origin === 'stream-capture');
  if (captured.length === 0) return candidate;

  const audio = captured
    .filter((format) => format.kind === 'audio')
    .sort((a, b) => (b.filesize ?? 0) - (a.filesize ?? 0));

  if (audio.length === 0) return candidate;

  const audioFor = (container: string) =>
    audio.find((track) => track.ext === (container === 'webm' ? 'webm' : 'm4a')) ?? audio[0]!;

  const formats = candidate.formats.map((format) => {
    if (format.origin !== 'stream-capture') return format;
    if (format.kind !== 'video' || !format.needsMux) return format;
    if (format.audioUrl) return format;

    const track = audioFor(format.ext);
    return {
      ...format,
      audioUrl: track.url,
      filesize: (format.filesize ?? 0) + (track.filesize ?? 0) || undefined,
    } satisfies MediaFormat;
  });

  return { ...candidate, formats: sortForDisplay(formats) };
}

/** Highest quality first, video before audio — the order a user expects. */
function sortForDisplay(formats: MediaFormat[]): MediaFormat[] {
  return [...formats].sort((a, b) => {
    if (a.kind !== b.kind) return a.kind === 'video' ? -1 : 1;
    return (b.height ?? 0) - (a.height ?? 0);
  });
}
