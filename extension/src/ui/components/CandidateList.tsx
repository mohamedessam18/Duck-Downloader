import type { MediaCandidate } from '@/core/types';
import { platformLabel } from '@/core/platform';
import { formatDuration } from '../format';
import { VideoIcon } from './Icons';

interface Props {
  candidates: MediaCandidate[];
  onSelect: (candidate: MediaCandidate) => void;
}

export function CandidateList({ candidates, onSelect }: Props) {
  return (
    <ul className="flex flex-col gap-1.5">
      {candidates.map((candidate) => (
        <li key={candidate.id}>
          <button
            type="button"
            onClick={() => onSelect(candidate)}
            className="group flex w-full items-center gap-3 rounded-xl border border-duck-border bg-duck-surface p-2 text-left transition hover:bg-duck-surface-hover focus:outline-none focus-visible:ring-2 focus-visible:ring-duck-accent"
          >
            <Thumbnail candidate={candidate} />
            <div className="min-w-0 flex-1">
              <p className="truncate text-[13px] font-semibold text-duck-text">
                {candidate.title}
              </p>
              <p className="mt-0.5 truncate text-[11px] text-duck-muted">
                {platformLabel(candidate.platform)}
                {candidate.author ? ` · ${candidate.author}` : ''}
                {candidate.durationSec ? ` · ${formatDuration(candidate.durationSec)}` : ''}
              </p>
            </div>
            <span className="rounded-lg bg-duck-accent/10 px-2 py-1 text-[11px] font-semibold text-duck-accent opacity-0 transition group-hover:opacity-100">
              Choose
            </span>
          </button>
        </li>
      ))}
    </ul>
  );
}

function Thumbnail({ candidate }: { candidate: MediaCandidate }) {
  if (!candidate.thumbnail) {
    return (
      <div className="flex size-14 flex-none items-center justify-center rounded-lg bg-duck-border text-duck-muted">
        <VideoIcon className="size-5" />
      </div>
    );
  }

  return (
    <img
      src={candidate.thumbnail}
      alt=""
      className="size-14 flex-none rounded-lg object-cover"
      // Thumbnails come from the page's own CDN and are the one thing here that
      // can 404 without it being our bug.
      onError={(event) => {
        event.currentTarget.style.visibility = 'hidden';
      }}
    />
  );
}
