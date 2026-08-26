/**
 * The contract between Duck's parts.
 *
 * One file, imported by the extension, the engine, the bridge and the desktop
 * UI. Duplicating these shapes per language is how the two halves of a system
 * quietly drift apart; there is no schema to regenerate because there is only
 * ever one definition.
 *
 * Everything crossing the local socket or the native-messaging port is
 * described here. Nothing here is sent to a server — Duck has no server on the
 * download path.
 */

export const PROTOCOL_VERSION = 1;

/* -------------------------------------------------------------------------- */
/*  What the extension discovered                                             */
/* -------------------------------------------------------------------------- */

/**
 * How the bytes have to be fetched. This drives which engine handles the job,
 * so it is deliberately about *transport*, not about what the media is.
 */
export type ResourceClass =
  /** One HTTP URL holding the whole file. */
  | 'direct'
  /** An m3u8 playlist whose segments must be fetched and joined. */
  | 'hls'
  /** An mpd manifest with separately addressed tracks. */
  | 'dash'
  /** Video and audio at two URLs, to be merged locally. */
  | 'paired'
  /** A carousel, gallery or playlist — a parent with child jobs. */
  | 'bundle'
  /** A stream with no end; recording starts when the user says so. */
  | 'live'
  /** Recognised, but Duck will not attempt it. Always paired with a reason. */
  | 'unsupported';

export type MediaKind = 'video' | 'audio' | 'image' | 'document' | 'archive' | 'file';

/**
 * The request context the engine must reproduce for the fetch to succeed.
 *
 * Deliberately narrow. Media CDNs commonly check `Referer` and `Origin`, so
 * those are carried; cookies and authorization headers are not, because a
 * download Duck can only perform by replaying someone's session is the boundary
 * this product does not cross.
 */
export interface RequestContext {
  referer?: string;
  origin?: string;
  /** Only headers the extension observed on the page's own media request. */
  headers?: Record<string, string>;
}

/** One selectable version of a resource. */
export interface ResourceVariant {
  id: string;
  label: string;
  kind: MediaKind;
  container: string;
  url?: string;
  /** Present on `paired`: the audio track to merge with `url`. */
  audioUrl?: string;
  width?: number;
  height?: number;
  bitrate?: number;
  /** Bytes, when the source declared it. Never guessed. */
  size?: number;
  codecs?: string;
}

/**
 * What the extension hands the engine. A URL alone is not enough: the engine
 * runs outside the browser and cannot re-derive the page context, and a
 * short-lived URL cannot be re-captured without knowing where it came from.
 */
export interface JobRecipe {
  protocolVersion: number;
  /** Stable across re-detection of the same resource, so duplicates collapse. */
  resourceId: string;
  /** Groups children of one post or playlist. */
  bundleId?: string;
  resourceClass: ResourceClass;
  /** The page the user was on. The engine asks for a re-capture through it. */
  pageUrl: string;
  /** Which tab to ask, while it is still open. */
  tabId?: number;
  title: string;
  suggestedFilename: string;
  kind: MediaKind;
  variant: ResourceVariant;
  requestContext?: RequestContext;
  /** When the URL was seen, and when its signature expires if that is known. */
  capturedAt: number;
  expiresAt?: number;
  /** Where the user wants it. Absent means the engine's default folder. */
  destination?: string;
}

/* -------------------------------------------------------------------------- */
/*  What the engine is doing about it                                         */
/* -------------------------------------------------------------------------- */

export type JobState =
  | 'queued'
  | 'preparing'
  | 'downloading'
  | 'paused'
  | 'waitingForSource'
  | 'retrying'
  | 'verifying'
  | 'completed'
  | 'failed'
  | 'canceled';

/**
 * Why a job is not progressing, and what can be done about it.
 *
 * Every value here maps to a specific sentence and a specific button in the UI.
 * A bare "Error" is the failure this enum exists to prevent — if a new failure
 * mode has no entry, that is a signal to add one, not to fall back to `unknown`.
 */
export type JobProblem =
  /** The signed URL aged out. Re-capture from the page and continue. */
  | 'sourceExpired'
  /** The page that could refresh the URL is no longer open. */
  | 'sourceTabClosed'
  /** The server wants credentials Duck will not replay. */
  | 'authenticationRequired'
  /** DRM. There is no file to save; the bytes on the wire are encrypted. */
  | 'protectedContent'
  /** Recognised format, no handler yet. */
  | 'unsupportedFormat'
  /** The server answered with a page instead of the media. */
  | 'notMedia'
  | 'diskFull'
  | 'permissionDenied'
  | 'networkUnavailable'
  | 'serverError'
  /** Finished, but the bytes did not check out. */
  | 'verificationFailed'
  | 'canceledByUser';

/** What the user can do about a problem. The UI renders these as buttons. */
export type JobAction = 'retry' | 'refreshSource' | 'openSourcePage' | 'chooseFolder' | 'remove';

export interface JobProgress {
  receivedBytes: number;
  /** 0 when the server never declared a length. */
  totalBytes: number;
  bytesPerSecond: number;
  etaSeconds?: number;
  /** For segmented and HLS jobs: how much of the work is done. */
  partsDone?: number;
  partsTotal?: number;
}

export interface JobRecord {
  id: string;
  recipe: JobRecipe;
  state: JobState;
  progress: JobProgress;
  problem?: JobProblem;
  /** Human sentence, already written for the user. Not a stack trace. */
  message?: string;
  actions?: JobAction[];
  /** Where the file is being assembled, and where it will end up. */
  tempPath?: string;
  finalPath?: string;
  attempt: number;
  /** Epoch ms of the next automatic retry, when one is scheduled. */
  retryAt?: number;
  createdAt: number;
  updatedAt: number;
  completedAt?: number;
}

/* -------------------------------------------------------------------------- */
/*  Wire protocol — extension/UI to engine                                    */
/* -------------------------------------------------------------------------- */

export type EngineRequest =
  | { type: 'hello'; protocolVersion: number; client: 'extension' | 'desktop' }
  | { type: 'submit'; recipe: JobRecipe }
  | { type: 'submitBundle'; recipes: JobRecipe[] }
  | { type: 'list' }
  | { type: 'pause'; jobId: string }
  | { type: 'resume'; jobId: string }
  | { type: 'cancel'; jobId: string }
  | { type: 'remove'; jobId: string }
  | { type: 'retry'; jobId: string }
  /** The extension answering a `needSource` event with a fresh URL. */
  | { type: 'refreshedSource'; jobId: string; variant: ResourceVariant; capturedAt: number }
  | { type: 'reveal'; jobId: string }
  | { type: 'settings' }
  | { type: 'updateSettings'; patch: Partial<EngineSettings> };

export type EngineResponse =
  | { type: 'hello'; protocolVersion: number; engineVersion: string; downloadDir: string }
  | { type: 'accepted'; jobId: string }
  | { type: 'jobs'; jobs: JobRecord[] }
  | { type: 'settings'; settings: EngineSettings }
  | { type: 'ok' }
  | { type: 'error'; message: string };

/** Pushed without being asked, so the UI never has to poll. */
export type EngineEvent =
  | { type: 'jobUpdated'; job: JobRecord }
  | { type: 'jobRemoved'; jobId: string }
  /**
   * The engine cannot continue without a fresh URL. The extension re-captures
   * from `pageUrl` and answers with `refreshedSource` — restarting the whole
   * download blindly would throw away everything already on disk.
   */
  | { type: 'needSource'; jobId: string; pageUrl: string; tabId?: number };

export interface EngineSettings {
  downloadDir: string;
  /** Parallel transfers overall. */
  maxConcurrentJobs: number;
  /** Connections to one host, across all jobs. More is not always faster. */
  maxConnectionsPerHost: number;
  /** Parts a single file may be split into, when the host supports ranges. */
  maxPartsPerFile: number;
  /** 0 means unlimited. */
  speedLimitBytesPerSecond: number;
  /** Organise finished files into per-site folders. */
  organiseBySite: boolean;
}

export const DEFAULT_SETTINGS: EngineSettings = {
  downloadDir: '',
  maxConcurrentJobs: 3,
  maxConnectionsPerHost: 4,
  maxPartsPerFile: 4,
  speedLimitBytesPerSecond: 0,
  organiseBySite: false,
};

/**
 * Backoff before an automatic retry, by attempt number.
 *
 * After these are exhausted the job does not fail — it moves to
 * `waitingForSource`, because the usual cause of repeated failure is an expired
 * URL, and that is fixed by asking the page again rather than by waiting longer.
 */
export const RETRY_DELAYS_MS = [5_000, 30_000, 120_000] as const;

/** Problems worth retrying on their own. The rest need the user or the page. */
export const RETRIABLE: readonly JobProblem[] = [
  'networkUnavailable',
  'serverError',
] as const;
