import { open, mkdir, rename, stat, unlink } from 'node:fs/promises';
import { dirname } from 'node:path';
import type { JobProblem, RequestContext } from '../../../contracts/duck-protocol.js';
import { buildHeaders, probe, type ProbeResult } from './probe.js';
import {
  bytesDone,
  isComplete,
  isReusable,
  planParts,
  readPartMap,
  sidecarPath,
  writePartMap,
  type PartMap,
  type PartState,
} from './parts.js';
import { verifySignature } from './signatures.js';

/**
 * The direct-file downloader.
 *
 * Everything here exists to make one guarantee: a file Duck says is finished is
 * complete and correct, and a file Duck has not finished can always be
 * continued rather than restarted.
 */

export interface DownloadOptions {
  url: string;
  tempPath: string;
  /**
   * Resolves the destination once the server has been asked.
   *
   * A callback rather than a fixed path because the server's own
   * `Content-Disposition` filename is usually better than anything derived from
   * a page title — and it is only known after the probe.
   */
  finalPathFor: (serverFilename?: string) => string;
  context?: RequestContext;
  maxParts: number;
  signal: AbortSignal;
  onProgress: (received: number, total: number) => void;
}

export interface DownloadOutcome {
  ok: boolean;
  problem?: JobProblem;
  message?: string;
  finalPath?: string;
  bytes?: number;
}

/** Progress is persisted on this cadence, not on every chunk. */
const PERSIST_INTERVAL_MS = 1000;

export async function downloadDirect(options: DownloadOptions): Promise<DownloadOutcome> {
  // Checked before anything touches the network, so a missing link reads as a
  // missing link rather than as `TypeError: Failed to parse URL from` — an
  // internal message that tells the user nothing and suggests nothing.
  if (!/^https?:\/\//i.test(options.url)) {
    return {
      ok: false,
      problem: 'sourceExpired',
      message: 'Duck does not have a usable link for this yet. Open the page again so it can be captured.',
    };
  }

  let head: ProbeResult;
  try {
    head = await probe(options.url, options.context, options.signal);
  } catch (error) {
    if (options.signal.aborted) return { ok: false, problem: 'canceledByUser' };
    return {
      ok: false,
      problem: 'networkUnavailable',
      message: `Could not reach the server: ${describe(error)}`,
    };
  }

  const rejected = classifyStatus(head.status);
  if (rejected) return rejected;

  if (head.looksLikeHtml) {
    // A login wall or an expiry page, dressed as a successful response.
    return {
      ok: false,
      problem: 'notMedia',
      message: 'The server returned a web page instead of the file.',
    };
  }

  const finalPath = options.finalPathFor(head.filename);

  await mkdir(dirname(options.tempPath), { recursive: true });
  await mkdir(dirname(finalPath), { recursive: true });

  const map = await resolvePartMap(options, head);
  const handle = await open(options.tempPath, 'r+').catch(() => open(options.tempPath, 'w+'));

  let lastPersist = 0;
  const total = map.size;

  const persist = async (force = false) => {
    const now = Date.now();
    if (!force && now - lastPersist < PERSIST_INTERVAL_MS) return;
    lastPersist = now;
    await writePartMap(options.tempPath, map).catch(() => undefined);
  };

  const report = () => options.onProgress(bytesDone(map.parts), total);

  try {
    // Parts run together; each writes only into its own slice of the file, so
    // positional writes never collide and no assembly step is needed.
    const results = await Promise.all(
      map.parts.map((part) =>
        fetchPart({
          part,
          map,
          handle,
          options,
          onAdvance: () => {
            report();
            void persist();
          },
        }),
      ),
    );

    const failure = results.find((result) => result !== null);
    if (failure) {
      await persist(true);
      return failure;
    }

    await persist(true);
    await handle.sync();
  } finally {
    await handle.close().catch(() => undefined);
  }

  if (!isComplete(map.parts)) {
    return {
      ok: false,
      problem: 'serverError',
      message: 'The download stopped before the whole file arrived.',
    };
  }

  const verified = await verify(options.tempPath, total, extensionOf(finalPath));
  if (!verified.ok) return verified;

  // Only now does the file get its real name. Until this point nothing outside
  // Duck can mistake a partial download for a finished one.
  const destination = await uniquePath(finalPath);
  await rename(options.tempPath, destination);
  await unlink(sidecarPath(options.tempPath)).catch(() => undefined);

  return { ok: true, finalPath: destination, bytes: total };
}

/** Reuses an existing byte map when the source still matches, else starts clean. */
async function resolvePartMap(
  options: DownloadOptions,
  head: ProbeResult,
): Promise<PartMap> {
  const etag = undefined;
  const existing = await readPartMap(options.tempPath);

  if (
    existing &&
    isReusable(existing, { url: head.finalUrl, size: head.size, etag })
  ) {
    // Trust the file, not the note about it: if the partial was truncated or
    // removed, believing its byte map would leave a hole in the middle.
    const onDisk = await stat(options.tempPath).catch(() => null);
    if (onDisk && onDisk.size >= highestWrittenByte(existing.parts)) {
      existing.url = head.finalUrl;
      return existing;
    }
  }

  const size = head.size;
  const parts =
    head.acceptsRanges && size > 0
      ? planParts(size, options.maxParts)
      : // No range support means one stream, and no resume — the server has
        // given us no way to ask for the middle of the file.
        [{ index: 0, start: 0, end: Math.max(0, size - 1), done: 0 }];

  const map: PartMap = { version: 1, url: head.finalUrl, size, parts };

  // Reserve the file so a full disk is discovered now rather than at 90%.
  const handle = await open(options.tempPath, 'w');
  if (size > 0) await handle.truncate(size).catch(() => undefined);
  await handle.close();

  await writePartMap(options.tempPath, map);
  return map;
}

function highestWrittenByte(parts: PartState[]): number {
  return parts.reduce((max, part) => Math.max(max, part.start + part.done), 0);
}

interface FetchPartArgs {
  part: PartState;
  map: PartMap;
  handle: Awaited<ReturnType<typeof open>>;
  options: DownloadOptions;
  onAdvance: () => void;
}

/** Returns null on success, or the outcome describing why it stopped. */
async function fetchPart(args: FetchPartArgs): Promise<DownloadOutcome | null> {
  const { part, map, handle, options } = args;
  const length = part.end - part.start + 1;
  if (map.size > 0 && part.done >= length) return null;

  const from = part.start + part.done;
  const headers = buildHeaders(options.context);
  if (map.size > 0) headers.range = `bytes=${from}-${part.end}`;

  let response: Response;
  try {
    response = await fetch(map.url, { headers, redirect: 'follow', signal: options.signal });
  } catch (error) {
    if (options.signal.aborted) return { ok: false, problem: 'canceledByUser' };
    return {
      ok: false,
      problem: 'networkUnavailable',
      message: `Connection lost: ${describe(error)}`,
    };
  }

  const rejected = classifyStatus(response.status);
  if (rejected) return rejected;

  // A 200 where a range was asked means the server ignored it and is sending
  // the whole file. Writing that at the part's offset would corrupt everything.
  if (map.size > 0 && part.done > 0 && response.status !== 206) {
    part.done = 0;
    return {
      ok: false,
      problem: 'serverError',
      message: 'The server would not resume this file. Retrying from the start.',
    };
  }

  if (!response.body) {
    return { ok: false, problem: 'serverError', message: 'The server sent no data.' };
  }

  let offset = from;
  try {
    for await (const chunk of response.body as unknown as AsyncIterable<Uint8Array>) {
      if (options.signal.aborted) return { ok: false, problem: 'canceledByUser' };

      // Never write past the part's boundary, however much the server sends.
      const room = map.size > 0 ? part.end - offset + 1 : chunk.length;
      const slice = chunk.length > room ? chunk.subarray(0, room) : chunk;
      if (slice.length === 0) break;

      await handle.write(slice, 0, slice.length, offset);
      offset += slice.length;
      part.done += slice.length;
      args.onAdvance();
    }
  } catch (error) {
    if (options.signal.aborted) return { ok: false, problem: 'canceledByUser' };
    return {
      ok: false,
      problem: 'networkUnavailable',
      message: `Transfer interrupted: ${describe(error)}`,
    };
  }

  // With no declared length the part grows to whatever arrived, and that is the
  // file's real size.
  if (map.size === 0) {
    part.end = Math.max(0, part.done - 1);
    map.size = part.done;
  }

  return null;
}

/** Maps HTTP status to something the UI can turn into a sentence and a button. */
function classifyStatus(status: number): DownloadOutcome | null {
  if (status >= 200 && status < 300) return null;

  if (status === 401 || status === 407) {
    return {
      ok: false,
      problem: 'authenticationRequired',
      message: 'This file needs a sign-in that Duck does not carry.',
    };
  }
  if (status === 403) {
    // Overwhelmingly an expired signature rather than a real permission wall.
    return {
      ok: false,
      problem: 'sourceExpired',
      message: 'The temporary link is no longer valid.',
    };
  }
  if (status === 404 || status === 410) {
    return { ok: false, problem: 'serverError', message: 'The file is no longer on the server.' };
  }
  if (status === 416) {
    return {
      ok: false,
      problem: 'sourceExpired',
      message: 'The server no longer recognises the part Duck asked for.',
    };
  }
  if (status === 429) {
    return { ok: false, problem: 'serverError', message: 'The server asked Duck to slow down.' };
  }
  return { ok: false, problem: 'serverError', message: `The server answered ${status}.` };
}

/**
 * Confirms the file is what it claims to be.
 *
 * A 200 response is not proof of a good download: truncated transfers and error
 * pages both arrive with success codes. Size is checked against what the server
 * promised, and the first bytes are checked for markup, which catches the
 * expiry page served in place of media.
 */
function extensionOf(filePath: string): string {
  const name = filePath.split(/[\\/]/).pop() ?? '';
  const dot = name.lastIndexOf('.');
  return dot > 0 ? name.slice(dot + 1) : '';
}

async function verify(
  tempPath: string,
  expected: number,
  extension: string,
): Promise<DownloadOutcome> {
  const info = await stat(tempPath).catch(() => null);
  if (!info) {
    return { ok: false, problem: 'verificationFailed', message: 'The downloaded file vanished.' };
  }

  if (expected > 0 && info.size !== expected) {
    return {
      ok: false,
      problem: 'verificationFailed',
      message: `Expected ${expected} bytes but got ${info.size}.`,
    };
  }

  if (info.size === 0) {
    return { ok: false, problem: 'verificationFailed', message: 'The file came through empty.' };
  }

  const handle = await open(tempPath, 'r');
  try {
    const buffer = Buffer.alloc(Math.min(512, info.size));
    await handle.read(buffer, 0, buffer.length, 0);
    const head = buffer.toString('utf8').trimStart().toLowerCase();
    if (head.startsWith('<!doctype html') || head.startsWith('<html')) {
      return {
        ok: false,
        problem: 'notMedia',
        message: 'The server sent a web page instead of the file.',
      };
    }

    // The last line of defence: bytes that do not match the container they are
    // named for. This is what stops a file that downloaded "successfully" from
    // reaching the user unopenable.
    const verdict = verifySignature(extension, new Uint8Array(buffer));
    if (!verdict.ok) {
      return {
        ok: false,
        problem: 'notMedia',
        message: `What arrived is not a ${verdict.expected} file. The source did not send the media itself.`,
      };
    }
  } finally {
    await handle.close().catch(() => undefined);
  }

  return { ok: true };
}

/** Never silently overwrite something the user already has. */
async function uniquePath(path: string): Promise<string> {
  const exists = await stat(path).then(() => true).catch(() => false);
  if (!exists) return path;

  const dot = path.lastIndexOf('.');
  const stem = dot > 0 ? path.slice(0, dot) : path;
  const extension = dot > 0 ? path.slice(dot) : '';

  for (let index = 2; index < 1000; index++) {
    const candidate = `${stem} (${index})${extension}`;
    const taken = await stat(candidate).then(() => true).catch(() => false);
    if (!taken) return candidate;
  }
  return `${stem} (${Date.now()})${extension}`;
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
