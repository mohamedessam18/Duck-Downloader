import type { JobAction, JobRecord, JobState } from '../../../../contracts/duck-protocol';
import { sendMessage } from '@/core/messaging';
import { formatBytes, formatEta, formatSpeed } from '../format';

/**
 * Jobs as the engine sees them.
 *
 * The important difference from the old browser-side list is that a stopped job
 * is never a dead end. The engine attaches a written explanation and the set of
 * actions that actually apply, so this component renders those rather than
 * inventing its own — a bare "Error" with no next step is the failure the whole
 * design exists to avoid.
 */

interface Props {
  jobs: JobRecord[];
  compact?: boolean;
}

export function EngineJobList({ jobs, compact = false }: Props) {
  const visible = compact ? jobs.slice(0, 3) : jobs;

  return (
    <ul className="flex flex-col gap-1.5">
      {visible.map((job) => (
        <li key={job.id}>
          <Row job={job} />
        </li>
      ))}
    </ul>
  );
}

const ACTIVE: JobState[] = ['queued', 'preparing', 'downloading', 'verifying', 'retrying'];

function Row({ job }: { job: JobRecord }) {
  const active = ACTIVE.includes(job.state);
  const { receivedBytes, totalBytes, bytesPerSecond, etaSeconds } = job.progress;
  const percent = totalBytes > 0 ? Math.min(100, Math.round((receivedBytes / totalBytes) * 100)) : -1;

  return (
    <div className="rounded-xl border border-duck-border bg-duck-surface p-2.5">
      <div className="flex items-center gap-2">
        <p className="min-w-0 flex-1 truncate text-[12px] font-semibold">{job.recipe.title}</p>
        <StateBadge state={job.state} />
      </div>

      {(active || job.state === 'paused') && (
        <>
          <div className="mt-2 h-1 overflow-hidden rounded-full bg-duck-border">
            <div
              className={`h-full rounded-full bg-duck-accent transition-[width] duration-300 ${
                percent < 0 ? 'animate-pulse' : ''
              }`}
              style={{ width: percent < 0 ? '100%' : `${percent}%` }}
            />
          </div>
          <p className="mt-1.5 flex items-center gap-2 text-[10px] tabular-nums text-duck-muted">
            {percent >= 0 && <span>{percent}%</span>}
            {totalBytes > 0 && (
              <span>
                {formatBytes(receivedBytes)} / {formatBytes(totalBytes)}
              </span>
            )}
            <span>{formatSpeed(bytesPerSecond)}</span>
            <span className="ml-auto">{formatEta(etaSeconds)}</span>
          </p>
        </>
      )}

      {/* The engine's own sentence. Never a status code, never a stack trace. */}
      {job.message && (
        <p
          className={`mt-1.5 text-[10px] leading-relaxed ${
            job.state === 'failed' ? 'text-duck-danger' : 'text-duck-muted'
          }`}
        >
          {job.message}
        </p>
      )}

      {job.state === 'completed' && job.finalPath && (
        <p className="mt-1.5 truncate text-[10px] text-duck-muted" title={job.finalPath}>
          {job.finalPath}
        </p>
      )}

      <div className="mt-2 flex flex-wrap gap-1.5">
        {active && <Action label="Pause" job={job} action="pause" />}
        {job.state === 'paused' && <Action label="Resume" job={job} action="resume" />}
        {(active || job.state === 'paused') && <Action label="Cancel" job={job} action="cancel" />}

        {/* Actions the engine says apply to this particular problem. */}
        {(job.actions ?? []).map((action) => (
          <ActionButton key={action} action={action} job={job} />
        ))}
      </div>
    </div>
  );
}

function ActionButton({ action, job }: { action: JobAction; job: JobRecord }) {
  switch (action) {
    case 'retry':
      return job.state === 'failed' ? <Action label="Try again" job={job} action="retry" /> : null;
    case 'remove':
      return <Action label="Remove" job={job} action="remove" />;
    case 'openSourcePage':
      return (
        <button
          type="button"
          onClick={() => void chrome.tabs.create({ url: job.recipe.pageUrl })}
          className={actionClass}
        >
          Open the page
        </button>
      );
    case 'refreshSource':
      return (
        <button
          type="button"
          onClick={() => void chrome.tabs.create({ url: job.recipe.pageUrl })}
          className={actionClass}
        >
          Reopen to refresh the link
        </button>
      );
    case 'chooseFolder':
      // Belongs to the desktop app, which owns destinations.
      return <span className="px-2 py-1 text-[10px] text-duck-muted">Free up space, then retry</span>;
    default:
      return null;
  }
}

const actionClass =
  'rounded-md px-2 py-1 text-[10px] font-semibold text-duck-muted transition hover:bg-duck-surface-hover hover:text-duck-text';

function Action({
  label,
  job,
  action,
}: {
  label: string;
  job: JobRecord;
  action: 'pause' | 'resume' | 'cancel' | 'remove' | 'retry' | 'reveal';
}) {
  return (
    <button
      type="button"
      onClick={() => void sendMessage('engine:action', { action, jobId: job.id })}
      className={actionClass}
    >
      {label}
    </button>
  );
}

const TONE: Record<JobState, string> = {
  queued: 'bg-duck-border text-duck-muted',
  preparing: 'bg-duck-border text-duck-muted',
  downloading: 'bg-duck-accent/15 text-duck-accent',
  paused: 'bg-duck-border text-duck-muted',
  waitingForSource: 'bg-amber-500/15 text-amber-400',
  retrying: 'bg-amber-500/15 text-amber-400',
  verifying: 'bg-duck-accent/15 text-duck-accent',
  completed: 'bg-emerald-500/15 text-emerald-400',
  failed: 'bg-duck-danger/15 text-duck-danger',
  canceled: 'bg-duck-border text-duck-muted',
};

/** Wording the user can act on, not the internal state name. */
const LABEL: Record<JobState, string> = {
  queued: 'Queued',
  preparing: 'Checking',
  downloading: 'Downloading',
  paused: 'Paused',
  waitingForSource: 'Needs the page',
  retrying: 'Retrying',
  verifying: 'Verifying',
  completed: 'Saved',
  failed: 'Stopped',
  canceled: 'Canceled',
};

function StateBadge({ state }: { state: JobState }) {
  return (
    <span className={`flex-none rounded px-1.5 py-0.5 text-[10px] font-semibold ${TONE[state]}`}>
      {LABEL[state]}
    </span>
  );
}
