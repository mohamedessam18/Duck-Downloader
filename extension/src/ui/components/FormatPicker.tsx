import { useState } from 'react';
import type { MediaCandidate, MediaFormat } from '@/core/types';
import { sendMessage } from '@/core/messaging';
import { formatBytes } from '../format';
import { BackIcon, DownloadIcon, MusicIcon, VideoIcon } from './Icons';

interface Props {
  candidate: MediaCandidate;
  onBack: () => void;
  onStarted: () => void;
}

export function FormatPicker({ candidate, onBack, onStarted }: Props) {
  const [busyId, setBusyId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const start = async (format: MediaFormat) => {
    setBusyId(format.id);
    setError(null);
    try {
      await sendMessage('download:start', { candidate, format });
      onStarted();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not start the download.');
    } finally {
      setBusyId(null);
    }
  };

  const video = candidate.formats.filter((format) => format.kind === 'video');
  const audio = candidate.formats.filter((format) => format.kind === 'audio');
  const unresolved = candidate.formats.length === 0;

  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-center gap-2">
        <button
          type="button"
          onClick={onBack}
          className="rounded-lg p-1.5 text-duck-muted transition hover:bg-duck-surface hover:text-duck-text"
          aria-label="Back"
        >
          <BackIcon />
        </button>
        <p className="min-w-0 flex-1 truncate text-[13px] font-semibold">{candidate.title}</p>
      </div>

      {error && (
        <p className="rounded-lg border border-duck-danger/40 bg-duck-danger/10 p-2 text-[11px] text-duck-danger">
          {error}
        </p>
      )}

      {unresolved ? (
        <AutoOption busy={busyId !== null} onStart={() => start(autoFormat())} />
      ) : (
        <>
          {video.length > 0 && (
            <Section title="Video" icon={<VideoIcon className="size-3.5" />}>
              {video.map((format) => (
                <FormatRow
                  key={format.id}
                  format={format}
                  busy={busyId === format.id}
                  onStart={() => start(format)}
                />
              ))}
            </Section>
          )}

          {audio.length > 0 && (
            <Section title="Audio" icon={<MusicIcon className="size-3.5" />}>
              {audio.map((format) => (
                <FormatRow
                  key={format.id}
                  format={format}
                  busy={busyId === format.id}
                  onStart={() => start(format)}
                />
              ))}
            </Section>
          )}
        </>
      )}
    </div>
  );
}

function Section({
  title,
  icon,
  children,
}: {
  title: string;
  icon: React.ReactNode;
  children: React.ReactNode;
}) {
  return (
    <section className="flex flex-col gap-1.5">
      <h2 className="flex items-center gap-1.5 px-0.5 text-[11px] font-semibold uppercase tracking-wide text-duck-muted">
        {icon}
        {title}
      </h2>
      <div className="flex flex-col gap-1">{children}</div>
    </section>
  );
}

function FormatRow({
  format,
  busy,
  onStart,
}: {
  format: MediaFormat;
  busy: boolean;
  onStart: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onStart}
      disabled={busy}
      className="flex items-center gap-2 rounded-lg border border-duck-border bg-duck-surface px-3 py-2 text-left transition hover:bg-duck-surface-hover disabled:opacity-60 focus:outline-none focus-visible:ring-2 focus-visible:ring-duck-accent"
    >
      <span className="flex-1 text-[13px] font-semibold">{format.label}</span>
      <span className="text-[11px] text-duck-muted">{format.ext.toUpperCase()}</span>
      {format.filesize ? (
        <span className="text-[11px] tabular-nums text-duck-muted">
          {formatBytes(format.filesize)}
        </span>
      ) : null}
      {/* Muxing happens off-device today, so it is worth being upfront that this
          particular pick takes a different route. */}
      {format.needsMux ? (
        <span className="rounded bg-duck-accent/10 px-1.5 py-0.5 text-[10px] font-semibold text-duck-accent">
          MERGE
        </span>
      ) : null}
      <DownloadIcon className={busy ? 'size-4 animate-pulse' : 'size-4 text-duck-muted'} />
    </button>
  );
}

function AutoOption({ busy, onStart }: { busy: boolean; onStart: () => void }) {
  return (
    <div className="flex flex-col gap-2">
      <p className="text-[11px] leading-relaxed text-duck-muted">
        Qualities for this one are worked out at download time. Start it and Duck picks the best
        available.
      </p>
      <button
        type="button"
        onClick={onStart}
        disabled={busy}
        className="flex items-center justify-center gap-2 rounded-xl bg-duck-accent px-3 py-2.5 text-[13px] font-bold text-black transition hover:brightness-105 disabled:opacity-60"
      >
        <DownloadIcon className="size-4" />
        {busy ? 'Starting…' : 'Download best quality'}
      </button>
    </div>
  );
}

function autoFormat(): MediaFormat {
  return {
    id: 'auto',
    label: 'Best',
    ext: 'mp4',
    kind: 'video',
    protocol: 'https',
    origin: 'popup-auto',
  };
}
