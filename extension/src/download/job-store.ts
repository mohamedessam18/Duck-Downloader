import type { DownloadJob } from '@/core/types';
import { emit } from '@/core/messaging';

/**
 * Persistent job history.
 *
 * Local storage rather than session storage: a user expects yesterday's
 * downloads to still be listed after a browser restart. Blobs are never kept
 * here — only metadata.
 */

const KEY = 'duck:jobs';
const MAX_JOBS = 200;

export async function allJobs(): Promise<DownloadJob[]> {
  const stored = await chrome.storage.local.get(KEY);
  return (stored[KEY] as DownloadJob[] | undefined) ?? [];
}

export async function getJob(jobId: string): Promise<DownloadJob | undefined> {
  return (await allJobs()).find((job) => job.id === jobId);
}

export async function putJob(job: DownloadJob): Promise<DownloadJob[]> {
  const jobs = await allJobs();
  const index = jobs.findIndex((existing) => existing.id === job.id);
  if (index >= 0) jobs[index] = job;
  else jobs.unshift(job);
  return persist(jobs.slice(0, MAX_JOBS));
}

export async function patchJob(
  jobId: string,
  patch: Partial<DownloadJob>,
): Promise<DownloadJob | undefined> {
  const jobs = await allJobs();
  const index = jobs.findIndex((job) => job.id === jobId);
  if (index < 0) return undefined;

  const updated: DownloadJob = { ...jobs[index]!, ...patch, updatedAt: Date.now() };
  jobs[index] = updated;
  await persist(jobs);
  return updated;
}

export async function removeJob(jobId: string): Promise<DownloadJob[]> {
  const jobs = (await allJobs()).filter((job) => job.id !== jobId);
  return persist(jobs);
}

/** Jobs the manager still needs to watch after a service worker restart. */
export async function activeJobs(): Promise<DownloadJob[]> {
  return (await allJobs()).filter((job) =>
    ['queued', 'resolving', 'downloading', 'muxing', 'paused'].includes(job.status),
  );
}

async function persist(jobs: DownloadJob[]): Promise<DownloadJob[]> {
  await chrome.storage.local.set({ [KEY]: jobs });
  emit('jobs:changed', jobs);
  return jobs;
}
