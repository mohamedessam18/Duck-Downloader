import type { DownloadJob } from '@/core/types';
import { sendMessage } from '@/core/messaging';
import { formatBytes, formatEta, formatSpeed } from '../format';

interface Props {
  jobs: DownloadJob[];
  compact?: boolean;
}

export function JobList({ jobs, compact = false }: Props) {
  const visible = compact ? jobs.slice(0, 3) : jobs;

  return (
    <ul className="flex flex-col gap-1.5">
      {visible.map((job) => (
        <li key={job.id}>
          <JobRow job={job} />
        </li>
      ))}
    </ul>
  );
}

function JobRow({ job }: { job: DownloadJob }) {
  const active = job.status === 'downloading' || job.status === 'muxing' || job.status === 'resolving';
  const indeterminate = job.progress < 0;

  return (
    <div className="rounded-xl border border-duck-border bg-duck-surface p-2.5">
      <div className="flex items-center gap-2">
        <p className="min-w-0 flex-1 truncate text-[12px] font-semibold">{job.title}</p>
        <StatusBadge job={job} />
      </div>

      {(active || job.status === 'paused') && (
        <>
          <div className="mt-2 h-1 overflow-hidden rounded-full bg-duck-border">
            <div
              className={`h-full rounded-full bg-duck-accent transition-[width] duration-300 ${
                indeterminate ? 'animate-pulse' : ''
              }`}
              style={{ width: indeterminate ? '100%' : `${job.progress}%` }}
            />
          </div>
          <p className="mt-1.5 flex items-center gap-2 text-[10px] tabular-nums text-duck-muted">
            {!indeterminate && <span>{job.progress}%</span>}
            {job.totalBytes > 0 && (
              <span>
                {formatBytes(job.receivedBytes)} / {formatBytes(job.totalBytes)}
              </span>
            )}
            <span>{formatSpeed(job.speedBps)}</span>
            <span className="ml-auto">{formatEta(job.etaSec)}</span>
          </p>
        </>
      )}

      {job.status === 'failed' && job.error && (
        <p className="mt-1.5 line-clamp-2 text-[10px] text-duck-danger">{job.error}</p>
      )}

      <div className="mt-2 flex gap-1.5">
        {active && <Action label="Pause" onClick={() => sendMessage('download:pause', { jobId: job.id })} />}
        {job.status === 'paused' && (
          <Action label="Resume" onClick={() => sendMessage('download:resume', { jobId: job.id })} />
        )}
        {(active || job.status === 'paused') && (
          <Action label="Cancel" onClick={() => sendMessage('download:cancel', { jobId: job.id })} />
        )}
        {!active && job.status !== 'paused' && (
          <Action label="Remove" onClick={() => sendMessage('download:remove', { jobId: job.id })} />
        )}
        {job.status === 'completed' && (
          <Action
            label="Show in folder"
            onClick={async () => {
              if (job.browserDownloadId !== undefined) {
                chrome.downloads.show(job.browserDownloadId);
              }
            }}
          />
        )}
      </div>
    </div>
  );
}

function Action({ label, onClick }: { label: string; onClick: () => void | Promise<unknown> }) {
  return (
    <button
      type="button"
      onClick={() => void onClick()}
      className="rounded-md px-2 py-1 text-[10px] font-semibold text-duck-muted transition hover:bg-duck-surface-hover hover:text-duck-text"
    >
      {label}
    </button>
  );
}

const TONE: Record<DownloadJob['status'], string> = {
  queued: 'bg-duck-border text-duck-muted',
  resolving: 'bg-duck-border text-duck-muted',
  downloading: 'bg-duck-accent/15 text-duck-accent',
  muxing: 'bg-duck-accent/15 text-duck-accent',
  paused: 'bg-duck-border text-duck-muted',
  completed: 'bg-emerald-500/15 text-emerald-400',
  failed: 'bg-duck-danger/15 text-duck-danger',
  canceled: 'bg-duck-border text-duck-muted',
};

function StatusBadge({ job }: { job: DownloadJob }) {
  return (
    <span
      className={`flex-none rounded px-1.5 py-0.5 text-[10px] font-semibold capitalize ${TONE[job.status]}`}
    >
      {job.status}
    </span>
  );
}
