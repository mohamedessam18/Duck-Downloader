import type { Platform } from './types';

const PATTERNS: Array<[Platform, RegExp]> = [
  ['youtube', /(^|\.)(youtube\.com|youtu\.be|youtube-nocookie\.com)$/i],
  ['twitter', /(^|\.)(twitter\.com|x\.com)$/i],
  ['instagram', /(^|\.)instagram\.com$/i],
  ['tiktok', /(^|\.)tiktok\.com$/i],
  ['facebook', /(^|\.)(facebook\.com|fb\.watch|fb\.com)$/i],
  ['reddit', /(^|\.)(reddit\.com|redd\.it)$/i],
  ['threads', /(^|\.)(threads\.net|threads\.com)$/i],
  ['soundcloud', /(^|\.)soundcloud\.com$/i],
];

export function platformOf(url: string): Platform {
  let host: string;
  try {
    host = new URL(url).hostname;
  } catch {
    return 'generic';
  }
  for (const [platform, pattern] of PATTERNS) {
    if (pattern.test(host)) return platform;
  }
  return 'generic';
}

const LABELS: Record<Platform, string> = {
  youtube: 'YouTube',
  twitter: 'X',
  instagram: 'Instagram',
  tiktok: 'TikTok',
  facebook: 'Facebook',
  reddit: 'Reddit',
  threads: 'Threads',
  soundcloud: 'SoundCloud',
  generic: 'Web',
};

export function platformLabel(platform: Platform): string {
  return LABELS[platform];
}

/** Filesystem-safe filename, mirroring the backend's sanitize_filename. */
export function sanitizeFilename(value: string): string {
  const cleaned = value
    .replace(/[<>:"/\\|?*\x00-\x1f]+/g, '_')
    .replace(/^[\s.]+|[\s.]+$/g, '');
  return cleaned.slice(0, 140) || 'duck_download';
}
