import { readFile, writeFile, rename } from 'node:fs/promises';

/**
 * The byte map for a partial download.
 *
 * Lives beside the partial file rather than in the job list, for two reasons:
 * it changes constantly while the queue does not, and deleting a stray
 * `.duckpart` file takes its bookkeeping with it instead of leaving the engine
 * convinced bytes exist that do not.
 *
 * `done` is the count of bytes written from the *start* of each part. Storing a
 * count rather than a set of ranges keeps resume honest: a part is always
 * contiguous from its offset, so there is no way to record progress that a
 * subsequent read cannot verify against the file's own length.
 */
export interface PartState {
  index: number;
  start: number;
  /** Inclusive, matching HTTP Range semantics. */
  end: number;
  done: number;
}

export interface PartMap {
  version: 1;
  url: string;
  size: number;
  /** Written by the server, used to detect that the source changed underneath us. */
  etag?: string;
  lastModified?: string;
  parts: PartState[];
}

export function sidecarPath(tempPath: string): string {
  return `${tempPath}.duckpart`;
}

export async function readPartMap(tempPath: string): Promise<PartMap | null> {
  try {
    const raw = await readFile(sidecarPath(tempPath), 'utf8');
    const parsed = JSON.parse(raw) as PartMap;
    return parsed.version === 1 ? parsed : null;
  } catch {
    return null;
  }
}

export async function writePartMap(tempPath: string, map: PartMap): Promise<void> {
  const target = sidecarPath(tempPath);
  const temporary = `${target}.tmp`;
  await writeFile(temporary, JSON.stringify(map), { mode: 0o600 });
  await rename(temporary, target);
}

/**
 * Splits a file into parts.
 *
 * Capped by size as well as by count: splitting a 3MB file four ways costs three
 * extra round trips to save nothing, and many hosts throttle per connection
 * rather than per client, so more parts past a point buys only rate limiting.
 */
export function planParts(size: number, maxParts: number): PartState[] {
  const MIN_PART_BYTES = 4 * 1024 * 1024;

  const count = Math.max(1, Math.min(maxParts, Math.floor(size / MIN_PART_BYTES) || 1));
  const chunk = Math.ceil(size / count);

  return Array.from({ length: count }, (_, index) => ({
    index,
    start: index * chunk,
    end: Math.min(size - 1, (index + 1) * chunk - 1),
    done: 0,
  }));
}

/**
 * Decides whether an existing byte map can still be trusted.
 *
 * If the server now reports a different size, or a different validator, the
 * bytes already on disk belong to a different file. Continuing would splice two
 * versions together into something that passes every size check and is
 * unplayable — the worst possible failure, because it looks like success.
 */
export function isReusable(
  map: PartMap,
  current: { url: string; size: number; etag?: string; lastModified?: string },
): boolean {
  if (map.size !== current.size || map.size === 0) return false;
  if (map.etag && current.etag && map.etag !== current.etag) return false;
  if (map.lastModified && current.lastModified && map.lastModified !== current.lastModified) {
    return false;
  }
  return true;
}

export function bytesDone(parts: PartState[]): number {
  return parts.reduce((total, part) => total + part.done, 0);
}

export function isComplete(parts: PartState[]): boolean {
  return parts.every((part) => part.done >= part.end - part.start + 1);
}
