import { readFile, writeFile, rename, mkdir } from 'node:fs/promises';
import { dirname } from 'node:path';
import type { JobRecord } from '../../contracts/duck-protocol.js';
import { JOBS_FILE } from './paths.js';

/**
 * The durable job list.
 *
 * A plain JSON file written atomically, not a database. The whole queue is a few
 * hundred small records at most, so a database would buy nothing but a native
 * dependency that has to be rebuilt for every Electron version. What actually
 * matters — that a half-written file can never be read back — is handled by
 * writing to a sibling and renaming, which is atomic on every platform Duck
 * targets.
 *
 * Byte-level resume state does *not* live here. It sits beside each partial
 * file, so a huge download's progress is never at risk from a rewrite of the
 * queue, and deleting a partial takes its bookkeeping with it.
 */
export class JobStore {
  private jobs = new Map<string, JobRecord>();
  private writing: Promise<void> = Promise.resolve();
  private dirty = false;

  async load(): Promise<void> {
    try {
      const raw = await readFile(JOBS_FILE, 'utf8');
      const parsed = JSON.parse(raw) as JobRecord[];
      for (const job of parsed) this.jobs.set(job.id, job);
    } catch (error) {
      // A missing file is the normal first run. A corrupt one must not stop the
      // engine from starting — an empty queue beats a boot loop.
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') {
        console.error('[duck] could not read the job list, starting empty:', error);
      }
    }
  }

  all(): JobRecord[] {
    return [...this.jobs.values()].sort((a, b) => b.createdAt - a.createdAt);
  }

  get(jobId: string): JobRecord | undefined {
    return this.jobs.get(jobId);
  }

  /** Finds an existing job for the same resource, so a repeat click is a no-op. */
  findByResource(resourceId: string): JobRecord | undefined {
    for (const job of this.jobs.values()) {
      if (job.recipe.resourceId === resourceId && job.state !== 'canceled') return job;
    }
    return undefined;
  }

  put(job: JobRecord): JobRecord {
    this.jobs.set(job.id, job);
    this.schedule();
    return job;
  }

  patch(jobId: string, patch: Partial<JobRecord>): JobRecord | undefined {
    const current = this.jobs.get(jobId);
    if (!current) return undefined;
    const next: JobRecord = { ...current, ...patch, updatedAt: Date.now() };
    this.jobs.set(jobId, next);
    this.schedule();
    return next;
  }

  delete(jobId: string): void {
    this.jobs.delete(jobId);
    this.schedule();
  }

  /**
   * Coalesces writes.
   *
   * Progress updates arrive many times a second; persisting each one would turn
   * a download into a disk-thrashing exercise. State *transitions* call
   * `flush()` directly, so what survives a crash is always the last known state,
   * even if the last byte count is a moment stale.
   */
  private schedule(): void {
    this.dirty = true;
    queueMicrotask(() => {
      if (!this.dirty) return;
      void this.flush();
    });
  }

  async flush(): Promise<void> {
    if (!this.dirty) return;
    this.dirty = false;

    this.writing = this.writing.then(async () => {
      const payload = JSON.stringify([...this.jobs.values()], null, 0);
      const temporary = `${JOBS_FILE}.tmp`;
      await mkdir(dirname(JOBS_FILE), { recursive: true });
      await writeFile(temporary, payload, { mode: 0o600 });
      // Rename is atomic: a reader sees either the old file or the new one.
      await rename(temporary, JOBS_FILE);
    });

    return this.writing;
  }

  /**
   * Reconciles state after a restart.
   *
   * Anything that was mid-flight when the process died is now stalled, and the
   * engine is the only thing that could have been moving it. Marking those as
   * paused rather than failed keeps the partial file and its byte map intact,
   * so resuming continues instead of starting over.
   */
  recoverAfterRestart(): JobRecord[] {
    const recovered: JobRecord[] = [];
    for (const job of this.jobs.values()) {
      if (['downloading', 'preparing', 'verifying', 'retrying'].includes(job.state)) {
        const next: JobRecord = {
          ...job,
          state: 'paused',
          message: 'Duck restarted. Resume to continue from where this stopped.',
          actions: ['retry', 'remove'],
          updatedAt: Date.now(),
        };
        this.jobs.set(job.id, next);
        recovered.push(next);
      }
    }
    if (recovered.length > 0) this.schedule();
    return recovered;
  }
}
