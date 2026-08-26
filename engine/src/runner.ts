import { randomUUID } from 'node:crypto';
import { join } from 'node:path';
import { unlink } from 'node:fs/promises';
import {
  RETRIABLE,
  RETRY_DELAYS_MS,
  type EngineEvent,
  type JobAction,
  type JobProblem,
  type JobRecipe,
  type JobRecord,
  type ResourceVariant,
} from '../../contracts/duck-protocol.js';
import { JobStore } from './store.js';
import { downloadDirect } from './downloader/direct.js';
import { sidecarPath } from './downloader/parts.js';
import { getSettings } from './settings.js';
import { buildFinalPath, siteFolderFor } from './filenames.js';
import { PARTS_DIR } from './paths.js';

/**
 * The job runner: the queue, the state machine, and the retry policy.
 *
 * The rule this class is built around is that a job never dead-ends. Every
 * terminal state carries a sentence explaining what happened and a list of
 * actions the user can actually take. "Error" with no next step is the outcome
 * the whole design exists to prevent.
 */
export class Runner {
  private running = new Map<string, AbortController>();
  private timers = new Map<string, NodeJS.Timeout>();

  constructor(
    private readonly store: JobStore,
    private readonly emit: (event: EngineEvent) => void,
  ) {}

  /** Deduplicates by resource, so clicking twice does not download twice. */
  async submit(recipe: JobRecipe): Promise<JobRecord> {
    const existing = this.store.findByResource(recipe.resourceId);
    if (existing && existing.state !== 'failed') {
      return existing;
    }

    const job: JobRecord = {
      id: randomUUID(),
      recipe,
      state: 'queued',
      progress: { receivedBytes: 0, totalBytes: recipe.variant.size ?? 0, bytesPerSecond: 0 },
      attempt: 0,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };

    this.store.put(job);
    await this.store.flush();
    this.publish(job);
    void this.pump();
    return job;
  }

  /** Starts whatever the concurrency budget allows. */
  async pump(): Promise<void> {
    const settings = await getSettings();
    if (this.running.size >= settings.maxConcurrentJobs) return;

    const next = this.store
      .all()
      .filter((job) => job.state === 'queued')
      .sort((a, b) => a.createdAt - b.createdAt)[0];

    if (!next) return;
    void this.start(next.id);

    // Fill the remaining slots.
    if (this.running.size < settings.maxConcurrentJobs) void this.pump();
  }

  private async start(jobId: string): Promise<void> {
    const job = this.store.get(jobId);
    if (!job || this.running.has(jobId)) return;

    const controller = new AbortController();
    this.running.set(jobId, controller);

    const settings = await getSettings();
    const tempPath = join(PARTS_DIR, `${jobId}.part`);

    const finalPathFor = (serverFilename?: string) =>
      buildFinalPath({
        downloadDir: settings.downloadDir,
        suggestedFilename: job.recipe.suggestedFilename,
        container: job.recipe.variant.container,
        serverFilename,
        siteFolder: settings.organiseBySite ? siteFolderFor(job.recipe.pageUrl) : undefined,
      });

    this.update(jobId, {
      state: 'preparing',
      tempPath,
      // Provisional: replaced with the real destination once the server has
      // been asked, since its own filename usually wins.
      finalPath: finalPathFor(),
      message: undefined,
    });

    let lastTick = Date.now();
    let lastBytes = 0;

    const outcome = await downloadDirect({
      url: job.recipe.variant.url ?? '',
      tempPath,
      finalPathFor,
      context: job.recipe.requestContext,
      maxParts: settings.maxPartsPerFile,
      signal: controller.signal,
      onProgress: (received, total) => {
        const now = Date.now();
        const elapsed = (now - lastTick) / 1000;
        // Rate is sampled rather than averaged over the whole job, so a stall
        // shows as a stall instead of being hidden by a fast first minute.
        if (elapsed < 0.5) return;

        const bytesPerSecond = (received - lastBytes) / elapsed;
        lastTick = now;
        lastBytes = received;

        this.update(jobId, {
          state: 'downloading',
          progress: {
            receivedBytes: received,
            totalBytes: total,
            bytesPerSecond,
            etaSeconds:
              total > received && bytesPerSecond > 0
                ? Math.round((total - received) / bytesPerSecond)
                : undefined,
          },
        });
      },
    });

    this.running.delete(jobId);

    if (outcome.ok) {
      this.update(jobId, {
        state: 'completed',
        finalPath: outcome.finalPath,
        completedAt: Date.now(),
        message: undefined,
        problem: undefined,
        actions: ['remove'],
        progress: {
          receivedBytes: outcome.bytes ?? 0,
          totalBytes: outcome.bytes ?? 0,
          bytesPerSecond: 0,
        },
      });
      await this.store.flush();
      void this.pump();
      return;
    }

    await this.handleFailure(jobId, outcome.problem ?? 'serverError', outcome.message);
    void this.pump();
  }

  /**
   * Decides what a failure means.
   *
   * Three outcomes, and the distinction matters: retry it, ask the page for a
   * fresh URL, or stop and tell the user what only they can fix. Retrying an
   * expired signature forever is the bug this branch exists to avoid.
   */
  private async handleFailure(
    jobId: string,
    problem: JobProblem,
    message?: string,
  ): Promise<void> {
    const job = this.store.get(jobId);
    if (!job) return;

    if (problem === 'canceledByUser') {
      this.update(jobId, { state: 'paused', message: 'Paused.', actions: ['retry', 'remove'] });
      await this.store.flush();
      return;
    }

    // An expired link is not a network problem — waiting cannot fix it, only the
    // page that minted it can.
    if (problem === 'sourceExpired') {
      this.update(jobId, {
        state: 'waitingForSource',
        problem,
        // The downloader knows which of the two happened — a link that aged out,
        // or one Duck never received — and those read very differently to
        // someone trying to work out what to do next.
        message: message ?? 'The temporary link expired. Duck is asking the page for a new one.',
        actions: ['refreshSource', 'openSourcePage', 'remove'],
      });
      await this.store.flush();
      this.emit({
        type: 'needSource',
        jobId,
        pageUrl: job.recipe.pageUrl,
        tabId: job.recipe.tabId,
      });
      return;
    }

    const attempt = job.attempt + 1;
    const delay = RETRY_DELAYS_MS[attempt - 1];

    if (RETRIABLE.includes(problem) && delay !== undefined) {
      this.update(jobId, {
        state: 'retrying',
        problem,
        attempt,
        retryAt: Date.now() + delay,
        message: joinSentences(
          message ?? 'The download stopped.',
          `Retrying in ${Math.round(delay / 1000)}s.`,
        ),
        actions: ['retry', 'remove'],
      });
      await this.store.flush();

      const timer = setTimeout(() => {
        this.timers.delete(jobId);
        this.update(jobId, { state: 'queued', retryAt: undefined });
        void this.pump();
      }, delay);
      this.timers.set(jobId, timer);
      return;
    }

    // Retries exhausted on a retriable problem usually means the URL went stale
    // rather than the network being down, so ask the page rather than give up.
    if (RETRIABLE.includes(problem)) {
      this.update(jobId, {
        state: 'waitingForSource',
        problem: 'sourceExpired',
        attempt,
        message: 'Duck could not continue. Open the page again so it can refresh the link.',
        actions: ['refreshSource', 'openSourcePage', 'remove'],
      });
      await this.store.flush();
      this.emit({
        type: 'needSource',
        jobId,
        pageUrl: job.recipe.pageUrl,
        tabId: job.recipe.tabId,
      });
      return;
    }

    this.update(jobId, {
      state: 'failed',
      problem,
      attempt,
      message: message ?? 'The download could not be completed.',
      actions: actionsFor(problem),
    });
    await this.store.flush();
  }

  /** The extension answering `needSource` with a freshly captured URL. */
  async refreshedSource(
    jobId: string,
    variant: ResourceVariant,
    capturedAt: number,
  ): Promise<void> {
    const job = this.store.get(jobId);
    if (!job) return;

    // Keeps everything already on disk: only the URL changed, not the file.
    this.update(jobId, {
      recipe: { ...job.recipe, variant, capturedAt },
      state: 'queued',
      attempt: 0,
      problem: undefined,
      message: 'Duck got a fresh link and is continuing.',
      retryAt: undefined,
    });
    await this.store.flush();
    void this.pump();
  }

  async pause(jobId: string): Promise<void> {
    this.running.get(jobId)?.abort();
    this.clearTimer(jobId);
    const job = this.store.get(jobId);
    if (job && job.state !== 'completed') {
      this.update(jobId, { state: 'paused', message: 'Paused.', actions: ['retry', 'remove'] });
      await this.store.flush();
    }
  }

  async resume(jobId: string): Promise<void> {
    const job = this.store.get(jobId);
    if (!job || job.state === 'completed') return;
    this.update(jobId, { state: 'queued', problem: undefined, message: undefined, attempt: 0 });
    await this.store.flush();
    void this.pump();
  }

  async cancel(jobId: string): Promise<void> {
    this.running.get(jobId)?.abort();
    this.clearTimer(jobId);
    this.update(jobId, { state: 'canceled', message: 'Canceled.', actions: ['remove'] });
    await this.store.flush();
    void this.pump();
  }

  async remove(jobId: string): Promise<void> {
    const job = this.store.get(jobId);
    this.running.get(jobId)?.abort();
    this.clearTimer(jobId);

    // A removed job takes its partial with it; leaving orphaned parts behind is
    // how a downloads folder quietly fills with gigabytes nobody can account for.
    if (job?.tempPath && job.state !== 'completed') {
      await unlink(job.tempPath).catch(() => undefined);
      await unlink(sidecarPath(job.tempPath)).catch(() => undefined);
    }

    this.store.delete(jobId);
    await this.store.flush();
    this.emit({ type: 'jobRemoved', jobId });
    void this.pump();
  }

  /** Requeues everything that a restart left stranded. */
  async recover(): Promise<void> {
    for (const job of this.store.recoverAfterRestart()) this.publish(job);
    await this.store.flush();
  }

  private clearTimer(jobId: string): void {
    const timer = this.timers.get(jobId);
    if (timer) {
      clearTimeout(timer);
      this.timers.delete(jobId);
    }
  }

  private update(jobId: string, patch: Partial<JobRecord>): void {
    const next = this.store.patch(jobId, patch);
    if (next) this.publish(next);
  }

  private publish(job: JobRecord): void {
    this.emit({ type: 'jobUpdated', job });
  }
}

/** Keeps two sentences readable however the first one was punctuated. */
function joinSentences(first: string, second: string): string {
  const trimmed = first.trim();
  const ended = /[.!?]$/.test(trimmed);
  return `${trimmed}${ended ? '' : '.'} ${second}`;
}

/** Every problem maps to something the user can press. */
function actionsFor(problem: JobProblem): JobAction[] {
  switch (problem) {
    case 'diskFull':
      return ['chooseFolder', 'retry', 'remove'];
    case 'authenticationRequired':
    case 'notMedia':
      return ['openSourcePage', 'retry', 'remove'];
    case 'sourceTabClosed':
      return ['openSourcePage', 'remove'];
    case 'protectedContent':
    case 'unsupportedFormat':
      return ['remove'];
    default:
      return ['retry', 'remove'];
  }
}
